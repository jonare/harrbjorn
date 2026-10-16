#!/usr/bin/env python3
"""Deterministisk test-originsjever til test-proxy-integration.sh.

Kjører PÅ HOSTEN (ikke i container) og lytter på 0.0.0.0 — ikke 127.0.0.1:
en host-tjeneste bundet til loopback når ikke via 169.254.1.2
(host.containers.internal) fra containeren.

Svarer med faste, kjente verdier slik at testen kan verifisere at proxyen
slår igjennom uten å endre noe:
  GET /known.txt  -> fast body + X-Test-Header: keepme-value + Content-Length
  GET /           -> "origin-home\n" (bekrefter at CONNECT-tunnelen kom frem)
  POST /echo      -> echo av method/host/x-test-header/content-length/body-sha256

Prints på stdout ved oppstart (testen leser disse):
  origin-sha256=<sha256 av known.txt-body>
  origin-port=<faktisk port>
  origin-marker=keepme-value
"""
import hashlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODY = ("harrbjorn-proxy-test-body\n" + "x" * 1024 + "\nend-marker\n").encode()
MARKER = "keepme-value"
HOME = b"origin-home\n"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, extra=()):
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/known.txt":
            self._send(200, BODY,
                       [("Content-Type", "text/plain"),
                        ("X-Test-Header", MARKER)])
        elif self.path == "/":
            self._send(200, HOME, [("Content-Type", "text/plain")])
        else:
            self._send(404, b"")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        reply = (
            "method=%s\n"
            "host=%s\n"
            "x-test-header=%s\n"
            "content-length=%s\n"
            "body-sha256=%s\n"
            "body=%r\n" % (
                self.command,
                self.headers.get("Host", ""),
                self.headers.get("X-Test-Header", ""),
                n,
                hashlib.sha256(body).hexdigest(),
                body.decode(errors="replace"),
            )
        ).encode()
        self._send(200, reply, [("Content-Type", "text/plain")])


if __name__ == "__main__":
    want = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = ThreadingHTTPServer(("0.0.0.0", want), H)
    print("origin-sha256=%s" % hashlib.sha256(BODY).hexdigest(), flush=True)
    print("origin-port=%d" % srv.server_address[1], flush=True)
    print("origin-marker=%s" % MARKER, flush=True)
    srv.serve_forever()
