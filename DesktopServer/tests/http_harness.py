"""Real loopback HTTP harness; no model loading, TLS or LAN listener."""
import http.client
import json
import socket
import threading
import time


class HTTPHarness:
    def __init__(self, store, worker, settings):
        self.store, self.worker, self.settings = store, worker, settings
        self.thread = self.listener = self.server = None
    def __enter__(self):
        import uvicorn
        from picax_lan.server import create_app
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        config = uvicorn.Config(create_app(self.store, self.worker, self.settings), host="127.0.0.1", port=self.port,
                                proxy_headers=False, access_log=False, log_level="error", server_header=False)
        self.server = uvicorn.Server(config)
        self.thread = threading.Thread(target=lambda: self.server.run(sockets=[self.listener]), daemon=True)
        self.thread.start()
        self.wait(lambda: self.server.started, 15)
        return self
    @staticmethod
    def wait(predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            threading.Event().wait(0.05)
        raise TimeoutError("HTTP validation condition timed out")
    def request(self, method, path, body=None, client_id=None, raw=False, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        try:
            fields = {"Content-Type": "image/png" if raw else "application/json"}
            if client_id:
                fields["X-PicaX-Client-ID"] = client_id
            if headers:
                fields.update(headers)
            payload = body if raw or body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
            connection.request(method, path, body=payload, headers=fields)
            response = connection.getresponse()
            data = response.read()
            if response.getheader("Content-Type", "").startswith("application/json"):
                data = json.loads(data)
            return response.status, data
        finally:
            connection.close()
    def __exit__(self, *unused):
        if self.server:
            self.server.should_exit = True
        if self.thread:
            self.thread.join(timeout=10)
        if self.listener:
            self.listener.close()
