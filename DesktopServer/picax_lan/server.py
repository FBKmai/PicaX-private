"""Plain HTTP on a trusted LAN; no pairing, TLS or bearer authentication."""
import asyncio
import json
import logging
import time

from .inference import validate_png
from .models import MODELS
from .protocol import (VERSION, MAX_JSON, MAX_INPUT_BYTES, MAX_OUTPUT_BYTES,
                       MAX_OUTPUT_PIXELS, MAX_OUTPUT_SIDE, ProtocolError, exact_keys,
                       validate_spec)


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate key")
            result[key] = value
        return result
    def reject_constant(_):
        raise ValueError("Nonfinite JSON")
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=reject_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise ProtocolError("Invalid JSON") from None


def create_app(store, worker, settings):
    from fastapi import FastAPI, Request
    from fastapi.responses import FileResponse, JSONResponse
    # FastAPI resolves forward annotations in module globals, not this scope.
    globals()["Request"] = Request
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    uploads = asyncio.Semaphore(2)
    busy_pages = set()

    @app.exception_handler(ProtocolError)
    async def protocol_error(request, error):
        return JSONResponse({"error": str(error)}, status_code=error.status)

    @app.middleware("http")
    async def private_transport(request, call_next):
        started = time.monotonic()
        response = None
        try:
            if request.headers.get("content-encoding", "identity") != "identity":
                raise ProtocolError("Compressed request bodies are not accepted", 415)
            response = await call_next(request)
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
            return response
        except ProtocolError as error:
            response = JSONResponse({"error": str(error)}, status_code=error.status)
            return response
        finally:
            if settings.get("diagnostics"):
                # Only registered route templates are logged. Never log raw
                # URLs, query strings, headers, request bodies or responses.
                route = getattr(request.scope.get("route"), "path", "unmatched")
                method = request.method if request.method in {"GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"} else "OTHER"
                logging.getLogger("uvicorn.error").info(
                    "LAN request peer=%s method=%s route=%s status=%s elapsed_ms=%.1f",
                    request.client.host if request.client else "unknown", method, route,
                    response.status_code if response is not None else 500,
                    (time.monotonic() - started) * 1000,
                )

    def client(request):
        # A nonsecret grouping label, not authentication. No registration needed;
        # simple HTTP clients without the header share the default LAN group.
        return request.headers.get("x-picax-client-id") or "lan"

    async def read_json(request, maximum=MAX_JSON):
        if request.headers.get("content-type", "").split(";")[0].lower() != "application/json":
            raise ProtocolError("Expected application/json", 415)
        body = bytearray()
        async def read():
            async for chunk in request.stream():
                if len(body) + len(chunk) > maximum:
                    raise ProtocolError("JSON body too large", 413)
                body.extend(chunk)
        try:
            await asyncio.wait_for(read(), timeout=30)
        except asyncio.TimeoutError:
            raise ProtocolError("Request timed out", 408) from None
        return strict_json(body)

    @app.get("/")
    async def health():
        return {"status": "ok", "service": "PicaX LAN", "transport": "http",
                "serverID": store.server_id}

    @app.get("/v1/capabilities")
    async def capabilities():
        models = []
        for model in MODELS:
            if model.id not in settings["weights"]:
                continue
            state = worker.model_states.get(model.id, {})
            capability = model.capability(settings["maximum_side"], settings["maximum_pixels"])
            models.append(dict(capability, ready=bool(state.get("ready")), error=state.get("error")))
        ready = [model for model in models if model["ready"]]
        default = next((model["id"] for model in ready if "fdat-xl" in model["id"]), ready[0]["id"] if ready else None)
        return {"version": VERSION, "serverID": store.server_id, "models": models,
                "defaultModelID": default, "defaultDeliveryScale": 2,
                "maximumInputBytes": MAX_INPUT_BYTES, "maximumOutputBytes": MAX_OUTPUT_BYTES,
                "maximumOutputPixels": MAX_OUTPUT_PIXELS, "maximumOutputSide": MAX_OUTPUT_SIDE,
                "maximumPages": 4096, "retentionSeconds": settings.get("retention", 86400)}

    @app.post("/v1/jobs")
    async def create_job(request: Request):
        owner = client(request)
        body = await read_json(request)
        validate_spec(body, settings["maximum_side"], settings["maximum_pixels"])
        state = worker.model_states.get(body["modelID"], {})
        if body["modelID"] not in settings["weights"] or not state.get("ready"):
            raise ProtocolError("Selected model is not configured and verified", 503)
        return await asyncio.to_thread(store.create, owner, body, settings["maximum_side"], settings["maximum_pixels"])

    @app.get("/v1/jobs/{job_id}")
    async def status(job_id: str, request: Request):
        return await asyncio.to_thread(store.status, job_id, client(request))

    @app.put("/v1/jobs/{job_id}/pages/{page_id}")
    async def upload(job_id: str, page_id: str, request: Request):
        owner = client(request)
        page, state = await asyncio.to_thread(store.page, job_id, owner, page_id)
        if state == "cancelled":
            raise ProtocolError("Job cancelled", 409)
        if request.headers.get("content-type") != "image/png":
            raise ProtocolError("Expected image/png", 415)
        length = request.headers.get("content-length")
        if length is not None and (not length.isdecimal() or int(length) != page["bytes"]):
            raise ProtocolError("Content-Length differs from manifest", 422)
        key = (job_id, page_id)
        if key in busy_pages:
            raise ProtocolError("This page is already uploading", 409)
        busy_pages.add(key)
        acquired = False
        temporary = None
        try:
            try:
                await asyncio.wait_for(uploads.acquire(), timeout=5)
                acquired = True
            except asyncio.TimeoutError:
                raise ProtocolError("Upload connections busy", 429) from None
            temporary = store.path(job_id, page_id, "source.part")
            # No other HTTP handler can open this page's staging path.
            received = 0
            async def receive():
                nonlocal received
                with temporary.open("xb") as stream:
                    async for chunk in request.stream():
                        received += len(chunk)
                        if received > min(page["bytes"], MAX_INPUT_BYTES):
                            raise ProtocolError("Input body exceeds manifest", 413)
                        await asyncio.to_thread(stream.write, chunk)
                    stream.flush()
                if received != page["bytes"]:
                    raise ProtocolError("Truncated input body", 422)
            try:
                await asyncio.wait_for(receive(), timeout=180)
            except asyncio.TimeoutError:
                raise ProtocolError("Upload timed out", 408) from None
            await asyncio.to_thread(validate_png, temporary, (page["width"], page["height"]))
            await asyncio.to_thread(store.accept_upload, job_id, owner, page_id, temporary)
            return {"ok": True}
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
            if acquired:
                uploads.release()
            busy_pages.discard(key)

    @app.post("/v1/jobs/{job_id}/commit")
    async def commit(job_id: str, request: Request):
        return await asyncio.to_thread(store.commit, job_id, client(request))

    @app.post("/v1/jobs/{job_id}/cancel")
    async def cancel(job_id: str, request: Request):
        return await asyncio.to_thread(store.cancel, job_id, client(request))

    @app.post("/v1/jobs/{job_id}/retry")
    async def retry(job_id: str, request: Request):
        return await asyncio.to_thread(store.retry_failed, job_id, client(request))

    @app.get("/v1/jobs/{job_id}/pages/{page_id}/result")
    async def result(job_id: str, page_id: str, request: Request):
        owner = client(request)
        if request.headers.get("range"):
            raise ProtocolError("Page downloads must be complete", 400)
        status = await asyncio.to_thread(store.status, job_id, owner)
        page = next((p for p in status["pages"] if p["id"] == page_id), None)
        if not page or page["state"] != "succeeded":
            raise ProtocolError("Result not ready", 409)
        path = store.path(job_id, page_id, "result.png")
        if not path.is_file():
            raise ProtocolError("Result expired or missing", 410)
        return FileResponse(path, media_type="image/png", headers={"X-Content-SHA256": page["result"]["sha256"]})

    @app.post("/v1/jobs/{job_id}/pages/{page_id}/ack")
    async def acknowledge(job_id: str, page_id: str, request: Request):
        owner = client(request)
        body = await read_json(request, 256)
        exact_keys(body, ("sha256",))
        return await asyncio.to_thread(store.acknowledge, job_id, owner, page_id, body["sha256"])

    return app
