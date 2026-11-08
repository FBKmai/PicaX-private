#!/usr/bin/env python3
"""Resource-contract tests only. Stub model directories are not Core ML models."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("bundle_audit", Path(__file__).with_name("verify-super-resolution-bundle.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BundleAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Synthetic.app"
        self.app.mkdir()

    def write_model(self, model_id="color", **changes):
        model = dict(id=model_id, preset="color", displayName="Synthetic fixture", version="test",
                     resourceName=model_id, sourceURL="https://example.invalid/model", license="CC-BY-NC-4.0",
                     weightSHA256="a" * 64, inputName="input", outputName="output", tileSize=128,
                     overlap=20, scale=2, precision="float32", validated=True)
        model.update(changes)
        path = self.app / (model_id + ".superresolution.json")
        path.write_text(json.dumps(model), encoding="utf-8")
        compiled = self.app / (model["resourceName"] + ".mlmodelc")
        compiled.mkdir(exist_ok=True)
        return path

    def test_no_models_is_explicit_engineering_build(self):
        report = audit.audit_bundle(self.app)
        self.assertEqual(report["status"], "engineering-build-no-models")
        self.assertEqual(report["models"], [])

    def test_valid_declaration_is_not_claimed_as_independent_verification(self):
        self.write_model()
        report = audit.audit_bundle(self.app)
        self.assertEqual(report["status"], "validated-models-declared")
        self.assertIn("not independent", report["note"])

    def test_unvalidated_or_unresolved_model_is_rejected(self):
        for changes in ({"validated": False}, {"license": "UNRESOLVED"}, {"license": "MIT"},
                        {"weightSHA256": "invalid"}, {"tileSize": 256}, {"overlap": 40},
                        {"inputName": "image"}, {"precision": "int8"}):
            self.write_model(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                audit.audit_bundle(self.app)

    def test_source_url_requires_https_and_a_host(self):
        for source in ("https://", "https:///no-host", "http://example.invalid/model", "not a URL"):
            self.write_model(sourceURL=source)
            with self.subTest(source=source), self.assertRaises(ValueError):
                audit.audit_bundle(self.app)
        self.write_model(sourceURL="HTTPS://example.invalid/model")
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)

    def test_optional_color_range_matches_runtime_contract(self):
        for changes in ({"minimumPageHeight": 100}, {"maximumPageHeight": 200},
                        {"minimumPageHeight": 0, "maximumPageHeight": 200},
                        {"minimumPageHeight": 200, "maximumPageHeight": 199},
                        {"minimumPageHeight": True, "maximumPageHeight": 200}):
            self.write_model(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                audit.audit_bundle(self.app)
        self.write_model(minimumPageHeight=100, maximumPageHeight=200)
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)
        self.write_model(minimumPageHeight=None, maximumPageHeight=None)
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)

    def test_non_string_hash_and_whitespace_identity_are_rejected(self):
        for changes in ({"weightSHA256": 123}, {"id": "  "}, {"tileSize": 128.0}):
            self.write_model(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                audit.audit_bundle(self.app)

    def test_nested_resources_are_not_mistaken_for_main_bundle_resources(self):
        descriptor = self.write_model()
        nested = self.app / "Nested"
        nested.mkdir()
        descriptor.rename(nested / descriptor.name)
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)
        (nested / descriptor.name).rename(descriptor)
        compiled = self.app / "color.mlmodelc"
        compiled.rename(nested / compiled.name)
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_missing_compiled_resource_is_rejected(self):
        self.write_model()
        (self.app / "color.mlmodelc").rmdir()
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_manga_needs_explicit_range_and_float32(self):
        self.write_model("manga", preset="manga", minimumPageHeight=1100, maximumPageHeight=1300)
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)
        self.write_model("manga", preset="manga", minimumPageHeight=True, maximumPageHeight=1300)
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)
        self.write_model("manga", preset="manga", minimumPageHeight=1100, maximumPageHeight=1300, precision="float16")
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_touching_manga_closed_ranges_are_ambiguous(self):
        self.write_model("small", preset="manga", minimumPageHeight=1100, maximumPageHeight=1300)
        self.write_model("large", preset="manga", minimumPageHeight=1301, maximumPageHeight=1500)
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 2)
        self.write_model("large", preset="manga", minimumPageHeight=1300, maximumPageHeight=1500)
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_multiple_color_models_are_ambiguous(self):
        self.write_model("one")
        self.write_model("two")
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_duplicate_model_resource_is_rejected(self):
        self.write_model("one", preset="manga", resourceName="shared", minimumPageHeight=1100, maximumPageHeight=1300)
        self.write_model("two", preset="manga", resourceName="shared", minimumPageHeight=1301, maximumPageHeight=1500)
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def test_malformed_json_contract_is_rejected(self):
        (self.app / "bad.superresolution.json").write_text("[]", encoding="utf-8")
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)

    def full_page(self, **changes):
        capability = dict(validated=True, shapeMode="range", alignment=16,
                          minimumWidth=64, minimumHeight=64, maximumWidth=2048,
                          maximumHeight=2048, maximumPixels=2_000_000,
                          estimatedWorkingBytesPerPixel=2048)
        capability.update(changes)
        return capability

    def test_tiled_only_descriptor_remains_backward_compatible(self):
        self.write_model()
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)

    def test_valid_range_and_enumerated_full_page_descriptors(self):
        self.write_model(fullPage=self.full_page())
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)
        self.write_model(fullPage=self.full_page(
            shapeMode="enumerated", enumeratedSizes=[[256, 384], [1008, 1504]]))
        self.assertEqual(len(audit.audit_bundle(self.app)["models"]), 1)

    def test_invalid_full_page_descriptors_are_rejected(self):
        cases = (
            {"validated": "yes"}, {"shapeMode": "fixed"}, {"alignment": 12},
            {"alignment": 0}, {"minimumWidth": 0}, {"maximumWidth": 32},
            {"maximumPixels": 100}, {"estimatedWorkingBytesPerPixel": True},
            {"shapeMode": "enumerated"},
            {"shapeMode": "enumerated", "enumeratedSizes": [[1000, 1500]]},
            {"shapeMode": "enumerated", "enumeratedSizes": [[256, 384], [256, 384]]},
            {"shapeMode": "enumerated", "enumeratedSizes": [[4096, 64]]},
            {"shapeMode": "enumerated", "enumeratedSizes": [[256]]},
            {"shapeMode": "enumerated", "enumeratedSizes": [[256.0, 384]]},
            {"shapeMode": "range", "enumeratedSizes": [[256, 384]]},
        )
        for changes in cases:
            self.write_model(fullPage=self.full_page(**changes))
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                audit.audit_bundle(self.app)
        self.write_model(fullPage=[])
        with self.assertRaises(ValueError):
            audit.audit_bundle(self.app)


if __name__ == "__main__":
    unittest.main()
