#!/usr/bin/env python3
"""Falsk Burp (forward-proxy) til test-burp-chain-integration.sh.

Med UPSTREAM=host:port sendes hver request uendret videre til en
upstream-proxy — som Burp med «Upstream proxy servers» satt til harrbjorns
Smokescreen; Burp slår da ikke opp målet selv. Uten UPSTREAM kobler den
direkte til målet (Burp uten upstream), slik at testen kan vise at
kanarisjekken oppdager det.

Logger første request-linje per tilkobling på stdout ("burp <linje>").
Kjøres: fake-burp.py [PORT]   (default 8080; BIND=adresse, default 0.0.0.0 —
på hosten 127.0.0.1, så den ikke er nåbar fra LAN-et)
"""
import os
import socket
import sys
import threading

UPSTREAM = os.environ.get("UPSTREAM", "")
BIND = os.environ.get("BIND", "0.0.0.0")


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def read_head(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        data = conn.recv(4096)
        if not data:
            return None, b""
        buf += data
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head + b"\r\n\r\n", rest


def target(line):
    method, uri = line.split()[:2]
    if method == "CONNECT":
        host, port = uri.rsplit(":", 1)
        return host, int(port)
    if "://" not in uri:
        raise ValueError(f"not a proxy request: {line}")
    hostport = uri.split("://", 1)[1].split("/", 1)[0]
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        return host, int(port)
    return hostport, 80


def handle(conn):
    try:
        head, rest = read_head(conn)
        if head is None:
            return
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        print(f"burp {line}", flush=True)
        if UPSTREAM:
            host, port = UPSTREAM.rsplit(":", 1)
            up = socket.create_connection((host, int(port)), timeout=10)
            up.sendall(head + rest)
        else:
            up = socket.create_connection(target(line), timeout=10)
            if line.startswith("CONNECT "):
                conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                if rest:
                    up.sendall(rest)
            else:
                up.sendall(head + rest)
        up.settimeout(None)
        conn.settimeout(None)
        back = threading.Thread(target=pipe, args=(up, conn), daemon=True)
        back.start()
        pipe(conn, up)
        back.join()
    except Exception as e:  # noqa: BLE001 — every failure is a 502 to the client
        print(f"burp error {e}", flush=True)
        try:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                         b"Connection: close\r\n\r\n")
        except OSError:
            pass
    finally:
        conn.close()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = socket.create_server((BIND, port))
    print(f"fake-burp listening on {BIND}:{port} (upstream: {UPSTREAM or 'none'})", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
