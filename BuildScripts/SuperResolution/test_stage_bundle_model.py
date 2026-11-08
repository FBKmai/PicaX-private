#!/usr/bin/env python3
"""Standard-library tests for stage_bundle_model.py; no model weights are used."""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "picax_sr_stage", Path(__file__).with_name("stage_bundle_model.py"))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

SYNTHETIC_PACKAGE = {
    "Manifest.json": b"manifest\n",
    "Data/com.apple.CoreML/model.mlmodel": b"model\n",
    "Data/com.apple.CoreML/weights/weight.bin": b"weight\n",
}
SYNTHETIC_PACKAGE_SHA256 = "ccd7de46535a53d89426ffb801255072aad4f46d42346a4be7c6317a2f5d910a"


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.original_package_sha = stage.COLOR_PACKAGE_SHA256
        stage.COLOR_PACKAGE_SHA256 = SYNTHETIC_PACKAGE_SHA256
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        self.output = self.root / "output"

    def tearDown(self):
        stage.COLOR_PACKAGE_SHA256 = self.original_package_sha
        self.temporary.cleanup()

    def descriptor(self, **overrides):
        model = {
            "id": "color-test",
            "preset": "color",
            "displayName": "Test Color",
            "version": "1.0.0",
            "resourceName": "Color",
            "sourceURL": "https://example.invalid/model",
            "license": "CC-BY-NC-4.0",
            "weightSHA256": stage.COLOR_WEIGHT_SHA256,
            "inputName": "input",
            "outputName": "output",
            "tileSize": 128,
            "overlap": 20,
            "scale": 2,
            "minimumPageHeight": None,
            "maximumPageHeight": None,
            "precision": "float32",
            "validated": False,
            "fullPage": dict(stage.FULL_PAGE_CONTRACT, validated=False),
        }
        model.update(overrides)
        return model

    def write_artifact(self, model=None, package_name="Color.mlpackage", files=None):
        (self.artifact / "Color.superresolution.json").write_text(
            json.dumps(model or self.descriptor()), encoding="utf-8")
        package = self.artifact / package_name
        for name, data in (files or SYNTHETIC_PACKAGE).items():
            target = package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return package

    def arguments(self, **overrides):
        values = {
            "--artifact-dir": str(self.artifact),
            "--output-dir": str(self.output),
            "--expected-weight-sha256": stage.COLOR_WEIGHT_SHA256,
            "--expected-package-sha256": SYNTHETIC_PACKAGE_SHA256,
            "--validation-run-id": "42461503524",
            "--artifact-name": "color-artifact",
        }
        values.update(overrides)
        arguments = []
        for key, value in values.items():
            arguments.extend([key, value])
        return stage.parse_args(arguments)

    def assert_rejected(self, arguments, fragment):
        with self.assertRaises(ValueError) as raised:
            stage.stage(arguments)
        self.assertIn(fragment, str(raised.exception))

    def test_success_approves_only_the_output_copy(self):
        self.write_artifact()
        result = stage.stage(self.arguments())
        self.assertEqual(result["resourceName"], "Color")
        source = json.loads(
            (self.artifact / "Color.superresolution.json").read_text(encoding="utf-8"))
        self.assertFalse(source["validated"])
        self.assertFalse(source["fullPage"]["validated"])
        output = json.loads(
            (self.output / "Color.superresolution.json").read_text(encoding="utf-8"))
        self.assertTrue(output["validated"])
        self.assertTrue(output["fullPage"]["validated"])
        self.assertEqual(output["bundleApproval"]["validationRunId"], "42461503524")
        self.assertEqual(output["bundleApproval"]["packageSHA256"], SYNTHETIC_PACKAGE_SHA256)
        self.assertEqual(stage.package_sha256(self.output / "Color.mlpackage"),
                         SYNTHETIC_PACKAGE_SHA256)
        attribution = (self.output / stage.ATTRIBUTION_NAME).read_text(encoding="utf-8")
        self.assertIn("Attribution-NonCommercial 4.0", attribution)
        self.assertIn("the-database/MangaJaNai", attribution)
        self.assertIn("MangaJaNai V1", attribution)

    def test_rejects_preapproved_descriptor(self):
        self.write_artifact(model=self.descriptor(validated=True))
        self.assert_rejected(self.arguments(), "must be False")

    def test_rejects_license_weight_and_precision_changes(self):
        cases = (
            (self.descriptor(license="UNRESOLVED"), "license"),
            (self.descriptor(weightSHA256="0" * 64), "weightSHA256"),
            (self.descriptor(precision="float16"), "precision"),
            (self.descriptor(preset="manga"), "preset"),
        )
        for model, fragment in cases:
            with self.subTest(fragment=fragment):
                for path in self.artifact.iterdir():
                    if path.is_dir():
                        import shutil
                        shutil.rmtree(path)
                    else:
                        path.unlink()
                self.write_artifact(model=model)
                self.assert_rejected(self.arguments(), fragment)

    def test_rejects_full_page_contract_changes(self):
        capability = dict(stage.FULL_PAGE_CONTRACT, validated=False, alignment=8)
        self.write_artifact(model=self.descriptor(fullPage=capability))
        self.assert_rejected(self.arguments(), "alignment")
        capability = dict(stage.FULL_PAGE_CONTRACT, validated=True)
        self.write_artifact(model=self.descriptor(fullPage=capability))
        self.assert_rejected(self.arguments(), "pre-approval")
        capability = dict(stage.FULL_PAGE_CONTRACT, validated=False,
                          enumeratedSizes=[[256, 384]])
        self.write_artifact(model=self.descriptor(fullPage=capability))
        self.assert_rejected(self.arguments(), "enumerated")

    def test_rejects_ambiguous_or_nested_descriptors(self):
        self.write_artifact()
        (self.artifact / "second.superresolution.json").write_text("{}", encoding="utf-8")
        self.assert_rejected(self.arguments(), "exactly one")
        (self.artifact / "second.superresolution.json").unlink()
        nested = self.artifact / "nested"
        nested.mkdir()
        (nested / "third.superresolution.json").write_text("{}", encoding="utf-8")
        self.assert_rejected(self.arguments(), "nested")

    def test_rejects_package_mismatch(self):
        self.write_artifact(package_name="Other.mlpackage")
        self.assert_rejected(self.arguments(), "package at top level")
        for path in self.artifact.iterdir():
            if path.is_dir():
                import shutil
                shutil.rmtree(path)
            else:
                path.unlink()
        self.write_artifact(files={"Manifest.json": b"manifest\n"})
        self.assert_rejected(self.arguments(), "missing Data/com.apple.CoreML/model.mlmodel")
        for path in self.artifact.iterdir():
            if path.is_dir():
                import shutil
                shutil.rmtree(path)
            else:
                path.unlink()
        self.write_artifact()
        self.assert_rejected(
            self.arguments(**{"--expected-package-sha256": "0" * 64}), "package SHA-256")

    def test_rejects_non_empty_or_overlapping_output(self):
        self.write_artifact()
        self.output.mkdir()
        (self.output / "stale").write_text("x", encoding="utf-8")
        self.assert_rejected(self.arguments(), "must be empty")
        self.assert_rejected(
            self.arguments(**{"--output-dir": str(self.artifact / "out")}),
            "separate from the artifact")

    @unittest.skipIf(os.name == "nt", "symlink creation may require elevation")
    def test_rejects_symlink_inside_package(self):
        package = self.write_artifact()
        (package / "linked").symlink_to(package / "Manifest.json")
        self.assert_rejected(self.arguments(), "symlink")


if __name__ == "__main__":
    unittest.main()
