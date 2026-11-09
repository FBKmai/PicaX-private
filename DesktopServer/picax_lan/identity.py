"""Connection URL and Bonjour advertisement for the plain-HTTP LAN server."""
import ipaddress


def connection_url(host, port):
    address = "[" + host + "]" if ":" in host else host
    return "http://%s:%s" % (address, port)


class Advertisement:
    def __init__(self, host, port, server_id):
        from zeroconf import Zeroconf, ServiceInfo
        address = ipaddress.ip_address(host)
        self.zeroconf = Zeroconf(interfaces=[host])
        self.info = ServiceInfo("_picax-sr._tcp.local.",
                                "PicaX-" + server_id[:8] + "._picax-sr._tcp.local.",
                                addresses=[address.packed], port=port,
                                properties={"version": "1", "serverID": server_id, "transport": "http"},
                                server="picax-" + server_id + ".local.")
        try:
            self.zeroconf.register_service(self.info)
        except Exception:
            self.zeroconf.close()
            raise

    def close(self):
        try:
            self.zeroconf.unregister_service(self.info)
        finally:
            self.zeroconf.close()
