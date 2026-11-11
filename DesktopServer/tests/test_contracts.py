"""Stdlib-only tests. No Torch, Pillow, network or GPU imports are required."""
import copy
from contextlib import nullcontext, redirect_stderr, redirect_stdout
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
from unittest.mock import MagicMock, Mock, call, patch
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
            "deviceName": "explicit test fixture; no AI was run", "precision": body.get("precision", "float32"), "torchVersion": "test-only",
            "cudaVersion": "none", "license": LICENSE, "sourceURL": SOURCE, "mode": "fullPage",
            "downsampling": "lanczos" if scale < body["nativeScale"] else "none", "seconds": 1.0}


class ProtocolTests(unittest.TestCase):
    def test_all_models_and_delivery_scales(self):
        for model in MODELS:
            for scale in model.delivery_scales:
                body = spec(model, scale)
                self.assertIs(validate_spec(body), body)
                validate_result(result(body), body, body["pages"][0])

    def test_job_precision_is_optional_but_results_must_match(self):
        for precision in (None, "float32", "bfloat16"):
            body = spec()
            if precision is not None:
                body["precision"] = precision
            self.assertIs(validate_spec(body), body)
            value = result(body)
            self.assertEqual(value["precision"], precision or "float32")
            validate_result(value, body, body["pages"][0])
            value["precision"] = "bfloat16" if value["precision"] == "float32" else "float32"
            with self.assertRaises(ProtocolError): validate_result(value, body, body["pages"][0])
        for precision in ("float16", "auto", None, True, 16, [], {}):
            body = spec(); body["precision"] = precision
            with self.subTest(precision=precision), self.assertRaises(ProtocolError): validate_spec(body)

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

    def test_delivery_and_input_decoder_limits_are_separate(self):
        body = spec(MODELS[-2], 4); body["pages"][0].update(width=1500, height=1500)
        with self.assertRaises(ProtocolError) as error: validate_spec(body)
        self.assertEqual(error.exception.status, 413)
        self.assertIn("phone's receive limits", str(error.exception))
        body = spec(); body["pages"][0].update(width=65, height=64)
        with self.assertRaises(ProtocolError) as error: validate_spec(body, maximum_pixels=4096)
        self.assertIn("input decoder limit", str(error.exception))

    def test_all_models_accept_large_pages_without_model_or_native_pixel_ceiling(self):
        # Manifest-only checks; no large image buffers or model loading.
        for model in MODELS:
            for width, height in ((1280, 1864), (2000, 3000), (2000, 4000)):
                with self.subTest(model=model.id, size=(width, height)):
                    body = spec(model); body["pages"][0].update(width=width, height=height)
                    self.assertIs(validate_spec(body, maximum_side=4096), body)
                    self.assertEqual(model.capability(4096, 8_000_000)["maximumInputPixels"], 8_000_000)

    def test_input_decoder_limit_counts_original_not_aligned_pixels(self):
        for model in MODELS:
            with self.subTest(model=model.id):
                body = spec(model); body["pages"][0].update(width=65, height=63)
                self.assertIs(validate_spec(body, maximum_pixels=4096), body)
                body["pages"][0].update(width=2001, height=4000)
                with self.assertRaises(ProtocolError) as error: validate_spec(body)
                self.assertIn("input decoder limit", str(error.exception))

    def test_configured_alignment_side_limit_is_still_enforced(self):
        body = spec(MODELS[0]); body["pages"][0].update(width=100, height=64)
        with self.assertRaises(ProtocolError) as error: validate_spec(body, maximum_side=100)
        self.assertIn("configured side limit", str(error.exception))

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
    def test_cli_starts_plain_http_with_legacy_flag_and_disk_quotas(self):
        from picax_lan.cli import main
        from picax_lan import worker as worker_module
        cases = (([], 8, 16), (["--pair"], 8, 16),
                 (["--job-quota-gib", "32", "--total-quota-gib", "64"], 32, 64))
        for flags, job_gib, total_gib in cases:
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / MODELS[-2].file).touch()  # Worker is mocked; no checkpoint is loaded.
                worker = SimpleNamespace(thread=SimpleNamespace(ident=None), start=Mock())
                run = Mock()
                output = io.StringIO()
                with patch.dict(sys.modules, {"uvicorn": SimpleNamespace(run=run), "qrcode": SimpleNamespace(QRCode=Mock())}), \
                     patch.object(worker_module, "Worker", return_value=worker) as worker_factory, \
                     patch("picax_lan.cli.JobStore", wraps=JobStore) as store_factory, \
                     patch("picax_lan.server.create_app", return_value="http-app"), redirect_stdout(output):
                    main(["--host", "192.168.5.8", "--weights-dir", str(root), "--data-dir", str(root / "data"),
                          "--no-discovery", "--accept-noncommercial-license"] + flags)
                self.assertEqual(store_factory.call_args.kwargs,
                                 {"job_quota": job_gib * 1024**3, "total_quota": total_gib * 1024**3})
                self.assertEqual(worker_factory.call_args.args[1]["precisions"], {MODELS[-2].id: "float32"})
                self.assertEqual(worker_factory.call_args.args[1]["hat_window_batch"], 128)
                self.assertEqual(worker_factory.call_args.args[1]["hat_attention_backend"], "eager")
                worker.start.assert_called_once()
                run.assert_called_once()
                self.assertEqual(run.call_args.args, ("http-app",))
                self.assertFalse(any(key.startswith("ssl_") for key in run.call_args.kwargs))
                self.assertIn("http://192.168.5.8:18443", output.getvalue())
                self.assertNotIn("pairingSecret", output.getvalue())
                self.assertFalse((root / "data" / "identity").exists())

    def test_cli_precision_overrides_and_invalid_selections(self):
        from picax_lan.cli import main
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for model in (MODELS[0], MODELS[-2]):
                (root / model.file).touch()  # No real weights are loaded.
            base = ["--host", "192.168.5.8", "--weights-dir", str(root), "--data-dir", str(root / "data"),
                    "--models", "hat-l", "fdat-xl", "--no-discovery", "--accept-noncommercial-license"]
            for flags, expected, window_batch, backend in (
                (["--model-precision", "hat-l=bfloat16", "--hat-window-batch", "0"],
                 {MODELS[0].id: "bfloat16", MODELS[-2].id: "float32"}, 0, "eager"),
                (["--precision", "bfloat16", "--model-precision", "hat-l=bfloat16", "--model-precision", "hat-l=float32",
                  "--hat-window-batch", "256", "--hat-attention-backend", "sdpa"],
                 {MODELS[0].id: "float32", MODELS[-2].id: "bfloat16"}, 256, "sdpa"),
            ):
                worker = SimpleNamespace(thread=SimpleNamespace(ident=None), start=Mock())
                with patch.dict(sys.modules, {"uvicorn": SimpleNamespace(run=Mock()), "qrcode": SimpleNamespace(QRCode=Mock())}), \
                     patch("picax_lan.worker.Worker", return_value=worker) as factory, \
                     patch("picax_lan.server.create_app", return_value="http-app"), redirect_stdout(io.StringIO()):
                    main(base + flags)
                self.assertEqual(factory.call_args.args[1]["precisions"], expected)
                self.assertEqual(factory.call_args.args[1]["hat_window_batch"], window_batch)
                self.assertEqual(factory.call_args.args[1]["hat_attention_backend"], backend)
            for flags in (["--model-precision", "hat-l=float16"], ["--model-precision", "fdat-m=bfloat16"],
                          ["--model-precision", "hat-l"], ["--device", "cpu", "--precision", "bfloat16"],
                          ["--hat-window-batch", "-1"], ["--hat-window-batch", "4097"],
                          ["--hat-window-batch", "1.5"], ["--hat-attention-backend", "math"],
                          ["--hat-window-batch", "0", "--hat-attention-backend", "sdpa"],
                          ["--device", "cpu", "--hat-attention-backend", "sdpa"]):
                with self.subTest(flags=flags), patch("picax_lan.cli.JobStore") as factory, redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error: main(base + flags)
                    self.assertEqual(error.exception.code, 2)
                    factory.assert_not_called()

    def test_invalid_disk_quotas_rejected_before_storage_is_opened(self):
        from picax_lan.cli import main
        for job_gib, total_gib in (("0", "16"), ("-1", "16"), ("17", "16"), ("8", "0"), ("1.5", "16")):
            with self.subTest(job=job_gib, total=total_gib), \
                 patch("picax_lan.cli.JobStore") as store_factory, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    main(["--cleanup", "--job-quota-gib", job_gib, "--total-quota-gib", total_gib])
                self.assertEqual(error.exception.code, 2)
                store_factory.assert_not_called()


class HATOptionsTests(unittest.TestCase):
    def test_options_and_original_path_require_no_heavy_imports(self):
        from picax_lan.hat_memory import install, validate_options
        for count in (0, 1, 64, 128, 512, 4096):
            validate_options(count, "eager")
        validate_options(128, "sdpa")
        for count, backend in ((True, "eager"), (1.5, "eager"), (-1, "eager"), (4097, "eager"),
                               ("128", "eager"), (0, "sdpa"), (128, "math")):
            with self.subTest(count=count, backend=backend), self.assertRaises(ValueError):
                validate_options(count, backend)
        with patch.dict(sys.modules, {"torch": None, "spandrel": None}), \
             patch("picax_lan.hat_memory.version", side_effect=AssertionError("Original path must not inspect packages")):
            self.assertIsNone(install(object(), 0, "eager"))

    def test_diagnostics_log_sizes_and_memory_not_titles_or_content(self):
        from picax_lan.inference import Predictor
        predictor = Predictor.__new__(Predictor)
        predictor.settings = {"device": "cpu", "diagnostics": True}
        predictor.descriptor = MODELS[0]
        predictor.metadata = {"precision": "bfloat16", "attentionWindowBatch": 128, "attentionBackend": "eager"}
        predictor.torch = Mock()
        self.assertEqual(predictor.memory_snapshot(), {})
        predictor.torch.assert_not_called()
        output = io.StringIO()
        with redirect_stdout(output):
            predictor.diagnostic("pageStart", {"width": 960, "height": 1616, "chapterTitle": "private title"},
                                 {"allocatedBytes": 123})
        value = json.loads(output.getvalue().removeprefix("LAN inference "))
        self.assertEqual(value["memory"], {"allocatedBytes": 123})
        self.assertEqual((value["width"], value["height"], value["windowBatch"]), (960, 1616, 128))
        self.assertNotIn("private title", output.getvalue())
        self.assertNotIn("chapterTitle", value)
        predictor.settings["diagnostics"] = False
        with redirect_stdout(io.StringIO()) as quiet:
            predictor.diagnostic("pageStart", {"width": 1, "height": 1})
        self.assertEqual(quiet.getvalue(), "")


class InferenceContractTests(unittest.TestCase):
    """Mock only the inference boundary; never import Torch, NumPy or Pillow."""

    class CUDAOutOfMemoryError(RuntimeError):
        pass

    def test_startup_precision_support_without_vram_estimates(self):
        from picax_lan.inference import Predictor
        cases = [(model, None, True, True, "cuda", 128, "eager") for model in MODELS]
        cases += [(MODELS[0], "bfloat16", model_bf16, gpu_bf16, device, 128, "eager")
                  for model_bf16, gpu_bf16, device in ((True, True, "cuda"), (False, True, "cuda"),
                                                      (True, False, "cuda"), (True, True, "cpu"))]
        cases += [(MODELS[0], "bfloat16", True, True, "cuda", 0, "eager"),
                  (MODELS[0], "bfloat16", True, True, "cuda", 64, "sdpa"),
                  (MODELS[0], None, True, True, "cpu", 64, "sdpa")]
        for model, precision, model_bf16, gpu_bf16, device, window_batch, backend in cases:
            with self.subTest(model=model.id, precision=precision, model_bf16=model_bf16, gpu_bf16=gpu_bf16,
                              device=device, window_batch=window_batch, backend=backend):
                torch = MagicMock()
                torch.__version__ = "test-only"
                torch.version.cuda = "test-only"
                torch.cuda.is_available.return_value = True
                torch.cuda.get_device_capability.return_value = (8, 0)
                torch.cuda.get_device_name.return_value = "Mock GPU; no model loaded"
                torch.cuda.is_bf16_supported.return_value = gpu_bf16
                torch.get_num_threads.return_value = 4
                torch.cuda.mem_get_info.side_effect = AssertionError("No startup VRAM estimate allowed")
                descriptor_type = type("TestDescriptor", (SimpleNamespace,), {})
                detected = descriptor_type(architecture=SimpleNamespace(id=model.architecture), scale=model.scale,
                    input_channels=3, output_channels=3, model=MagicMock(), supports_bfloat16=model_bf16,
                    size_requirements=SimpleNamespace(square=False, check=Mock(return_value=True), multiple_of=model.alignment))
                loader = SimpleNamespace(load_from_state_dict=Mock(return_value=detected))
                safetensors = SimpleNamespace(load=Mock(return_value={}))
                modules = {"numpy": SimpleNamespace(), "torch": torch,
                           "safetensors": SimpleNamespace(torch=safetensors), "safetensors.torch": safetensors,
                           "spandrel": SimpleNamespace(ImageModelDescriptor=descriptor_type, ModelLoader=Mock(return_value=loader),
                                                       canonicalize_state_dict=lambda value: value)}
                settings = {"model_id": model.id, "device": device, "noncommercial": True,
                            "hat_window_batch": window_batch, "hat_attention_backend": backend,
                            "weights": {model.id: "not-a-real-checkpoint"}, "maximum_pixels": 8_000_000}
                if precision is not None:
                    settings["precisions"] = {model.id: precision}
                contract = SimpleNamespace(checked_weight_bytes=Mock(return_value=b"test-only"))
                supported = ["float32"] + (["bfloat16"] if device == "cuda" and model_bf16 and gpu_bf16 else [])
                scheduler = SimpleNamespace(metadata=Mock(return_value={
                    "attentionImplementation": "mock-bounded-hat", "attentionWindowBatch": window_batch,
                    "attentionBackend": backend})) if window_batch else None
                with patch.dict(sys.modules, modules), \
                     patch("picax_lan.inference.install", return_value=scheduler) as installer, \
                     patch("picax_lan.inference.trusted_tooling", return_value=(contract, SimpleNamespace())):
                    if (precision or "float32") not in supported:
                        with self.assertRaisesRegex(RuntimeError, "no implicit precision fallback"): Predictor(settings)
                        detected.model.eval.assert_not_called()
                        installer.assert_not_called()
                        continue
                    if device == "cpu" and backend == "sdpa":
                        with self.assertRaisesRegex(RuntimeError, "Fused HAT SDPA requires CUDA"): Predictor(settings)
                        detected.model.eval.assert_not_called()
                        installer.assert_not_called()
                        continue
                    predictor = Predictor(settings)
                self.assertEqual(predictor.metadata["maximumInputPixels"], 8_000_000)
                self.assertEqual(predictor.metadata["precision"], precision or "float32")
                self.assertEqual(predictor.metadata["supportedPrecisions"], supported)
                if model.architecture == "HAT":
                    installer.assert_called_once_with(detected.model.eval.return_value.to.return_value, window_batch, backend)
                    self.assertEqual(predictor.metadata["attentionImplementation"],
                                     "mock-bounded-hat" if window_batch else "spandrel-original")
                    self.assertEqual(predictor.metadata["attentionWindowBatch"], window_batch)
                    self.assertEqual(predictor.metadata["attentionBackend"], backend)
                else:
                    installer.assert_not_called()
                    self.assertIsNone(predictor.hat_memory)
                    self.assertNotIn("attentionImplementation", predictor.metadata)
                detected.model.eval.return_value.to.assert_called_once_with(device=device, dtype=getattr(torch, precision or "float32"))
                detected.model.float.assert_not_called()
                torch.cuda.mem_get_info.assert_not_called()

    def test_large_page_reaches_actual_model_without_vram_estimate(self):
        from picax_lan.inference import Predictor
        for model in MODELS:
            with self.subTest(model=model.id):
                body = spec(model); page = body["pages"][0]
                page.update(width=2000, height=3000)
                predictor = Predictor.__new__(Predictor)
                predictor.descriptor = model
                predictor.settings = {"device": "cuda", "maximum_side": 4096, "maximum_pixels": 8_000_000}
                predictor.np, predictor.torch = MagicMock(), MagicMock()
                predictor.metadata = {"precision": "float32"}
                predictor.dtype = predictor.torch.float32
                predictor.torch.inference_mode.side_effect = nullcontext
                predictor.torch.cuda.mem_get_info.side_effect = AssertionError("No per-page VRAM estimate allowed")
                predictor.full_page = SimpleNamespace(pad_reflect=MagicMock())
                predictor.model = Mock(side_effect=self.CUDAOutOfMemoryError("simulated allocation failure"))
                image = MagicMock()
                image.open.return_value.__enter__.return_value.mode = "RGB"
                source, destination = Path("no-source-file.png"), Path("no-result-file.part")
                with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=image)}), \
                     patch("picax_lan.inference.validate_png"), \
                     patch("picax_lan.inference.digest_file", return_value=page["sha256"]):
                    with self.assertRaises(self.CUDAOutOfMemoryError):
                        predictor.predict(source, destination, page, body)
                predictor.model.assert_called_once_with(predictor.torch.from_numpy.return_value.to.return_value)
                predictor.torch.from_numpy.return_value.to.assert_called_once_with(device="cuda", dtype=predictor.torch.float32)
                predictor.torch.cuda.reset_peak_memory_stats.assert_called_once_with()
                predictor.torch.cuda.mem_get_info.assert_not_called()
                predictor.torch.cuda.memory_reserved.assert_called_once_with()
                predictor.torch.cuda.empty_cache.assert_not_called()
                pw, ph = padded_dimensions(page["width"], page["height"], model.alignment)
                self.assertEqual(predictor.full_page.pad_reflect.call_args.args[2:], (2000, 3000, pw, ph))

    def test_cuda_allocation_failure_is_reported_as_actual_single_page_oom(self):
        from picax_lan.inference import worker_main
        for failure, precision in ((self.CUDAOutOfMemoryError("test allocation failure"), "float32"),
                                   (self.CUDAOutOfMemoryError("test allocation failure"), "bfloat16"),
                                   (RuntimeError("test invalid output"), "float32")):
            with self.subTest(error=type(failure).__name__, precision=precision):
                body = spec(MODELS[0]); page = body["pages"][0]
                page.update(width=1280, height=1864)
                predictor = SimpleNamespace(metadata={"precision": precision}, descriptor=MODELS[0],
                    torch=SimpleNamespace(cuda=SimpleNamespace(OutOfMemoryError=self.CUDAOutOfMemoryError)),
                    memory_snapshot=Mock(return_value={"allocatedBytes": 123}),
                    diagnostic=Mock(side_effect=RuntimeError("simulated diagnostics failure")),
                    predict=Mock(side_effect=failure))
                connection = Mock()
                connection.recv.return_value = {"source": "source.png", "destination": "result.part", "page": page, "spec": body}
                with patch("picax_lan.inference.Predictor", return_value=predictor):
                    worker_main(connection, {"device": "cuda", "diagnostics": True})
                predictor.diagnostic.assert_called_once_with("error", page, {"allocatedBytes": 123})
                self.assertEqual(connection.send.call_args_list[0].args[0], {"ready": True, "metadata": predictor.metadata})
                error = connection.send.call_args_list[1].args[0]["error"]
                if isinstance(failure, self.CUDAOutOfMemoryError):
                    label = "BF16" if precision == "bfloat16" else "FP32"
                    for fragment in ("显存实际不足", "1280×1864", "原生 4×", label, "不是输入像素预估拦截", "未缩图、未分块、未换模型"):
                        self.assertIn(fragment, error)
                else:
                    self.assertEqual(error, "RuntimeError: test invalid output")
                connection.close.assert_called_once_with()
                connection.recv.assert_called_once_with()

    def test_bf16_input_and_cpu_float32_png_boundary(self):
        from picax_lan.inference import Predictor
        body = spec(MODELS[0]); body["precision"] = "bfloat16"
        page = body["pages"][0]
        page.update(width=63, height=65)  # Crop native padding and span three output bands.
        predictor = Predictor.__new__(Predictor)
        predictor.descriptor = MODELS[0]
        predictor.settings = {"device": "cuda", "maximum_side": 4096, "maximum_pixels": 8_000_000}
        predictor.np, predictor.torch = MagicMock(), MagicMock()
        predictor.hat_memory = SimpleNamespace(metadata=lambda: {"attentionWindowBatch": 128, "attentionMaxWindows": 128})
        for name, value in (("memory_allocated", 123), ("memory_reserved", 456),
                            ("max_memory_allocated", 789), ("max_memory_reserved", 1024)):
            getattr(predictor.torch.cuda, name).return_value = value
        predictor.torch.cuda.Event.return_value.elapsed_time.return_value = 1250.0
        predictor.dtype = predictor.torch.bfloat16
        predictor.torch.inference_mode.side_effect = nullcontext
        predictor.torch.isfinite.return_value.all.return_value.item.return_value = True
        predictor.metadata = result(body)
        predictor.full_page = SimpleNamespace(pad_reflect=MagicMock())
        output = MagicMock()
        output.shape = (1, 3, 512, 256)
        predictor.model = Mock(return_value=output)
        image = MagicMock()
        image.open.return_value.__enter__.return_value.mode = "RGB"
        destination = Mock()
        destination.stat.return_value.st_size = predictor.metadata["bytes"]
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=image)}), \
             patch("picax_lan.inference.validate_png"), \
             patch("picax_lan.inference.png_dimensions", return_value=(126, 130)), \
             patch("picax_lan.inference.digest_file", side_effect=[page["sha256"], predictor.metadata["sha256"]]):
            value = predictor.predict(Path("mock-input.png"), destination, page, body)
        self.assertEqual(value["precision"], "bfloat16")
        self.assertEqual(value["attentionWindowBatch"], 128)
        self.assertEqual(value["modelSeconds"], 1.25)
        self.assertEqual(value["peakAllocatedBytes"], 789)
        self.assertEqual(value["peakReservedBytes"], 1024)
        self.assertEqual(set(value["memoryStages"]), {"pageStart", "modelEnd", "outputReleased"})
        for stage in value["memoryStages"].values():
            self.assertEqual(stage, {"allocatedBytes": 123, "reservedBytes": 456,
                                     "peakAllocatedBytes": 789, "peakReservedBytes": 1024})
        self.assertIsInstance(value["workerPID"], int)
        self.assertGreaterEqual(value["postprocessSeconds"], 0)
        predictor.torch.cuda.Event.assert_has_calls([call(enable_timing=True), call(enable_timing=True)], any_order=True)
        predictor.torch.cuda.Event.return_value.synchronize.assert_called_once_with()
        predictor.torch.cuda.synchronize.assert_not_called()
        predictor.torch.cuda.empty_cache.assert_not_called()
        predictor.torch.from_numpy.return_value.to.assert_called_once_with(device="cuda", dtype=predictor.torch.bfloat16)
        self.assertEqual(output.__getitem__.call_args_list, [
            call((0, slice(None), slice(start, end), slice(None, 252)))
            for start, end in ((0, 128), (128, 256), (256, 260))])
        cropped = output.__getitem__.return_value.detach.return_value
        self.assertEqual(cropped.cpu.call_count, 3)
        cropped.float.assert_not_called()  # Never allocate a full-page FP32 copy on CUDA.
        cpu = cropped.cpu.return_value
        self.assertEqual(cpu.float.call_count, 3)
        cpu.numpy.assert_not_called()  # BF16 is not sent directly to NumPy.
        cpu.float.return_value.clamp_.assert_has_calls([call(0, 1)] * 3, any_order=True)
        self.assertEqual(cpu.float.return_value.clamp_.return_value.numpy.call_count, 3)
        predictor.np.empty.assert_called_once_with((260, 252, 3), dtype=predictor.np.uint8)
        self.assertEqual(predictor.np.rint.call_count, 3)
        self.assertEqual(predictor.np.clip.call_count, 3)
        for operation in (predictor.np.rint, predictor.np.clip):
            for entry in operation.call_args_list:
                self.assertIs(entry.args[0], entry.kwargs["out"])
        image.fromarray.return_value.resize.assert_called_once_with((126, 130), image.Resampling.LANCZOS)
        image.fromarray.return_value.resize.return_value.save.assert_called_once_with(destination, format="PNG")
        # Force the measured-pressure branch independently of CUDA internals.
        # Maintenance is after encoding, is optional, and does not erase peaks.
        after = {"allocatedBytes": 123, "reservedBytes": 128,
                 "peakAllocatedBytes": 789, "peakReservedBytes": 1024}
        maintenance = {"seconds": 0.01, "before": value["memoryStages"]["outputReleased"],
                       "after": after, "releasedBytes": 328, "deviceTotalBytes": 512}
        def release(memory):
            self.assertEqual(image.fromarray.return_value.resize.return_value.save.call_count, 2)
            self.assertEqual(memory, maintenance["before"])
            return maintenance
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=image)}), \
             patch("picax_lan.inference.validate_png"), \
             patch("picax_lan.inference.png_dimensions", return_value=(126, 130)), \
             patch("picax_lan.inference.digest_file", side_effect=[page["sha256"], predictor.metadata["sha256"]]), \
             patch.object(predictor, "release_idle_cache", side_effect=release) as trim:
            pressured = predictor.predict(Path("mock-input.png"), destination, page, body)
        trim.assert_called_once_with(maintenance["before"])
        self.assertEqual(pressured["cacheMaintenance"], maintenance)
        self.assertEqual(pressured["memoryStages"]["cacheReleased"], after)
        self.assertEqual((pressured["peakAllocatedBytes"], pressured["peakReservedBytes"]), (789, 1024))
        body["precision"] = "float32"
        with patch.dict(sys.modules, {"PIL": SimpleNamespace(Image=image)}):
            with self.assertRaisesRegex(RuntimeError, "Job precision differs"):
                predictor.predict(Path("mock-input.png"), destination, page, body)
        self.assertEqual(predictor.model.call_count, 2)

    def test_idle_cache_trim_only_for_optimized_cuda_hat_under_pressure(self):
        from picax_lan.inference import Predictor
        gib = 1024**3
        # No model changes, live allocation cap, free-memory estimate or reload.
        for device, model, adapter, reserved, allocated, expected in (
            ("cpu", MODELS[0], True, 30*gib, gib, False),
            ("cuda", MODELS[-1], False, 30*gib, gib, False),
            ("cuda", MODELS[0], False, 30*gib, gib, False),
            ("cuda", MODELS[0], True, 20*gib, 20*gib - gib + 1, False),
            ("cuda", MODELS[0], True, 16*gib, gib, False),  # Exactly 80% of 20 GiB.
            ("cuda", MODELS[0], True, 16*gib + 1, gib, True),
            ("cuda", MODELS[0], True, 20*gib, 19*gib, True),  # Exactly 1 GiB idle.
            ("cuda", MODELS[0], True, 40*gib, 30*gib, True),  # Even live > capacity is not rejected.
        ):
            with self.subTest(device=device, model=model.id, adapter=adapter, reserved=reserved, allocated=allocated):
                predictor = Predictor.__new__(Predictor)
                predictor.settings = {"device": device}
                predictor.descriptor, predictor.hat_memory = model, object() if adapter else None
                predictor.torch = MagicMock()
                predictor.torch.cuda.get_device_properties.return_value.total_memory = 20*gib
                after = {"allocatedBytes": allocated, "reservedBytes": allocated,
                         "peakAllocatedBytes": 40*gib, "peakReservedBytes": 40*gib}
                predictor.memory_snapshot = Mock(return_value=after)
                before = {"allocatedBytes": allocated, "reservedBytes": reserved,
                          "peakAllocatedBytes": 40*gib, "peakReservedBytes": 40*gib}
                untouched = dict(before)
                value = predictor.release_idle_cache(before)
                self.assertEqual(before, untouched)
                if expected:
                    predictor.torch.cuda.empty_cache.assert_called_once_with()
                    predictor.memory_snapshot.assert_called_once_with()
                    self.assertEqual(value["releasedBytes"], reserved - allocated)
                    self.assertEqual(value["before"], before)
                    self.assertEqual(value["after"], after)
                    self.assertGreaterEqual(value["seconds"], 0)
                else:
                    self.assertIsNone(value)
                    predictor.torch.cuda.empty_cache.assert_not_called()
                    predictor.memory_snapshot.assert_not_called()
                predictor.torch.cuda.mem_get_info.assert_not_called()
                predictor.torch.cuda.set_per_process_memory_fraction.assert_not_called()
                predictor.torch.cuda.synchronize.assert_not_called()

    def test_supervisor_reloads_precision_and_keeps_legacy_jobs_fp32(self):
        from picax_lan.worker import Worker
        model = MODELS[0]
        bodies = [spec(model) for _ in range(4)]
        for body, precision in zip(bodies, ("bfloat16", "float32", None, "bfloat16")):
            if precision is not None:
                body["precision"] = precision
        with tempfile.TemporaryDirectory() as directory:
            store = Mock()
            store.spec.side_effect = {body["jobID"]: body for body in bodies}.__getitem__
            store.path.side_effect = lambda job, page, name: Path(directory) / (job + "-" + page + "-" + name)
            store.next_page.side_effect = [(body["jobID"], body["pages"][0]) for body in bodies]
            store.state.return_value = "running"
            for body in bodies:
                store.path(body["jobID"], body["pages"][0]["id"], "result.part").write_bytes(png(128, 128))
            connection = Mock()
            connection.poll.return_value = True
            connection.recv.side_effect = [{"result": result(body)} for body in bodies]
            process = Mock()
            process.is_alive.return_value = True
            worker = Worker(store, {"weights": {model.id: "mock"}, "precisions": {model.id: "bfloat16"}, "timeout": 10})
            worker.stop_event = Mock()
            worker.stop_event.is_set.return_value = False
            worker.stop_event.wait.side_effect = [False] * len(bodies) + [True]
            def launch(model_id, precision=None):
                worker.current_model = model_id
                worker.current_precision = precision or "bfloat16"
                worker.process, worker.connection = process, connection
                return True
            worker.launch = Mock(side_effect=launch)
            worker.run()
            self.assertEqual(worker.launch.call_args_list, [call(model.id), call(model.id, "float32"), call(model.id, "bfloat16")])
            self.assertEqual([entry.kwargs["result"]["precision"] for entry in store.finish_page.call_args_list],
                             ["bfloat16", "float32", "float32", "bfloat16"])
            self.assertEqual([entry.args[0]["spec"] for entry in connection.send.call_args_list], bodies)

    def test_worker_process_handles_each_page_in_separate_predict_call(self):
        from picax_lan.inference import worker_main
        body = spec(pages=2)
        work = [{"source": f"source-{index}.png", "destination": f"result-{index}.part", "page": page, "spec": body}
                for index, page in enumerate(body["pages"])]
        predictor = SimpleNamespace(metadata={"test": True}, predict=Mock(side_effect=[{"page": 0}, {"page": 1}]))
        connection = Mock()
        connection.recv.side_effect = [*work, None]
        with patch("picax_lan.inference.Predictor", return_value=predictor):
            worker_main(connection, {"device": "cuda"})
        self.assertEqual([entry.args for entry in predictor.predict.call_args_list],
                         [(Path(item["source"]), Path(item["destination"]), item["page"], body) for item in work])
        self.assertEqual([entry.args[0] for entry in connection.send.call_args_list[1:]],
                         [{"result": {"page": 0}}, {"result": {"page": 1}}])
        connection.close.assert_called_once_with()


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

    def test_selected_precision_survives_recovery_and_cannot_change_in_place(self):
        body = spec(); body["precision"] = "bfloat16"
        self.store.create(self.owner, body, 8192, 8_000_000)
        self.store.recover()
        self.assertEqual(self.store.spec(body["jobID"])["precision"], "bfloat16")
        changed = copy.deepcopy(body); changed["precision"] = "float32"
        with self.assertRaises(ProtocolError): self.store.create(self.owner, changed, 8192, 8_000_000)
        self.assertNotIn("precision", self.store.spec(self.body["jobID"]))  # Legacy spec stays unchanged.

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
        candidate = spec()
        with self.assertRaises(ProtocolError) as error:
            self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertEqual(error.exception.status, 507)
        self.assertIn("单任务磁盘配额不足", str(error.exception))
        self.assertIn("--job-quota-gib", str(error.exception))
        self.assertIn("清理旧任务不会解除单任务上限", str(error.exception))
        self.assertFalse(self.store.directory(candidate["jobID"]).exists())
        for page in ("../../oops", "e0000-p0000/../../oops"):
            with self.assertRaises(ProtocolError): self.store.path(self.body["jobID"], page, "source.png")

    def test_total_quota_rejection_is_distinct_from_single_task_limit(self):
        reserved = self.store.db.execute("SELECT reserved FROM jobs WHERE id=?", (self.body["jobID"],)).fetchone()[0]
        self.store.job_quota = reserved
        self.store.total_quota = reserved * 2 - 1
        candidate = spec()
        with self.assertRaises(ProtocolError) as error:
            self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertEqual(error.exception.status, 507)
        self.assertIn("任务总磁盘配额不足", str(error.exception))
        self.assertIn("已有任务预留", str(error.exception))
        self.assertIn("--total-quota-gib", str(error.exception))
        self.assertFalse(self.store.directory(candidate["jobID"]).exists())

    def test_disk_space_rejection_is_distinct_from_configured_quota(self):
        reserved = self.store.db.execute("SELECT reserved FROM jobs WHERE id=?", (self.body["jobID"],)).fetchone()[0]
        candidate = spec()
        with patch("picax_lan.jobs.shutil.disk_usage", return_value=SimpleNamespace(free=reserved + 128 * 1024**2 - 1)):
            with self.assertRaises(ProtocolError) as error:
                self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertEqual(error.exception.status, 507)
        self.assertIn("实际剩余空间不足", str(error.exception))
        self.assertIn("提高任务配额不能解决", str(error.exception))
        self.assertFalse(self.store.directory(candidate["jobID"]).exists())

    def test_larger_quota_accepts_large_manifest_without_bypassing_real_disk_check(self):
        # Manifest only: never allocate large images, weights or disk files.
        candidate = spec(pages=256)
        for page in candidate["pages"]:
            page.update(width=1280, height=1864, bytes=3_000_000)
        with self.assertRaises(ProtocolError) as error:
            self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertIn("单任务磁盘配额不足", str(error.exception))
        self.store.job_quota = 32 * 1024**3
        self.store.total_quota = 64 * 1024**3
        with patch("picax_lan.jobs.shutil.disk_usage", return_value=SimpleNamespace(free=1024**3)):
            with self.assertRaises(ProtocolError) as error:
                self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertIn("实际剩余空间不足", str(error.exception))
        with patch("picax_lan.jobs.shutil.disk_usage", return_value=SimpleNamespace(free=64 * 1024**3)):
            status = self.store.create(self.owner, candidate, 8192, 8_000_000)
        self.assertEqual(status["state"], "uploading")
        self.assertEqual(len(status["pages"]), 256)
        self.assertEqual(list(self.store.directory(candidate["jobID"]).iterdir()), [])

    def test_quota_boundaries_and_idempotent_recovery(self):
        reserved = self.store.db.execute("SELECT reserved FROM jobs WHERE id=?", (self.body["jobID"],)).fetchone()[0]
        self.store.job_quota = reserved
        self.store.total_quota = reserved * 2
        candidate = spec()
        self.assertEqual(self.store.create(self.owner, candidate, 8192, 8_000_000)["state"], "uploading")
        self.store.job_quota = self.store.total_quota = 1
        self.assertEqual(self.store.create(self.owner, candidate, 8192, 8_000_000)["state"], "uploading")

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
