"""Opt-in real CUDA + HTTPS end-to-end validation, bound to loopback only.

Uses the actual production pairing, transport, SQLite store and GPU worker.
No mock inference, no firewall edits, no LAN listener, no permanent server.
"""
import argparse
import hashlib
import json
import multiprocessing
from pathlib import Path
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(1, str(Path(__file__).resolve().parent / "tests"))
from picax_lan.auth import Pairing
from picax_lan.cli import ALIASES
from picax_lan.jobs import JobStore
from picax_lan.protocol import digest_file, validate_result
from picax_lan.worker import Worker
from http_harness import HTTPSHarness
from validate_local import make_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", choices=list(ALIASES), default="fdat-xl")
    parser.add_argument("--accept-noncommercial-license", action="store_true", required=True)
    args = parser.parse_args()
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        parser.error("Output directory must be new or empty")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    model = ALIASES[args.model]
    store = JobStore(args.output_dir / "server-data")
    settings = {"weights": {model.id: str((args.weights_dir / model.file).resolve())}, "device": "cuda", "noncommercial": True,
                "maximum_side": 4096, "maximum_pixels": 8_000_000, "timeout": 180}
    worker = Worker(store, settings)
    report = {"kind": "real-HTTPS-SQLite-CUDA-end-to-end", "passed": False, "cases": []}
    try:
        worker.start()
        with HTTPSHarness(store, worker, Pairing(store), settings) as transport:
            # The exact server leaf is verified before any pairing/token header.
            owner = str(uuid.uuid4())
            code, pairing = transport.request("POST", "/v1/pair", {"clientID": owner, "pairingSecret": transport.pairing.secret})
            if code != 200:
                raise RuntimeError("Pairing failed: " + str(code))
            token = pairing["token"]
            report["certificateSHA256"] = transport.fingerprint
            report["serverID"] = store.server_id
            def request(method, path, body=None, raw=False):
                code, response = transport.request(method, path, body, token=token, raw=raw)
                if code != 200:
                    raise RuntimeError("HTTP %s %s: %s" % (code, path, response))
                return response
            HTTPSHarness.wait(lambda: worker.model_states[model.id].get("ready") or worker.model_states[model.id].get("error") != "Not checked yet", 180)
            capabilities = request("GET", "/v1/capabilities")
            if not capabilities["models"][0]["ready"]:
                raise RuntimeError("CUDA worker failed: " + str(capabilities))
            report["capabilities"] = capabilities
            # Two successive large pages prove allocator-cache reuse. A native
            # 4x case proves the wire contract does not hard-code 2x output.
            cases = [(1000, 1500, 2), (1000, 1500, 2), (256, 384, 4)] if model.scale == 4 and args.model != "hat-l" else [(256, 384, 2)]
            for number, (width, height, scale) in enumerate(cases):
                started = time.monotonic()
                source = args.output_dir / ("source-%d.png" % number)
                make_fixture(source, width, height)
                page = {"id": "e0000-p0000", "chapterIndex": 0, "chapterTitle": "HTTPS validation", "pageIndex": 0,
                        "width": width, "height": height, "bytes": source.stat().st_size, "sha256": digest_file(source)}
                spec = {"version": 1, "jobID": str(uuid.uuid4()), "sourceRecordID": "loopback-validation", "title": "HTTPS CUDA validation",
                        "modelID": model.id, "modelSHA256": model.sha256, "nativeScale": model.scale,
                        "deliveryScale": scale, "mode": "fullPage", "pages": [page]}
                base = "/v1/jobs/" + spec["jobID"]
                request("POST", "/v1/jobs", spec)
                request("PUT", base + "/pages/" + page["id"], source.read_bytes(), raw=True)
                request("POST", base + "/commit")
                def completed():
                    status = request("GET", base)
                    if status["state"] == "partial":
                        raise RuntimeError("Real worker failed: " + str(status["pages"][0]["error"]))
                    return status if status["state"] == "completed" else None
                status = HTTPSHarness.wait(completed, 210)
                metadata = validate_result(status["pages"][0]["result"], spec, page)
                if metadata["device"] != "cuda":
                    raise RuntimeError("Unexpected CPU execution")
                output = request("GET", base + "/pages/" + page["id"] + "/result")
                if hashlib.sha256(output).hexdigest() != metadata["sha256"]:
                    raise RuntimeError("Result hash mismatch over HTTPS")
                destination = args.output_dir / ("received-%d.png" % number)
                destination.write_bytes(output)
                from PIL import Image
                with Image.open(destination) as image:
                    image.load()
                    if image.size != (width * scale, height * scale):
                        raise RuntimeError("Delivered dimensions incorrect")
                # ACK only after the received file exists and its hash matches.
                request("POST", base + "/pages/" + page["id"] + "/ack", {"sha256": metadata["sha256"]})
                if request("GET", base)["state"] != "acknowledged":
                    raise RuntimeError("Durable ACK did not finish the task")
                report["cases"].append({"input": [width, height], "deliveryScale": scale, "result": metadata,
                                        "roundTripSeconds": time.monotonic() - started, "passed": True})
                print("PASS HTTPS + CUDA", width, height, "->", metadata["width"], metadata["height"],
                      "%.3fs inference" % metadata["seconds"], flush=True)
            store.recover()
            report["restartRecoveryPassed"] = True
            report["passed"] = True
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        print("FAIL", report["error"], flush=True)
    finally:
        worker.stop()
        store.close()
        target = args.output_dir / "report.json"
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print("Report:", target.resolve(), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    multiprocessing.freeze_support()
    raise SystemExit(main())
