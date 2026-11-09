"""Local HTTP server for a trusted LAN. No pairing or certificate setup."""
import argparse
import logging
import os
from pathlib import Path

from .jobs import JobStore
from .models import MODELS
from .protocol import MAX_PIXELS, MAX_SIDE, local_address

ALIASES = dict(zip(("hat-l", "dat2", "fdat-xl", "fdat-m"), MODELS))


def main(argv=None):
    parser = argparse.ArgumentParser(description="PicaX LAN AI super-resolution server (Python 3.11)")
    parser.add_argument("--host", help="This computer's LAN IP, for example 192.168.1.10")
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "PicaX-LAN")
    parser.add_argument("--weights-dir", type=Path)
    parser.add_argument("--models", nargs="+", choices=list(ALIASES), default=["fdat-xl"])
    parser.add_argument("--device", choices=["cuda", "cpu"], default="cuda")
    parser.add_argument("--maximum-side", type=int, default=4096)
    parser.add_argument("--maximum-pixels", type=int, default=MAX_PIXELS)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--retention-hours", type=int, default=24)
    # Accept existing launchers, but there is no longer a pairing mode.
    parser.add_argument("--pair", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--accept-noncommercial-license", action="store_true")
    parser.add_argument("--no-discovery", action="store_true")
    parser.add_argument("--diagnostics", action="store_true", help="Log HTTP route/status, without request bodies or query strings")
    parser.add_argument("--cleanup", action="store_true", help="Remove expired inactive jobs and exit")
    args = parser.parse_args(argv)
    if not 1 <= args.retention_hours <= 720:
        parser.error("retention must be 1..720 hours")
    if args.cleanup:
        store = JobStore(args.data_dir)
        try:
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
                "timeout": args.timeout, "retention": args.retention_hours * 3600,
                "diagnostics": args.diagnostics}
    from .identity import Advertisement, connection_url
    from .server import create_app
    from .worker import Worker
    import uvicorn
    store = JobStore(args.data_dir)
    worker = Worker(store, settings)
    advertisement = None
    try:
        store.recover()
        store.cleanup(settings["retention"])
        address = connection_url(host, args.port)
        print("PicaX LAN: enter this address in the phone app, or scan the QR:")
        print(address)
        print("No pairing code, password or certificate. Trusted LAN only; do not expose this port to the Internet.")
        import qrcode
        qr = qrcode.QRCode(border=2)
        qr.add_data(address)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
        print("GPU models load on startup; check their readiness in PicaX.")
        if not args.no_discovery:
            try:
                advertisement = Advertisement(host, args.port, store.server_id)
            except Exception as error:
                logging.getLogger("uvicorn.error").warning("LAN discovery unavailable; use the address or QR: %s", error)
        worker.start()
        uvicorn.run(create_app(store, worker, settings), host=host, port=args.port,
                    proxy_headers=False, access_log=False, server_header=False,
                    limit_concurrency=16, timeout_keep_alive=5)
    finally:
        if worker.thread.ident is not None:
            worker.stop()
        if advertisement:
            advertisement.close()
        store.close()
