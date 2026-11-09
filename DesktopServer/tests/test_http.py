"""Loopback HTTPS integration tests. No model loading or GPU work."""
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(1, str(Path(__file__).resolve().parent))
from picax_lan.auth import Pairing
from picax_lan.jobs import JobStore
from picax_lan.models import MODELS
from http_harness import HTTPSHarness
from test_contracts import spec, png, result


class FakeWorker:
    """Transport-only state fixture, never used as a production AI fallback."""
    def __init__(self):
        self.model_states = {model.id: {"ready": True} for model in MODELS}


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = JobStore(self.temp.name)
        self.pairing = Pairing(self.store)
        self.worker = FakeWorker()
        self.settings = {"weights": {model.id: "test-not-a-checkpoint" for model in MODELS}, "maximum_side": 4096, "maximum_pixels": 8_000_000}
        self.harness = HTTPSHarness(self.store, self.worker, self.pairing, self.settings).__enter__()
        self.owner = str(uuid.uuid4())
        code, data = self.harness.request("POST", "/v1/pair", {"clientID": self.owner, "pairingSecret": self.pairing.secret})
        self.assertEqual(code, 200)
        self.token = data["token"]
    def tearDown(self):
        self.harness.__exit__(); self.store.close(); self.temp.cleanup()
    def request(self, method, path, body=None, **kwargs):
        return self.harness.request(method, path, body=body, token=self.token, **kwargs)

    def test_authentication_and_revocation(self):
        self.assertEqual(self.harness.request("GET", "/v1/capabilities")[0], 401)
        self.assertEqual(self.request("GET", "/v1/capabilities")[0], 200)
        self.store.revoke(self.owner)
        self.assertEqual(self.request("GET", "/v1/capabilities")[0], 401)

    def test_capability_default_and_live_budget(self):
        self.worker.model_states[MODELS[0].id]["metadata"] = {"maximumInputPixels": 400000}
        code, data = self.request("GET", "/v1/capabilities")
        self.assertEqual(code, 200)
        self.assertEqual(data["defaultDeliveryScale"], 2)
        self.assertEqual(data["defaultModelID"], MODELS[-2].id)
        self.assertEqual(data["models"][0]["maximumInputPixels"], 400000)

    def test_no_owner_leak_or_unknown_model_submission(self):
        body = spec(); self.request("POST", "/v1/jobs", body)
        self.assertEqual(self.store.status(body["jobID"], self.owner)["state"], "uploading")
        self.assertEqual(self.request("GET", "/v1/jobs/" + str(uuid.uuid4()))[0], 404)
        self.worker.model_states[body["modelID"]] = {"ready": False}
        self.assertEqual(self.request("POST", "/v1/jobs", spec())[0], 503)

    def test_upload_commit_result_and_idempotent_ack(self):
        body = spec(); base = "/v1/jobs/" + body["jobID"]; page = body["pages"][0]; page_path = base + "/pages/" + page["id"]
        self.assertEqual(self.request("POST", "/v1/jobs", body)[0], 200)
        self.assertEqual(self.request("POST", base + "/commit")[0], 409)
        self.assertEqual(self.request("PUT", page_path, png(), raw=True)[0], 200)
        self.assertEqual(self.request("POST", base + "/commit")[0], 200)
        self.store.next_page()
        value = result(body)
        self.store.path(body["jobID"], page["id"], "result.png").write_bytes(png(128, 128))
        self.store.finish_page(body["jobID"], page["id"], result=value)
        code, data = self.request("GET", page_path + "/result")
        self.assertEqual(code, 200); self.assertEqual(data, png(128, 128))
        self.assertEqual(self.request("GET", page_path + "/result", headers={"Range": "bytes=1-3"})[0], 400)
        for _ in range(2): self.assertEqual(self.request("POST", page_path + "/ack", {"sha256": value["sha256"]})[0], 200)
        self.assertEqual(self.request("GET", base)[1]["state"], "acknowledged")

    def test_oversized_corrupt_and_wrong_content_type_uploads(self):
        body = spec(); self.request("POST", "/v1/jobs", body)
        path = "/v1/jobs/" + body["jobID"] + "/pages/" + body["pages"][0]["id"]
        self.assertEqual(self.request("PUT", path, png() + b"bad", raw=True)[0], 422)
        self.assertEqual(self.request("PUT", path, b"X" * len(png()), raw=True)[0], 400)
        self.assertEqual(self.request("PUT", path, {"not": "png"})[0], 415)
        self.assertEqual(self.request("PUT", path, png(), raw=True)[0], 200)

    def test_tls_pin_and_single_use_pairing(self):
        self.assertEqual(self.harness.request("POST", "/v1/pair", {"clientID": str(uuid.uuid4()), "pairingSecret": self.pairing.secret})[0], 403)
        old = self.harness.fingerprint
        self.harness.fingerprint = "0" * 64
        with self.assertRaises(RuntimeError): self.request("GET", "/v1/capabilities")
        self.harness.fingerprint = old


if __name__ == "__main__":
    unittest.main()
