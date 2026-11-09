"""Opt-in real model smoke test; never runs as part of lightweight unit tests.

Uses the production spawned worker, with a hard timeout and one GPU model at a
time. Generated text/line/noise fixtures test execution, not perceptual quality.
User-supplied pages may be passed with --source. No original files are modified.
"""
import argparse
import json
import multiprocessing
from pathlib import Path
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from picax_lan.cli import ALIASES
from picax_lan.inference import worker_main
from picax_lan.protocol import digest_file, page_id, validate_spec, validate_result


def make_fixture(path, width, height):
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (width, height), "#fff8ee")
    draw = ImageDraw.Draw(image)
    for row in range(height):
        color = (200 + row % 55, 180 + row * 3 % 65, 160 + row * 7 % 85)
        draw.line((width // 2, row, width - 1, row), fill=color)
    for x in range(8, width // 2, 7):
        draw.line((x, 8, width // 2 - x // 2, height - 8), fill="black", width=1)
    for y in range(20, height - 20, 29):
        draw.rectangle((12, y, min(width - 8, 240), y + 20), fill="white", outline="black")
        draw.text((16, y + 4), "PicaX AI SR 012345 abcXYZ", fill="black")
    image.save(path, format="PNG")


def reply(connection, process, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if connection.poll(0.25):
            return connection.recv()
        if not process.is_alive():
            raise RuntimeError("Model process exited: " + str(process.exitcode))
    raise TimeoutError("Model process exceeded %ss" % timeout)


def stop(process, connection):
    if process.is_alive():
        try:
            connection.send(None)
        except (EOFError, OSError):
            pass
        process.join(timeout=3)
    if process.is_alive():
        process.terminate()
        process.join(timeout=5)
    if process.is_alive():
        process.kill()
        process.join(timeout=2)
    connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--models", nargs="+", choices=list(ALIASES), default=["fdat-m", "fdat-xl", "hat-l"])
    parser.add_argument("--device", choices=["cuda", "cpu"], default="cuda")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--accept-noncommercial-license", action="store_true", required=True)
    args = parser.parse_args()
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        parser.error("Output directory must be new or empty")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    report = {"kind": "real-model-execution-not-perceptual-quality", "device": args.device, "models": []}
    weights = {ALIASES[key].id: str((args.weights_dir / ALIASES[key].file).resolve()) for key in args.models}
    settings = {"weights": weights, "device": args.device, "noncommercial": True,
                "maximum_side": 4096, "maximum_pixels": 8_000_000, "timeout": args.timeout}
    for alias in args.models:
        model = ALIASES[alias]
        entry = {"modelID": model.id, "checkpointSHA256": model.sha256, "cases": []}
        report["models"].append(entry)
        parent, child = multiprocessing.get_context("spawn").Pipe()
        process = multiprocessing.get_context("spawn").Process(target=worker_main, args=(child, dict(settings, model_id=model.id)))
        print("Loading", alias, "on", args.device, flush=True)
        process.start()
        child.close()
        try:
            loaded = reply(parent, process, 180)
            entry["startup"] = loaded
            if not loaded.get("ready"):
                raise RuntimeError(loaded.get("error", "Model did not initialize"))
            print("READY", json.dumps(loaded, ensure_ascii=False), flush=True)
            cases = [(128, 192, 2)]
            if model.scale == 4:
                cases.append((256, 384, 4))
            cases.append((512, 768, 2) if alias == "hat-l" else (1000, 1500, 2))
            if args.source:
                from PIL import Image
                with Image.open(args.source) as image:
                    cases = [(image.width, image.height, scale) for scale in model.delivery_scales]
            for number, (width, height, scale) in enumerate(cases):
                name = "%s-%dx%d-%dx" % (alias, width, height, scale)
                source, destination = args.output_dir / (name + "-input.png"), args.output_dir / (name + "-output.png")
                case = {"input": [width, height], "deliveryScale": scale, "passed": False}
                entry["cases"].append(case)
                if args.source:
                    from PIL import Image
                    with Image.open(args.source) as image:
                        image.convert("RGB").save(source, format="PNG")
                else:
                    make_fixture(source, width, height)
                page = {"id": page_id(0, 0), "chapterIndex": 0, "chapterTitle": "Diagnostic fixture", "pageIndex": 0,
                        "width": width, "height": height, "bytes": source.stat().st_size, "sha256": digest_file(source)}
                spec = {"version": 1, "jobID": str(uuid.uuid4()), "sourceRecordID": "local-diagnostic", "title": "PicaX GPU execution check",
                        "modelID": model.id, "modelSHA256": model.sha256, "nativeScale": model.scale,
                        "deliveryScale": scale, "mode": "fullPage", "pages": [page]}
                try:
                    validate_spec(spec, 4096, 8_000_000)
                    parent.send({"source": str(source.resolve()), "destination": str(destination.resolve()), "page": page, "spec": spec})
                    response = reply(parent, process, args.timeout)
                    if "error" in response:
                        raise RuntimeError(response["error"])
                    result = validate_result(response["result"], spec, page)
                    if result["device"] != args.device or digest_file(destination) != result["sha256"]:
                        raise RuntimeError("Device/hash mismatch")
                    from PIL import Image, ImageChops
                    with Image.open(destination) as output, Image.open(source) as original:
                        output.load()
                        if output.size != (width * scale, height * scale):
                            raise RuntimeError("Output dimensions incorrect")
                        baseline = original.resize(output.size, Image.Resampling.LANCZOS)
                        if ImageChops.difference(output.convert("RGB"), baseline).getbbox() is None:
                            raise RuntimeError("Output is identical to ordinary resizing")
                    case.update({"passed": True, "result": result, "output": str(destination.resolve())})
                    print("PASS", name, "%.3fs" % result["seconds"], "peak allocated %.2f GiB" % (result.get("peakAllocatedBytes", 0) / 1024**3), flush=True)
                except Exception as error:
                    case["error"] = type(error).__name__ + ": " + str(error)
                    print("FAIL", name, case["error"], flush=True)
                    if not process.is_alive():
                        break
                finally:
                    (args.output_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception as error:
            entry["error"] = type(error).__name__ + ": " + str(error)
            print("MODEL FAILED", alias, entry["error"], flush=True)
        finally:
            stop(process, parent)
            (args.output_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    passed = all(not item.get("error") and item["cases"] and all(case["passed"] for case in item["cases"]) for item in report["models"])
    print("Report:", (args.output_dir / "report.json").resolve(), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    multiprocessing.freeze_support()
    raise SystemExit(main())
