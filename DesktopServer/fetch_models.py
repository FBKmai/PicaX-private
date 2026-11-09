"""Fetch only allowlisted safetensors from pinned upstream archives.

Run from trusted source with python -I -B. Never extract upstream scripts or
import anything from a download directory. A destination must be new/empty.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.request
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from picax_lan.cli import ALIASES

ARCHIVES = {
    "detail": ("IllustrationJaNai_V3detail.zip", "27749962bc934779f867730cdb10617e3d7475313f920a7a966c56b75dbdbeda"),
    "denoise": ("IllustrationJaNai_V3denoise.zip", "6c26828ad8e142c9e9c7181451257f3f56a0f5c7f897d9c7878ce898404f53e5"),
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", choices=list(ALIASES), required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--download-parent", type=Path, required=True)
    parser.add_argument("--accept-noncommercial-license", action="store_true", required=True)
    args = parser.parse_args()
    if args.destination.exists() and (args.destination.is_symlink() or any(args.destination.iterdir())):
        parser.error("Destination must be a new or empty directory")
    args.destination.mkdir(parents=True, exist_ok=True)
    args.download_parent.mkdir(parents=True, exist_ok=True)
    models = [ALIASES[key] for key in dict.fromkeys(args.models)]
    evidence = []
    for kind, (name, expected) in ARCHIVES.items():
        selected = [model for model in models if ("denoise" in model.id) == (kind == "denoise")]
        if not selected:
            continue
        download = Path(tempfile.mkdtemp(prefix="picax-" + kind + "-", dir=args.download_parent))
        archive = download / name
        url = "https://github.com/the-database/MangaJaNai/releases/download/3.0.0/" + name
        print("Downloading", url, flush=True)
        request = urllib.request.Request(url + "?picax=" + uuid.uuid4().hex, headers={"User-Agent": "PicaX-LAN-model-fetch"})
        with urllib.request.urlopen(request, timeout=120) as response, archive.open("xb") as output:
            count = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > 512 * 1024 * 1024:
                    raise RuntimeError("Archive exceeded limit")
                output.write(chunk)
        if digest(archive) != expected:
            raise RuntimeError("Upstream archive SHA-256 mismatch; left isolated for inspection")
        with zipfile.ZipFile(archive) as container:
            for model in selected:
                matches = [info for info in container.infolist() if Path(info.filename).name == model.file]
                if len(matches) != 1 or not 0 < matches[0].file_size <= 512 * 1024 * 1024:
                    raise RuntimeError("Missing/ambiguous/oversized checkpoint: " + model.file)
                # Basename is from our allowlist, not the archive's path.
                target = args.destination / model.file
                with container.open(matches[0]) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                if digest(target) != model.sha256:
                    raise RuntimeError("Individual checkpoint SHA-256 mismatch: " + model.file)
                evidence.append({"modelID": model.id, "file": model.file, "sha256": model.sha256,
                                 "archiveURL": url, "archiveSHA256": expected})
                print("Verified", model.id, target.stat().st_size, "bytes", flush=True)
    (args.destination / "provenance.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print("Weights:", args.destination.resolve(), flush=True)


if __name__ == "__main__":
    main()
