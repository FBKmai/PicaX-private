"""Real loopback HTTPS test harness; no listener or firewall change on the LAN."""
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl
import threading
import time


class HTTPSHarness:
    def __init__(self, store, worker, pairing, settings):
        self.store, self.worker, self.pairing, self.settings = store, worker, pairing, settings
        self.thread = self.listener = self.server = None
    def __enter__(self):
        import uvicorn
        from picax_lan.identity import tls_identity
        from picax_lan.server import create_app
        certificate, key, self.fingerprint = tls_identity(self.store.root, "127.0.0.1")
        self.context = ssl.create_default_context(cafile=str(certificate))
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        settings = dict(self.settings, diagnostic=True)
        config = uvicorn.Config(create_app(self.store, self.worker, self.pairing, settings), host="127.0.0.1", port=self.port,
                                ssl_certfile=str(certificate), ssl_keyfile=str(key), proxy_headers=False,
                                access_log=False, log_level="error", server_header=False)
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
        raise TimeoutError("HTTPS validation condition timed out")
    def request(self, method, path, body=None, token=None, raw=False, headers=None):
        connection = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.context, timeout=30)
        try:
            # Pin before any HTTP headers or bearer credentials are transmitted.
            connection.connect()
            fingerprint = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
            if fingerprint != self.fingerprint:
                raise RuntimeError("Test TLS certificate pin mismatch")
            fields = {"Content-Type": "image/png" if raw else "application/json"}
            if token:
                fields["Authorization"] = "Bearer " + token
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
