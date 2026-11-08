#!/usr/bin/env python3
"""Acquisition tests use small inert fixtures, never model deserialization."""
import hashlib
import importlib.util
import io
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("picax_fetch_checkpoint", Path(__file__).with_name("fetch_checkpoint.py"))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class CheckpointAcquisitionTests(unittest.TestCase):
    def fixture(self, directory, extra=()):
        data = b"inert checkpoint bytes, not executable"
        archive = directory / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("selected.pth", data)
            bundle.writestr("LICENSE.txt", "test-only notice")
            bundle.writestr("unrelated.py", "raise AssertionError('must never execute or extract')")
            for name, value in extra:
                # ZipInfo normalizes backslashes on Windows; plant the raw ZIP
                # spelling explicitly so this fixture also tests that platform.
                entry = zipfile.ZipInfo("placeholder")
                entry.filename = name
                bundle.writestr(entry, value)
        output = directory / "weights"
        output.mkdir()
        config = {"filename": "selected.pth", "weightSHA256": hashlib.sha256(data).hexdigest(),
                  "archiveBytes": archive.stat().st_size,
                  "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        return archive, output, config

    def test_only_selected_checkpoint_is_extracted_and_hashed(self):
        with tempfile.TemporaryDirectory() as temp:
            archive, output, config = self.fixture(Path(temp))
            report = fetch.extract_verified(archive, output, config)
            self.assertEqual([path.name for path in output.iterdir()], ["selected.pth"])
            self.assertEqual(report["observedWeightSHA256"], config["weightSHA256"])
            self.assertFalse(report["validated"])
            self.assertEqual(report["archiveNotices"], [{"name": "LICENSE.txt", "text": "test-only notice"}])

    def test_hash_and_size_mismatch_fail_closed(self):
        for change in ({"archiveSHA256": "0" * 64}, {"archiveBytes": 1}, {"weightSHA256": "0" * 64}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                archive, output, config = self.fixture(Path(temp))
                with self.assertRaises(ValueError):
                    fetch.extract_verified(archive, output, {**config, **change})

    def test_unsafe_members_rejected_even_when_not_selected(self):
        for name in ("../escape.py", "/absolute", "C:/drive", "folder\\entry"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                archive, output, config = self.fixture(Path(temp), [(name, "bad")])
                with self.assertRaises(ValueError):
                    fetch.extract_verified(archive, output, config)
                self.assertFalse(any(output.iterdir()))

    def test_duplicate_checkpoint_and_links_rejected(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate), tempfile.TemporaryDirectory() as temp:
                archive, output, config = self.fixture(Path(temp))
                with zipfile.ZipFile(archive, "a") as bundle:
                    if duplicate:
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore", UserWarning)
                            bundle.writestr("selected.pth", b"duplicate")
                    else:
                        entry = zipfile.ZipInfo("link")
                        entry.create_system = 3
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                        bundle.writestr(entry, "outside")
                config["archiveBytes"] = archive.stat().st_size
                config["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
                with self.assertRaises(ValueError):
                    fetch.extract_verified(archive, output, config)

    def test_empty_and_nonoverlapping_destinations_required(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            first, second = directory / "a", directory / "b"
            fetch.check_separation(first, second)
            for other in (first, first / "child", directory):
                with self.assertRaises(ValueError):
                    fetch.check_separation(first, other)
            fetch.empty_directory(first)
            (first / "existing").write_bytes(b"do not overwrite")
            with self.assertRaises(ValueError):
                fetch.empty_directory(first)

    def test_redirects_cannot_leave_https_release_hosts(self):
        handler = fetch.ReleaseRedirects()
        for url in ("http://github.com/file", "https://example.com/file", "https://github.com.evil.test/file"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                handler.redirect_request(None, None, 302, "Found", {}, url)


if __name__ == "__main__":
    unittest.main()
