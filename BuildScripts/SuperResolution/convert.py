#!/usr/bin/env python3
"""Experimental JaNai -> Core ML conversion; see Docs/SuperResolution.md.

No checkpoint is downloaded and the result is never marked validated. The
implementation follows the pinned upstream converter's Spandrel path, but
loads checkpoint bytes itself with a verified SHA-256 and safe loaders.
"""

import argparse
import hashlib
import io
import json
import math
import platform
import re
import sys
from pathlib import Path

TILE_SIZE = 128
OVERLAP = 20  # INPUT pixels removed from EACH edge, not total tile overlap.
SCALE = 2
CONVERTER_REVISION = "68e3f51517e04433164c09d8505a409e26477905"
CONVERTER_SOURCE = (
    "https://github.com/imxieyi/waifu2x-ios-model-converter/blob/"
    + CONVERTER_REVISION + "/known_models.yaml"
)
MANGA_RELEASE = "https://github.com/the-database/MangaJaNai/releases/tag/1.0.0"
COLOR_RELEASE = "https://github.com/the-database/MangaJaNai/releases/tag/3.0.0"
MANGA_LICENSE = "UNRESOLVED: tag 1.0.0 CC-BY-NC-SA-4.0; current repository CC-BY-NC-4.0"
COLOR_LICENSE = "CC-BY-NC-4.0"

# These hashes are published by the pinned third-party converter, NOT a signed
# checksum from the weight author. They identify the individual checkpoints,
# not the release archives. File contents are still verified before loading.
MANGA_WEIGHTS = {
    1200: ("70k", "43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267"),
    1300: ("75k", "15ca3c0f75f97f7bf52065bf7c9b8d602de94ce9e3b078ac58793855eed18589"),
    1400: ("70k", "a940ad8ebcf6bea5580f2f59df67deb009f054c9b87dbbc58c2e452722f34858"),
    1500: ("90k", "d91f2d247fa61144c1634a2ba46926acd3956ae90d281a5bed6655f8364a5b2c"),
    1600: ("90k", "6f5923f812dbc5d6aeed727635a21e74cacddce595afe6135cbd95078f6eee44"),
    1920: ("70k", "1ad4aa6f64684baa430da1bb472489bff2a02473b14859015884a3852339c005"),
    2048: ("95k", "146cd009b9589203a8444fe0aa7195709bb5b9fdeaca3808b7fbbd5538f94c41"),
}
COLOR_WEIGHT = "8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0"
COLOR_FILE = "2x_IllustrationJaNai_V3detail_FDAT_M_unshuffle_40k_fp16.safetensors"
HEX_SHA = re.compile(r"[0-9a-f]{64}\Z")


def positive_int(value):
    value = int(value)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return value


def nonnegative_float(value):
    value = float(value)
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("must be finite and non-negative")
    return value


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, choices=["manga", "color"])
    parser.add_argument("--manga-height", type=int, choices=sorted(MANGA_WEIGHTS),
                        help="Nominal source page height for the chosen Manga checkpoint")
    parser.add_argument("--minimum-page-height", type=positive_int)
    parser.add_argument("--maximum-page-height", type=positive_int)
    parser.add_argument("--weight", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True,
                        help="Independently obtained individual checkpoint SHA-256")
    parser.add_argument("--precision", choices=["float32", "float16"], required=True,
                        help="Intermediate compute precision; tensor I/O is always float32")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="Staging directory outside the project and weight directories")
    parser.add_argument("--max-abs-error", type=nonnegative_float, required=True,
                        help="Preselected maximum allowed absolute error per sample")
    parser.add_argument("--max-mean-error", type=nonnegative_float, required=True,
                        help="Preselected maximum allowed mean absolute error per sample")
    parser.add_argument("--validate-tiles", action="store_true",
                        help="Also compare full-page Torch with real Core ML tiled predictions")
    parser.add_argument("--max-tile-abs-error", type=nonnegative_float)
    parser.add_argument("--max-tile-mean-error", type=nonnegative_float)
    parser.add_argument("--max-seam-mean-error", type=nonnegative_float)
    args = parser.parse_args(argv)
    tile_limits = (args.max_tile_abs_error, args.max_tile_mean_error, args.max_seam_mean_error)
    if args.validate_tiles != all(value is not None for value in tile_limits):
        parser.error("--validate-tiles requires all three explicit tile/seam limits")
    if not args.validate_tiles and any(value is not None for value in tile_limits):
        parser.error("tile/seam limits require --validate-tiles")
    if args.model == "manga":
        if args.manga_height is None or args.minimum_page_height is None or args.maximum_page_height is None:
            parser.error("manga requires --manga-height and explicit minimum/maximum page heights")
        if args.minimum_page_height > args.maximum_page_height:
            parser.error("minimum page height must not exceed maximum page height")
        if args.precision != "float32":
            parser.error("Manga ESRGAN requires float32 intermediate precision")
    elif any(x is not None for x in (args.manga_height, args.minimum_page_height, args.maximum_page_height)):
        parser.error("page-height options apply only to manga")
    args.expected_sha256 = args.expected_sha256.lower()
    if not HEX_SHA.fullmatch(args.expected_sha256):
        parser.error("expected SHA-256 must be 64 hexadecimal characters")
    return args


def model_info(args):
    if args.model == "manga":
        steps, digest = MANGA_WEIGHTS[args.manga_height]
        resource = f"MangaJaNai_V1_{args.manga_height}p_2x_float32"
        return {
            "filename": f"2x_MangaJaNai_{args.manga_height}p_V1_ESRGAN_{steps}.pth",
            "hash": digest, "architecture": "ESRGAN", "extension": ".pth",
            "id": f"mangajanai-v1-{args.manga_height}p-2x-float32",
            "resource": resource, "display": f"MangaJaNai V1 {args.manga_height}p 2×",
            "source": MANGA_RELEASE, "license": MANGA_LICENSE, "version": "1.0.0",
        }
    return {
        "filename": COLOR_FILE, "hash": COLOR_WEIGHT, "architecture": "FDAT",
        "extension": ".safetensors", "id": f"illustrationjanai-v3detail-fdat-m-2x-{args.precision}",
        "resource": f"IllustrationJaNai_V3detail_FDAT_M_2x_{args.precision}",
        "display": f"IllustrationJaNai V3detail FDAT M 2× ({args.precision})",
        "source": COLOR_RELEASE, "license": COLOR_LICENSE, "version": "3.0.0",
    }


def make_descriptor(args, info):
    return {
        "id": info["id"], "preset": args.model, "displayName": info["display"],
        "version": info["version"], "resourceName": info["resource"],
        "sourceURL": info["source"], "license": info["license"],
        "weightSHA256": info["hash"], "inputName": "input", "outputName": "output",
        "tileSize": TILE_SIZE, "overlap": OVERLAP, "scale": SCALE,
        "minimumPageHeight": args.minimum_page_height,
        "maximumPageHeight": args.maximum_page_height,
        "precision": args.precision, "validated": False,
    }


def ranges_overlap(first_min, first_max, second_min, second_max):
    return first_min <= second_max and second_min <= first_max


def check_existing_ranges(output, candidate):
    """Reject ambiguous Manga ranges already staged in this output directory."""
    if candidate["preset"] != "manga":
        return
    for path in output.glob("*.superresolution.json"):
        with path.open("r", encoding="utf-8") as source:
            other = json.load(source)
        if not isinstance(other, dict):
            raise ValueError(f"invalid existing descriptor: {path.name}")
        if other.get("preset") != "manga":
            continue
        low, high = other.get("minimumPageHeight"), other.get("maximumPageHeight")
        if type(low) is not int or type(high) is not int or low <= 0 or high < low:
            raise ValueError(f"invalid existing Manga range: {path.name}")
        if ranges_overlap(candidate["minimumPageHeight"], candidate["maximumPageHeight"], low, high):
            raise ValueError(f"Manga range overlaps existing descriptor: {path.name}")


def is_within(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def check_paths(weight, output):
    weight = weight.resolve(strict=True)
    output = output.resolve()
    project = Path(__file__).resolve().parents[2]
    if not weight.is_file():
        raise ValueError("weight path must be a regular file")
    if is_within(weight, project):
        raise ValueError("keep downloaded weights outside the project")
    if is_within(output, project):
        raise ValueError("stage output outside the project; never write directly to the app bundle")
    if is_within(output, weight.parent) or is_within(weight.parent, output):
        raise ValueError("weight and output directories must be separate, non-overlapping directories")
    return weight, output


def checked_weight_bytes(path, expected, pinned, extension):
    if expected != pinned:
        raise ValueError("caller SHA-256 does not match the pinned converter checkpoint hash")
    if path.suffix.lower() != extension:
        raise ValueError(f"checkpoint must have extension {extension}")
    # Load and hash the same bytes to avoid swapping the file between verification
    # and deserialization. The known JaNai checkpoints are smaller than 512 MiB.
    with path.open("rb") as source:
        data = source.read(512 * 1024 * 1024 + 1)
    if len(data) > 512 * 1024 * 1024:
        raise ValueError("checkpoint exceeds the 512 MiB safety limit")
    digest = hashlib.sha256(data).hexdigest()
    if digest != pinned:
        raise ValueError(f"checkpoint SHA-256 mismatch: observed {digest}")
    return data


def write_json(path, data):
    # Exclusive creation also prevents replacing a previous run's evidence.
    with path.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(data, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")


def package_sha256(path):
    """Hash relative names, lengths, and contents, independent of traversal order."""
    digest = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise ValueError("model package may not contain symlinks")
        if item.is_file():
            name = item.relative_to(path).as_posix().encode("utf-8")
            size = item.stat().st_size
            digest.update(len(name).to_bytes(8, "big"))
            digest.update(name)
            digest.update(size.to_bytes(8, "big"))
            with item.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def read_versions():
    from importlib import metadata
    requirements = Path(__file__).with_name("requirements-macos-arm64-py311.txt")
    versions = {}
    for line in requirements.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, rest = line.split("==", 1)
        expected = rest.split()[0]
        try:
            actual = metadata.version(name)
        except metadata.PackageNotFoundError as exc:
            raise RuntimeError(f"{name} is not installed; install the complete locked environment") from exc
        if actual != expected:
            raise RuntimeError(f"{name}: installed {actual}, lock requires {expected}")
        versions[name] = actual
    return versions


def require_environment():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("conversion/prediction requires macOS arm64; see the lock file")
    if sys.version_info[:3] != (3, 11, 9):
        raise RuntimeError("the pinned conversion environment requires CPython 3.11.9")
    if platform.python_implementation() != "CPython":
        raise RuntimeError("the pinned conversion environment requires CPython")
    return read_versions()


def synthetic_inputs(np):
    y, x = np.indices((TILE_SIZE, TILE_SIZE), dtype=np.float32)
    gradient = np.stack((x / 127, y / 127, (x + y) / 254))
    checker = (np.floor(x / 4) + np.floor(y / 7)) % 2
    lines = np.stack((checker, (x % 13 == 0).astype(np.float32),
                      ((x + 2 * y) % 17 == 0).astype(np.float32)))
    random = np.random.default_rng(20261108).random((3, TILE_SIZE, TILE_SIZE), dtype=np.float32)
    return {name: np.ascontiguousarray(value[None], dtype=np.float32)
            for name, value in (("gradient_rgb", gradient), ("lines_and_edges", lines), ("seeded_noise", random))}


def error_metrics(np, actual, expected, max_abs, max_mean):
    actual = np.asarray(actual)
    expected = np.asarray(expected)
    shape = (1, 3, TILE_SIZE * SCALE, TILE_SIZE * SCALE)
    if actual.shape != shape or expected.shape != shape:
        raise ValueError(f"unexpected output shape: actual={actual.shape}, reference={expected.shape}")
    if actual.dtype != np.float32 or expected.dtype != np.float32:
        raise ValueError(f"unexpected output dtype: actual={actual.dtype}, reference={expected.dtype}")
    if not np.isfinite(actual).all() or not np.isfinite(expected).all():
        raise ValueError("non-finite output")
    diff = np.abs(actual.astype(np.float64) - expected.astype(np.float64))
    maximum = float(np.max(diff))
    mean = float(np.mean(diff))
    low, high = float(np.min(actual)), float(np.max(actual))
    reference_low, reference_high = float(np.min(expected)), float(np.max(expected))
    in_range = low >= 0 and high <= 1 and reference_low >= 0 and reference_high <= 1
    return {"maxAbsoluteError": maximum, "meanAbsoluteError": mean,
            "p99AbsoluteError": float(np.percentile(diff, 99)),
            "actualRange": [low, high], "referenceRange": [reference_low, reference_high],
            "rangePassed": in_range,
            "passed": maximum <= max_abs and mean <= max_mean and in_range}


def check_coreml_spec(ct, model):
    spec = model.get_spec()
    expected = (("input", (1, 3, TILE_SIZE, TILE_SIZE)),
                ("output", (1, 3, TILE_SIZE * SCALE, TILE_SIZE * SCALE)))
    features = (spec.description.input, spec.description.output)
    for entries, (name, shape) in zip(features, expected):
        if len(entries) != 1:
            raise ValueError(f"expected exactly one {name} feature")
        feature = entries[0]
        if feature.name != name or feature.type.WhichOneof("Type") != "multiArrayType":
            raise ValueError(f"{name} must be a named MLMultiArray")
        array = feature.type.multiArrayType
        if (tuple(array.shape) != shape or
                array.dataType != ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32 or
                array.WhichOneof("ShapeFlexibility") is not None):
            raise ValueError(f"{name} must be float32 with fixed shape {shape}")


def reflected(coordinate, length):
    """Exactly the app's reflect mapping, including length=1 and far padding."""
    if length <= 0:
        raise ValueError("reflection requires a positive dimension")
    if length == 1:
        return 0
    position = coordinate % ((length - 1) * 2)
    return position if position < length else (length - 1) * 2 - position


def tile_positions(width, height):
    if width <= 0 or height <= 0:
        raise ValueError("page dimensions must be positive")
    core = TILE_SIZE - OVERLAP * 2
    return [(x, y, min(core, width - x), min(core, height - y))
            for y in range(0, height, core) for x in range(0, width, core)]


def reflected_window(np, image, x, y, width, height):
    page_height, page_width = image.shape[1:]
    xs = [reflected(x + offset, page_width) for offset in range(width)]
    ys = [reflected(y + offset, page_height) for offset in range(height)]
    return np.ascontiguousarray(image[:, ys, :][:, :, xs][None], dtype=np.float32)


def calibration_page(np, width, height):
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


def validate_tile_seams(np, torch, model, compiled, package, args):
    from PIL import Image
    results = {}
    fixtures = package.parent / "tile-fixtures"
    fixtures.mkdir(exist_ok=False)
    core = TILE_SIZE - OVERLAP * 2
    cases = {"multitile": (216, 344), "odd_small": (35, 49),
             "one_pixel": (1, 1), "one_column": (1, 19), "one_row": (31, 1)}
    for name, (width, height) in cases.items():
        page = calibration_page(np, width, height)
        # Round the full reference canvas to 128: this accommodates the
        # architectures' unshuffle/window divisibility without resizing pixels.
        padded_width = math.ceil((width + OVERLAP * 2) / TILE_SIZE) * TILE_SIZE
        padded_height = math.ceil((height + OVERLAP * 2) / TILE_SIZE) * TILE_SIZE
        full_input = reflected_window(np, page, -OVERLAP, -OVERLAP, padded_width, padded_height)
        with torch.no_grad():
            full = model(torch.from_numpy(full_input)).detach().cpu().numpy()
        if (full.shape != (1, 3, padded_height * SCALE, padded_width * SCALE)
                or full.dtype != np.float32 or not np.isfinite(full).all()
                or np.min(full) < 0 or np.max(full) > 1):
            raise ValueError("invalid full-page reference output")
        halo = OVERLAP * SCALE
        reference = full[0, :, halo:halo + height * SCALE, halo:halo + width * SCALE]
        assembled = np.empty((3, height * SCALE, width * SCALE), dtype=np.float32)
        torch_assembled = np.empty_like(assembled)
        tile_comparisons = []
        for x, y, tile_width, tile_height in tile_positions(width, height):
            sample = reflected_window(np, page, x - OVERLAP, y - OVERLAP, TILE_SIZE, TILE_SIZE)
            prediction = np.asarray(compiled.predict({"input": sample})["output"])
            # Compare the exact same window before attributing a seam failure
            # to Core ML conversion versus the model's limited tile context.
            with torch.no_grad():
                torch_tile = model(torch.from_numpy(sample)).detach().cpu().numpy()
            tile_comparisons.append(error_metrics(
                np, prediction, torch_tile, args.max_abs_error, args.max_mean_error))
            if (prediction.shape != (1, 3, TILE_SIZE * SCALE, TILE_SIZE * SCALE)
                    or prediction.dtype != np.float32 or not np.isfinite(prediction).all()
                    or np.min(prediction) < 0 or np.max(prediction) > 1):
                raise ValueError("invalid Core ML tile output, including discarded halo")
            assembled[:, y * SCALE:(y + tile_height) * SCALE, x * SCALE:(x + tile_width) * SCALE] = (
                prediction[0, :, halo:halo + tile_height * SCALE, halo:halo + tile_width * SCALE])
            torch_assembled[:, y * SCALE:(y + tile_height) * SCALE, x * SCALE:(x + tile_width) * SCALE] = (
                torch_tile[0, :, halo:halo + tile_height * SCALE, halo:halo + tile_width * SCALE])
        difference = np.abs(assembled.astype(np.float64) - reference.astype(np.float64))
        torch_difference = np.abs(torch_assembled.astype(np.float64) - reference.astype(np.float64))
        seams = np.zeros((height * SCALE, width * SCALE), dtype=bool)
        # Inspect a 4-output-pixel band centered on every internal join.
        for x in range(core, width, core):
            seams[:, x * SCALE - 2:x * SCALE + 2] = True
        for y in range(core, height, core):
            seams[y * SCALE - 2:y * SCALE + 2, :] = True
        seam_values, nonseam_values = difference[:, seams], difference[:, ~seams]
        maximum, mean = float(np.max(difference)), float(np.mean(difference))
        seam_mean = float(np.mean(seam_values)) if seam_values.size else 0.0
        results[name] = {
            "sourceDimensions": [width, height], "tileCount": len(tile_positions(width, height)),
            "maxAbsoluteError": maximum, "meanAbsoluteError": mean,
            "p99AbsoluteError": float(np.percentile(difference, 99)),
            "seamPixelCount": int(np.count_nonzero(seams)), "seamMeanAbsoluteError": seam_mean,
            "seamMaxAbsoluteError": float(np.max(seam_values)) if seam_values.size else None,
            "nonseamMeanAbsoluteError": float(np.mean(nonseam_values)) if nonseam_values.size else None,
            "coreMLVsTorchSameTiles": {
                "passed": all(item["passed"] for item in tile_comparisons),
                "maxAbsoluteError": max(item["maxAbsoluteError"] for item in tile_comparisons),
                "meanAbsoluteError": sum(item["meanAbsoluteError"] for item in tile_comparisons) / len(tile_comparisons),
                "tileCount": len(tile_comparisons),
            },
            "torchTiledVsFull": {
                "maxAbsoluteError": float(np.max(torch_difference)),
                "meanAbsoluteError": float(np.mean(torch_difference)),
                "seamMeanAbsoluteError": float(np.mean(torch_difference[:, seams])) if np.any(seams) else 0.0,
            },
            "passed": maximum <= args.max_tile_abs_error and mean <= args.max_tile_mean_error
                      and seam_mean <= args.max_seam_mean_error
                      and all(item["passed"] for item in tile_comparisons),
        }
        for suffix, value in (("input", page), ("torch-full", reference),
                              ("torch-tiled", torch_assembled), ("coreml-tiled", assembled)):
            pixels = np.floor(value.transpose(1, 2, 0) * 255 + 0.5).astype(np.uint8)
            Image.fromarray(pixels, "RGB").save(fixtures / f"{name}-{suffix}.png")
        print(f"Tile fixture {name}: {results[name]}", flush=True)
    return {"passed": all(item["passed"] for item in results.values()), "samples": results,
            "thresholds": {"maxAbsoluteError": args.max_tile_abs_error,
                           "maxMeanAbsoluteError": args.max_tile_mean_error,
                           "maxSeamMeanAbsoluteError": args.max_seam_mean_error},
            "scope": "synthetic CPU engineering evidence, not real-device or visual-quality acceptance"}


def run_conversion(args, info, weight_data, package, report):
    import numpy as np
    import torch
    import coremltools as ct
    from spandrel import ImageModelDescriptor, ModelLoader, canonicalize_state_dict
    from safetensors.torch import load as load_safetensors

    if info["extension"] == ".pth":
        state = torch.load(io.BytesIO(weight_data), map_location="cpu", weights_only=True)
    else:
        state = load_safetensors(weight_data)
    if not isinstance(state, dict):
        raise ValueError("checkpoint is not a state dictionary")
    state = canonicalize_state_dict(state)
    detected = ModelLoader(device="cpu").load_from_state_dict(state)
    if not isinstance(detected, ImageModelDescriptor):
        raise ValueError("checkpoint is not an image-to-image model")
    if detected.architecture.id != info["architecture"] or detected.scale != SCALE:
        raise ValueError(f"unexpected architecture or scale: {detected.architecture.id}, {detected.scale}")
    if detected.input_channels != detected.output_channels or detected.input_channels not in (1, 3):
        raise ValueError("checkpoint must have matching 1- or 3-channel input/output")
    if not detected.size_requirements.check(TILE_SIZE, TILE_SIZE):
        raise ValueError(f"tile size violates {detected.size_requirements}")
    report["detectedModel"] = {"architecture": detected.architecture.id, "scale": detected.scale,
                               "channels": detected.input_channels, "tags": list(detected.tags)}

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

    torch.set_num_threads(1)
    model = RGBWrapper(detected.model.float().cpu().eval(), detected.input_channels == 1).eval()
    samples = synthetic_inputs(np)
    reference = {}
    with torch.no_grad():
        for name, sample in samples.items():
            reference[name] = model(torch.from_numpy(sample)).detach().cpu().numpy()
        example = torch.from_numpy(samples["gradient_rgb"])
        traced = torch.jit.trace(model, example, check_trace=False)
        trace_results = {}
        for name, sample in samples.items():
            actual = traced(torch.from_numpy(sample)).detach().cpu().numpy()
            trace_results[name] = error_metrics(np, actual, reference[name], args.max_abs_error, args.max_mean_error)
    report["torchTraceVsEager"] = trace_results
    if not all(item["passed"] for item in trace_results.values()):
        raise ValueError("Torch trace differs from the eager reference beyond the supplied limits")

    converted = ct.convert(
        traced, convert_to="mlprogram", skip_model_load=True,
        inputs=[ct.TensorType(name="input", shape=(1, 3, TILE_SIZE, TILE_SIZE), dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT32 if args.precision == "float32" else ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )
    check_coreml_spec(ct, converted)
    converted.save(str(package))
    report["packageSHA256"] = package_sha256(package)
    compiled = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    check_coreml_spec(ct, compiled)
    for name, sample in samples.items():
        output = compiled.predict({"input": sample})["output"]
        report["coreMLCpuVsTorch"][name] = error_metrics(
            np, output, reference[name], args.max_abs_error, args.max_mean_error)
    report["numericComparisonPassed"] = all(
        item["passed"] for item in report["coreMLCpuVsTorch"].values())
    if not report["numericComparisonPassed"]:
        raise ValueError("Core ML CPU output exceeds the supplied numerical limits")
    if args.validate_tiles:
        report["tileSeamValidation"] = validate_tile_seams(np, torch, model, compiled, package, args)
        if not report["tileSeamValidation"]["passed"]:
            raise ValueError("full-page versus tiled output exceeds the preselected tile/seam limits")


def main(argv=None):
    args = parse_args(argv)
    info = model_info(args)
    try:
        versions = require_environment()
        weight, out = check_paths(args.weight, args.output_dir)
        data = checked_weight_bytes(weight, args.expected_sha256, info["hash"], info["extension"])
        out.mkdir(parents=True, exist_ok=True)
        check_existing_ranges(out, make_descriptor(args, info))
        package = out / (info["resource"] + ".mlpackage")
        descriptor_path = out / (info["resource"] + ".superresolution.json")
        report_path = out / (info["resource"] + ".validation.json")
        if any(path.exists() for path in (package, descriptor_path, report_path)):
            raise ValueError("refusing to overwrite existing output; use a new output directory")
        report = {
            "status": "started", "validated": False, "numericComparisonPassed": False,
            "tileSeamValidation": "NOT RUN: full-page versus tiled and real-device visual tests required",
            "licenseReview": "PENDING: check actual archive and intended distribution; see documentation",
            "model": info["id"], "weightSHA256": info["hash"], "checkpointFile": info["filename"],
            "checkpointHashSource": CONVERTER_SOURCE, "upstreamConverterRevision": CONVERTER_REVISION,
            "python": sys.version, "platform": platform.platform(), "dependencies": versions,
            "conversionScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "tileSize": TILE_SIZE, "overlapPerSide": OVERLAP, "scale": SCALE,
            "tensorIO": "float32 NCHW RGB [0,1]", "computePrecision": args.precision,
            "minimumDeploymentTarget": "iOS16", "computeUnit": "CPU_ONLY",
            "thresholds": {"maxAbsoluteError": args.max_abs_error, "maxMeanAbsoluteError": args.max_mean_error},
            "torchTraceVsEager": {}, "coreMLCpuVsTorch": {},
        }
        try:
            run_conversion(args, info, data, package, report)
            report["status"] = "numeric_comparison_passed_other_gates_pending"
        except Exception as exc:
            report["status"] = "failed"
            report["error"] = f"{type(exc).__name__}: {exc}"
        # A descriptor is emitted only if a saved package passed the structural
        # checks. Its validation flag remains false even when numbers pass.
        if package.is_dir() and "packageSHA256" in report:
            write_json(descriptor_path, make_descriptor(args, info))
        write_json(report_path, report)
        print(f"Report: {report_path}")
        if report["status"] == "failed":
            print(report["error"], file=sys.stderr)
            return 1
        print("Numerical comparison passed; descriptor remains UNVALIDATED. See the report and documentation.")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
