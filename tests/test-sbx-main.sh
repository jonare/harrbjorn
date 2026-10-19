#!/usr/bin/env bash
# tests/test-sbx-main.sh — enhetstester for sbx_main (lib/sandbox.sh) via
# wrapper-flow (run-code.sh), kjørt hermetisk: testskallet source IKKE
# sandbox.sh, alle assert mot PODMAN-stubbens arkart.
#
# Dekker (M1–M8):
#  - M1 grunnleggende: run-linje (hardening, limits, runtime), --internal-nett,
#    éi proxy-run med fanget proxy.yaml/acl.yaml (open-modus: tillitshost-port
#    i proxy.yaml, IKKE i acl.yaml), agent-home 700, loopback-rewrite av
#    ANTHROPIC_BASE_URL
#  - M2 -p suksess: egress-nett (uten --internal), ingen harrbjorn-proxy,
#    HTTP_PROXY/SBX_EXTERNAL_PROXY mot host.containers.internal
#  - M3 -p fail-closed: ingenting svarar på porten → exit 1, ingen nettverk
#  - M4 -p ugyldig: «localhost» (ingen port) og «h:99999» → exit 1
#  - M5 -H: duplisert port → nøyaktig éi tillitshost-post i proxy.yaml (dedup);
#    «-H abc» → exit 1, ingen run-linje
#  - M6 .env-preferanse: SBX_MEMORY/SBX_PIDS fra .env vinner over default
#  - M7 ingen modellkonfig + nøkkelen i .env: advarsel + -e ANTHROPIC_API_KEY
#  - M8 ingen modellkonfig, ingen nøkkelen → exit 1
#
# Krevd: bash, python3 (PyYAML for fanget YAML, loopback-lyttar i M2/M3).
# Ingen podman (fake PODMAN-stubb), ingen ekstern nettverk (berre 127.0.0.1).
# Kjør: bash tests/test-sbx-main.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required." >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ------------------------------------------------------------ hermetisk repo
# Kopier wrapper + kjerne + allowlist til $T/repo — subprocessen sin
# SCRIPT_DIR/STATE_DIR peikar dit, så røkt .env/.sandbox rørist aldri.
# run-code.sh sourcear lib/sandbox.sh relativt eigen sti → layoutet må
# mirrast: $T/repo/{run-code.sh,lib/sandbox.sh,allowlist.code.default}.
mkdir -p "$T/repo/lib" "$T/home" "$T/work-m1"
cp "$REPO/run-code.sh" "$REPO/allowlist.code.default" "$T/repo/"
cp "$REPO/lib/sandbox.sh" "$T/repo/lib/"

# ------------------------------------------------------- PODMAN-stubb + bin
mkdir -p "$T/bin"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
# Fake podman for tests/test-sbx-main.sh. Loggar «PODMAN <args>» per kall
# (éin linje per kall; ingen -e-verdi inneheld whitespace) og fanger
# proxy.yaml/acl.yaml frå <dir> ved run-kall med -v <dir>:/config —
# må skje no, for sbx_cleanup slettar policy-direktivet ved avslutt.
printf 'PODMAN %s\n' "$*" >> "${FAKE_PODMAN_LOG:-/dev/null}"
case "${1:-}" in
  run)
    prev=""
    for a in "${@:2}"; do
      if [[ "$prev" == "-v" ]]; then
        dir="${a%%:*}"
        tgt="${a#*:}"; tgt="${tgt%%:*}"
        if [[ "$tgt" == "/config" ]]; then
          mkdir -p "${FAKE_PODMAN_CAPTURE:-/dev/null}"
          cp "$dir/proxy.yaml" "$dir/acl.yaml" "${FAKE_PODMAN_CAPTURE}/" 2>/dev/null || true
        fi
      fi
      prev="$a"
    done
    exit 0
    ;;
  inspect)
    echo 10.0.0.2
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/podman"

# Fake resolvectl på PATH: deterministisk uplink DNS (éin server).
cat > "$T/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
echo '[{"ifname":"eth1","currentServer":{"addressString":"10.99.99.99"},"servers":[{"addressString":"10.99.99.99"}]}]'
EOF
chmod +x "$T/bin/resolvectl"

# Stub crun: SBX_RUNTIME=crun + crun på PATH → deterministisk --runtime crun,
# uavhengig av host sin KVM.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/crun"
chmod +x "$T/bin/crun"

# Modellkonfig: loopback-base_url (M1 påseier rewrite) + nøkkelen.
cat > "$T/claude.sh" <<'EOF'
export ANTHROPIC_BASE_URL=http://localhost:8787
export ANTHROPIC_API_KEY=test-key
EOF

pass=0 fail=0
check() { # label file pattern (grep -q; «--» slik at mønster som startar med - blir tatt)
  if grep -q -- "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — mangler '$3' i $(basename "$2")"; echo "--- $(basename "$2"):"; cat "$2"; echo "----"
  fi
}
check_absent() { # label file pattern
  if grep -q -- "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 — '$3' finnes i $(basename "$2")"; cat "$2"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}
check_once() { # label file pattern (nøyaktig éi linje)
  local n
  n="$(grep -c -- "$3" "$2" 2>/dev/null || true)"
  if [[ "${n:-0}" == "1" ]]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — venta nøyaktig éi linje med '$3', fann ${n:-0}"
  fi
}
check_rc() { # label expected actual
  if [[ "$3" -eq "$2" ]]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — return $3, ventet $2"
  fi
}

# sbx_run <tag> <args...>: harnes-env per kjøring, arkart til $T/log-<tag>,
# wrapper-utdata til $T/out-<tag>.log / $T/err-<tag>.log, RC settest.
sbx_run() {
  local tag="$1"; shift
  : > "$T/log-$tag"
  # -u ANTHROPIC_API_KEY: M7/M8 må isolere nøkkelen til .env — ein nøkkel i
  # vertens miljø ville skjule M8 si feil og forfalske M7 si kilde.
  env -u SBX_MEMORY -u SBX_CPUS -u SBX_PIDS -u SBX_LOCALE -u ANTHROPIC_API_KEY \
    HOME="$T/home" \
    SBX_CLAUDE_CONFIG="$T/claude.sh" \
    SBX_RUNTIME=crun \
    PODMAN="$T/bin/podman" \
    PATH="$T/bin:$PATH" \
    FAKE_PODMAN_LOG="$T/log-$tag" \
    FAKE_PODMAN_CAPTURE="$T/cap-$tag" \
    bash "$T/repo/run-code.sh" "$@" \
    >"$T/out-$tag.log" 2>"$T/err-$tag.log"
  RC=$?
}

# ---------------------------------------------------------- M1 grunnleggende
# Inga -p: harrbjorns eiga proxy, --internal-nett, open-modus (code-default),
# modellkonfig frå $T/claude.sh med loopback-rewrite.
sbx_run m1 -w "$T/work-m1"
check_rc    "M1: exit 0" 0 "$RC"
LOG="$T/log-m1"
# Harnes: deterministisk uplink DNS frå fake resolvectl.
check    "M1: uplink DNS frå fake resolvectl" "$T/out-m1.log" "dns: 10\.99\.99\.99"
# Sesjonsnett: internal.
check    "M1: network create --internal sbx-" "$LOG" "^PODMAN network create --internal sbx-"
# Éi proxy-run, med fanget policy.
check_once "M1: nøyaktig éi proxy-run"        "$LOG" "^PODMAN run -d --name sbx-.*-proxy"
check    "M1: proxy med --config-file"        "$LOG" "run -d --name sbx-.*--config-file /config/proxy\.yaml"
# Fanget proxy.yaml/acl.yaml: gyldig YAML, open-modus.
P="$T/cap-m1/proxy.yaml" A="$T/cap-m1/acl.yaml"
if python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$P" 2>/dev/null; then
  pass=$((pass+1)); echo "PASS  M1: fanget proxy.yaml er gyldig YAML"
else fail=$((fail+1)); echo "FAIL  M1: fanget proxy.yaml er ugyldig YAML"; cat "$P" 2>/dev/null; fi
check    "M1: proxy.yaml port"        "$P" "port: 3128"
check    "M1: proxy.yaml acl_file"    "$P" "acl_file: /config/acl.yaml"
check    "M1: tillitshost-port 8787"  "$P" "169\.254\.1\.2:8787"
check_absent "M1: open-modus — tillitshost ikkje i acl.yaml" "$A" "host\.containers\.internal"
check    "M1: acl open action"        "$A" "action: open"
# Agent HOME: persistent, 700.
AH="$T/repo/.sandbox/agent-home/code$T/work-m1"
if [[ -d "$AH" && "$(stat -c %a "$AH")" == "700" ]]; then
  pass=$((pass+1)); echo "PASS  M1: agent-home code<work> 700"
else fail=$((fail+1)); echo "FAIL  M1: agent-home manglar eller ikkje 700: $AH"; fi
# Sandbox-run-linje: ikkje-tty, runtime, hardening, limits, bilde.
check    "M1: run --rm -i (ikkje-tty)" "$LOG" "^PODMAN run --rm -i --name sbx-"
check    "M1: --runtime crun"          "$LOG" "\-\-runtime crun"
check    "M1: keep-id userns"          "$LOG" "\-\-userns=keep-id:uid=1000,gid=1000"
check    "M1: workdir-montert"         "$LOG" "\-v $T/work-m1:/work:z"
check    "M1: -w /work"                "$LOG" "-w /work"
check    "M1: --read-only"             "$LOG" "\-\-read-only"
check    "M1: --cap-drop ALL"          "$LOG" "\-\-cap-drop ALL"
check    "M1: no-new-privileges:true"  "$LOG" "\-\-security-opt no-new-privileges:true"
check    "M1: --memory 4g"             "$LOG" "\-\-memory 4g"
check    "M1: --pids-limit 1024"       "$LOG" "\-\-pids-limit 1024"
check    "M1: --cpus 2"                "$LOG" "\-\-cpus 2"
check    "M1: bilde"                   "$LOG" "harrbjorn/code:latest"
check    "M1: base_url rewrite"        "$LOG" "\-e ANTHROPIC_BASE_URL=http://host\.containers\.internal:8787"
check    "M1: proxy env (eiga proxy)"  "$LOG" "\-e HTTP_PROXY=http://sbx-[^ ]*-proxy:3128"

# ------------------------------------------------------------- M2 -p suksess
# Loopback-lyttar på 127.0.0.1 (self-contained TCP, ikkje «nettverk»).
cat > "$T/listener.py" <<'EOF'
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept()
    try:
        c.recv(64); c.close()
    except OSError:
        pass
EOF
python3 "$T/listener.py" > "$T/m2port.txt" &
LISTENER_PID=$!
for _ in $(seq 1 50); do [[ -s "$T/m2port.txt" ]] && break; sleep 0.1; done
M2_PORT="$(head -n1 "$T/m2port.txt")"
[[ -n "$M2_PORT" ]] || { echo "error: lyttaren starta ikkje" >&2; exit 1; }
sbx_run m2 -p "127.0.0.1:$M2_PORT" -w "$T/work-m1"
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
check_rc "M2: exit 0" 0 "$RC"
LOG="$T/log-m2"
check      "M2: egress-nett (network create sbx-)" "$LOG" "^PODMAN network create sbx-"
check_absent "M2: ikkje --internal"                 "$LOG" "network create --internal"
check_absent "M2: ingen harrbjorn-proxy"            "$LOG" "^PODMAN run -d"
check_absent "M2: ingen eiga proxy i env"           "$LOG" "HTTP_PROXY=http://sbx-"
check      "M2: HTTP_PROXY mot host.containers"     "$LOG" "\-e HTTP_PROXY=http://host\.containers\.internal:$M2_PORT"
check      "M2: NO_PROXY med host.containers"       "$LOG" "NO_PROXY=localhost,127\.0\.0\.1,::1,host\.containers\.internal"
check      "M2: SBX_EXTERNAL_PROXY"                 "$LOG" "\-e SBX_EXTERNAL_PROXY=http://host\.containers\.internal:$M2_PORT"

# ------------------------------------------- M3 -p fail-closed (lukka port)
# Finn ein lukka 127.0.0.1-port via /dev/tcp-probe.
CLOSED_PORT=""
for p in 46001 46002 46003 46004 46005 46006 46007 46008 46009 46010; do
  if ! (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then CLOSED_PORT=$p; break; fi
done
[[ -n "$CLOSED_PORT" ]] || { echo "error: fann ingen lukka port" >&2; exit 1; }
sbx_run m3 -p "127.0.0.1:$CLOSED_PORT" -w "$T/work-m1"
check_rc    "M3: exit 1 (fail-closed)" 1 "$RC"
check       "M3: feilmelding fail-closed" "$T/err-m3.log" "error: -p: no forward proxy answering at 127\.0\.0\.1:$CLOSED_PORT (fail-closed"
check_absent "M3: ingen network create"  "$T/log-m3" "^PODMAN network create"
check_absent "M3: ingen run-linje"       "$T/log-m3" "^PODMAN run"

# -------------------------------------------------------- M4 -p ugyldig
sbx_run m4a -p localhost -w "$T/work-m1"
check_rc    "M4: 'localhost' (ingen port) → exit 1" 1 "$RC"
check       "M4: 'localhost' feilmelding" "$T/err-m4a.log" "error: -p: bad proxy 'localhost'"
check_absent "M4: 'localhost' — ingen network create" "$T/log-m4a" "^PODMAN network create"
sbx_run m4b -p h:99999 -w "$T/work-m1"
check_rc    "M4: 'h:99999' (port > 65535) → exit 1" 1 "$RC"
check       "M4: 'h:99999' feilmelding" "$T/err-m4b.log" "error: -p: bad proxy 'h:99999'"

# ---------------------------------------------------------- M5 -H host-portar
# -H port → tillitt upstream på host.containers.internal (proxy.yaml si
# allow_addresses). Duplisert port må bli nøyaktig éi post — dedup i
# PROXY_TRUSTED og i policy-generatoren.
sbx_run m5 -H 8080 -H 8080 -w "$T/work-m1"
check_rc    "M5: exit 0" 0 "$RC"
P="$T/cap-m5/proxy.yaml"
check_once  "M5: dedup — nøyaktig éi 169.254.1.2:8080" "$P" "169\.254\.1\.2:8080"
check_once  "M5: modellporten 8787 finst òg"            "$P" "169\.254\.1\.2:8787"
sbx_run m5b -H abc -w "$T/work-m1"
check_rc     "M5: '-H abc' → exit 1" 1 "$RC"
check        "M5: '-H abc' feilmelding" "$T/err-m5b.log" "error: -H: bad port 'abc'"
check_absent "M5: '-H abc' — ingen run-linje" "$T/log-m5b" "^PODMAN run"

# ---------------------------------------------------------- M6 .env-preferanse
# .env blir sourcea i sbx_main (set -a) og vinn over defaulten:
# --memory 4g/--pids-limit 1024 → verdiane i .env.
printf 'SBX_MEMORY=7g\nSBX_PIDS=42\n' > "$T/repo/.env"
sbx_run m6 -w "$T/work-m1"
check_rc "M6: exit 0" 0 "$RC"
LOG="$T/log-m6"
check  "M6: --memory 7g (frå .env)"       "$LOG" "\-\-memory 7g"
check  "M6: --pids-limit 42 (frå .env)"   "$LOG" "\-\-pids-limit 42"

# ------------------------------------------- M7 ingen modellkonfig + nøkkelen
# SBX_CLAUDE_CONFIG peiker på finast fil (sletta $T/claude.sh) → advarsel, og
# ANTHROPIC_API_KEY kjem frå .env (sourcea med set -a — vinn over env).
rm -f "$T/claude.sh"
printf 'ANTHROPIC_API_KEY=test-key\n' > "$T/repo/.env"
sbx_run m7 -w "$T/work-m1"
check_rc "M7: exit 0" 0 "$RC"
check  "M7: -e ANTHROPIC_API_KEY (frå .env)" "$T/log-m7" "\-e ANTHROPIC_API_KEY=test-key"
check  "M7: advarsel om manglande modellkonfig" "$T/err-m7.log" "warn: no model config at"

# ------------------------------------- M8 ingen modellkonfig, ingen nøkkelen
# Ingen konfig + usetta ANTHROPIC_API_KEY (sletta .env, -u i harneset) →
# hard feil før noko sesjonsressurs oppretast.
rm -f "$T/repo/.env"
sbx_run m8 -w "$T/work-m1"
check_rc     "M8: exit 1" 1 "$RC"
check        "M8: feilmelding" "$T/err-m8.log" "set ANTHROPIC_API_KEY in .env, or provide a model config"
check_absent "M8: ingen network create" "$T/log-m8" "^PODMAN network create"
check_absent "M8: ingen run-linje"      "$T/log-m8" "^PODMAN run"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
