"""Versioned, stdlib-only wire contracts shared by HTTP, storage and tests."""
import hashlib
import ipaddress
import json
import re
import struct
import uuid

from .models import LICENSE, MODELS, PRECISIONS, SOURCE as MODEL_SOURCE, get_model

VERSION = 1
# Compatibility names for the previously verified mobile baseline.
MODEL_ID = MODELS[-1].id
MODEL_SHA256 = MODELS[-1].sha256
MODEL_FILE = MODELS[-1].file
MAX_JSON = 2 * 1024 * 1024
MAX_INPUT_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_BYTES = 128 * 1024 * 1024
MAX_SIDE = 8192
MAX_PIXELS = 8_000_000
MAX_PAGES = 4096
MAX_OUTPUT_PIXELS = 32_000_000
MAX_OUTPUT_SIDE = 16384
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
PAGE_RE = re.compile(r"e[0-9]{4}-p[0-9]{4}\Z")


class ProtocolError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(256 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def identifier(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError):
        raise ProtocolError("Invalid UUID") from None
    return value


def integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ProtocolError("Invalid " + name)
    return value


def text(value, limit, name):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > limit:
        raise ProtocolError("Invalid " + name)
    if any(ord(char) < 32 for char in value):
        raise ProtocolError("Control characters in " + name)
    return value


def exact_keys(obj, keys):
    if not isinstance(obj, dict) or set(obj) != set(keys):
        raise ProtocolError("Unexpected or missing fields")


def local_address(value, allow_loopback=False):
    """Deliberately exclude public, multicast, unspecified and CGNAT addresses."""
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise ProtocolError("Use a literal LAN IP address") from None
    if address.is_loopback and allow_loopback:
        return str(address)
    networks = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10")
    if not any(address in ipaddress.ip_network(network) for network in networks):
        raise ProtocolError("Address must be on a private LAN")
    return str(address)


def page_id(chapter, page):
    integer(chapter, 0, 9999, "chapterIndex")
    integer(page, 0, 9999, "pageIndex")
    return "e%04d-p%04d" % (chapter, page)


def validate_spec(body, maximum_side=MAX_SIDE, maximum_pixels=MAX_PIXELS):
    keys = ("version", "jobID", "sourceRecordID", "title", "modelID", "modelSHA256", "nativeScale", "deliveryScale", "mode", "pages")
    # Optional for legacy clients/jobs; new phone jobs pin their chosen precision.
    if isinstance(body, dict) and "precision" in body:
        keys += ("precision",)
    exact_keys(body, keys)
    if "precision" in body and body["precision"] not in PRECISIONS:
        raise ProtocolError("Unsupported job precision", 409)
    if body["version"] != VERSION or type(body["version"]) is not int:
        raise ProtocolError("Unsupported protocol version", 409)
    identifier(body["jobID"])
    text(body["sourceRecordID"], 512, "sourceRecordID")
    text(body["title"], 1024, "title")
    model = get_model(body["modelID"])
    native = integer(body["nativeScale"], 2, 4, "nativeScale")
    scale = integer(body["deliveryScale"], 2, 4, "deliveryScale")
    if body["modelSHA256"] != model.sha256 or native != model.scale or scale not in model.delivery_scales or body["mode"] != "fullPage":
        raise ProtocolError("Model identity, scale or mode mismatch", 409)
    pages = body["pages"]
    if not isinstance(pages, list) or not 1 <= len(pages) <= MAX_PAGES:
        raise ProtocolError("Invalid page count")
    seen = set()
    chapter_titles = {}
    chapter_pages = {}
    for page in pages:
        exact_keys(page, ("id", "chapterIndex", "chapterTitle", "pageIndex", "width", "height", "bytes", "sha256"))
        expected_id = page_id(page["chapterIndex"], page["pageIndex"])
        if page["id"] != expected_id or expected_id in seen:
            raise ProtocolError("Duplicate or invalid page ID")
        seen.add(expected_id)
        title = text(page["chapterTitle"], 1024, "chapterTitle")
        if chapter_titles.setdefault(page["chapterIndex"], title) != title:
            raise ProtocolError("Inconsistent chapter title")
        chapter_pages.setdefault(page["chapterIndex"], []).append(page["pageIndex"])
        width = integer(page["width"], 1, min(MAX_SIDE, maximum_side), "width")
        height = integer(page["height"], 1, min(MAX_SIDE, maximum_side), "height")
        padded_width, padded_height = padded_dimensions(width, height, model.alignment)
        if width * height > min(MAX_PIXELS, maximum_pixels):
            raise ProtocolError("Page exceeds the configured input decoder limit", 413)
        if padded_width > maximum_side or padded_height > maximum_side:
            raise ProtocolError("Aligned page exceeds the configured side limit", 413)
        if width * height * scale**2 > MAX_OUTPUT_PIXELS or max(width, height) * scale > MAX_OUTPUT_SIDE:
            raise ProtocolError("Delivered image exceeds the phone's receive limits", 413)
        integer(page["bytes"], 1, MAX_INPUT_BYTES, "bytes")
        if not isinstance(page["sha256"], str) or not SHA_RE.fullmatch(page["sha256"]):
            raise ProtocolError("Invalid SHA-256")
    if sorted(chapter_pages) != list(range(len(chapter_pages))):
        raise ProtocolError("Chapter indices must be compact")
    for indices in chapter_pages.values():
        if sorted(indices) != list(range(len(indices))):
            raise ProtocolError("Page indices must be contiguous")
    if len(canonical(body).encode("utf-8")) > MAX_JSON:
        raise ProtocolError("Manifest is too large", 413)
    return body


def padded_dimensions(width, height, alignment=16):
    return (max(64, (width + alignment - 1) // alignment * alignment),
            max(64, (height + alignment - 1) // alignment * alignment))


def reflected(coordinate, length):
    if length <= 0:
        raise ProtocolError("Invalid reflection dimension")
    if length == 1:
        return 0
    position = coordinate % ((length - 1) * 2)
    return position if position < length else (length - 1) * 2 - position


def validate_result(result, spec, page):
    """Worker and phone use the same identity and delivered-size invariants."""
    import math
    model = get_model(spec["modelID"])
    scale = spec["deliveryScale"]
    if not isinstance(result, dict):
        raise ProtocolError("Missing result metadata", 422)
    if spec.get("precision", "float32") not in PRECISIONS:
        raise ProtocolError("Unsupported job precision", 422)
    expected = {"modelID": model.id, "modelSHA256": model.sha256,
                "nativeScale": model.scale, "deliveryScale": scale,
                "width": page["width"] * scale, "height": page["height"] * scale,
                "precision": spec.get("precision", "float32"), "mode": "fullPage", "engine": "PyTorch",
                "downsampling": "lanczos" if scale < model.scale else "none"}
    if any(result.get(key) != value or (type(value) is int and type(result.get(key)) is not int)
           for key, value in expected.items()):
        raise ProtocolError("Result identity/scale/dimensions mismatch", 422)
    integer(result.get("bytes"), 1, MAX_OUTPUT_BYTES, "result bytes")
    if not isinstance(result.get("sha256"), str) or not SHA_RE.fullmatch(result["sha256"]):
        raise ProtocolError("Invalid result SHA-256", 422)
    if result.get("device") not in ("cuda", "cpu") or result.get("license") != LICENSE or result.get("sourceURL") != MODEL_SOURCE:
        raise ProtocolError("Invalid inference provenance", 422)
    for field in ("deviceName", "torchVersion", "cudaVersion"):
        text(result.get(field), 256, field)
    seconds = result.get("seconds")
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 0:
        raise ProtocolError("Invalid result duration", 422)
    return result


def png_dimensions(path, maximum_bytes, maximum_pixels):
    """Bound dimensions before asking an image decoder to allocate a raster.

    This is only a header check; production uploads additionally use Pillow's
    verify/load. Tests can exercise limits without importing an image library.
    """
    if not 0 < path.stat().st_size <= maximum_bytes:
        raise ProtocolError("PNG exceeds the encoded size limit", 413)
    with path.open("rb") as stream:
        header = stream.read(33)
    if len(header) != 33 or header[:8] != PNG_SIGNATURE or header[8:16] != b"\x00\x00\x00\rIHDR":
        raise ProtocolError("Expected PNG with IHDR")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", header[16:29])
    if not width or not height or width * height > maximum_pixels:
        raise ProtocolError("PNG exceeds the decoded pixel limit", 413)
    if depth != 8 or color not in (2, 6) or compression or filtering or interlace not in (0, 1):
        raise ProtocolError("Only 8-bit RGB/RGBA PNG is supported")
    return width, height
