"""Loopback HTTP integration tests for CI. No model loading or GPU work."""
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(1, str(Path(__file__).resolve().parent))
from picax_lan.jobs import JobStore
from picax_lan.models import MODELS
from http_harness import HTTPHarness
from test_contracts import spec, png, result


class FakeWorker:
    """Transport-only state fixture, never used as a production AI fallback."""
    def __init__(self):
        self.model_states = {model.id: {"ready": True} for model in MODELS}


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = JobStore(self.temp.name)
        self.worker = FakeWorker()
        self.settings = {"weights": {model.id: "test-not-a-checkpoint" for model in MODELS}, "maximum_side": 4096, "maximum_pixels": 8_000_000}
        self.harness = HTTPHarness(self.store, self.worker, self.settings).__enter__()
        self.owner = str(uuid.uuid4())
    def tearDown(self):
        self.harness.__exit__(); self.store.close(); self.temp.cleanup()
    def request(self, method, path, body=None, **kwargs):
        return self.harness.request(method, path, body=body, client_id=self.owner, **kwargs)

    def test_http_connects_without_pairing_or_authorization(self):
        code, data = self.harness.request("GET", "/")
        self.assertEqual(code, 200)
        self.assertEqual(data["transport"], "http")
        self.assertEqual(self.harness.request("GET", "/v1/capabilities")[0], 200)
        self.assertEqual(self.request("GET", "/v1/capabilities")[0], 200)
        self.assertEqual(self.harness.request("POST", "/v1/pair", {})[0], 404)

    def test_jobs_work_without_any_client_registration(self):
        body = spec(); base = "/v1/jobs/" + body["jobID"]
        self.assertEqual(self.harness.request("POST", "/v1/jobs", body)[0], 200)
        self.assertEqual(self.harness.request("GET", base)[1]["state"], "uploading")
        self.assertEqual(self.harness.request("POST", base + "/cancel")[0], 200)

    def test_capabilities_ignore_cached_startup_vram_estimate(self):
        self.worker.model_states[MODELS[0].id]["metadata"] = {"maximumInputPixels": 400000}
        code, data = self.request("GET", "/v1/capabilities")
        self.assertEqual(code, 200)
        self.assertEqual(data["defaultDeliveryScale"], 2)
        self.assertEqual(data["defaultModelID"], MODELS[-2].id)
        self.assertTrue(all(model["maximumInputPixels"] == self.settings["maximum_pixels"] for model in data["models"]))

    def test_large_page_manifest_is_not_rejected_by_model_or_startup_vram_ceiling(self):
        # Manifests only; do not create large images or run inference.
        for model in (MODELS[0], MODELS[-2]):
            for width, height in ((1280, 1864), (2000, 3000), (2000, 4000)):
                with self.subTest(model=model.id, size=(width, height)):
                    self.worker.model_states[model.id]["metadata"] = {"maximumInputPixels": 400000}
                    body = spec(model=model)
                    body["pages"][0].update(width=width, height=height)
                    code, data = self.request("POST", "/v1/jobs", body)
                    self.assertEqual(code, 200, data)
                    self.assertEqual(data["state"], "uploading")

    def test_book_manifest_is_validated_per_page_not_as_one_combined_image(self):
        body = spec(model=MODELS[-2], pages=84)
        for page in body["pages"]:
            page.update(width=1280, height=1864)
        code, data = self.request("POST", "/v1/jobs", body)
        self.assertEqual(code, 200, data)
        self.assertEqual(len(data["pages"]), 84)
        self.assertEqual(list(self.store.directory(body["jobID"]).iterdir()), [])

    def test_configured_input_decoder_limit_remains_enforced(self):
        self.settings["maximum_pixels"] = 1_000_000
        self.worker.model_states[MODELS[-2].id]["metadata"] = {"maximumInputPixels": 8_000_000}
        code, data = self.request("GET", "/v1/capabilities")
        self.assertEqual(code, 200)
        self.assertTrue(all(model["maximumInputPixels"] == 1_000_000 for model in data["models"]))
        body = spec(model=MODELS[-2]); body["pages"][0].update(width=1000, height=1500)
        code, data = self.request("POST", "/v1/jobs", body)
        self.assertEqual(code, 413)
        self.assertIn("configured input decoder limit", data["error"])

    def test_delivery_decode_limit_is_still_enforced(self):
        body = spec(model=MODELS[-2], scale=4)
        body["pages"][0].update(width=1500, height=1500)
        code, data = self.request("POST", "/v1/jobs", body)
        self.assertEqual(code, 413)
        self.assertIn("phone's receive limits", data["error"])

    def test_client_ids_group_jobs_but_need_no_token(self):
        body = spec(); self.request("POST", "/v1/jobs", body)
        self.assertEqual(self.store.status(body["jobID"], self.owner)["state"], "uploading")
        self.assertEqual(self.harness.request("GET", "/v1/jobs/" + body["jobID"], client_id=str(uuid.uuid4()))[0], 404)
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


if __name__ == "__main__":
    unittest.main()
