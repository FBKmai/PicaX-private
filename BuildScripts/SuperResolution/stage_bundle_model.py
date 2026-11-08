#!/usr/bin/env python3
"""Stage one validated full-page Core ML package for the unsigned personal build.

The input is the untouched artifact produced by validate_full_page.py. This
script verifies its pinned hashes and contract, then creates a copy whose
descriptor flips the two human-review assertions to true. It never downloads
anything and never edits the source artifact in place.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

SHA256 = re.compile(r"[0-9a-fA-F]{64}")
RESOURCE_NAME = re.compile(r"[A-Za-z0-9_-]+")
COLOR_LICENSE = "CC-BY-NC-4.0"
COLOR_WEIGHT_SHA256 = "8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0"
COLOR_PACKAGE_SHA256 = "94f6697f579a45e18fd9247b59e0fe236a52506b3e20807799747438a0b75b13"
FULL_PAGE_CONTRACT = {
    "shapeMode": "range",
    "alignment": 16,
    "minimumWidth": 64,
    "minimumHeight": 64,
    "maximumWidth": 2048,
    "maximumHeight": 2048,
    "maximumPixels": 2_000_000,
    "estimatedWorkingBytesPerPixel": 1024,
}
ATTRIBUTION_NAME = "SuperResolutionAttribution.txt"
ATTRIBUTION = """PicaX personal noncommercial super-resolution build

Model: IllustrationJaNai V3detail FDAT M 2x
Author / project: the-database / MangaJaNai
Source: https://github.com/the-database/MangaJaNai/releases/tag/3.0.0
License: Creative Commons Attribution-NonCommercial 4.0 International
         https://creativecommons.org/licenses/by-nc/4.0/

Changes: The original weights were converted to a Core ML ML Program
(float32, flexible full-page input) with coremltools 8.3.0. The FDAT graph
was specialized for inputs aligned to 16 pixels, removing runtime window
padding and an output crop that are empty for this input contract. The app
runs one full-page prediction and crops to the original page's 2x size.

This build is for the user's personal, noncommercial use. No endorsement by
the model authors is implied. The model is not sold or redistributed
commercially. MangaJaNai V1 (black-and-white) is not bundled because the
license of the 1.0.0 checkpoint remains unresolved.
"""


def _sha256_argument(value):
    if not SHA256.fullmatch(value):
        raise argparse.ArgumentTypeError("expected a 64-hex SHA-256")
    return value.lower()


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--preset", choices=("color",), default="color")
    parser.add_argument("--expected-weight-sha256", type=_sha256_argument, required=True)
    parser.add_argument("--expected-package-sha256", type=_sha256_argument, required=True)
    parser.add_argument("--validation-run-id", default=None)
    parser.add_argument("--artifact-name", default=None)
    return parser.parse_args(argv)


def package_sha256(path):
    """Match convert.package_sha256 on macOS without Windows path-order drift.

    The pinned hash was produced on macOS with POSIX path ordering. Sorting the
    relative path components keeps that ordering on every host platform.
    """
    files = []
    for item in path.rglob("*"):
        if item.is_symlink():
            raise ValueError("model package may not contain symlinks")
        if item.is_dir():
            continue
        if not item.is_file():
            raise ValueError(f"model package contains an unsupported entry: {item}")
        relative = item.relative_to(path).as_posix()
        files.append((tuple(relative.split("/")), relative, item))
    digest = hashlib.sha256()
    for _, relative, item in sorted(files, key=lambda entry: entry[0]):
        name = relative.encode("utf-8")
        size = item.stat().st_size
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(size.to_bytes(8, "big"))
        with item.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def _require_text(model, key):
    value = model.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"descriptor.{key} must be a non-empty string")
    return value


def _require_exact(model, key, expected):
    value = model.get(key)
    if value != expected or type(value) is not type(expected):
        raise ValueError(f"descriptor.{key} must be {expected!r}, got {value!r}")


def validate_descriptor(model, args):
    if not isinstance(model, dict):
        raise ValueError("descriptor must be a JSON object")
    _require_text(model, "id")
    _require_text(model, "displayName")
    _require_text(model, "version")
    _require_text(model, "sourceURL")
    source = urlsplit(model["sourceURL"])
    if source.scheme.lower() != "https" or not source.hostname:
        raise ValueError("descriptor.sourceURL must be HTTPS with a host")

    _require_exact(model, "preset", args.preset)
    _require_exact(model, "license", COLOR_LICENSE)
    _require_exact(model, "inputName", "input")
    _require_exact(model, "outputName", "output")
    _require_exact(model, "tileSize", 128)
    _require_exact(model, "overlap", 20)
    _require_exact(model, "scale", 2)
    _require_exact(model, "precision", "float32")
    _require_exact(model, "validated", False)
    _require_exact(model, "minimumPageHeight", None)
    _require_exact(model, "maximumPageHeight", None)

    weight = model.get("weightSHA256")
    if not isinstance(weight, str) or weight.lower() != args.expected_weight_sha256:
        raise ValueError("descriptor.weightSHA256 does not match the pinned validation weight")
    if args.expected_weight_sha256 != COLOR_WEIGHT_SHA256:
        raise ValueError("the pinned color weight SHA-256 changed; update this script deliberately")

    resource = model.get("resourceName")
    if (not isinstance(resource, str) or len(resource) > 160
            or not RESOURCE_NAME.fullmatch(resource)):
        raise ValueError("descriptor.resourceName is not a safe model resource name")

    capability = model.get("fullPage")
    if not isinstance(capability, dict):
        raise ValueError("descriptor.fullPage is required for a colour full-page model")
    if capability.get("validated") is not False:
        raise ValueError("refusing to approve a descriptor that is not in the pre-approval state")
    if "enumeratedSizes" in capability:
        raise ValueError("range-mode full-page descriptor must not declare enumerated sizes")
    for key, expected in FULL_PAGE_CONTRACT.items():
        _require_exact(capability, key, expected)
    return resource


def locate_inputs(artifact, args):
    if not artifact.is_dir():
        raise ValueError("artifact directory does not exist")
    descriptors = sorted(artifact.glob("*.superresolution.json"))
    if len(descriptors) != 1:
        raise ValueError("artifact must contain exactly one top-level *.superresolution.json")
    nested = [path for path in artifact.rglob("*.superresolution.json")
              if path.parent != artifact]
    if nested:
        raise ValueError("artifact contains a nested descriptor")
    descriptor_path = descriptors[0]
    if descriptor_path.is_symlink() or not descriptor_path.is_file():
        raise ValueError("descriptor must be a regular file")
    model = json.loads(descriptor_path.read_text(encoding="utf-8"))
    resource = validate_descriptor(model, args)
    packages = sorted(artifact.glob("*.mlpackage"))
    if len(packages) != 1 or packages[0].name != resource + ".mlpackage":
        raise ValueError("artifact must contain exactly the descriptor's .mlpackage at top level")
    package = packages[0]
    if package.is_symlink() or not package.is_dir():
        raise ValueError("model package must be a real directory")
    for required in ("Manifest.json", "Data/com.apple.CoreML/model.mlmodel"):
        if not (package / required).is_file():
            raise ValueError(f"model package is missing {required}")
    digest = package_sha256(package)
    if digest != args.expected_package_sha256:
        raise ValueError("model package SHA-256 does not match the pinned validation artifact")
    if args.expected_package_sha256 != COLOR_PACKAGE_SHA256:
        raise ValueError("the pinned color package SHA-256 changed; update this script deliberately")
    return descriptor_path, model, package, digest


def _is_within(path, folder):
    try:
        path.relative_to(folder)
        return True
    except ValueError:
        return False


def stage(args):
    artifact = args.artifact_dir.resolve()
    output = args.output_dir.resolve()
    if _is_within(output, artifact) or _is_within(artifact, output):
        raise ValueError("output directory must be separate from the artifact directory")
    descriptor_path, model, package, package_digest = locate_inputs(artifact, args)
    if output.exists():
        if not output.is_dir():
            raise ValueError("output path exists and is not a directory")
        if any(output.iterdir()):
            raise ValueError("output directory must be empty")
    approval = {
        "validationRunId": args.validation_run_id,
        "artifactName": args.artifact_name,
        "packageSHA256": package_digest,
        "weightSHA256": args.expected_weight_sha256,
        "scope": "personal noncommercial unsigned build; macOS numeric validation declared, "
                 "iPhone Duo runtime still unverified",
    }
    if args.validation_run_id is None:
        approval.pop("validationRunId")
    if args.artifact_name is None:
        approval.pop("artifactName")
    model = json.loads(json.dumps(model))
    model["validated"] = True
    model["fullPage"]["validated"] = True
    model["bundleApproval"] = approval

    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(package, output / package.name)
    (output / descriptor_path.name).write_text(
        json.dumps(model, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / ATTRIBUTION_NAME).write_text(ATTRIBUTION, encoding="utf-8")
    return {
        "descriptor": str(output / descriptor_path.name),
        "package": str(output / package.name),
        "attribution": str(output / ATTRIBUTION_NAME),
        "resourceName": model["resourceName"],
        "packageSHA256": package_digest,
        "weightSHA256": model["weightSHA256"],
        "validationRunId": args.validation_run_id,
        "artifactName": args.artifact_name,
    }


def main(argv=None):
    args = parse_args(argv)
    try:
        result = stage(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"Model staging failed: {error}\n")
    print("Staged validated colour full-page model:")
    for key, value in result.items():
        print(f"- {key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
