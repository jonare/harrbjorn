#!/usr/bin/env bash
# tests/test-pi-model-integration.sh — pi i code-bildet mot modellconfigen
# sbx-init.sh skriver fra SBX_MODEL_*: ekte pi, falsk OpenAI-kompatibel
# server inne i samme container (ingen nett, ingen host-tjeneste).
#
# Dekker at pi, uten flagg:
#  1. bruker harrbjorn-provideren og SBX_MODEL som standard
#  2. snakker OpenAI-API-et (POST .../v1/chat/completions)
#  3. sender nøkkelen som `Authorization: Bearer` (det vLLMs --api-key sjekker)
#
# sbx-init.sh tas fra kilden (montert), ikke fra bildet, så testen gjelder
# koden i repoet; pi er bildets.
#
# Krevd: podman, harrbjorn/code:latest. Runtime SBX_RUNTIME (default krun;
# SBX_RUNTIME=crun uten KVM).
# Kjør: bash tests/test-pi-model-integration.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PODMAN="${PODMAN:-podman}"
IMAGE="${SBX_IMAGE:-harrbjorn/code:latest}"
die() { echo "ABORT $1" >&2; exit 1; }
command -v "$PODMAN" >/dev/null || die "podman mangler"
"$PODMAN" image exists "$IMAGE" || die "$IMAGE mangler (harrbjorn code --rebuild)"

# Falsk server: logger metode, sti, Authorization og body; svarer med en
# minimal strømmet chat completion.
cat > "$T_TMP/fake.py" <<'PY'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open("/tmp/req.log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                "body": json.loads(body or b"{}")}) + "\n")
        chunk = lambda d, fr: "data: " + json.dumps({"id": "x", "object": "chat.completion.chunk",
            "created": 0, "model": "m", "choices": [{"index": 0, "delta": d, "finish_reason": fr}]}) + "\n\n"
        out = chunk({"role": "assistant", "content": "OK"}, None) + chunk({}, "stop") + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(out.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18080), H).serve_forever()
PY

out="$("$PODMAN" run --rm --runtime "${SBX_RUNTIME:-krun}" --network none --userns=keep-id:uid=1000,gid=1000 \
  -v "$T_REPO/code:/opt/sbx-src:ro,z" -v "$T_TMP:/opt/t:ro,z" \
  -e SBX_MODEL_BASE_URL=http://127.0.0.1:18080/v1 -e SBX_MODEL=m-test -e SBX_MODEL_API_KEY=test-key-123 \
  -e PI_TELEMETRY=0 -e PI_SKIP_VERSION_CHECK=1 \
  --entrypoint sh "$IMAGE" /opt/sbx-src/sbx-init.sh sh -c '
    python3 /opt/t/fake.py & sleep 1
    timeout 60 pi -p "hei" >/tmp/pi.out 2>&1; echo "rc=$?"
    echo "--- pi"; cat /tmp/pi.out; echo "--- req"; cat /tmp/req.log 2>/dev/null' 2>&1)"
req="$(sed -n '/^--- req$/,$p' <<< "$out" | sed 1d | head -1)"
field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2:]: v=v[k]
print(v)' "$req" "$@" 2>/dev/null; }

assert_ne    "pi sendte en forespørsel"    "" "$req"
assert_eq    "OpenAI chat completions"     /v1/chat/completions "$(field path)"
assert_eq    "nøkkelen som Bearer"         "Bearer test-key-123" "$(field auth)"
assert_eq    "SBX_MODEL som standard"      m-test "$(field body model)"
assert_match "pi fikk svaret"              '(^|'$'\n'')OK($|'$'\n'')' "$(sed -n '/^--- pi$/,/^--- req$/p' <<< "$out")"
(( t_fail )) && echo "$out" >&2

t_summary
