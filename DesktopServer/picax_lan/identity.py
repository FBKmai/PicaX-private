"""Local TLS identity and Bonjour advertisement (no client secrets in mDNS)."""
import datetime
import hashlib
import ipaddress
import os
import socket
from pathlib import Path


def tls_identity(root, host):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    directory = Path(root) / "identity"
    directory.mkdir(exist_ok=True)
    certificate, key = directory / "server.pem", directory / "server-key.pem"
    if certificate.is_symlink() or key.is_symlink():
        raise RuntimeError("TLS identity must not be a symlink")
    if not certificate.exists() and not key.exists():
        private = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "PicaX LAN SR")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(private.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=5))
                .not_valid_after(now + datetime.timedelta(days=3650))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(host))]), critical=False)
                .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                .sign(private, hashes.SHA256()))
        # Exclusive creation: never overwrite an existing identity on startup.
        with key.open("xb") as stream:
            stream.write(private.private_bytes(serialization.Encoding.PEM,
                         serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        os.chmod(key, 0o600)
        with certificate.open("xb") as stream:
            stream.write(cert.public_bytes(serialization.Encoding.PEM))
    if not certificate.is_file() or not key.is_file():
        raise RuntimeError("Incomplete TLS identity; inspect local identity files before replacing them")
    cert = x509.load_pem_x509_certificate(certificate.read_bytes())
    names = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    if ipaddress.ip_address(host) not in names.get_values_for_type(x509.IPAddress):
        raise RuntimeError("LAN address changed. Restore the old address or explicitly replace identity and pair again")
    private = serialization.load_pem_private_key(key.read_bytes(), password=None)
    def public_bytes(public):
        return public.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if public_bytes(private.public_key()) != public_bytes(cert.public_key()):
        raise RuntimeError("TLS key does not match certificate")
    fingerprint = hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    return certificate, key, fingerprint


class Advertisement:
    def __init__(self, host, port, server_id):
        from zeroconf import Zeroconf, ServiceInfo
        address = ipaddress.ip_address(host)
        self.zeroconf = Zeroconf(interfaces=[host])
        self.info = ServiceInfo("_picax-sr._tcp.local.",
                                "PicaX-" + server_id[:8] + "._picax-sr._tcp.local.",
                                addresses=[address.packed], port=port,
                                properties={"version": "1", "serverID": server_id},
                                server="picax-" + server_id + ".local.")
        self.zeroconf.register_service(self.info)

    def close(self):
        self.zeroconf.unregister_service(self.info)
        self.zeroconf.close()
