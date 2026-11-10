"""Real eager JaNai inference; heavyweight imports stay inside the worker."""
import importlib.util
import time
from pathlib import Path

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
        self.model = detected.model.eval().to(device=device, dtype=self.dtype)
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
        if self.settings["device"] == "cuda":
            # Attempt the actual single-page inference; no predicted VRAM veto.
            torch.cuda.reset_peak_memory_stats()
        with Image.open(source) as image:
            if image.mode == "RGBA":
                background = Image.new("RGB", image.size, "white")
                background.paste(image, mask=image.getchannel("A"))
                image = background
            array = np.asarray(image.convert("RGB"), dtype=np.float32).transpose(2, 0, 1) / 255.0
        array = self.full_page.pad_reflect(np, array, width, height, pw, ph)[None]
        with torch.inference_mode():
            tensor = torch.from_numpy(array).to(device=self.settings["device"], dtype=self.dtype)
            result = self.model(tensor)
            if tuple(result.shape) != (1, 3, ph * native, pw * native) or not bool(torch.isfinite(result).all().item()):
                raise RuntimeError("Invalid/nonfinite native model output")
            # NumPy cannot consume BF16 directly. Convert only after the GPU-to-CPU
            # copy, and quantize PNG pixels in FP32 for either inference dtype.
            pixels = result[0, :, :height * native, :width * native].detach().cpu().float().clamp_(0, 1).numpy()
            del result, tensor
        pixels = np.rint(pixels.transpose(1, 2, 0) * 255.0).clip(0, 255).astype(np.uint8)
        image = Image.fromarray(pixels)
        if scale < native:
            image = image.resize((width * scale, height * scale), Image.Resampling.LANCZOS)
        image.save(destination, format="PNG")
        if png_dimensions(destination, MAX_OUTPUT_BYTES, MAX_OUTPUT_PIXELS) != (width * scale, height * scale):
            raise RuntimeError("Encoded result dimensions mismatch")
        metadata = dict(self.metadata)
        if self.settings["device"] == "cuda":
            torch.cuda.synchronize()
            metadata.update({"peakAllocatedBytes": torch.cuda.max_memory_allocated(),
                             "peakReservedBytes": torch.cuda.max_memory_reserved()})
        metadata.update({"width": width * scale, "height": height * scale,
                         "deliveryScale": scale, "downsampling": "lanczos" if scale < native else "none",
                         "paddedWidth": pw, "paddedHeight": ph,
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
