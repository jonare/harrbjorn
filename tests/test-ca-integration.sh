#!/usr/bin/env bash
# tests/test-ca-integration.sh — integrasjonstest for --ca-cert: en ekte
# `harrbjorn code`-økt mot en TLS-server på hosten med sertifikat fra en
# generert test-CA (står for en TLS-inspiserende mellomboks).
#
# Serveren nås som https://host.containers.internal:<port> via proxyen
# (-H <port>). Dekker, med og uten --ca-cert:
#  1. curl (SSL_CERT_FILE/CURL_CA_BUNDLE)
#  2. node, TLS over en CONNECT-tunnel (NODE_EXTRA_CA_CERTS)
#  3. python3 urllib (SSL_CERT_FILE)
#  4. git over HTTPS (GIT_SSL_CAINFO): ingen sertifikatfeil
#
# Krevd: podman, python3, openssl, bygde bilder harrbjorn/code:latest og
# harrbjorn/sbx-proxy:latest. Runtime som i produksjon (SBX_RUNTIME).
# Kjør: bash tests/test-ca-integration.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

die() { echo "ABORT $1" >&2; exit 1; }
for img in harrbjorn/code:latest harrbjorn/sbx-proxy:latest; do
  podman image inspect "$img" >/dev/null 2>&1 || die "$img mangler (bygg med harrbjorn code --rebuild)"
done

# ---- test-CA og serversertifikat for host.containers.internal ---------------
C="$T_TMP/certs"; mkdir -p "$C"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$C/ca.key" -out "$C/ca.pem" -days 2 -subj /CN=harrbjorn-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2>/dev/null \
  || die "test-CA"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$C/srv.key" -out "$C/srv.csr" -subj /CN=host.containers.internal 2>/dev/null
printf 'subjectAltName=DNS:host.containers.internal\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$C/ext"
openssl x509 -req -in "$C/srv.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial \
  -out "$C/srv.pem" -days 2 -extfile "$C/ext" 2>/dev/null || die "serversertifikat"

# ---- TLS-server på hosten (0.0.0.0: pasta mapper host.containers.internal
# til hostens primæradresse) --------------------------------------------------
python3 - "$C/srv.pem" "$C/srv.key" > "$T_TMP/tls.out" 2>&1 <<'PY' &
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = b"ca-ok"
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("0.0.0.0", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[1], sys.argv[2])
s.socket = ctx.wrap_socket(s.socket, server_side=True)
print(f"tls-port={s.server_address[1]}", flush=True)
s.serve_forever()
PY
SRV=$!
WD="$T_TMP/wd"; mkdir -p "$WD"
cleanup() {
  kill "$SRV" 2>/dev/null
  ( source "$T_REPO/lib/sandbox.sh"; set +e
    podman unshare rm -rf "$(sbx_agent_home "$STATE_DIR" code "$WD")" )
  rm -rf "$T_TMP"
}
trap cleanup EXIT
for _ in $(seq 1 25); do grep -q '^tls-port=' "$T_TMP/tls.out" && break; sleep 0.2; done
PORT="$(sed -n 's/^tls-port=//p' "$T_TMP/tls.out")"
[[ -n "$PORT" ]] || die "TLS-serveren startet ikke: $(cat "$T_TMP/tls.out")"
echo ">> TLS-server: :$PORT"

# ---- probe i sandboxen ------------------------------------------------------
# shellcheck disable=SC2016  # expanded inside the sandbox
PROBE='h=host.containers.internal; u="https://$h:$1/"
echo "curl=$(curl -sS --max-time 10 "$u" 2>&1)"
echo "node=$(node -e "
const http=require(\"http\"),tls=require(\"tls\"),p=new URL(process.env.HTTPS_PROXY),[h,port]=process.argv.slice(1);
http.request({host:p.hostname,port:p.port,method:\"CONNECT\",path:h+\":\"+port}).on(\"connect\",(r,sock)=>{
  const t=tls.connect({socket:sock,servername:h},()=>t.write(\"GET / HTTP/1.0\\r\\nHost: \"+h+\"\\r\\n\\r\\n\"));
  let d=\"\";t.on(\"data\",c=>d+=c);t.on(\"end\",()=>console.log(d.split(\"\\r\\n\\r\\n\")[1]));t.on(\"error\",e=>console.log(\"ERR \"+e.code));
}).on(\"error\",e=>console.log(\"ERR \"+e.code)).end();" "$h" "$1")"
echo "python=$(python3 -c "import sys,urllib.request
try: print(urllib.request.urlopen(sys.argv[1],timeout=10).read().decode())
except Exception as e: print(\"ERR\",e)" "$u")"
echo "git=$(git ls-remote "${u}repo" 2>&1 | tr "\n" " ")"'

session() { # [--ca-cert FILE] -> probe output
  "$T_REPO/harrbjorn" code -w "$WD" --net "host:$PORT" "$@" sh -c "$PROBE" _ "$PORT" 2>"$T_TMP/session.err"
}
line() { sed -n "s/^$1=//p" <<< "$2"; }

out="$(session --ca-cert "$C/ca.pem")"
echo "$out"
assert_eq       "1: curl med CA"             ca-ok "$(line curl "$out")"
assert_eq       "2: node med CA"             ca-ok "$(line node "$out")"
assert_eq       "3: python med CA"           ca-ok "$(line python "$out")"
assert_no_match "4: git med CA: ingen sertifikatfeil" '[Cc]ertificate|SSL' "$(line git "$out")"
assert_match    "init melder CA-en"          'extra CA installed' "$(cat "$T_TMP/session.err")"

out="$(session)"
echo "$out"
assert_match    "1: curl uten CA feiler"     'certificate' "$(line curl "$out")"
assert_match    "2: node uten CA feiler"     '^ERR ' "$(line node "$out")"
assert_match    "3: python uten CA feiler"   'CERTIFICATE_VERIFY_FAILED' "$(line python "$out")"
assert_match    "4: git uten CA feiler"      '[Cc]ertificate|SSL' "$(line git "$out")"

t_summary
