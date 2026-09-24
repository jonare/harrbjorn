#!/usr/bin/env python3
"""sbx-proxy: minimal forward proxy with a host allowlist (stdlib only).

Sits between the sandbox network and the egress network. It is the ONLY
route out of the sandbox container:

  - HTTP  (absolute-URI requests) is forwarded via http.client.
  - HTTPS (CONNECT) is tunnelled as raw bytes - no MITM, no TLS termination.
  - Everything not on the allowlist is denied with 403.

Every request is logged to stdout (docker logs sbx-proxy) as an audit line:
  2026-01-01 00:00:00,000 client=... method=... target=host:port action=ALLOWED|DENIED

Allowlist file (one entry per line, '#' comments):
  host            -> ports 80 and 443
  host:port       -> that port only
  *.example.com   -> wildcard subdomain
  10.1.2.3[:port] -> IP literal (for pentest targets; private ranges allowed)

DNS-rebinding guard: for hostname entries the name is resolved before
forwarding and the connection is refused if any resolved address falls in
reserved ranges (including the sandbox subnets - so a hostname can never
stealthily point at the host bridge gateway). IP-literal entries are
checked against the always-deny set (loopback, unspecified, link-local);
everything else is governed purely by the allowlist.
"""

import ipaddress
import logging
import os
import re
import select
import socket
import sys
import threading
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(os.environ.get("SBX_PROXY_PORT", "3128"))
ALLOWLIST_FILE = os.environ.get("ALLOWLIST_FILE", "/allowlist/allowlist.txt")
CONNECT_IDLE_SECONDS = int(os.environ.get("CONNECT_IDLE_SECONDS", "600"))
MAX_BODY_BYTES = int(os.environ.get("SBX_PROXY_MAX_BODY", str(200 * 1024 * 1024)))
CONNECT_TIMEOUT_SECONDS = 30

log = logging.getLogger("sbx-proxy")

# Reserved ranges a hostname entry must never resolve to (defeats
# DNS-rebinding / "my domain points at the host" tricks).
RESERVED_NETS = [
    ipaddress.ip_network(n) for n in (
        "0.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "172.28.0.0/24",  # sbx-internal
        "172.29.0.0/24",  # sbx-egress
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "::/128",
    )
]

# Always denied even for explicit IP-literal entries. The sandbox subnets are
# NOT here: the host bridge gateway (172.28.0.1) is a legitimate target for
# host services (e.g. a local model server) when the operator allows it
# explicitly in the allowlist (plus the matching host-iptables port).
ALWAYS_DENY_NETS = [
    ipaddress.ip_network(n) for n in (
        "0.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "::1/128",
        "::/128",
    )
]

HOP_BY_HOP = {
    "connection",
    "proxy-connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

IPV4_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")
HOST_RE = re.compile(r"^[a-z0-9._*-]+$", re.IGNORECASE)


class Allowlist:
    def __init__(self, hosts, wildcards, ipnets):
        self.hosts = hosts
        self.wildcards = wildcards
        self.ipnets = ipnets

    def __len__(self):
        return len(self.hosts) + len(self.wildcards) + len(self.ipnets)

    def allowed(self, name, port):
        """Return True if (name, port) may be reached."""
        try:
            ip = ipaddress.ip_address(name)
        except ValueError:
            ip = None

        if ip is not None:
            for net, ports in self.ipnets:
                if ip in net:
                    return _port_allowed(ports, port)
            return False

        name = name.lower().rstrip(".")
        if name in self.hosts:
            return _port_allowed(self.hosts[name], port)
        for wc, ports in self.wildcards.items():
            if name.endswith(wc):  # wc starts with '.'
                return _port_allowed(ports, port)
        return False

    def is_hostname_entry(self, name):
        """True if (name) is an entry that needs the DNS-rebinding guard."""
        name = name.lower().rstrip(".")
        if name in self.hosts:
            return True
        return any(name.endswith(wc) for wc in self.wildcards)


def _port_allowed(ports, port):
    if not ports:
        return port in (80, 443)
    return port in ports


def load_allowlist(path):
    hosts, wildcards, ipnets = {}, {}, []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            ports = None
            if line.count(":") == 1 and not IPV4_RE.match(line):
                name, _, port_s = line.rpartition(":")
                try:
                    ports = int(port_s)
                except ValueError:
                    log.warning("allowlist line %d: bad port %r, skipping", lineno, line)
                    continue
                line = name
            entry_ports = frozenset([ports]) if ports is not None else frozenset()
            try:
                if IPV4_RE.match(line) or line.count(":") >= 2:
                    ip = ipaddress.ip_address(line)
                    ipnets.append((ipaddress.ip_network(str(ip)), entry_ports))
                    continue
            except ValueError:
                pass
            line = line.lower()
            if line.startswith("*."):
                if not HOST_RE.match(line[1:]):
                    log.warning("allowlist line %d: bad entry %r, skipping", lineno, raw)
                    continue
                wildcards[line] = entry_ports
            elif line == "*":
                log.warning(
                    "allowlist line %d: bare '*' wildcard disabled (use *.domain)",
                    lineno,
                )
                continue
            elif HOST_RE.match(line):
                hosts[line] = entry_ports
            else:
                log.warning("allowlist line %d: bad entry %r, skipping", lineno, raw)
    return Allowlist(hosts, wildcards, ipnets)


def always_denied(ip):
    return any(ip in net for net in ALWAYS_DENY_NETS)


def resolve_checked(name, port):
    """Resolve name; refuse if any address is reserved. Yields (family, sockaddr)."""
    try:
        infos = socket.getaddrinfo(name, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise RefusedError(f"DNS resolution failed for {name!r}: {e}")
    addrs = []
    for family, _type, _proto, _canon, sockaddr in infos:
        ip = ipaddress.ip_address(sockaddr[0])
        if any(ip in net for net in RESERVED_NETS):
            raise PermissionError(
                f"{name} resolves to reserved address {ip} - refusing (DNS-rebinding guard)"
            )
        addrs.append((family, sockaddr))
    if not addrs:
        raise RefusedError(f"no addresses for {name!r}")
    return addrs


def upstream_addrs(name, port):
    """Return candidate (family, sockaddr) tuples for the target.

    IP literals are checked against the always-deny set only (an explicit
    172.28.0.1:8000 entry must be able to reach the host bridge gateway).
    Hostnames go through the DNS-rebinding guard (resolve_checked).
    """
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        ip = None
    if ip is not None:
        if always_denied(ip):
            raise PermissionError(f"target {name} is in the always-deny set")
        if ip.version == 6:
            return [(socket.AF_INET6, (str(ip), port, 0, 0))]
        return [(socket.AF_INET, (str(ip), port))]
    return resolve_checked(name, port)


def connect_upstream(name, port):
    """Connect to the upstream, honouring allowlist semantics."""
    addrs = upstream_addrs(name, port)
    last_err = None
    for family, sockaddr in addrs:
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
            s.settimeout(CONNECT_TIMEOUT_SECONDS)
            s.connect(sockaddr)
            return s
        except OSError as e:
            last_err = e
    raise ConnectionError(f"upstream {name} unreachable: {last_err}")


def tunnel(a, b, idle_seconds):
    """Pump bytes a<->b until either side closes or the idle limit expires."""
    while True:
        try:
            readable, _, _ = select.select([a, b], [], [], idle_seconds)
        except (OSError, ValueError):
            return
        if not readable:
            return
        for s in readable:
            try:
                data = s.recv(65536)
            except OSError:
                data = b""
            if not data:
                return
            dst = b if s is a else a
            try:
                dst.sendall(data)
            except OSError:
                return


ALLOWLIST = None  # set in main()


def deny(handler, method, target, reason):
    log.warning(
        "client=%s method=%s target=%s action=DENIED reason=%s",
        handler.client_address[0], method, target, reason,
    )
    handler.send_response(403)
    handler.send_header("Content-Type", "text/plain")
    body = (f"sandbox proxy: {target} not in allowlist\n").encode()
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except OSError:
        pass


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "sbx-proxy/1.0"

    # -- CONNECT (HTTPS tunnel) ------------------------------------------
    def do_CONNECT(self):
        target = self.path
        host, _, port_s = target.rpartition(":")
        if not host or not HOST_RE.match(host.replace("*", "a")):
            deny(self, "CONNECT", target, "malformed target")
            return
        try:
            port = int(port_s or "443")
        except ValueError:
            deny(self, "CONNECT", target, "malformed port")
            return
        if not ALLOWLIST.allowed(host, port):
            deny(self, "CONNECT", target, "not in allowlist")
            return
        if not ALLOWLIST.is_hostname_entry(host):
            # IP literal that matched an IP entry: still fine, connect directly.
            pass
        try:
            upstream = connect_upstream(host, port)
        except PermissionError as e:
            deny(self, "CONNECT", target, str(e))
            return
        except (OSError, RefusedError) as e:
            log.warning(
                "client=%s method=CONNECT target=%s action=ERROR reason=%s",
                self.client_address[0], target, e,
            )
            self.send_response(502)
            self.end_headers()
            self.close_connection = True
            return
        log.info(
            "client=%s method=CONNECT target=%s action=ALLOWED",
            self.client_address[0], target,
        )
        self.send_response(200)
        self.end_headers()
        self.wfile.flush()
        upstream.settimeout(None)
        try:
            tunnel(self.connection, upstream, CONNECT_IDLE_SECONDS)
        finally:
            for s in (self.connection, upstream):
                try:
                    s.close()
                except OSError:
                    pass
        self.close_connection = True

    # -- absolute-URI HTTP forwarding ------------------------------------
    def _forward(self):
        target = self.path
        parsed = urlparse(target)
        if parsed.scheme != "http" or not parsed.hostname:
            deny(self, self.command, target, "only absolute http:// URLs are proxied")
            return
        host, port = parsed.hostname, parsed.port or 80
        if not ALLOWLIST.allowed(host, port):
            deny(self, self.command, target, "not in allowlist")
            return
        try:
            body = self._read_body()
        except (ValueError, OSError) as e:
            log.warning(
                "client=%s method=%s target=%s action=ERROR reason=bad-request-body: %s",
                self.client_address[0], self.command, target, e,
            )
            self.send_response(400)
            self.end_headers()
            self.close_connection = True
            return
        try:
            addrs = upstream_addrs(host, port)
        except PermissionError as e:
            deny(self, self.command, target, str(e))
            return
        except (OSError, RefusedError) as e:
            log.warning(
                "client=%s method=%s target=%s action=ERROR reason=%s",
                self.client_address[0], self.command, target, e,
            )
            self.send_response(502)
            self.end_headers()
            self.close_connection = True
            return
        last_err = None
        for _family, sockaddr in addrs:
            conn = HTTPConnection(sockaddr[0], sockaddr[1], timeout=60)
            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in HOP_BY_HOP
            }
            headers["Host"] = host if port == 80 else f"{host}:{port}"
            try:
                conn.request(
                    self.command,
                    parsed._replace(netloc=f"{host}:{port}").geturl(),
                    body=body,
                    headers=headers,
                )
                resp = conn.getresponse()
                payload = resp.read(MAX_BODY_BYTES + 1)
            except (OSError, Exception) as e:
                last_err = e
                try:
                    conn.close()
                except Exception:
                    pass
                continue
            log.info(
                "client=%s method=%s target=%s action=ALLOWED status=%s",
                self.client_address[0], self.command, target, resp.status,
            )
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP or k.lower() in ("content-length",):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
            conn.close()
            return
        log.warning(
            "client=%s method=%s target=%s action=ERROR reason=upstream-failed: %s",
            self.client_address[0], self.command, target, last_err,
        )
        self.send_response(502)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.close_connection = True

    def _read_body(self):
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            body = bytearray()
            while True:
                size_line = self.rfile.readline(65537).strip()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    while True:
                        line = self.rfile.readline(65537)
                        if line in (b"\r\n", b"\n", b""):
                            break
                    break
                body += self.rfile.read(size)
                self.rfile.read(2)
                if len(body) > MAX_BODY_BYTES:
                    raise ValueError("request body exceeds proxy limit")
            return bytes(body)
        length = self.headers.get("Content-Length")
        if length:
            n = int(length)
            if n > MAX_BODY_BYTES:
                raise ValueError("request body exceeds proxy limit")
            return self.rfile.read(n)
        return b""

    do_GET = _forward
    do_POST = _forward
    do_PUT = _forward
    do_DELETE = _forward
    do_HEAD = _forward
    do_PATCH = _forward
    do_OPTIONS = _forward

    def handle_one_request(self):
        # Clients routinely drop the connection right after a 403 deny or a
        # failed CONNECT; the stdlib would otherwise dump a traceback per event.
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True
        except OSError as e:
            log.debug("client %s: connection error: %s", self.client_address[0], e)
            self.close_connection = True

    def log_message(self, fmt, *args):  # keep http.server chatter out of the audit log
        pass


def main():
    global ALLOWLIST
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(asctime)s %(message)s")
    sys.stdout.reconfigure(line_buffering=True)
    ALLOWLIST = load_allowlist(ALLOWLIST_FILE)
    log.info("loaded %d allowlist entries from %s", len(ALLOWLIST), ALLOWLIST_FILE)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), ProxyHandler)
    server.daemon_threads = True
    log.info("listening on 0.0.0.0:%d", PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
