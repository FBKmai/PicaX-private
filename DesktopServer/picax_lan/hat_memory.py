"""Bounded HAT attention, not image tiling. Heavy imports stay in the worker.

Keep full-page convolutions/channel attention and every original attention edge.
Only independent windows are scheduled in smaller batches. No module-level
patches, checkpoint changes, full-page im2col, or implicit SDPA math fallback.
"""
from importlib.metadata import version
from types import MethodType

DEFAULT_WINDOW_BATCH = 128
BACKENDS = ("eager", "sdpa")


def validate_options(window_batch, backend):
    if type(window_batch) is not int or not 0 <= window_batch <= 4096:
        raise ValueError("--hat-window-batch must be 0..4096 (0 is the original diagnostic path)")
    if backend not in BACKENDS:
        raise ValueError("--hat-attention-backend must be eager or sdpa")
    if window_batch == 0 and backend != "eager":
        raise ValueError("Original HAT (--hat-window-batch 0) requires backend eager")


class WindowScheduler:
    def __init__(self, torch, partition, reverse, window_batch, backend):
        self.torch, self.partition, self.reverse = torch, partition, reverse
        self.window_batch, self.backend = window_batch, backend
        self.max_attention_windows = self.max_kv_windows = 0
        self.sdpa_choices = {}  # Shape/stride keys and enum values only, never tensors.
        self.sdpa_backends = set()

    def metadata(self):
        return {"attentionImplementation": "hat-window-batched-v1",
                "attentionWindowBatch": self.window_batch,
                "attentionBackend": self.backend,
                "attentionMaxWindows": self.max_attention_windows,
                "attentionMaxKVWindows": self.max_kv_windows,
                "sdpaBackends": sorted(self.sdpa_backends)}

    def guard(self, module):
        if module.training or self.torch.is_grad_enabled():
            raise RuntimeError("Bounded HAT attention requires eval() and inference_mode()/no_grad()")

    def compact_mask(self, module, x_size, dtype):
        """Same nine regions as HAT.calculate_mask, without the N x N expansion."""
        self.guard(module)
        h, w = x_size
        labels = self.torch.zeros((1, h, w, 1), dtype=dtype)
        slices = (slice(0, -module.window_size),
                  slice(-module.window_size, -module.shift_size),
                  slice(-module.shift_size, None))
        for row, hs in enumerate(slices):
            for col, ws in enumerate(slices):
                labels[:, hs, ws, :] = row * 3 + col
        return self.partition(labels, module.window_size).view(-1, module.window_size ** 2)

    def mask_chunk(self, mask, start, end, x):
        if mask is None:
            return None
        indices = self.torch.arange(start, end, device=x.device) % mask.shape[0]
        selected = mask.index_select(0, indices)
        if mask.ndim == 2:
            # HAT uses finite -100, not -inf. No full-page dense mask is built.
            return (selected.unsqueeze(1) != selected.unsqueeze(2)).to(x.dtype).mul_(-100).unsqueeze(1)
        if mask.ndim == 3:  # Also accept the original mask in standalone comparisons.
            return selected.unsqueeze(1)
        raise RuntimeError("Unexpected HAT attention mask shape")

    def attend(self, q, k, v, bias, mask, scale, dropout=None):
        self.max_attention_windows = max(self.max_attention_windows, q.shape[0])
        if q.shape[0] > self.window_batch:
            raise RuntimeError("HAT attention exceeded its window batch")
        if self.backend == "eager":
            # Preserve the original BF16 rounding order: scale Q before matmul.
            scores = (q * scale) @ k.transpose(-2, -1)
            scores.add_(bias.unsqueeze(0))
            if mask is not None:
                scores.add_(mask)
            probabilities = scores.softmax(dim=-1)
            del scores
            if dropout is not None:
                probabilities = dropout(probabilities)  # eval dropout is a no-op.
            return probabilities @ v
        return self.fused_attention(q, k, v, bias, mask, scale)

    def fused_attention(self, q, k, v, bias, mask, scale):
        from torch.nn.attention import SDPBackend, sdpa_kernel
        functional = self.torch.nn.functional
        original_dim = q.shape[-1]
        padding = (-original_dim) % 8
        if padding:
            q, k, v = (functional.pad(t, (0, padding)) for t in (q, k, v))
        additive = bias.unsqueeze(0)
        if mask is not None:
            additive = additive + mask  # Bounded by window_batch, never all windows.
        signature = (str(q.device), str(q.dtype), tuple(q.shape), tuple(k.shape),
                     tuple(q.stride()), tuple(k.stride()), tuple(v.stride()),
                     tuple(additive.shape), tuple(additive.stride()))
        choice = self.sdpa_choices.get(signature)
        if choice is None:
            cuda = self.torch.backends.cuda
            params = cuda.SDPAParams(q, k, v, additive, 0.0, False, False)
            candidates = ((SDPBackend.CUDNN_ATTENTION, cuda.can_use_cudnn_attention, "cudnn"),
                          (SDPBackend.EFFICIENT_ATTENTION, cuda.can_use_efficient_attention, "efficient"),
                          (SDPBackend.FLASH_ATTENTION, cuda.can_use_flash_attention, "flash"))
            for candidate, supported, label in candidates:
                if supported(params):
                    choice = candidate
                    self.sdpa_choices[signature] = choice
                    self.sdpa_backends.add(label)
                    break
            if choice is None:
                raise RuntimeError("No fused CUDA SDPA backend supports this HAT bias/mask/shape; "
                                   "select --hat-attention-backend eager. Math fallback is disabled")
        # Explicitly exclude MATH, including on an unsupported Windows wheel.
        with sdpa_kernel(backends=[choice]):
            result = functional.scaled_dot_product_attention(q, k, v, attn_mask=additive,
                                                            dropout_p=0.0, scale=scale)
        return result[..., :original_dim]

    def window_forward(self, module, x, rpi, mask=None):
        self.guard(module)
        count, tokens, channels = x.shape
        heads = module.num_heads
        if tokens != module.window_size[0] * module.window_size[1] or channels % heads:
            raise RuntimeError("Unexpected HAT window features")
        bias = module.relative_position_bias_table[rpi.reshape(-1)].view(tokens, tokens, heads)
        bias = bias.permute(2, 0, 1).contiguous()
        output = x.new_empty(x.shape)
        for start in range(0, count, self.window_batch):
            end = min(start + self.window_batch, count)
            qkv = module.qkv(x[start:end]).reshape(end - start, tokens, 3, heads, channels // heads)
            q, k, v = qkv.permute(2, 0, 3, 1, 4).unbind(0)
            chunk_mask = self.mask_chunk(mask, start, end, x)
            attended = self.attend(q, k, v, bias, chunk_mask, module.scale, module.attn_drop)
            attended = attended.transpose(1, 2).reshape(end - start, tokens, channels)
            output[start:end] = module.proj_drop(module.proj(attended))
            del qkv, q, k, v, attended, chunk_mask
        return output

    def overlap_forward(self, module, x, x_size, rpi):
        self.guard(module)
        torch = self.torch
        h, w = x_size
        batch, length, channels = x.shape
        ws, overlap, heads = module.window_size, module.overlap_win_size, module.num_heads
        if length != h * w or h % ws or w % ws or channels != module.dim:
            raise RuntimeError("Unexpected HAT overlapping-window features")
        shortcut = x
        normalized = module.norm1(x).view(batch, h, w, channels)
        qkv = module.qkv(normalized).reshape(batch, h, w, 3, channels).permute(3, 0, 4, 1, 2)
        queries = self.partition(qkv[0].permute(0, 2, 3, 1), ws).view(-1, ws * ws, channels)
        kv = torch.cat((qkv[1], qkv[2]), dim=1)
        del normalized, qkv
        padding = (overlap - ws) // 2
        kv = torch.nn.functional.pad(kv, (padding, padding, padding, padding))
        # Tensor.unfold is a strided VIEW; nn.Unfold/im2col materializes the page.
        grid = kv.unfold(2, overlap, ws).unfold(3, overlap, ws)
        rows, cols = h // ws, w // ws
        if tuple(grid.shape[2:4]) != (rows, cols):
            raise RuntimeError("HAT K/V grid differs from the original unfold contract")
        per_image, count = rows * cols, batch * rows * cols
        windows = queries.new_empty((count, ws * ws, channels))
        bias = module.relative_position_bias_table[rpi.reshape(-1)].view(ws * ws, overlap * overlap, heads)
        bias = bias.permute(2, 0, 1).contiguous()
        for start in range(0, count, self.window_batch):
            end = min(start + self.window_batch, count)
            indices = torch.arange(start, end, device=x.device)
            image_indices = indices // per_image
            window_indices = indices % per_image
            # Advanced indices materialize ONLY this chunk, before any reshape.
            patches = grid[image_indices, :, window_indices // cols, window_indices % cols]
            packed = patches.reshape(end - start, 2, channels, overlap, overlap)
            packed = packed.permute(1, 0, 3, 4, 2).reshape(2, end - start, overlap * overlap, channels)
            self.max_kv_windows = max(self.max_kv_windows, end - start)
            q = queries[start:end].reshape(end - start, ws * ws, heads, channels // heads).permute(0, 2, 1, 3)
            k, v = (part.reshape(end - start, overlap * overlap, heads, channels // heads).permute(0, 2, 1, 3)
                    for part in packed.unbind(0))
            attended = self.attend(q, k, v, bias, None, module.scale)
            windows[start:end] = attended.transpose(1, 2).reshape(end - start, ws * ws, channels)
            del indices, image_indices, window_indices, patches, packed, q, k, v, attended
        del queries, grid, kv, bias
        x = self.reverse(windows.view(-1, ws, ws, channels), ws, h, w).view(batch, h * w, channels)
        del windows
        x = module.proj(x) + shortcut
        return x + module.mlp(module.norm2(x))


def install(model, window_batch=DEFAULT_WINDOW_BATCH, backend="eager"):
    """Install atomically after validating the pinned implementation's structure."""
    validate_options(window_batch, backend)
    if window_batch == 0:
        return None
    if version("spandrel") != "0.4.2":
        raise RuntimeError("Bounded HAT attention requires the pinned spandrel==0.4.2")
    import torch
    from spandrel.architectures.HAT.__arch.HAT import HAT, OCAB, WindowAttention, window_partition, window_reverse

    if type(model) is not HAT or model.training or hasattr(model, "_picax_hat_memory"):
        raise RuntimeError("Expected an unmodified eval-mode Spandrel HAT")
    windows = [m for m in model.modules() if type(m) is WindowAttention]
    overlaps = [m for m in model.modules() if type(m) is OCAB]
    if not windows or not overlaps:
        raise RuntimeError("HAT attention modules are missing")
    for module in windows:
        if module.dim % module.num_heads or not all(hasattr(module, name) for name in
                ("qkv", "proj", "proj_drop", "attn_drop", "relative_position_bias_table", "scale")):
            raise RuntimeError("Unsupported HAT WindowAttention layout")
    def pair(value):
        return tuple(value) if isinstance(value, (tuple, list)) else (value, value)
    for module in overlaps:
        ws, overlap = module.window_size, module.overlap_win_size
        expected = {"kernel_size": (overlap, overlap), "stride": (ws, ws),
                    "padding": ((overlap - ws) // 2,) * 2, "dilation": (1, 1)}
        if overlap < ws or (overlap - ws) % 2 or module.dim % module.num_heads or any(
                pair(getattr(module.unfold, key)) != value for key, value in expected.items()):
            raise RuntimeError("Unsupported HAT OCAB unfold layout")
    scheduler = WindowScheduler(torch, window_partition, window_reverse, window_batch, backend)
    for module in windows:
        module.forward = MethodType(scheduler.window_forward, module)
    for module in overlaps:
        module.forward = MethodType(scheduler.overlap_forward, module)
    model.calculate_mask = MethodType(scheduler.compact_mask, model)
    model._picax_hat_memory = scheduler
    return scheduler
