#!/usr/bin/env python3
"""Full-page (non-tiled) JaNai Core ML conversion and isolated validation.

This module is imported by convert.py when ``--full-page`` is supplied and by
validate_full_page.py.  It intentionally has no heavyweight module-level
imports: the stdlib-only test suite imports convert.py without PyTorch or
coremltools installed.

Two things are kept separate on purpose:

* conversion (this module, called inside the conversion process) proves that a
  single full-page ``MLModel.prediction`` call can be produced from a dynamic
  Torch export and checks one small page numerically;
* validation (validate_full_page.py) runs every expensive prediction in its own
  subprocess with a timeout and an optional address-space limit, so one OOM or
  crash cannot take down the remaining experiments.

Neither step proves iPhone Duo behaviour.  The macOS Core ML evidence is
recorded with the compute unit that actually ran and is never labelled ANE.
"""

import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
FULL_PAGE_MINIMUM = 64
FULL_PAGE_EXAMPLE = (256, 384)
PNG_SCALE = 255.0


class FullPageValidationError(ValueError):
    """A conversion or validation result that must not be treated as success."""


def align_up(value, alignment):
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError("dimensions must be positive integers")
    if alignment <= 0 or alignment & (alignment - 1):
        raise ValueError("alignment must be a positive power of two")
    return (value + alignment - 1) // alignment * alignment


def padded_dimensions(width, height, alignment, maximum_side, maximum_pixels):
    """Return the aligned input size and reject pages outside the declared range."""
    padded_width = align_up(width, alignment)
    padded_height = align_up(height, alignment)
    if padded_width > maximum_side or padded_height > maximum_side:
        raise ValueError(
            f"{width}x{height} needs {padded_width}x{padded_height} aligned input, "
            f"above the {maximum_side}-pixel side limit")
    if padded_width * padded_height > maximum_pixels:
        raise ValueError(
            f"{width}x{height} needs {padded_width * padded_height} aligned pixels, "
            f"above the {maximum_pixels}-pixel limit")
    return padded_width, padded_height


def aligned_fallback_sizes(sizes, alignment, maximum_side, maximum_pixels):
    """Aligned, deduplicated sizes used only if flexible shapes cannot convert."""
    result = []
    for width, height in sizes:
        padded = padded_dimensions(width, height, alignment, maximum_side, maximum_pixels)
        if padded not in result:
            result.append(padded)
    return result


def reflected(coordinate, length):
    """Exactly the app's reflect mapping, including length=1 and far padding."""
    if length <= 0:
        raise ValueError("reflection requires a positive dimension")
    if length == 1:
        return 0
    position = coordinate % ((length - 1) * 2)
    return position if position < length else (length - 1) * 2 - position


def pad_reflect(np, image, width, height, padded_width, padded_height):
    """Reflect-pad right/bottom only, matching the iOS full-page path."""
    if image.shape != (3, height, width):
        raise ValueError(f"unexpected page shape {image.shape}")
    if padded_width == width and padded_height == height:
        return np.ascontiguousarray(image, dtype=np.float32)
    xs = [reflected(x, width) for x in range(padded_width)]
    ys = [reflected(y, height) for y in range(padded_height)]
    return np.ascontiguousarray(image[:, ys, :][:, :, xs], dtype=np.float32)


def calibration_page(np, width, height):
    """Deterministic engineering fixture; not a real manga page or art asset."""
    y, x = np.indices((height, width), dtype=np.float32)
    rng = np.random.default_rng(20261108)
    image = np.stack((x / max(width - 1, 1), y / max(height - 1, 1),
                      (x + y) / max(width + height - 2, 1)))
    image = image * 0.8 + rng.random(image.shape, dtype=np.float32) * 0.2
    lines = ((x + 2 * y) % 17 == 0) | ((x % 13 == 0) & (y > height / 3))
    image[:, lines] = 0.05
    dots = ((x % 5 == 0) & (y % 5 == 0) & (x > width / 2))
    image[:, dots] = 0
    image[:, (x < 2) | (y < 2)] = 0.9
    return np.ascontiguousarray(image, dtype=np.float32)


def seeded_input(np, torch, width, height):
    values = np.random.default_rng(20261108).random((1, 3, height, width), dtype=np.float32)
    return torch.from_numpy(np.ascontiguousarray(values))


def make_wrapper(torch, detected):
    """The same channel handling and clamp used by the tiled converter."""

    class RGBWrapper(torch.nn.Module):
        def __init__(self, model, monochrome):
            super().__init__()
            self.model = model
            self.monochrome = monochrome

        def forward(self, x):
            if self.monochrome:
                x = x.mean(dim=1, keepdim=True)
            x = self.model(x)
            if self.monochrome:
                x = x.repeat(1, 3, 1, 1)
            return x.clamp(0, 1)

    return RGBWrapper(detected.model.float().cpu().eval(),
                      detected.input_channels == 1).eval()


def load_detected(torch, io, np, model_name, path, expected_sha256):
    """Load a verified checkpoint; used by the isolated torch worker."""
    import hashlib
    from safetensors.torch import load as load_safetensors
    from spandrel import ImageModelDescriptor, ModelLoader, canonicalize_state_dict

    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_sha256:
        raise ValueError(f"checkpoint SHA-256 mismatch: observed {digest}")
    if Path(path).suffix.lower() == ".pth":
        state = torch.load(io.BytesIO(data), map_location="cpu", weights_only=True)
    else:
        state = load_safetensors(data)
    if not isinstance(state, dict):
        raise ValueError("checkpoint is not a state dictionary")
    detected = ModelLoader(device="cpu").load_from_state_dict(canonicalize_state_dict(state))
    if not isinstance(detected, ImageModelDescriptor):
        raise ValueError("checkpoint is not an image-to-image model")
    if detected.scale != 2 or detected.input_channels not in (1, 3):
        raise ValueError("checkpoint must be a 2x, 1- or 3-channel model")
    expected_architecture = "ESRGAN" if model_name == "manga" else "FDAT"
    if detected.architecture.id != expected_architecture:
        raise ValueError(f"unexpected architecture {detected.architecture.id}")
    return detected


def peak_rss_bytes():
    try:
        import resource
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    except (ImportError, OSError):
        return None
    # macOS reports bytes; Linux reports KiB.
    return int(value if sys.platform == "darwin" else value * 1024)


def multiarray_to_numpy(np, array):
    """Copy an MLMultiArray honoring its advertised strides, not just its shape."""
    import ctypes

    shape = tuple(int(value) for value in array.shape)
    strides = tuple(int(value) for value in array.strides)
    if any(stride < 0 for stride in strides):
        raise ValueError("MLMultiArray has a negative stride")
    # An MLMultiArray may be padded, so the reachable extent can be larger than
    # the product of its shape. Read the advertised extent before re-striding.
    span = 1 + sum((size - 1) * stride for size, stride in zip(shape, strides))
    pointer = ctypes.cast(array.dataPointer(), ctypes.POINTER(ctypes.c_float))
    flat = np.ctypeslib.as_array(pointer, shape=(span,)).copy()
    contiguous = all(stride == math.prod(shape[index + 1:])
                     for index, stride in enumerate(strides))
    if not contiguous:
        flat = np.lib.stride_tricks.as_strided(
            flat, shape=shape, strides=tuple(stride * 4 for stride in strides))
    return np.array(flat, dtype=np.float32, copy=True, order="C")


def compare_outputs(np, actual, expected, max_abs, max_mean):
    """App-visible cropped output versus the Torch reference on the same input."""
    actual = np.asarray(actual)
    expected = np.asarray(expected)
    if actual.shape != expected.shape:
        raise ValueError(f"shape mismatch: actual={actual.shape}, reference={expected.shape}")
    if actual.ndim != 4 or actual.shape[0] != 1 or actual.shape[1] != 3:
        raise ValueError(f"unexpected output shape {actual.shape}")
    if actual.dtype != np.float32 or expected.dtype != np.float32:
        raise ValueError(f"unexpected dtype: actual={actual.dtype}, reference={expected.dtype}")
    if not np.isfinite(actual).all() or not np.isfinite(expected).all():
        raise ValueError("non-finite output")
    difference = np.abs(actual.astype(np.float64) - expected.astype(np.float64))
    maximum = float(np.max(difference))
    mean = float(np.mean(difference))
    actual_low, actual_high = float(np.min(actual)), float(np.max(actual))
    reference_low, reference_high = float(np.min(expected)), float(np.max(expected))
    in_range = (actual_low >= 0 and actual_high <= 1
                and reference_low >= 0 and reference_high <= 1)
    return {
        "outputShape": list(actual.shape),
        "maxAbsoluteError": maximum,
        "meanAbsoluteError": mean,
        "p99AbsoluteError": float(np.percentile(difference, 99)),
        "actualRange": [actual_low, actual_high],
        "referenceRange": [reference_low, reference_high],
        "rangePassed": in_range,
        "passed": maximum <= max_abs and mean <= max_mean and in_range,
    }


def _shape_description(ct, array):
    flexibility = array.WhichOneof("ShapeFlexibility")
    description = {"shape": list(array.shape), "flexibility": flexibility}
    if flexibility == "shapeRange":
        description["shapeRange"] = [
            {"lowerBound": list(size.lowerBound), "upperBound": list(size.upperBound)}
            for size in array.shapeRange.sizeRanges]
    elif flexibility == "enumeratedShapes":
        description["enumeratedShapes"] = [
            list(shape.shape) for shape in array.enumeratedShapes.shapes]
    return description


def check_full_page_spec(ct, model, alignment, maximum_side, report):
    """Reject fixed or mismatched I/O; record the real flexible constraints."""
    spec = model.get_spec()
    features = (spec.description.input, spec.description.output)
    descriptions = []
    for entries, expected_name in zip(features, ("input", "output")):
        if len(entries) != 1:
            raise FullPageValidationError(f"expected exactly one {expected_name} feature")
        feature = entries[0]
        if feature.name != expected_name or feature.type.WhichOneof("Type") != "multiArrayType":
            raise FullPageValidationError(f"{expected_name} must be a named MLMultiArray")
        array = feature.type.multiArrayType
        if array.dataType != ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32:
            raise FullPageValidationError(f"{expected_name} must be float32")
        description = _shape_description(ct, array)
        if description["flexibility"] is None:
            raise FullPageValidationError(
                f"{expected_name} has a fixed shape; a full page would be rejected")
        descriptions.append(description)
    input_description, output_description = descriptions
    if input_description["flexibility"] == "shapeRange":
        ranges = input_description["shapeRange"]
        if len(ranges) != 4:
            raise FullPageValidationError("input shape range must have four dimensions")
        if ranges[0]["lowerBound"] != [1] or ranges[1]["lowerBound"] != [3]:
            raise FullPageValidationError("input must accept one three-channel image")
        for index in (2, 3):
            if ranges[index]["lowerBound"][0] > FULL_PAGE_MINIMUM:
                raise FullPageValidationError(
                    f"input dimension {index} lower bound is above {FULL_PAGE_MINIMUM}")
            if ranges[index]["upperBound"][0] < maximum_side:
                raise FullPageValidationError(
                    f"input dimension {index} upper bound is below the declared {maximum_side}")
    else:
        shapes = input_description.get("enumeratedShapes", [])
        if not shapes:
            raise FullPageValidationError("input enumerated shapes are empty")
        for shape in shapes:
            if len(shape) != 4 or shape[0] != 1 or shape[1] != 3:
                raise FullPageValidationError("enumerated input shape is not one 3-channel image")
            if shape[2] > maximum_side or shape[3] > maximum_side:
                raise FullPageValidationError("enumerated input shape exceeds the side limit")
            if shape[2] % alignment or shape[3] % alignment:
                raise FullPageValidationError("enumerated input shape is not aligned")
    report["input"] = input_description
    report["output"] = output_description
    return descriptions


def _export_aten(torch, model, example, dynamic_shapes):
    """Return an ATEN/EDGE ExportedProgram for coremltools 8.3.

    PyTorch 2.6's OSS rollout makes ``torch.export.export`` return the
    TRAINING dialect, which coremltools 8.3 rejects. Disable that rollout only
    for this call, then assert the actual dialect instead of assuming it.
    """
    import torch._utils_internal as internal

    original = getattr(internal, "export_training_ir_rollout_check", None)
    if original is not None:
        internal.export_training_ir_rollout_check = lambda: False
    try:
        program = torch.export.export(
            model, (example,), strict=False, dynamic_shapes=dynamic_shapes)
    finally:
        if original is not None:
            internal.export_training_ir_rollout_check = original
    dialect = str(getattr(program, "dialect", ""))
    if dialect not in ("ATEN", "EDGE"):
        raise FullPageValidationError(
            f"torch.export produced unsupported dialect {dialect!r}; "
            "coremltools 8.3 requires ATEN or EDGE")
    return program


def export_dynamic(torch, np, model, architecture, alignment, maximum_side):
    """Export a model whose spatial axes are constrained by the alignment."""
    from torch.export import Dim

    if maximum_side % alignment:
        raise ValueError("maximum side must be a multiple of the alignment")
    multiplier = 2 if architecture == "ESRGAN" else alignment
    if alignment % multiplier:
        raise ValueError("alignment must be a multiple of the architecture's divisibility")
    height_symbol = Dim("height", min=FULL_PAGE_MINIMUM // multiplier,
                        max=maximum_side // multiplier)
    width_symbol = Dim("width", min=FULL_PAGE_MINIMUM // multiplier,
                       max=maximum_side // multiplier)
    example_width, example_height = FULL_PAGE_EXAMPLE
    if example_width > maximum_side or example_height > maximum_side:
        example_width = maximum_side
        example_height = maximum_side
    example = seeded_input(np, torch, example_width, example_height)
    program = _export_aten(torch, model, example, ({2: multiplier * height_symbol,
                                                   3: multiplier * width_symbol},))
    constraints = {}
    for symbol, value_range in program.range_constraints.items():
        constraints[str(symbol)] = {"lower": str(value_range.lower),
                                    "upper": str(value_range.upper)}
    return program, multiplier, (example_width, example_height), constraints


def verify_export(torch, np, program, model, sizes):
    """The exported program must follow the eager model at more than one size."""
    results = {}
    module = program.module()
    for width, height in sizes:
        sample = seeded_input(np, torch, width, height)
        with torch.no_grad():
            expected = model(sample)
            actual = module(sample)
        results[f"{width}x{height}"] = compare_outputs(
            np, actual.detach().cpu().numpy(), expected.detach().cpu().numpy(),
            max_abs=1e-5, max_mean=1e-6)
    if not all(item["passed"] for item in results.values()):
        raise FullPageValidationError("exported program differs from the eager model")
    return results


def convert_flexible(np, ct, program, alignment, maximum_side, example):
    example_width, example_height = example
    return ct.convert(
        program, convert_to="mlprogram", skip_model_load=True,
        inputs=[ct.TensorType(
            name="input", dtype=np.float32,
            shape=ct.Shape(shape=(
                1, 3,
                ct.RangeDim(lower_bound=FULL_PAGE_MINIMUM, upper_bound=maximum_side,
                            default=example_height),
                ct.RangeDim(lower_bound=FULL_PAGE_MINIMUM, upper_bound=maximum_side,
                            default=example_width))))],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS16)


def convert_enumerated(np, ct, program, sizes, example):
    shapes = [(1, 3, height, width) for width, height in sizes]
    default = (1, 3, example[1], example[0])
    if default not in shapes:
        shapes.append(default)
    return ct.convert(
        program, convert_to="mlprogram", skip_model_load=True,
        inputs=[ct.TensorType(
            name="input", dtype=np.float32,
            shape=ct.EnumeratedShapes(shapes=shapes, default=default))],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS16)


def small_page_check(np, ct, compiled, model, torch, width, height, alignment,
                     maximum_side, maximum_pixels, max_abs, max_mean):
    """One CPU_ONLY prediction that mirrors the app's padding and crop."""
    padded_width, padded_height = padded_dimensions(
        width, height, alignment, maximum_side, maximum_pixels)
    page = calibration_page(np, width, height)
    padded = pad_reflect(np, page, width, height, padded_width, padded_height)
    sample = np.ascontiguousarray(padded[None], dtype=np.float32)
    with torch.no_grad():
        reference = model(torch.from_numpy(sample)).detach().cpu().numpy()
    prediction = compiled.predict({"input": sample})["output"]
    actual = prediction if isinstance(prediction, np.ndarray) else multiarray_to_numpy(np, prediction)
    reference = reference[:, :, :height * 2, :width * 2]
    actual = np.asarray(actual)[:, :, :height * 2, :width * 2]
    metrics = compare_outputs(np, actual, reference, max_abs, max_mean)
    metrics.update({"sourceDimensions": [width, height],
                    "paddedInputDimensions": [padded_width, padded_height],
                    "computeUnit": "CPU_ONLY", "backend": "Core ML MLProgram float32"})
    return metrics


def convert_full_page(np, torch, ct, model, architecture, args, package, package_hasher,
                      fallback_sizes):
    """Convert and smoke-test a genuine one-call full-page model.

    Raises on failure so convert.py does not emit a descriptor for a package
    whose shape contract was never verified.
    """
    report = {"fullPageConversion": {
        "alignment": args.full_page_alignment,
        "maximumSide": args.full_page_max_side,
        "maximumPixels": args.full_page_max_pixels,
        "minimumSide": FULL_PAGE_MINIMUM,
        "shapeMode": None,
        "fallbackReason": None,
    }}
    program, multiplier, example, constraints = export_dynamic(
        torch, np, model, architecture, args.full_page_alignment, args.full_page_max_side)
    report["fullPageConversion"].update({
        "dynamicDivisibility": multiplier,
        "exportDialect": str(program.dialect),
        "exampleSize": list(example),
        "exportRangeConstraints": constraints,
        "exportVsEager": verify_export(
            torch, np, program, model,
            [(128, 192), (256, 384), example]),
    })
    converted = None
    conversion_error = None
    try:
        converted = convert_flexible(
            np, ct, program, args.full_page_alignment, args.full_page_max_side, example)
        report["fullPageConversion"]["shapeMode"] = "range"
    except Exception as error:  # conversion errors are experiment evidence
        conversion_error = f"{type(error).__name__}: {error}"
        report["fullPageConversion"]["fallbackReason"] = conversion_error
    if converted is None:
        fallback = aligned_fallback_sizes(
            fallback_sizes, args.full_page_alignment,
            args.full_page_max_side, args.full_page_max_pixels)
        report["fullPageConversion"].update({
            "shapeMode": "enumerated",
            "enumeratedSizes": [list(size) for size in fallback],
        })
        try:
            converted = convert_enumerated(np, ct, program, fallback, example)
        except Exception as error:
            report["fullPageConversion"]["enumeratedConversionError"] = (
                f"{type(error).__name__}: {error}")
            raise FullPageValidationError(
                "neither flexible-range nor enumerated full-page conversion succeeded; "
                f"range error: {conversion_error}; enumerated error: {error}") from error
    check_full_page_spec(ct, converted, args.full_page_alignment,
                         args.full_page_max_side, report["fullPageConversion"])
    converted.save(str(package))
    report["packageSHA256"] = package_hasher(package)
    compiled = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    check_full_page_spec(ct, compiled, args.full_page_alignment,
                         args.full_page_max_side, report["fullPageConversion"])
    metrics = small_page_check(
        np, ct, compiled, model, torch, 256, 384, args.full_page_alignment,
        args.full_page_max_side, args.full_page_max_pixels,
        args.max_abs_error, args.max_mean_error)
    report["coreMLCpuVsTorch"] = {"full_page_256x384": metrics}
    report["numericComparisonPassed"] = metrics["passed"]
    report["fullPageValidation"] = (
        "NOT RUN: run validate_full_page.py in isolated workers for the required sizes, "
        "compute units, timing and peak memory")
    if not metrics["passed"]:
        raise FullPageValidationError(
            "Core ML full-page CPU output exceeds the preselected numerical limits")
    return report


# ---------------------------------------------------------------------------
# Isolated worker orchestration.  Called by validate_full_page.py.
# ---------------------------------------------------------------------------


def _worker_command(kind, arguments):
    return [sys.executable, str(SCRIPT_DIRECTORY / "validate_full_page.py"),
            "worker", kind, *arguments]


def _worker_environment():
    environment = os.environ.copy()
    environment.update({
        "PYTHONDONTWRITEBYTECODE": "1",
        "OMP_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "TOKENIZERS_PARALLELISM": "false",
    })
    return environment


def _run_worker(kind, arguments, run_directory, timeout, memory_mb):
    command = _worker_command(kind, arguments)
    started = time.monotonic()
    kwargs = {"cwd": str(run_directory), "env": _worker_environment(),
              "capture_output": True, "text": True, "timeout": timeout}
    if memory_mb > 0:
        try:
            import resource
            limit = memory_mb * 1024 * 1024

            def limit_address_space():
                resource.setrlimit(resource.RLIMIT_AS, (limit, limit))

            kwargs["preexec_fn"] = limit_address_space
        except ImportError:
            pass
    try:
        completed = subprocess.run(command, **kwargs)
        return {"returnCode": completed.returncode,
                "stdout": completed.stdout[-4000:], "stderr": completed.stderr[-4000:],
                "wallSeconds": time.monotonic() - started, "timedOut": False}
    except subprocess.TimeoutExpired as error:
        def decode(value):
            return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")
        return {"returnCode": None, "stdout": decode(error.stdout)[-4000:],
                "stderr": decode(error.stderr)[-4000:],
                "wallSeconds": time.monotonic() - started, "timedOut": True}


def _read_worker_result(result_path, run):
    if result_path.is_file():
        with result_path.open("r", encoding="utf-8") as source:
            return json.load(source)
    detail = "timeout" if run["timedOut"] else f"exit {run['returnCode']}"
    return {"status": "failed",
            "error": f"worker produced no result ({detail})",
            "stderr": run["stderr"], "stdout": run["stdout"]}


def _save_png(np, image, path):
    from PIL import Image
    pixels = np.clip(np.floor(image.transpose(1, 2, 0) * PNG_SCALE + 0.5), 0, 255).astype(np.uint8)
    Image.fromarray(pixels).save(path)


def _verify_page(model_name, width, height):
    if width < FULL_PAGE_MINIMUM or height < FULL_PAGE_MINIMUM:
        raise ValueError(f"validation size {width}x{height} is below the minimum")
    if height > width * 4:
        raise ValueError(f"validation size {width}x{height} violates the long-page rule")
    if model_name == "manga" and height <= width:
        raise ValueError(f"validation size {width}x{height} is not a portrait manga page")


def run_validation(args):
    """Run every expensive prediction in an isolated worker, then compare."""
    import numpy as np
    from PIL import Image  # noqa: F401 - fail early if PNG evidence cannot be written

    sizes = [tuple(int(part) for part in value.lower().split("x")) for value in args.size]
    for width, height in sizes:
        _verify_page(args.model, width, height)
    if not sizes:
        raise ValueError("at least one --size is required")
    output_directory = Path(args.output_dir).resolve()
    if not output_directory.is_dir():
        raise ValueError("output directory must already exist")
    run_directory = output_directory / "full-page-run"
    fixtures = output_directory / "full-page-fixtures"
    run_directory.mkdir(exist_ok=False)
    fixtures.mkdir(exist_ok=False)
    units = [value.strip() for value in args.units.split(",") if value.strip()]
    if "cpuOnly" not in units:
        raise ValueError("cpuOnly is required for the numerical gate")
    all_units_at = set()
    for value in args.all_units_at:
        all_units_at.add(tuple(int(part) for part in value.lower().split("x")))

    report = {
        "status": "started",
        "scope": ("macOS arm64 Core ML engineering evidence on synthetic fixtures; "
                  "not iPhone Duo acceptance and not visual-quality acceptance"),
        "model": args.model, "package": str(Path(args.package).resolve()),
        "alignment": args.alignment, "maximumSide": args.max_side,
        "maximumPixels": args.max_pixels,
        "thresholds": {"maxAbsoluteError": args.max_abs_error,
                       "meanAbsoluteError": args.max_mean_error},
        "workerPolicy": {
            "isolatedProcessPerPrediction": True, "timeoutSeconds": args.timeout,
            "addressSpaceLimitMB": args.memory_mb,
            "requiredUnits": ["cpuOnly"],
            "unitsAtEverySize": ["cpuOnly"],
            "additionalUnitsAt": [list(size) for size in sorted(all_units_at)],
            "allUnits": units,
        },
        "sizes": {},
    }

    for width, height in sizes:
        label = f"{width}x{height}"
        entry = {"sourceDimensions": [width, height], "torch": None, "units": {}}
        report["sizes"][label] = entry
        reference_path = run_directory / f"torch-{label}.npy"
        torch_result_path = run_directory / f"torch-{label}.json"
        run = _run_worker("torch", [
            "--model", args.model, "--weight", str(Path(args.weight).resolve()),
            "--expected-sha256", args.expected_sha256,
            "--width", str(width), "--height", str(height),
            "--alignment", str(args.alignment), "--max-side", str(args.max_side),
            "--max-pixels", str(args.max_pixels),
            "--result-json", str(torch_result_path), "--output-npy", str(reference_path),
        ], run_directory, args.timeout, args.memory_mb)
        torch_result = _read_worker_result(torch_result_path, run)
        torch_result["run"] = {key: run[key] for key in ("returnCode", "timedOut", "wallSeconds")}
        entry["torch"] = torch_result
        if torch_result.get("status") != "success":
            for unit in units:
                entry["units"][unit] = {"status": "not_run", "reason": "torch reference failed"}
            continue
        reference = np.load(reference_path)
        expected_shape = (1, 3, height * 2, width * 2)
        if reference.shape != expected_shape:
            raise FullPageValidationError(
                f"{label}: torch reference shape {reference.shape} != {expected_shape}")
        _save_png(np, reference[0], fixtures / f"{label}-torch.png")
        for unit in units:
            if unit != "cpuOnly" and (width, height) not in all_units_at:
                entry["units"][unit] = {"status": "not_run", "reason": "outside additional-unit sample"}
                continue
            output_path = run_directory / f"{label}-{unit}.npy"
            result_path = run_directory / f"{label}-{unit}.json"
            coreml_run = _run_worker("coreml", [
                "--package", str(Path(args.package).resolve()),
                "--width", str(width), "--height", str(height),
                "--alignment", str(args.alignment), "--max-side", str(args.max_side),
                "--max-pixels", str(args.max_pixels),
                "--compute-unit", unit,
                "--result-json", str(result_path), "--output-npy", str(output_path),
            ], run_directory, args.timeout, args.memory_mb)
            unit_result = _read_worker_result(result_path, coreml_run)
            unit_result["run"] = {key: coreml_run[key]
                                  for key in ("returnCode", "timedOut", "wallSeconds")}
            if unit_result.get("status") == "success":
                actual = np.load(output_path)
                if actual.shape != expected_shape:
                    unit_result = {"status": "failed",
                                   "error": f"output shape {actual.shape} != {expected_shape}"}
                else:
                    metrics = compare_outputs(
                        np, actual, reference, args.max_abs_error, args.max_mean_error)
                    unit_result.update(metrics)
                    unit_result["required"] = unit == "cpuOnly"
                    unit_result["status"] = ("passed" if metrics["passed"] else "failed")
                    _save_png(np, actual[0], fixtures / f"{label}-coreml-{unit}.png")
                output_path.unlink(missing_ok=True)
            else:
                unit_result["required"] = unit == "cpuOnly"
            entry["units"][unit] = unit_result
        reference_path.unlink(missing_ok=True)
        page = calibration_page(np, width, height)
        _save_png(np, page, fixtures / f"{label}-input.png")

    required = []
    for entry in report["sizes"].values():
        cpu_only = entry["units"].get("cpuOnly")
        required.append(bool(cpu_only and cpu_only.get("status") == "passed"))
    report["requiredPassed"] = all(required)
    report["informationalPassed"] = all(
        unit.get("status") in ("passed", "not_run")
        for entry in report["sizes"].values() for unit in entry["units"].values())
    report["status"] = "passed" if report["requiredPassed"] else "failed"
    report_path = output_directory / f"{args.resource_name}.fullpage.json"
    with report_path.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(report, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
    for label, entry in report["sizes"].items():
        torch_status = (entry["torch"] or {}).get("status", "missing")
        units = ", ".join(f"{unit}:{value.get('status')}"
                          for unit, value in entry["units"].items())
        print(f"{label} torch:{torch_status} {units}", flush=True)
    print(f"required numerical gate: {'PASS' if report['requiredPassed'] else 'FAIL'}", flush=True)
    print(f"report: {report_path}", flush=True)
    return 0 if report["requiredPassed"] else 1
