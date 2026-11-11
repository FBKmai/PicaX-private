"""Real eager JaNai inference; heavyweight imports stay inside the worker."""
import importlib.util
import json
import os
import time
from pathlib import Path

from .hat_memory import DEFAULT_WINDOW_BATCH, install, validate_options
from .models import LICENSE, SOURCE, configured_precision, get_model
from .protocol import (MAX_INPUT_BYTES, MAX_OUTPUT_BYTES, MAX_OUTPUT_PIXELS, MAX_PIXELS,
                       ProtocolError, digest_file, padded_dimensions, png_dimensions, validate_result)


def trusted_tooling():
    # Only load trusted repository code, never from weight/upload directories.
    directory = Path(__file__).resolve().parents[2] / "BuildScripts" / "SuperResolution"
    def module(name, file):
        spec = importlib.util.spec_from_file_location(name, directory / file)
        loaded = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(loaded)
        return loaded
    return module("picax_sr_contract", "convert.py"), module("picax_sr_full_page", "full_page.py")


def validate_png(path, expected):
    from PIL import Image
    if png_dimensions(path, MAX_INPUT_BYTES, MAX_PIXELS) != expected:
        raise ProtocolError("Decoded dimensions differ from manifest", 422)
    with Image.open(path) as image:
        if image.format != "PNG" or getattr(image, "n_frames", 1) != 1 or image.mode not in ("RGB", "RGBA"):
            raise ProtocolError("Expected a single RGB PNG", 422)
        image.verify()
    with Image.open(path) as image:
        image.load()
        if image.size != expected:
            raise ProtocolError("Invalid PNG", 422)


def quantize_output(result, width, height, native, np, rows=128):
    """Bound CPU FP32 temporaries to a row band; keep the original PNG rounding."""
    pixels = np.empty((height * native, width * native, 3), dtype=np.uint8)
    for start in range(0, height * native, rows):
        end = min(start + rows, height * native)
        band = result[0, :, start:end, :width * native].detach().cpu().float().clamp_(0, 1).numpy()
        band *= 255.0
        np.rint(band, out=band)
        np.clip(band, 0, 255, out=band)
        pixels[start:end] = band.transpose(1, 2, 0)
        del band
    return pixels


class Predictor:
    def __init__(self, settings):
        import numpy as np
        import torch
        from safetensors.torch import load
        from spandrel import ImageModelDescriptor, ModelLoader, canonicalize_state_dict

        if not settings["noncommercial"]:
            raise RuntimeError("Acknowledge CC-BY-NC-4.0 personal noncommercial use")
        model = self.descriptor = get_model(settings["model_id"])
        contract, self.full_page = trusted_tooling()
        weight = Path(settings["weights"][model.id]).resolve()
        data = contract.checked_weight_bytes(weight, model.sha256, model.sha256, ".safetensors")
        detected = ModelLoader(device="cpu").load_from_state_dict(canonicalize_state_dict(load(data)))
        del data
        if not isinstance(detected, ImageModelDescriptor) or detected.architecture.id != model.architecture or detected.scale != model.scale or detected.input_channels != 3 or detected.output_channels != 3:
            raise RuntimeError("Unexpected architecture, RGB channels or effective scale")
        requirements = detected.size_requirements
        if requirements.square or not requirements.check(64, 64) or model.alignment % requirements.multiple_of:
            raise RuntimeError("Checkpoint size requirements differ from the declared protocol")
        self.np, self.torch, self.settings = np, torch, settings
        precision = configured_precision(settings, model.id)
        self.dtype = getattr(torch, precision)
        supported_precisions = ["float32"]
        device = settings["device"]
        if device == "cuda":
            if not torch.cuda.is_available():
                raise RuntimeError("CUDA unavailable; install the pinned CUDA wheel/driver (no implicit CPU fallback)")
            capability = torch.cuda.get_device_capability()
            architecture = "sm_%d%d" % capability
            if capability[0] >= 12 and architecture not in torch.cuda.get_arch_list():
                raise RuntimeError("PyTorch wheel lacks " + architecture + "; use a Blackwell-compatible official wheel")
            torch.backends.cuda.matmul.allow_tf32 = False
            torch.backends.cudnn.allow_tf32 = False
            torch.backends.cudnn.benchmark = False
            name = torch.cuda.get_device_name()
            if detected.supports_bfloat16 and torch.cuda.is_bf16_supported(including_emulation=False):
                supported_precisions.append("bfloat16")
        elif device == "cpu":
            torch.set_num_threads(min(4, torch.get_num_threads()))
            name = "CPU (explicit diagnostic backend)"
        else:
            raise RuntimeError("Unsupported device")
        if precision not in supported_precisions:
            raise RuntimeError(f"{model.name} on {device} does not support {precision}; no implicit precision fallback")
        window_batch = settings.get("hat_window_batch", DEFAULT_WINDOW_BATCH)
        backend = settings.get("hat_attention_backend", "eager")
        validate_options(window_batch, backend)
        if device != "cuda" and backend == "sdpa":
            raise RuntimeError("Fused HAT SDPA requires CUDA; select the eager backend for CPU diagnostics")
        self.model = detected.model.eval().to(device=device, dtype=self.dtype)
        self.hat_memory = install(self.model, window_batch, backend) if model.architecture == "HAT" else None
        self.metadata = {
            # Decoder/transport capacity only; do not turn a startup free-VRAM
            # estimate into an input veto on the phone or the server.
            "maximumInputPixels": min(settings["maximum_pixels"], MAX_PIXELS),
            "modelID": model.id, "modelSHA256": model.sha256, "nativeScale": model.scale,
            "engine": "PyTorch", "device": device, "deviceName": name,
            "precision": precision, "supportedPrecisions": supported_precisions,
            "torchVersion": str(torch.__version__),
            "cudaVersion": str(torch.version.cuda or "none"),
            "license": LICENSE, "sourceURL": SOURCE, "mode": "fullPage",
        }
        if model.architecture == "HAT":
            self.metadata.update(self.hat_memory.metadata() if self.hat_memory else {
                "attentionImplementation": "spandrel-original", "attentionWindowBatch": 0,
                "attentionBackend": "eager", "sdpaBackends": []})

    def memory_snapshot(self):
        if self.settings["device"] != "cuda":
            return {}
        cuda = self.torch.cuda
        return {"allocatedBytes": cuda.memory_allocated(), "reservedBytes": cuda.memory_reserved(),
                "peakAllocatedBytes": cuda.max_memory_allocated(), "peakReservedBytes": cuda.max_memory_reserved()}

    def release_idle_cache(self, memory):
        """Release idle HAT cache only under observed pressure, never limit inputs.

        Mixed page sizes can retain several disjoint allocator pools on WDDM.
        This runs after output release/encoding, never inside model attention.
        Keep ordinary reusable cache; trim only if >=1 GiB is idle and reserved
        exceeds 80% of physical device memory. No live allocation is capped.
        """
        if self.settings["device"] != "cuda" or self.descriptor.architecture != "HAT" or self.hat_memory is None:
            return None
        reserved, allocated = memory["reservedBytes"], memory["allocatedBytes"]
        if reserved - allocated < 1024**3:
            return None
        total = self.torch.cuda.get_device_properties().total_memory
        if reserved * 5 <= total * 4:
            return None
        began = time.monotonic()
        self.torch.cuda.empty_cache()  # Only idle allocator blocks; model stays resident.
        after = self.memory_snapshot()
        return {"seconds": time.monotonic() - began, "before": dict(memory), "after": after,
                "deviceTotalBytes": total, "releasedBytes": max(0, reserved - after["reservedBytes"])}

    def diagnostic(self, phase, page, memory=None):
        if self.settings.get("diagnostics"):
            entry = {"phase": phase, "pid": os.getpid(), "width": page["width"], "height": page["height"],
                     "precision": self.metadata["precision"], "modelID": self.descriptor.id,
                     "windowBatch": self.metadata.get("attentionWindowBatch"),
                     "backend": self.metadata.get("attentionBackend"), "memory": memory or {}}
            print("LAN inference " + json.dumps(entry, ensure_ascii=False), flush=True)

    def predict(self, source, destination, page, spec):
        from PIL import Image
        np, torch, model = self.np, self.torch, self.descriptor
        started = time.monotonic()
        if spec["modelID"] != model.id or spec["modelSHA256"] != model.sha256 or spec["nativeScale"] != model.scale or spec["deliveryScale"] not in model.delivery_scales:
            raise RuntimeError("Job model contract changed")
        if spec.get("precision", "float32") != self.metadata["precision"]:
            raise RuntimeError("Job precision differs from the loaded worker; no implicit precision fallback")
        scale, native = spec["deliveryScale"], model.scale
        width, height = page["width"], page["height"]
        validate_png(source, (width, height))
        if digest_file(source) != page["sha256"]:
            raise RuntimeError("Stored input hash changed")
        pw, ph = padded_dimensions(width, height, model.alignment)
        if max(pw, ph) > self.settings["maximum_side"] or width * height > min(MAX_PIXELS, self.settings["maximum_pixels"]):
            raise RuntimeError("Page exceeds the configured input decoder limit")
        if width * height * scale**2 > MAX_OUTPUT_PIXELS:
            raise RuntimeError("Delivered image exceeds the phone's receive limits")
        cuda = self.settings["device"] == "cuda"
        if cuda:
            # Attempt the actual single-page inference; no predicted VRAM veto.
            torch.cuda.reset_peak_memory_stats()
        memory = {"pageStart": self.memory_snapshot()}
        self.diagnostic("pageStart", page, memory["pageStart"])
        with Image.open(source) as image:
            if image.mode == "RGBA":
                background = Image.new("RGB", image.size, "white")
                background.paste(image, mask=image.getchannel("A"))
                image = background
            array = np.asarray(image.convert("RGB"), dtype=np.float32).transpose(2, 0, 1) / 255.0
        array = self.full_page.pad_reflect(np, array, width, height, pw, ph)[None]
        with torch.inference_mode():
            tensor = torch.from_numpy(array).to(device=self.settings["device"], dtype=self.dtype)
            del array
            if cuda:
                model_start, model_end = (torch.cuda.Event(enable_timing=True) for _ in range(2))
                model_start.record()
            model_started = time.monotonic()
            result = self.model(tensor)
            if cuda:
                model_end.record()
            if tuple(result.shape) != (1, 3, ph * native, pw * native) or not bool(torch.isfinite(result).all().item()):
                raise RuntimeError("Invalid/nonfinite native model output")
            model_wall_seconds = time.monotonic() - model_started
            if cuda:
                # Boundary only; never synchronize within an attention chunk.
                model_end.synchronize()
                model_seconds = model_start.elapsed_time(model_end) / 1000.0
            else:
                model_seconds = model_wall_seconds
            memory["modelEnd"] = self.memory_snapshot()
            self.diagnostic("modelEnd", page, memory["modelEnd"])
            postprocess_started = time.monotonic()
            # BF16 -> CPU -> FP32 only within a bounded band. Never allocate a
            # full-page FP32 CUDA output or several full-page NumPy temporaries.
            pixels = quantize_output(result, width, height, native, np)
            del result, tensor
        memory["outputReleased"] = self.memory_snapshot()
        self.diagnostic("outputReleased", page, memory["outputReleased"])
        image = Image.fromarray(pixels)
        if scale < native:
            image = image.resize((width * scale, height * scale), Image.Resampling.LANCZOS)
        image.save(destination, format="PNG")
        if png_dimensions(destination, MAX_OUTPUT_BYTES, MAX_OUTPUT_PIXELS) != (width * scale, height * scale):
            raise RuntimeError("Encoded result dimensions mismatch")
        postprocess_seconds = time.monotonic() - postprocess_started
        cache_maintenance = self.release_idle_cache(memory["outputReleased"])
        if cache_maintenance is not None:
            memory["cacheReleased"] = cache_maintenance["after"]
            self.diagnostic("cacheReleased", page, memory["cacheReleased"])
        metadata = dict(self.metadata)
        if cache_maintenance is not None:
            metadata["cacheMaintenance"] = cache_maintenance
        if self.hat_memory is not None:
            metadata.update(self.hat_memory.metadata())
        if cuda:
            metadata.update({"peakAllocatedBytes": memory["outputReleased"]["peakAllocatedBytes"],
                             "peakReservedBytes": memory["outputReleased"]["peakReservedBytes"]})
        metadata.update({"width": width * scale, "height": height * scale,
                         "deliveryScale": scale, "downsampling": "lanczos" if scale < native else "none",
                         "paddedWidth": pw, "paddedHeight": ph, "workerPID": os.getpid(),
                         "modelSeconds": model_seconds, "modelWallSeconds": model_wall_seconds,
                         "postprocessSeconds": postprocess_seconds, "memoryStages": memory,
                         "bytes": destination.stat().st_size, "sha256": digest_file(destination),
                         "seconds": time.monotonic() - started})
        return validate_result(metadata, spec, page)


def worker_main(connection, settings):
    try:
        predictor = Predictor(settings)
        connection.send({"ready": True, "metadata": predictor.metadata})
    except Exception as error:
        connection.send({"ready": False, "error": str(error)[:1024]})
        connection.close()
        return
    while True:
        try:
            work = connection.recv()
        except EOFError:
            break
        if work is None:
            break
        try:
            metadata = predictor.predict(Path(work["source"]), Path(work["destination"]), work["page"], work["spec"])
            connection.send({"result": metadata})
        except Exception as error:
            if settings.get("diagnostics"):
                try:
                    predictor.diagnostic("error", work["page"], predictor.memory_snapshot())
                except Exception:
                    pass  # Diagnostics must never hide the original allocation/error.
            if settings["device"] == "cuda" and isinstance(error, predictor.torch.cuda.OutOfMemoryError):
                page = work["page"]
                precision = {"float32": "FP32", "bfloat16": "BF16"}[predictor.metadata["precision"]]
                message = (f"CUDA 显存实际不足：{predictor.descriptor.name} 处理单页 "
                           f"{page['width']}×{page['height']}，原生 {predictor.descriptor.scale}×、{precision}。"
                           "这是实际推理分配失败，不是输入像素预估拦截；未缩图、未分块、未换模型。"
                           f" {str(error)[:256]}")
            else:
                message = type(error).__name__ + ": " + str(error)[:768]
            connection.send({"error": message})
            if settings["device"] == "cuda":
                connection.close()
                return
    connection.close()
