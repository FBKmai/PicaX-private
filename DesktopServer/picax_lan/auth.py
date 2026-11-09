"""One-time out-of-band pairing. No tokens are placed in HTTP URLs or logs."""
import hashlib
import secrets
import threading
import time
import uuid

from .protocol import ProtocolError, identifier


class Pairing:
    def __init__(self, store, ttl=300, clock=time.monotonic):
        self.store = store
        self.clock = clock
        self.secret = secrets.token_urlsafe(32)
        self.expires = clock() + ttl
        self.used = False
        self.lock = threading.Lock()
        self.attempts = []

    def pair(self, secret, client_id):
        identifier(client_id)
        with self.lock:
            now = self.clock()
            self.attempts = [stamp for stamp in self.attempts if now - stamp < 60]
            if len(self.attempts) >= 10:
                raise ProtocolError("Pairing rate limit exceeded", 429)
            self.attempts.append(now)
            valid_secret = isinstance(secret, str) and 32 <= len(secret) <= 128 and secret.isascii()
            if self.used or now >= self.expires or not valid_secret or not secrets.compare_digest(secret, self.secret):
                raise ProtocolError("Pairing code expired, used or invalid; restart with --pair", 403)
            token = secrets.token_urlsafe(32)
            # The store refuses changing an existing client credential through
            # pairing. Unpair/re-pair creates a fresh client UUID on the phone.
            self.store.add_client(client_id, token_digest(token))
            self.used = True
            return token


def token_digest(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def authenticate(store, authorization):
    if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
        raise ProtocolError("Authentication required", 401)
    token = authorization[7:]
    if not 32 <= len(token) <= 128:
        raise ProtocolError("Authentication required", 401)
    client_id = store.client_for_digest(token_digest(token))
    if not client_id:
        raise ProtocolError("Authentication required", 401)
    return client_id


def pairing_payload(host, port, server_id, fingerprint, pairing):
    return {
        "version": 1, "host": host, "port": port, "serverID": server_id,
        "certificateSHA256": fingerprint, "pairingSecret": pairing.secret,
        "expiresAt": int(time.time() + max(0, pairing.expires - pairing.clock())),
    }
