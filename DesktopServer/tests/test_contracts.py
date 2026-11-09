"""Stdlib-only tests. No Torch, Pillow, network or GPU imports are required."""
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from picax_lan.identity import connection_url
from picax_lan.jobs import JobStore
from picax_lan.models import MODELS, LICENSE, SOURCE
from picax_lan.protocol import (ProtocolError, canonical, digest_file, identifier, local_address,
                                padded_dimensions, png_dimensions, reflected, validate_spec, validate_result)
from picax_lan.server import strict_json


def png(width=64, height=64):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = (b"\x00" + b"\x28\x50\x80" * width) * height
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def spec(model=MODELS[-1], scale=2, pages=1):
    source = png()
    return {"version": 1, "jobID": str(uuid.uuid4()), "sourceRecordID": "picacg-source", "title": "契约测试",
            "modelID": model.id, "modelSHA256": model.sha256, "nativeScale": model.scale,
            "deliveryScale": scale, "mode": "fullPage", "pages": [
                {"id": "e0000-p%04d" % index, "chapterIndex": 0, "chapterTitle": "第 1 章", "pageIndex": index,
                 "width": 64, "height": 64, "bytes": len(source), "sha256": hashlib.sha256(source).hexdigest()}
                for index in range(pages)]}


def result(body, page=None):
    page = page or body["pages"][0]
    scale = body["deliveryScale"]
    output = png(page["width"] * scale, page["height"] * scale)
    return {"modelID": body["modelID"], "modelSHA256": body["modelSHA256"], "nativeScale": body["nativeScale"],
            "deliveryScale": scale, "width": page["width"] * scale, "height": page["height"] * scale,
            "bytes": len(output), "sha256": hashlib.sha256(output).hexdigest(), "engine": "PyTorch", "device": "cpu",
            "deviceName": "explicit test fixture; no AI was run", "precision": "float32", "torchVersion": "test-only",
            "cudaVersion": "none", "license": LICENSE, "sourceURL": SOURCE, "mode": "fullPage",
            "downsampling": "lanczos" if scale < body["nativeScale"] else "none", "seconds": 1.0}


class ProtocolTests(unittest.TestCase):
    def test_all_models_and_delivery_scales(self):
        for model in MODELS:
            for scale in model.delivery_scales:
                body = spec(model, scale)
                self.assertIs(validate_spec(body), body)
                validate_result(result(body), body, body["pages"][0])

    def test_manifest_version_is_not_boolean(self):
        body = spec(); body["version"] = True
        with self.assertRaises(ProtocolError): validate_spec(body)

    def test_native_and_delivery_scale_are_distinct(self):
        body = spec(MODELS[0], 2)
        self.assertEqual(result(body)["width"], 128)
        self.assertEqual(result(body)["downsampling"], "lanczos")
        body["nativeScale"] = 2
        with self.assertRaises(ProtocolError): validate_spec(body)

    def test_no_unknown_model_or_sha(self):
        for key, value in (("modelID", "arbitrary"), ("modelSHA256", "0" * 64), ("mode", "tiled")):
            body = spec(); body[key] = value
            with self.subTest(key=key), self.assertRaises(ProtocolError): validate_spec(body)

    def test_no_duplicate_or_sparse_pages(self):
        for index in (0, 3):
            body = spec(pages=2); body["pages"][1]["id"] = "e0000-p%04d" % index; body["pages"][1]["pageIndex"] = index
            with self.assertRaises(ProtocolError): validate_spec(body)

    def test_noncompact_chapters_rejected(self):
        body = spec(); body["pages"][0].update(id="e0002-p0000", chapterIndex=2)
        with self.assertRaises(ProtocolError): validate_spec(body)

    def test_output_budget_and_alignment_checked(self):
        body = spec(MODELS[-2], 4); body["pages"][0].update(width=1500, height=1500)
        with self.assertRaises(ProtocolError): validate_spec(body)
        body = spec(); body["pages"][0].update(width=65, height=64)
        with self.assertRaises(ProtocolError): validate_spec(body, maximum_pixels=4096)

    def test_identity_result_dimensions_and_provenance(self):
        body = spec()
        for key, value in (("width", 127), ("modelID", MODELS[0].id), ("device", "fake"),
                           ("sourceURL", "https://example.com"), ("seconds", float("nan")), ("deliveryScale", True)):
            candidate = result(body); candidate[key] = value
            with self.subTest(key=key), self.assertRaises(ProtocolError): validate_result(candidate, body, body["pages"][0])

    def test_lan_address_allowlist(self):
        for address in ("192.168.1.2", "10.0.0.1", "172.31.1.2", "fc00::1"):
            self.assertEqual(local_address(address), address)
        for address in ("127.0.0.1", "0.0.0.0", "8.8.8.8", "100.64.1.2", "224.0.0.1", "::1", "example.local"):
            with self.subTest(address=address), self.assertRaises(ProtocolError): local_address(address)
        self.assertEqual(local_address("127.0.0.1", allow_loopback=True), "127.0.0.1")

    def test_path_and_uuid_rejection(self):
        for value in ("../test", "{}", True, str(uuid.uuid4()).upper()):
            with self.assertRaises(ProtocolError): identifier(value)

    def test_reflection_works_for_small_dimensions(self):
        self.assertEqual([reflected(x, 3) for x in range(9)], [0, 1, 2, 1, 0, 1, 2, 1, 0])
        self.assertEqual(reflected(10000, 1), 0)
        self.assertEqual(padded_dimensions(65, 1, 64), (128, 64))

    def test_json_duplicate_nonfinite_and_bad_encoding(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}', b'\xff'):
            with self.assertRaises(ProtocolError): strict_json(data)
        with self.assertRaises(ValueError): canonical({"a": float("nan")})

    def test_swift_python_allowlists_match(self):
        root = Path(__file__).resolve().parents[2]
        text = (root / "PicaX/Services/LanSuperResolution/LanSuperResolutionModels.swift").read_text(encoding="utf-8")
        found = re.findall(r'"(illustrationjanai-[^"]+)": \("([0-9a-f]{64})", ([24])\)', text)
        self.assertEqual({key: (sha, int(scale)) for key, sha, scale in found}, {m.id: (m.sha256, m.scale) for m in MODELS})


class StartupTests(unittest.TestCase):
    def test_cli_starts_plain_http_and_accepts_old_launcher_flag(self):
        from picax_lan.cli import main
        from picax_lan import worker as worker_module
        for old_flags in ([], ["--pair"]):
            with self.subTest(old_flags=old_flags), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / MODELS[-2].file).touch()  # Worker is mocked; no checkpoint is loaded.
                worker = SimpleNamespace(thread=SimpleNamespace(ident=None), start=Mock())
                run = Mock()
                output = io.StringIO()
                with patch.dict(sys.modules, {"uvicorn": SimpleNamespace(run=run), "qrcode": SimpleNamespace(QRCode=Mock())}), \
                     patch.object(worker_module, "Worker", return_value=worker), \
                     patch("picax_lan.server.create_app", return_value="http-app"), redirect_stdout(output):
                    main(["--host", "192.168.5.8", "--weights-dir", str(root), "--data-dir", str(root / "data"),
                          "--no-discovery", "--accept-noncommercial-license"] + old_flags)
                worker.start.assert_called_once()
                run.assert_called_once()
                self.assertEqual(run.call_args.args, ("http-app",))
                self.assertFalse(any(key.startswith("ssl_") for key in run.call_args.kwargs))
                self.assertIn("http://192.168.5.8:18443", output.getvalue())
                self.assertNotIn("pairingSecret", output.getvalue())
                self.assertFalse((root / "data" / "identity").exists())


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = JobStore(self.temp.name)
        self.owner, self.other = str(uuid.uuid4()), str(uuid.uuid4())
        self.body = spec()
        self.store.create(self.owner, self.body, 8192, 8_000_000)
    def tearDown(self):
        self.store.close(); self.temp.cleanup()
    def upload(self, body=None, page_index=0):
        body = body or self.body
        page = body["pages"][page_index]
        path = self.store.path(body["jobID"], page["id"], "source.part")
        path.write_bytes(png())
        self.store.accept_upload(body["jobID"], self.owner, page["id"], path)
    def succeed(self, body=None, page_index=0):
        body = body or self.body
        page = body["pages"][page_index]
        value = result(body, page)
        self.store.path(body["jobID"], page["id"], "result.png").write_bytes(png(value["width"], value["height"]))
        self.store.finish_page(body["jobID"], page["id"], result=value)
        return value

    def test_client_ownership_and_idempotent_creation(self):
        self.store.create(self.owner, copy.deepcopy(self.body), 8192, 8_000_000)
        with self.assertRaises(ProtocolError): self.store.status(self.body["jobID"], self.other)
        with self.assertRaises(ProtocolError): self.store.create(self.other, self.body, 8192, 8_000_000)
        changed = copy.deepcopy(self.body); changed["title"] = "changed"
        with self.assertRaises(ProtocolError): self.store.create(self.owner, changed, 8192, 8_000_000)

    def test_incomplete_upload_cannot_commit(self):
        with self.assertRaises(ProtocolError): self.store.commit(self.body["jobID"], self.owner)
        self.assertIsNone(self.store.next_page())

    def test_upload_digest_mismatch_does_not_advance(self):
        path = self.store.path(self.body["jobID"], self.body["pages"][0]["id"], "source.part"); path.write_bytes(b"bad")
        with self.assertRaises(ProtocolError): self.store.accept_upload(self.body["jobID"], self.owner, self.body["pages"][0]["id"], path)
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["pages"][0]["state"], "missing")

    def test_full_lifecycle_and_repeated_ack(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner)
        self.assertIsNotNone(self.store.next_page())
        value = self.succeed()
        for _ in range(2): self.store.acknowledge(self.body["jobID"], self.owner, self.body["pages"][0]["id"], value["sha256"])
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["state"], "acknowledged")

    def test_lost_upload_response_does_not_reset_completed_page(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner); self.store.next_page(); self.succeed()
        self.upload()
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["pages"][0]["state"], "succeeded")

    def test_ack_wrong_hash_rejected(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner); self.store.next_page(); self.succeed()
        with self.assertRaises(ProtocolError): self.store.acknowledge(self.body["jobID"], self.owner, self.body["pages"][0]["id"], "0" * 64)

    def test_cancel_cannot_be_undone_by_worker(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner); self.store.next_page()
        self.store.cancel(self.body["jobID"], self.owner); self.succeed()
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["state"], "cancelled")
        with self.assertRaises(ProtocolError): self.store.commit(self.body["jobID"], self.owner)

    def test_retry_failed_page_preserves_success(self):
        body = spec(pages=2); self.store.create(self.owner, body, 8192, 8_000_000)
        for index in range(2): self.upload(body, index)
        self.store.commit(body["jobID"], self.owner); self.store.next_page(); self.succeed(body, 0)
        self.store.next_page(); self.store.finish_page(body["jobID"], body["pages"][1]["id"], error="simulated test failure")
        self.store.retry_failed(body["jobID"], self.owner)
        self.assertEqual([p["state"] for p in self.store.status(body["jobID"], self.owner)["pages"]], ["succeeded", "uploaded"])

    def test_restart_recovers_running_page_and_stale_staging(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner); self.store.next_page()
        for suffix in ("source.part", "result.part"):
            self.store.path(self.body["jobID"], self.body["pages"][0]["id"], suffix).write_bytes(b"interrupted")
        self.store.recover()
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["state"], "queued")
        self.assertFalse(self.store.path(self.body["jobID"], self.body["pages"][0]["id"], "source.part").exists())
        self.assertIsNotNone(self.store.next_page())

    def test_restart_repairs_missing_unacknowledged_result(self):
        self.upload(); self.store.commit(self.body["jobID"], self.owner); self.store.next_page(); self.succeed()
        self.store.path(self.body["jobID"], self.body["pages"][0]["id"], "result.png").unlink()
        self.store.recover()
        self.assertEqual(self.store.status(self.body["jobID"], self.owner)["state"], "queued")

    def test_quota_rejection_and_traversal(self):
        self.store.job_quota = 1
        with self.assertRaises(ProtocolError): self.store.create(self.owner, spec(), 8192, 8_000_000)
        for page in ("../../oops", "e0000-p0000/../../oops"):
            with self.assertRaises(ProtocolError): self.store.path(self.body["jobID"], page, "source.png")

    def test_http_connection_url_needs_no_identity_or_secret(self):
        self.assertEqual(connection_url("192.168.5.8", 18443), "http://192.168.5.8:18443")
        self.assertEqual(connection_url("fc00::1", 18443), "http://[fc00::1]:18443")

    def test_png_header_limits(self):
        path = Path(self.temp.name) / "page.png"; path.write_bytes(png())
        self.assertEqual(png_dimensions(path, 1024, 4096), (64, 64))
        with self.assertRaises(ProtocolError): png_dimensions(path, 1, 4096)
        with self.assertRaises(ProtocolError): png_dimensions(path, 1024, 4095)
        path.write_bytes(b"not a PNG")
        with self.assertRaises(ProtocolError): png_dimensions(path, 1024, 4096)


if __name__ == "__main__":
    unittest.main()
