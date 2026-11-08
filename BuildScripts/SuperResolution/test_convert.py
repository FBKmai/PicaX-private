#!/usr/bin/env python3
"""Standard-library-only tests; these do not test PyTorch or Core ML."""
import contextlib
import hashlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("picax_sr_convert", Path(__file__).with_name("convert.py"))
convert = importlib.util.module_from_spec(spec)
spec.loader.exec_module(convert)


class ConversionLogicTests(unittest.TestCase):
    def arguments(self, *extra):
        return ["--model", "manga", "--manga-height", "1200",
                "--minimum-page-height", "1175", "--maximum-page-height", "1225",
                "--weight", "input.pth", "--expected-sha256", convert.MANGA_WEIGHTS[1200][1],
                "--precision", "float32", "--output-dir", "out",
                "--max-abs-error", "0.1", "--max-mean-error", "0.01", *extra]

    def test_manga_descriptor_is_never_validated(self):
        args = convert.parse_args(self.arguments())
        info = convert.model_info(args)
        desc = convert.make_descriptor(args, info)
        self.assertEqual(desc["weightSHA256"], convert.MANGA_WEIGHTS[1200][1])
        self.assertEqual((desc["tileSize"], desc["overlap"], desc["scale"]), (128, 20, 2))
        self.assertEqual((desc["minimumPageHeight"], desc["maximumPageHeight"]), (1175, 1225))
        self.assertEqual((desc["inputName"], desc["outputName"]), ("input", "output"))
        self.assertEqual(desc["precision"], "float32")
        self.assertFalse(desc["validated"])
        self.assertIn("UNRESOLVED", desc["license"])
        self.assertFalse(desc["resourceName"].endswith(".mlpackage"))

    def test_color_precision_and_naming(self):
        args = convert.parse_args(["--model", "color", "--weight", "in.safetensors",
            "--expected-sha256", convert.COLOR_WEIGHT.upper(), "--precision", "float16",
            "--output-dir", "out", "--max-abs-error", "0", "--max-mean-error", "0"])
        info = convert.model_info(args)
        desc = convert.make_descriptor(args, info)
        self.assertEqual(desc["preset"], "color")
        self.assertEqual(desc["precision"], "float16")
        self.assertEqual(args.expected_sha256, convert.COLOR_WEIGHT)
        self.assertIsNone(desc["minimumPageHeight"])
        self.assertFalse(desc["validated"])

    def test_reject_invalid_or_missing_metadata(self):
        for extra in (["--precision", "float16"], ["--minimum-page-height", "0"],
                      ["--minimum-page-height", "1500"], ["--expected-sha256", "bad"],
                      ["--max-abs-error", "nan"], ["--max-mean-error", "inf"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                convert.parse_args(self.arguments(*extra))

    def test_existing_manga_height_ranges_must_not_overlap(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            folder = Path(temp)
            candidate = convert.make_descriptor(convert.parse_args(self.arguments()),
                                                convert.model_info(convert.parse_args(self.arguments())))
            original = folder / "existing.superresolution.json"
            convert.write_json(original, {"preset": "manga", "minimumPageHeight": 1100,
                                          "maximumPageHeight": 1174})
            convert.check_existing_ranges(folder, candidate)
            original.unlink()
            convert.write_json(original, {"preset": "manga", "minimumPageHeight": 1100,
                                          "maximumPageHeight": 1175})
            with self.assertRaises(ValueError):
                convert.check_existing_ranges(folder, candidate)
            original.unlink()
            convert.write_json(original, {"preset": "manga", "minimumPageHeight": True,
                                          "maximumPageHeight": 1000})
            with self.assertRaises(ValueError):
                convert.check_existing_ranges(folder, candidate)

    def test_checkpoint_hash_is_over_exact_loaded_bytes(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            path = Path(temp) / "weights.pth"
            data = b"synthetic checkpoint, not executable"
            path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(convert.checked_weight_bytes(path, digest, digest, ".pth"), data)
            for expected, pinned, extension in (("0" * 64, digest, ".pth"),
                                                ("0" * 64, "0" * 64, ".pth"),
                                                (digest, digest, ".safetensors")):
                with self.subTest(expected=expected, extension=extension), self.assertRaises(ValueError):
                    convert.checked_weight_bytes(path, expected, pinned, extension)

    def test_package_fingerprint_and_exclusive_json(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            package = Path(temp) / "model.mlpackage"
            package.mkdir()
            (package / "a").write_bytes(b"first")
            digest = convert.package_sha256(package)
            self.assertEqual(digest, convert.package_sha256(package))
            (package / "a").write_bytes(b"second")
            self.assertNotEqual(digest, convert.package_sha256(package))
            report = Path(temp) / "report.json"
            convert.write_json(report, {"validated": False})
            with self.assertRaises(FileExistsError):
                convert.write_json(report, {"validated": True})

    def test_reflection_matches_app_for_small_and_far_coordinates(self):
        self.assertEqual([convert.reflected(x, 3) for x in range(-5, 8)],
                         [1, 0, 1, 2, 1, 0, 1, 2, 1, 0, 1, 2, 1])
        self.assertTrue(all(convert.reflected(x, 1) == 0 for x in range(-100, 100)))
        with self.assertRaises(ValueError):
            convert.reflected(0, 0)

    def test_tiles_cover_odd_edges_exactly_once(self):
        width, height = 177, 89
        coverage = [[0] * width for _ in range(height)]
        tiles = convert.tile_positions(width, height)
        self.assertEqual(len(tiles), 6)
        self.assertIn((176, 88, 1, 1), tiles)
        for x, y, tile_width, tile_height in tiles:
            for row in range(y, y + tile_height):
                for column in range(x, x + tile_width):
                    coverage[row][column] += 1
        self.assertTrue(all(value == 1 for row in coverage for value in row))
        self.assertEqual(convert.tile_positions(1, 1), [(0, 0, 1, 1)])

    def test_tile_validation_requires_explicit_complete_limits(self):
        limits = ["--max-tile-abs-error", "0.05", "--max-tile-mean-error", "0.005",
                  "--max-seam-mean-error", "0.0075"]
        args = convert.parse_args(self.arguments("--validate-tiles", *limits))
        self.assertTrue(args.validate_tiles)
        for extra in (["--validate-tiles"], limits, ["--max-tile-mean-error", "0.005"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                convert.parse_args(self.arguments(*extra))

    def test_output_must_not_overlap_weights(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            root = Path(temp)
            weights = root / "download"
            weights.mkdir()
            path = weights / "checkpoint.pth"
            path.write_bytes(b"x")
            original = convert.__file__
            fake_project = root / "fake-project"
            convert.__file__ = str(fake_project / "BuildScripts" / "SuperResolution" / "convert.py")
            try:
                for output in (weights, weights / "output", root, fake_project / "PicaX"):
                    with self.subTest(output=output), self.assertRaises(ValueError):
                        convert.check_paths(path, output)
                self.assertEqual(convert.check_paths(path, root / "other")[0], path.resolve())
            finally:
                convert.__file__ = original


if __name__ == "__main__":
    unittest.main()
