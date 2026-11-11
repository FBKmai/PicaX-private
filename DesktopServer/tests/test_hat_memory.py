"""Small CPU numerical comparisons for Actions ONLY; never load checkpoints.

Run explicitly, not via the stdlib-only test_contracts entry point. Passing CPU
FP32 comparisons is not evidence of CUDA/BF16 performance or image quality.
"""
import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import numpy as np
import torch
from torch.utils._python_dispatch import TorchDispatchMode
from spandrel.architectures.HAT.__arch.HAT import HAT

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from picax_lan.hat_memory import install
from picax_lan.inference import quantize_output


class AttentionBounds(TorchDispatchMode):
    """Observe real eager matmuls/gathers, independently of scheduler counters."""
    def __init__(self, test, windows, heads, query, key):
        super().__init__()
        self.test, self.windows, self.heads, self.query, self.key = test, windows, heads, query, key
        self.gathers, self.scores = [], []

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        output = func(*args, **(kwargs or {}))
        if func is torch.ops.aten.index.Tensor and args[0].ndim == 6:
            self.gathers.append(output.shape[0])
            self.test.assertLessEqual(output.shape[0], self.windows)
        # inference_mode can expose aten.matmul directly instead of its bmm
        # decomposition. Observe either, including the explicit head dimension.
        if func in (torch.ops.aten.matmul.default, torch.ops.aten.bmm.default) and tuple(output.shape[-2:]) == (self.query, self.key):
            windows = output.numel() // (self.heads * self.query * self.key)
            self.scores.append(windows)
            self.test.assertLessEqual(windows, self.windows)
        return output


def small_hat(window_size=4, production_heads=False):
    return HAT(img_size=64, embed_dim=180 if production_heads else 60,
               depths=(2,), num_heads=(6 if production_heads else 2,),
               window_size=window_size, compress_ratio=3, squeeze_factor=6,
               overlap_ratio=0.5, mlp_ratio=2.0, drop_path_rate=0.0,
               upscale=2, num_feat=8).eval()


class HATMemoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def setUp(self):
        torch.manual_seed(1051)

    def close(self, expected, actual):
        torch.testing.assert_close(actual, expected, atol=2e-5, rtol=2e-5)

    def test_compact_mask_matches_every_original_entry(self):
        for window_size in (4, 16):
            with self.subTest(window_size=window_size), torch.inference_mode():
                original = small_hat(window_size)
                optimized = copy.deepcopy(original)
                install(optimized, 5)
                for h, w in ((window_size * 2, window_size * 3), (window_size, window_size)):
                    dense = original.calculate_mask((h, w), torch.float32)
                    labels = optimized.calculate_mask((h, w), torch.float32)
                    self.assertEqual(tuple(labels.shape), (h * w // window_size ** 2, window_size ** 2))
                    expanded = (labels.unsqueeze(1) != labels.unsqueeze(2)).float() * -100
                    torch.testing.assert_close(dense, expanded, atol=0, rtol=0)

    def test_window_attention_plain_shifted_multi_image_and_tail(self):
        for chunk in (1, 5, 32):
            for shifted in (False, True):
                for compact in (False, True):
                    with self.subTest(chunk=chunk, shifted=shifted, compact=compact), torch.inference_mode():
                        original = small_hat()
                        optimized = copy.deepcopy(original)
                        scheduler = install(optimized, chunk)
                        features = torch.randn(12, 16, 60)  # Two images, six windows each.
                        mask = original.calculate_mask((8, 12), features.dtype) if shifted else None
                        index = 1 if shifted else 0
                        expected = original.layers[0].residual_group.blocks[index].attn(
                            features, original.relative_position_index_SA, mask)
                        if shifted and compact:
                            mask = optimized.calculate_mask((8, 12), features.dtype)
                        attention = optimized.layers[0].residual_group.blocks[index].attn
                        with AttentionBounds(self, chunk, 2, 16, 16) as bounds, \
                             patch.object(attention.qkv, "forward", wraps=attention.qkv.forward) as qkv, \
                             patch.object(attention.proj, "forward", wraps=attention.proj.forward) as proj:
                            actual = attention(features, optimized.relative_position_index_SA, mask)
                        self.close(expected, actual)
                        expected_batches = [min(chunk, 12 - start) for start in range(0, 12, chunk)]
                        # Linear GEMM shapes must stay original for BF16 rounding;
                        # the quadratic attention must still obey the bound.
                        self.assertEqual([tuple(entry.args[0].shape) for entry in qkv.call_args_list], [(12, 16, 60)])
                        self.assertEqual([tuple(entry.args[0].shape) for entry in proj.call_args_list], [(12, 16, 60)])
                        self.assertEqual(bounds.scores, expected_batches)
                        self.assertEqual(scheduler.max_attention_windows, min(chunk, 12))

    def test_ocab_matches_zero_padding_and_window_order_without_full_unfold(self):
        for batch in (1, 2):
            for chunk in (1, 5, 64):
                with self.subTest(batch=batch, chunk=chunk), torch.inference_mode():
                    original = small_hat()
                    optimized = copy.deepcopy(original)
                    scheduler = install(optimized, chunk)
                    features = torch.randn(batch, 8 * 12, 60)
                    expected = original.layers[0].residual_group.overlap_attn(
                        features, (8, 12), original.relative_position_index_OCA)
                    with AttentionBounds(self, chunk, 2, 16, 36) as bounds, \
                         patch.object(torch.nn.Unfold, "forward", side_effect=AssertionError("Full-page im2col called")):
                        actual = optimized.layers[0].residual_group.overlap_attn(
                            features, (8, 12), optimized.relative_position_index_OCA)
                    self.close(expected, actual)
                    expected_batches = [min(chunk, batch * 6 - start) for start in range(0, batch * 6, chunk)]
                    self.assertEqual(bounds.gathers, expected_batches)
                    self.assertEqual(bounds.scores, expected_batches)
                    self.assertEqual(scheduler.max_kv_windows, min(chunk, batch * 6))
                    self.assertLessEqual(scheduler.max_attention_windows, chunk)

    def test_complete_hat_preserves_full_page_operations_and_state(self):
        for shape in ((1, 3, 8, 12), (2, 3, 9, 13)):
            with self.subTest(shape=shape), torch.inference_mode():
                original = small_hat()
                optimized = copy.deepcopy(original)
                keys = set(optimized.state_dict())
                scheduler = install(optimized, 5)
                features = torch.rand(shape)
                expected = original(features)
                with patch.object(torch.nn.Unfold, "forward", side_effect=AssertionError("Full-page im2col called")):
                    actual = optimized(features)
                self.close(expected, actual)
                self.assertEqual(tuple(actual.shape), (shape[0], 3, shape[2] * 2, shape[3] * 2))
                self.assertEqual(set(optimized.state_dict()), keys)
                for key, parameter in optimized.state_dict().items():
                    torch.testing.assert_close(parameter, original.state_dict()[key], atol=0, rtol=0)
                self.assertLessEqual(scheduler.metadata()["attentionMaxKVWindows"], 5)

    def test_production_head_dimension_and_16_24_window_geometry(self):
        with torch.inference_mode():
            original = small_hat(16, production_heads=True)
            optimized = copy.deepcopy(original)
            scheduler = install(optimized, 1)
            features = torch.rand(1, 3, 16, 32)
            expected = original(features)
            actual = optimized(features)
            self.close(expected, actual)
            self.assertEqual(scheduler.max_kv_windows, 1)
            self.assertEqual(scheduler.max_attention_windows, 1)

    def test_banded_output_matches_original_png_rounding_and_crop(self):
        for dtype in (torch.float32, torch.bfloat16):
            for rows in (1, 5, 128):
                with self.subTest(dtype=dtype, rows=rows), torch.inference_mode():
                    values = torch.tensor([-1.0, 0.0, 0.5 / 255, 1.5 / 255, 126.5 / 255,
                                           127.5 / 255, 254.5 / 255, 1.0, 2.0], dtype=dtype)
                    output = values.repeat(3 * 20 * 28 // 9 + 1)[:3 * 20 * 28].reshape(1, 3, 20, 28)[..., ::2]
                    self.assertFalse(output.is_contiguous())
                    old = output.clone()[0, :, :14, :10].cpu().float().clamp_(0, 1).numpy()
                    expected = np.rint(old.transpose(1, 2, 0) * 255.0).clip(0, 255).astype(np.uint8)
                    actual = quantize_output(output.clone(), 5, 7, 2, np, rows=rows)
                    np.testing.assert_array_equal(actual, expected)
                    self.assertEqual(actual.dtype, np.uint8)
                    self.assertEqual(actual.shape, (14, 10, 3))

    def test_patch_is_instance_local_and_rejects_training_or_reinstall(self):
        original = small_hat()
        optimized = copy.deepcopy(original)
        original_method = original.layers[0].residual_group.overlap_attn.forward.__func__
        install(optimized, 2)
        self.assertIs(original.layers[0].residual_group.overlap_attn.forward.__func__, original_method)
        self.assertIsNot(optimized.layers[0].residual_group.overlap_attn.forward.__func__, original_method)
        with self.assertRaisesRegex(RuntimeError, "unmodified"):
            install(optimized, 2)
        with self.assertRaisesRegex(RuntimeError, "inference_mode"):
            optimized(torch.rand(1, 3, 8, 12))
        with self.assertRaisesRegex(RuntimeError, "eval-mode"):
            install(small_hat().train(), 2)
        with patch("picax_lan.hat_memory.version", return_value="0.5.0"):
            with self.assertRaisesRegex(RuntimeError, "0.4.2"):
                install(small_hat(), 2)

    def test_sdpa_does_not_silently_fall_back_to_math(self):
        with torch.inference_mode():
            model = small_hat()
            scheduler = install(model, 2, "sdpa")
            with patch("torch.backends.cuda.can_use_cudnn_attention", return_value=False), \
                 patch("torch.backends.cuda.can_use_efficient_attention", return_value=False), \
                 patch("torch.backends.cuda.can_use_flash_attention", return_value=False), \
                 patch("torch.nn.functional.scaled_dot_product_attention") as sdpa:
                with self.assertRaisesRegex(RuntimeError, "Math fallback is disabled"):
                    model(torch.rand(1, 3, 8, 12))
                sdpa.assert_not_called()
            self.assertFalse(scheduler.sdpa_backends)

    def test_fused_path_pads_head_dim_but_preserves_scale_and_bias(self):
        # CPU math is used ONLY by this mocked oracle, never by production SDPA.
        from contextlib import nullcontext
        with torch.inference_mode():
            scheduler = install(small_hat(), 2, "sdpa")
            q, k, v = torch.randn(2, 2, 16, 30), torch.randn(2, 2, 36, 30), torch.randn(2, 2, 36, 30)
            bias, mask = torch.randn(2, 16, 36), torch.zeros(2, 1, 16, 36)
            mask[1, :, :, -4:] = -100
            scale = 30 ** -0.5
            expected = torch.nn.functional.scaled_dot_product_attention(q, k, v, attn_mask=bias.unsqueeze(0) + mask,
                                                                        scale=scale)
            with patch("torch.backends.cuda.can_use_cudnn_attention", return_value=True), \
                 patch("torch.nn.attention.sdpa_kernel", return_value=nullcontext()) as kernel:
                actual = scheduler.attend(q, k, v, bias, mask, scale)
            self.close(expected, actual)
            self.assertEqual(kernel.call_args.kwargs["backends"], [torch.nn.attention.SDPBackend.CUDNN_ATTENTION])
            self.assertEqual(scheduler.sdpa_backends, {"cudnn"})
            self.assertEqual(tuple(actual.shape), (2, 2, 16, 30))


if __name__ == "__main__":
    unittest.main()
