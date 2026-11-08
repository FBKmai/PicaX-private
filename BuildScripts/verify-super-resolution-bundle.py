#!/usr/bin/env python3
"""Audit build resources, not model accuracy, signature, or weight provenance.

An IPA without validated models is explicitly labelled an engineering build.
Actual Core ML feature/type checks happen at runtime, and numerical/device
validation is a separate macOS/device gate. This script never downloads models.
"""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit


LICENSES = {"CC-BY-NC-4.0", "CC-BY-NC-SA-4.0"}


def audit_bundle(app):
    app = Path(app).resolve()
    if not app.is_dir():
        raise ValueError("Built .app directory does not exist")
    manifests = sorted(app.rglob("*.superresolution.json"))
    records = []
    ids = set()
    resources = set()
    for path in manifests:
        # The iPhone runtime looks up these resources in Bundle.main, not an
        # arbitrary nested folder or embedded framework's bundle.
        if path.parent != app:
            raise ValueError(f"Descriptor must be a top-level iPhone app resource: {path.name}")
        model = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(model, dict):
            raise ValueError(f"Descriptor must be a JSON object: {path.name}")
        if model.get("validated") is not True:
            raise ValueError(f"Unvalidated descriptor must not be bundled: {path.name}")
        if not isinstance(model.get("id"), str) or not model["id"].strip() or model["id"] in ids:
            raise ValueError(f"Missing or duplicate model id: {path.name}")
        ids.add(model["id"])
        name = model.get("resourceName", "")
        if not isinstance(name, str) or len(name) > 160 or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ValueError(f"Invalid model resource name: {path.name}")
        if name in resources:
            raise ValueError(f"Duplicate model resource: {name}")
        resources.add(name)
        compiled = list(app.rglob(name + ".mlmodelc"))
        if len(compiled) != 1 or not compiled[0].is_dir() or compiled[0].parent != app:
            raise ValueError(f"Missing, nested, or ambiguous compiled model: {name}")
        if model.get("license") not in LICENSES:
            raise ValueError(f"Unresolved or unsupported weight license: {path.name}")
        digest = model.get("weightSHA256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise ValueError(f"Missing declared source weight SHA256: {path.name}")
        geometry = tuple(model.get(field) for field in ("tileSize", "overlap", "scale"))
        if not all(type(value) is int for value in geometry) or geometry != (128, 20, 2):
            raise ValueError(f"Unexpected tile contract: {path.name}")
        if (model.get("inputName"), model.get("outputName")) != ("input", "output"):
            raise ValueError(f"Unexpected feature names: {path.name}")
        preset = model.get("preset")
        if preset not in {"manga", "color"}:
            raise ValueError(f"Unexpected preset: {path.name}")
        if model.get("precision") not in {"float32", "float16"} or (preset == "manga" and model["precision"] != "float32"):
            raise ValueError(f"Unsupported precision: {path.name}")
        for field in ("version", "displayName", "sourceURL"):
            if not isinstance(model.get(field), str) or not model[field].strip():
                raise ValueError(f"Missing {field}: {path.name}")
        source = urlsplit(model["sourceURL"])
        if source.scheme.lower() != "https" or not source.hostname:
            raise ValueError(f"Expected HTTPS provenance with a host: {path.name}")
        lo, hi = model.get("minimumPageHeight"), model.get("maximumPageHeight")
        if preset == "manga" or lo is not None or hi is not None:
            if type(lo) is not int or type(hi) is not int or not 0 < lo <= hi:
                raise ValueError(f"Page height range must have two positive, ordered bounds: {path.name}")
        records.append(model)
    manga = sorted((r for r in records if r["preset"] == "manga"), key=lambda r: r["minimumPageHeight"])
    for first, second in zip(manga, manga[1:]):
        if first["maximumPageHeight"] >= second["minimumPageHeight"]:
            raise ValueError("Manga page-height ranges overlap")
    if sum(r["preset"] == "color" for r in records) > 1:
        raise ValueError("Color model selection is ambiguous")
    return {
        "schemaVersion": 1,
        "status": "validated-models-declared" if records else "engineering-build-no-models",
        "note": "Resource audit only. Declared validation and weight hashes are not independent numerical, license, device, or signature verification.",
        "models": records,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        report = audit_bundle(args.app)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"Super-resolution resource audit failed: {error}\n")
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Super-resolution resource status:", report["status"])
    if not report["models"]:
        print("WARNING: No validated Core ML models bundled. AI trials will report unavailable; this is not an AI quality-validation IPA.")


if __name__ == "__main__":
    main()
