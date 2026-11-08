#!/usr/bin/env python3
"""Fetch only pinned public JaNai archives and extract one verified checkpoint.

Run with -I from a trusted directory. Downloads, weights and scripts must live
in separate directories. No archive member is imported or executed here.
"""
import argparse
import hashlib
import json
import stat
import sys
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

CHECKPOINTS = {
    "manga": {
        "url": "https://github.com/the-database/MangaJaNai/releases/download/1.0.0/MangaJaNai_V1_ModelsOnly.zip",
        "archiveSHA256": "5156f4167875bba51a8ed52bd1c794b0d7277f7103f99b397518066e4dda7e55",
        "archiveHashSource": "observed from official release download, 2026-11-08; not publisher-signed",
        "archiveBytes": 433383160,
        "filename": "2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth",
        "weightSHA256": "43b784f674bdbf89886a62a64cd5f8d8df92caf4d861bdf4d47dad249ede0267",
    },
    "color": {
        "url": "https://github.com/the-database/MangaJaNai/releases/download/3.0.0/IllustrationJaNai_V3detail.zip",
        "archiveSHA256": "27749962bc934779f867730cdb10617e3d7475313f920a7a966c56b75dbdbeda",
        "archiveHashSource": "GitHub release asset API digest, independently matched 2026-11-08",
        "archiveBytes": 318641534,
        "filename": "2x_IllustrationJaNai_V3detail_FDAT_M_unshuffle_40k_fp16.safetensors",
        "weightSHA256": "8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0",
    },
}
MAX_WEIGHT_BYTES = 64 * 1024 * 1024


def contained(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def empty_directory(path):
    path = path.resolve()
    if path.exists():
        if not path.is_dir() or any(path.iterdir()):
            raise ValueError("destination must be a new or empty directory")
    else:
        path.mkdir(parents=True)
    return path


def check_separation(first, second):
    if contained(first, second) or contained(second, first):
        raise ValueError("download and extracted-weight directories must not overlap")
    project = Path(__file__).resolve().parents[2]
    if contained(first, project) or contained(second, project):
        raise ValueError("keep archives and weights outside the repository")


class ReleaseRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        from urllib.parse import urlsplit
        url = urlsplit(newurl)
        if url.scheme != "https" or url.hostname not in {
            "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
        }:
            raise ValueError("unexpected release download redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(config, destination):
    request = urllib.request.Request(config["url"], headers={"User-Agent": "PicaX-model-validation"})
    opener = urllib.request.build_opener(ReleaseRedirects())
    total = 0
    with opener.open(request, timeout=120) as source, destination.open("xb") as output:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            total += len(block)
            if total > config["archiveBytes"]:
                raise ValueError("archive exceeds pinned byte count")
            output.write(block)


def extract_verified(archive, output, config):
    # Keep one open handle from archive hashing through selected-member reading.
    # The selected member is independently hashed before any model loader sees it.
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        source.seek(0, 2)
        if source.tell() != config["archiveBytes"]:
            raise ValueError("archive byte count mismatch")
        source.seek(0)
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
        if digest.hexdigest() != config["archiveSHA256"]:
            raise ValueError("archive SHA-256 mismatch")
        source.seek(0)
        with zipfile.ZipFile(source) as bundle:
            total, weight_digest, notices = extract_member(bundle, output, config)
    return {**config, "observedArchiveSHA256": digest.hexdigest(),
            "observedWeightSHA256": weight_digest, "weightBytes": total,
            "archiveNotices": notices, "validated": False}


def extract_member(bundle, output, config):
    notices = []
    entries = bundle.infolist()
    if len(entries) > 10000:
        raise ValueError("unexpected archive entry count")
    for entry in entries:
        raw_name = entry.orig_filename
        name = PurePosixPath(raw_name)
        mode = entry.external_attr >> 16
        if (name.is_absolute() or ".." in name.parts or "\\" in raw_name
                or ":" in raw_name or "\x00" in raw_name or stat.S_ISLNK(mode)):
            raise ValueError("unsafe archive entry")
        if any(word in name.name.lower() for word in ("license", "readme", "notice", "copying")):
            if entry.file_size > 256 * 1024:
                raise ValueError("oversized archive notice")
            notices.append({"name": entry.filename,
                            "text": bundle.read(entry).decode("utf-8", errors="replace")})
    candidates = [entry for entry in entries if entry.filename == config["filename"]]
    if len(candidates) != 1 or candidates[0].is_dir():
        raise ValueError("expected exactly one pinned checkpoint at the archive root")
    selected = candidates[0]
    if not 0 < selected.file_size <= MAX_WEIGHT_BYTES:
        raise ValueError("checkpoint exceeds extraction budget")
    target = output / config["filename"]
    total = 0
    weight_digest = hashlib.sha256()
    with bundle.open(selected) as source, target.open("xb") as destination:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            total += len(block)
            if total > MAX_WEIGHT_BYTES:
                raise ValueError("checkpoint exceeds extraction budget")
            weight_digest.update(block)
            destination.write(block)
    if total != selected.file_size or weight_digest.hexdigest() != config["weightSHA256"]:
        raise ValueError("checkpoint SHA-256 or byte count mismatch; do not use output")
    return total, weight_digest.hexdigest(), notices


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, choices=sorted(CHECKPOINTS))
    parser.add_argument("--download-dir", type=Path,
                        help="New empty directory for a download; mutually exclusive with --archive")
    parser.add_argument("--archive", type=Path, help="Existing pinned archive; no download")
    parser.add_argument("--weight-dir", type=Path, required=True, help="Separate new empty directory")
    args = parser.parse_args(argv)
    if (args.download_dir is None) == (args.archive is None):
        parser.error("provide exactly one of --download-dir and --archive")
    try:
        config = CHECKPOINTS[args.model]
        output = args.weight_dir.resolve()
        source = args.download_dir.resolve() if args.download_dir else args.archive.resolve(strict=True).parent
        check_separation(source, output)
        output = empty_directory(output)
        if args.download_dir:
            source = empty_directory(source)
            archive = source / config["url"].rsplit("/", 1)[1]
            download(config, archive)
        else:
            archive = args.archive.resolve(strict=True)
        report = extract_verified(archive, output, config)
        with (output / "checkpoint-source.json").open("x", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, ensure_ascii=False, allow_nan=False)
            stream.write("\n")
        print(json.dumps(report, indent=2, ensure_ascii=True))
        return 0
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"Checkpoint acquisition failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
