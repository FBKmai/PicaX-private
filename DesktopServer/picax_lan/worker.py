"""Supervise a single spawned GPU process; release it when switching models."""
import multiprocessing
import os
import threading
import time

from .inference import worker_main
from .models import get_model
from .protocol import (MAX_OUTPUT_BYTES, MAX_OUTPUT_PIXELS, digest_file, png_dimensions,
                       validate_result)


class Worker:
    def __init__(self, store, settings):
        self.store, self.settings = store, settings
        self.stop_event = threading.Event()
        self.process = self.connection = self.current_model = None
        self.info = {"ready": False, "error": "Model worker is starting"}
        self.model_states = {key: {"ready": False, "error": "Not checked yet"} for key in settings["weights"]}
        self.thread = threading.Thread(target=self.run, name="PicaX-SR-worker", daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        # launch and inference both wake every 250ms and observe stop_event.
        self.thread.join(timeout=15)

    def terminate(self):
        process, self.process = self.process, None
        self.current_model = None
        if process:
            if process.is_alive():
                process.terminate()
            process.join(timeout=5)
            if process.is_alive():
                process.kill()
                process.join(timeout=2)
        if self.connection:
            self.connection.close()
            self.connection = None

    def launch(self, model_id):
        self.terminate()
        if self.stop_event.is_set():
            return False
        context = multiprocessing.get_context("spawn")
        parent, child = context.Pipe()
        settings = dict(self.settings, model_id=model_id)
        process = context.Process(target=worker_main, args=(child, settings), daemon=True)
        self.process, self.connection = process, parent
        self.info = {"ready": False, "error": "Loading and verifying " + model_id}
        process.start()
        child.close()
        deadline = time.monotonic() + 180
        try:
            while not self.stop_event.is_set() and time.monotonic() < deadline:
                if parent.poll(0.25):
                    self.info = parent.recv()
                    self.model_states[model_id] = dict(self.info)
                    if self.info.get("ready"):
                        self.current_model = model_id
                        return True
                    self.terminate()
                    return False
                if not process.is_alive():
                    break
        except (EOFError, OSError):
            pass
        self.info = {"ready": False, "error": "Model worker startup failed/timed out"}
        self.model_states[model_id] = dict(self.info)
        self.terminate()
        return False

    def run(self):
        try:
            # Validate each locally configured model once. Never advertise a
            # checkpoint as ready merely because its filename exists.
            for model_id in self.settings["weights"]:
                if self.stop_event.is_set():
                    return
                self.launch(model_id)
            while not self.stop_event.wait(0.5):
                work = self.store.next_page()
                if not work:
                    continue
                job_id, page = work
                spec = self.store.spec(job_id)
                model_id = spec["modelID"]
                source = self.store.path(job_id, page["id"], "source.png")
                temporary = self.store.path(job_id, page["id"], "result.part")
                try:
                    if self.current_model != model_id or not self.process or not self.process.is_alive():
                        if not self.launch(model_id):
                            raise RuntimeError(self.info.get("error", "Model unavailable"))
                    self.connection.send({"source": str(source), "destination": str(temporary), "page": page, "spec": spec})
                    deadline = time.monotonic() + self.settings["timeout"]
                    reply = None
                    while not self.stop_event.is_set() and time.monotonic() < deadline:
                        if self.store.state(job_id) == "cancelled":
                            raise RuntimeError("Cancelled by client")
                        if self.connection.poll(0.25):
                            reply = self.connection.recv()
                            break
                        if not self.process.is_alive():
                            raise RuntimeError("Inference worker exited")
                    if not reply:
                        raise RuntimeError("Inference timeout or server stopping")
                    if "error" in reply:
                        raise RuntimeError(reply["error"])
                    result = validate_result(reply["result"], spec, page)
                    scale = spec["deliveryScale"]
                    if temporary.stat().st_size != result["bytes"] or digest_file(temporary) != result["sha256"] or png_dimensions(temporary, MAX_OUTPUT_BYTES, MAX_OUTPUT_PIXELS) != (page["width"] * scale, page["height"] * scale):
                        raise RuntimeError("Invalid worker result")
                    with temporary.open("r+b") as stream:
                        os.fsync(stream.fileno())
                    temporary.replace(self.store.path(job_id, page["id"], "result.png"))
                    self.store.finish_page(job_id, page["id"], result=result)
                except Exception as error:
                    self.store.finish_page(job_id, page["id"], error=str(error))
                    self.terminate()  # Next page starts with a clean CUDA state.
                finally:
                    temporary.unlink(missing_ok=True)
        except Exception as error:
            self.info = {"ready": False, "error": type(error).__name__ + ": " + str(error)[:768]}
            self.model_states = {key: dict(self.info) for key in self.model_states}
        finally:
            self.terminate()
