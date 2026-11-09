"""Explicit local configuration; no automatic downloads or firewall changes."""
import argparse
import json
import os
from pathlib import Path

from .auth import Pairing, pairing_payload
from .jobs import JobStore
from .models import MODELS
from .protocol import MAX_PIXELS, MAX_SIDE, local_address

ALIASES = dict(zip(("hat-l", "dat2", "fdat-xl", "fdat-m"), MODELS))


def main(argv=None):
    parser = argparse.ArgumentParser(description="PicaX LAN AI super-resolution server (Python 3.11)")
    parser.add_argument("--host", help="Literal private LAN interface address; never 0.0.0.0")
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "PicaX-LAN")
    parser.add_argument("--weights-dir", type=Path)
    parser.add_argument("--models", nargs="+", choices=list(ALIASES), default=["fdat-xl"])
    parser.add_argument("--device", choices=["cuda", "cpu"], default="cuda")
    parser.add_argument("--maximum-side", type=int, default=4096)
    parser.add_argument("--maximum-pixels", type=int, default=MAX_PIXELS)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--retention-hours", type=int, default=24)
    parser.add_argument("--pair", action="store_true", help="Show a single-use pairing QR, valid for 5 minutes")
    parser.add_argument("--accept-noncommercial-license", action="store_true")
    parser.add_argument("--no-discovery", action="store_true")
    parser.add_argument("--list-clients", action="store_true")
    parser.add_argument("--revoke-client")
    parser.add_argument("--cleanup", action="store_true", help="Remove expired inactive jobs and exit")
    args = parser.parse_args(argv)
    if not 1 <= args.retention_hours <= 720:
        parser.error("retention must be 1..720 hours")
    store = JobStore(args.data_dir)
    if args.list_clients or args.revoke_client or args.cleanup:
        try:
            if args.revoke_client:
                store.revoke(args.revoke_client)
            if args.list_clients:
                with store.lock:
                    print("\n".join(row[0] for row in store.db.execute("SELECT id FROM clients ORDER BY id")))
            if args.cleanup:
                store.cleanup(args.retention_hours * 3600)
        finally:
            store.close()
        return
    if not args.host or not args.weights_dir or not args.accept_noncommercial_license:
        parser.error("--host, --weights-dir and --accept-noncommercial-license are required")
    host = local_address(args.host)
    if not 1 <= args.port <= 65535 or not 64 <= args.maximum_side <= MAX_SIDE or not 4096 <= args.maximum_pixels <= MAX_PIXELS or not 10 <= args.timeout <= 3600:
        parser.error("Invalid port, image budget or timeout")
    weights = {ALIASES[key].id: str((args.weights_dir / ALIASES[key].file).resolve()) for key in args.models}
    for path in weights.values():
        if not Path(path).is_file():
            parser.error("Missing local checkpoint: " + path)
    settings = {"weights": weights, "device": args.device, "noncommercial": True,
                "maximum_side": args.maximum_side, "maximum_pixels": args.maximum_pixels,
                "timeout": args.timeout, "retention": args.retention_hours * 3600}
    from .identity import tls_identity, Advertisement
    from .server import create_app
    from .worker import Worker
    import uvicorn
    certificate, key, fingerprint = tls_identity(store.root, host)
    store.recover()
    store.cleanup(settings["retention"])
    pairing = Pairing(store) if args.pair else None
    if pairing:
        import qrcode
        payload = json.dumps(pairing_payload(host, args.port, store.server_id, fingerprint, pairing), separators=(",", ":"))
        print("Pair only on a trusted private LAN. QR contains a one-time secret; do not share screenshots.")
        qr = qrcode.QRCode(border=2)
        qr.add_data(payload)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
        print("Paste this connection information into PicaX if scanning is unavailable:\n" + payload)
    print("Server ID:", store.server_id, "Certificate SHA-256:", fingerprint)
    print("GPU models are verified on startup; watch model readiness in PicaX.")
    worker = Worker(store, settings)
    advertisement = None
    try:
        if not args.no_discovery:
            advertisement = Advertisement(host, args.port, store.server_id)
        worker.start()
        uvicorn.run(create_app(store, worker, pairing, settings), host=host, port=args.port,
                    ssl_certfile=str(certificate), ssl_keyfile=str(key),
                    proxy_headers=False, access_log=False, server_header=False,
                    limit_concurrency=16, timeout_keep_alive=5)
    finally:
        if worker.thread.ident is not None:
            worker.stop()
        if advertisement:
            advertisement.close()
        store.close()
