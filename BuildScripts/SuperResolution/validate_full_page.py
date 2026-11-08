#!/usr/bin/env python3
"""Isolated full-page prediction workers and the validation orchestrator.

Every expensive prediction runs in its own process.  The parent applies a wall
clock timeout and (where the platform supports it) an address-space limit, then
compares the cropped Core ML output with the Torch output produced from exactly
the same padded input.  A crash, timeout or OOM is recorded for that size and
cannot terminate the remaining sizes or compute units.
"""

import argparse
import json
import sys
import time
import traceback
from pathlib import Path

import full_page


def _write_json(path, data):
    with Path(path).open("x", encoding="utf-8", newline="\n") as output:
        json.dump(data, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")


def _save_array(path, array):
    import numpy as np
    with Path(path).open("xb") as output:
        np.save(output, array)


def _crop(np, array, width, height):
    array = np.asarray(array)
    expected = (1, 3, height * 2, width * 2)
    if array.shape != expected:
        raise ValueError(f"model output shape {array.shape} != {expected}")
    if not np.isfinite(array).all():
        raise ValueError("model output contains non-finite values")
    return np.array(array, dtype=np.float32, copy=True, order="C")


def torch_worker(args):
    import io
    import numpy as np
    import torch

    torch.set_num_threads(1)
    started = time.monotonic()
    detected = full_page.load_detected(
        torch, io, np, args.model, args.weight, args.expected_sha256)
    model = full_page.make_wrapper(torch, detected)
    load_seconds = time.monotonic() - started
    padded_width, padded_height = full_page.padded_dimensions(
        args.width, args.height, args.alignment, args.max_side, args.max_pixels)
    page = full_page.calibration_page(np, args.width, args.height)
    padded = full_page.pad_reflect(
        np, page, args.width, args.height, padded_width, padded_height)
    sample = torch.from_numpy(np.ascontiguousarray(padded[None], dtype=np.float32))
    started = time.monotonic()
    with torch.no_grad():
        prediction = model(sample)
    prediction_seconds = time.monotonic() - started
    cropped = _crop(np, prediction.detach().cpu().numpy(), args.width, args.height)
    _save_array(args.output_npy, cropped)
    return {
        "status": "success", "backend": "PyTorch eager CPU",
        "model": args.model, "architecture": detected.architecture.id,
        "weightSHA256": args.expected_sha256,
        "loadSeconds": load_seconds, "predictionSeconds": prediction_seconds,
        "outputWidth": args.width * 2, "outputHeight": args.height * 2,
        "paddedInputDimensions": [padded_width, padded_height],
        "range": [float(cropped.min()), float(cropped.max())],
    }


def coreml_worker(args):
    import numpy as np
    import coremltools as ct

    units = {"cpuOnly": ct.ComputeUnit.CPU_ONLY,
             "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
             "all": ct.ComputeUnit.ALL}
    started = time.monotonic()
    model = ct.models.MLModel(str(args.package), compute_units=units[args.compute_unit])
    load_seconds = time.monotonic() - started
    padded_width, padded_height = full_page.padded_dimensions(
        args.width, args.height, args.alignment, args.max_side, args.max_pixels)
    page = full_page.calibration_page(np, args.width, args.height)
    padded = full_page.pad_reflect(
        np, page, args.width, args.height, padded_width, padded_height)
    sample = np.ascontiguousarray(padded[None], dtype=np.float32)
    started = time.monotonic()
    prediction = model.predict({"input": sample})
    prediction_seconds = time.monotonic() - started
    output = prediction["output"]
    if isinstance(output, np.ndarray):
        array = np.asarray(output)
    else:
        array = full_page.multiarray_to_numpy(np, output)
    cropped = _crop(np, array, args.width, args.height)
    _save_array(args.output_npy, cropped)
    return {
        "status": "success", "backend": "Core ML MLProgram float32",
        "computeUnit": args.compute_unit,
        "loadSeconds": load_seconds, "predictionSeconds": prediction_seconds,
        "outputWidth": args.width * 2, "outputHeight": args.height * 2,
        "paddedInputDimensions": [padded_width, padded_height],
        "range": [float(cropped.min()), float(cropped.max())],
    }


def worker_main(args):
    result = {"status": "started", "backend": args.kind,
              "width": args.width, "height": args.height}
    if args.kind == "coreml":
        result["computeUnit"] = args.compute_unit
    try:
        if args.kind == "torch":
            result.update(torch_worker(args))
        else:
            result.update(coreml_worker(args))
    except Exception as error:
        result.update({"status": "failed", "error": f"{type(error).__name__}: {error}",
                       "traceback": traceback.format_exc()[-4000:]})
    result["peakRSSBytes"] = full_page.peak_rss_bytes()
    try:
        _write_json(args.result_json, result)
    except FileExistsError:
        pass
    return 0 if result["status"] == "success" else 1


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    worker = subparsers.add_parser("worker", help="Run one prediction in this process")
    worker.add_argument("kind", choices=["torch", "coreml"])
    worker.add_argument("--model", choices=["manga", "color"])
    worker.add_argument("--weight", type=Path)
    worker.add_argument("--expected-sha256")
    worker.add_argument("--package", type=Path)
    worker.add_argument("--compute-unit", choices=["cpuOnly", "cpuAndGPU", "all"],
                        default="cpuOnly")
    worker.add_argument("--width", type=int, required=True)
    worker.add_argument("--height", type=int, required=True)
    worker.add_argument("--alignment", type=int, required=True)
    worker.add_argument("--max-side", type=int, required=True)
    worker.add_argument("--max-pixels", type=int, required=True)
    worker.add_argument("--result-json", type=Path, required=True)
    worker.add_argument("--output-npy", type=Path, required=True)
    validate = subparsers.add_parser("validate", help="Run all isolated size/unit trials")
    validate.add_argument("--model", choices=["manga", "color"], required=True)
    validate.add_argument("--weight", type=Path, required=True)
    validate.add_argument("--expected-sha256", required=True)
    validate.add_argument("--package", type=Path, required=True)
    validate.add_argument("--resource-name", required=True)
    validate.add_argument("--output-dir", type=Path, required=True)
    validate.add_argument("--size", action="append", required=True)
    validate.add_argument("--alignment", type=int, default=16)
    validate.add_argument("--max-side", type=int, default=2048)
    validate.add_argument("--max-pixels", type=int, default=2_000_000)
    validate.add_argument("--timeout", type=int, default=1800)
    validate.add_argument("--memory-mb", type=int, default=12288)
    validate.add_argument("--units", default="cpuOnly,cpuAndGPU,all")
    validate.add_argument("--all-units-at", action="append", default=["256x384", "1000x1500"])
    validate.add_argument("--max-abs-error", type=float, required=True)
    validate.add_argument("--max-mean-error", type=float, required=True)
    summary = subparsers.add_parser("summary", help="Print a Markdown summary of a report")
    summary.add_argument("report", type=Path)
    return parser


def summary_main(args):
    report = json.loads(args.report.read_text(encoding="utf-8"))
    print(f"### {report.get('model')} full-page Core ML")
    print(f"- status: **{report.get('status')}**; required CPU gate: "
          f"{report.get('requiredPassed')}; informational units: {report.get('informationalPassed')}")
    print(f"- scope: {report.get('scope')}")
    policy = report.get("workerPolicy", {})
    print(f"- isolated process per prediction: {policy.get('isolatedProcessPerPrediction')}; "
          f"timeout {policy.get('timeoutSeconds')}s; address-space limit "
          f"{policy.get('addressSpaceLimitMB')} MiB")
    print("| page | torch | unit | status | max err | mean err | P99 err | predict s | peak RSS MiB |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for label, entry in report.get("sizes", {}).items():
        torch = entry.get("torch") or {}
        print(f"| {label} | {torch.get('status')} | - | - | - | - | - | "
              f"{torch.get('predictionSeconds')} | {_mib(torch.get('peakRSSBytes'))} |")
        for unit, value in entry.get("units", {}).items():
            print(f"| {label} | - | {unit} | {value.get('status')} | "
                  f"{_number(value.get('maxAbsoluteError'))} | "
                  f"{_number(value.get('meanAbsoluteError'))} | "
                  f"{_number(value.get('p99AbsoluteError'))} | "
                  f"{value.get('predictionSeconds')} | {_mib(value.get('peakRSSBytes'))} |")
    return 0


def _number(value):
    return "-" if value is None else f"{value:.8g}"


def _mib(value):
    return "-" if value is None else f"{value / (1024 * 1024):.0f}"


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "worker":
            if args.alignment <= 0 or args.alignment & (args.alignment - 1):
                raise ValueError("alignment must be a positive power of two")
            if args.kind == "torch" and not (args.model and args.weight and args.expected_sha256):
                raise ValueError("torch workers require --model, --weight and --expected-sha256")
            if args.kind == "coreml" and not args.package:
                raise ValueError("coreml workers require --package")
            return worker_main(args)
        if args.command == "summary":
            return summary_main(args)
        return full_page.run_validation(args)
    except Exception as error:
        print(f"error: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
