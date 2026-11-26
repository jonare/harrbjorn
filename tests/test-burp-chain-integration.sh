#!/usr/bin/env bash
# tests/test-burp-chain-integration.sh — integrasjonstest for -p med
# allowlist: produksjonens sbx_start_proxy (upstream-modus) og
# sbx_burp_chained mot en falsk Burp på hosten (tests/fake-burp.py).
#
# Kjeden i en -p-sesjon: sandbox → relay → Burp → Smokescreen → mål. Burp
# har harrbjorns Smokescreen som upstream-proxy, så Smokescreen slår opp og
# kobler til målet selv: ACL og IP-filter gjelder IP-en den dialer, og
# Burps egne DNS-oppslag spiller ingen rolle. Relayen (sandbox → Burp) er
# uendret og testes i test-relay-integration.sh; her er klienten curl på
# hosten.
#
# Forkastet alternativ: Smokescreen foran Burp (--upstream-*-proxy-addr).
# Smokescreen sender navnet videre, så Burp slår opp på nytt (DNS-rebinding
# forbi IP-filteret), og IP-filteret gjelder også Smokescreens egen dial til
# Burp — unntaket for den (allow_addresses) slipper klienten til Burp selv.
#
#   curl ─ fake-burp (127.0.0.1) ─ 127.0.0.1:<port> ─ Smokescreen ─ podman-nett ─ origin
#
# Dekker:
#  1. Smokescreen publisert kun på hostens loopback, kun på podman-nettet
#  2. tillatt mål (IP-literal, CONNECT og ren HTTP) nås gjennom kjeden
#  3. enforce: navn utenfor allowlisten og loopback avvises
#  4. open (-a '*'): loopback avvises av IP-filteret, tillatt mål nås
#  5. kanarisjekken: kjedet Burp godkjennes, direkte Burp avvises (begge
#     moduser)
#
# Runtime: Smokescreen under SBX_RUNTIME (default krun) som i produksjon;
# origin (målet, utenfor sandboxen) under crun.
# Krevd: podman, curl og python3 på hosten, harrbjorn/sbx-proxy:latest,
# harrbjorn/code:latest (origin).
# Kjør: bash tests/test-burp-chain-integration.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PODMAN="${PODMAN:-podman}"
die() { echo "ABORT $1" >&2; exit 1; }
command -v "$PODMAN" >/dev/null || die "podman finnes ikke"
command -v curl >/dev/null || die "curl finnes ikke på hosten"

source "$T_REPO/lib/sandbox.sh"
set +e
RUNTIME_ARGS=()
SBX_RUNTIME="${SBX_RUNTIME:-krun}"
sbx_check_runtime
echo ">> runtime: $SBX_RUNTIME"
for img in harrbjorn/sbx-proxy:latest harrbjorn/code:latest; do
  $PODMAN image inspect "$img" >/dev/null 2>&1 || die "bildet $img mangler"
done

ID="sbxtest-chain-$$"
ORIGIN="$ID-origin"
BURPS=() STACKS=()
cleanup() {
  local c p
  for p in ${BURPS[@]+"${BURPS[@]}"}; do kill "$p" 2>/dev/null; done
  for c in ${STACKS[@]+"${STACKS[@]}"} "$ORIGIN"; do $PODMAN rm -f -t 1 "$c" >/dev/null 2>&1; done
  rm -rf "$T_TMP"
}
trap cleanup EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# ---- origin (målet) på podman-nettet ----------------------------------------
$PODMAN run -d --name "$ORIGIN" --runtime crun --network podman \
  -v "$T_REPO/tests/origin.py:/origin.py:ro,z" --read-only --cap-drop ALL \
  --entrypoint python3 harrbjorn/code:latest /origin.py 8080 >/dev/null || die "origin startet ikke"
O_IP="$($PODMAN inspect -f '{{(index .NetworkSettings.Networks "podman").IPAddress}}' "$ORIGIN")"

# ---- Smokescreen via produksjonens sbx_start_proxy (upstream-modus) --------
# Som i sbx_main med -p: målet som IP-literal (--net), ingen andre poster.
# PROXY_TRUSTED er satt (modellport) og skal ikke havne i Smokescreen.
STATE_DIR="$T_TMP/state" NET_NAME="" SBX_NOFILE="$(sbx_nofile_limit "$(ulimit -Hn)")"
start_stack() { # name open(0|1) port
  PROXY_NAME="$1"; STACKS+=("$1")
  OPEN_EGRESS="$2" NET_ENTRIES=("$O_IP:8080")
  PROXY_TRUSTED="host.containers.internal:8000"
  ( sbx_start_proxy "$1" "" "$3" ) || die "sbx_start_proxy ($1)"
}
# start_burp UPSTREAM_PORT|"" — falsk Burp på hostens loopback; setter BURP_PORT
start_burp() {
  BURP_PORT="$(free_port)"; local out="$T_TMP/burp-$BURP_PORT.out" _
  BIND=127.0.0.1 UPSTREAM="${1:+127.0.0.1:$1}" python3 "$T_REPO/tests/fake-burp.py" "$BURP_PORT" > "$out" 2>&1 &
  BURPS+=($!)
  for _ in $(seq 1 25); do grep -q listening "$out" && return 0; sleep 0.2; done
  die "fake-burp startet ikke ($(cat "$out"))"
}
via() { # burp-port curl-args...
  local b="$1"; shift
  curl -sS -i --max-time 15 --noproxy '' -x "http://127.0.0.1:$b" "$@" 2>&1
}

P_ENF="$(free_port)"; start_stack "$ID-enf" 0 "$P_ENF"
start_burp "$P_ENF"; B_ENF="$BURP_PORT"
P_OPEN="$(free_port)"; start_stack "$ID-open" 1 "$P_OPEN"
start_burp "$P_OPEN"; B_OPEN="$BURP_PORT"
start_burp ""; B_DIRECT="$BURP_PORT"
echo ">> origin $O_IP; enforce 127.0.0.1:$P_ENF (burp :$B_ENF); open 127.0.0.1:$P_OPEN (burp :$B_OPEN); direkte burp :$B_DIRECT"

# ---- 1. publisering ---------------------------------------------------------
assert_eq "1: publisert kun på loopback" "127.0.0.1:$P_ENF" "$($PODMAN port "$ID-enf" 3128/tcp)"
assert_eq "1: kun på podman-nettet"      podman \
  "$($PODMAN inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$ID-enf" | xargs)"

# ---- 2. tillatt mål gjennom kjeden ------------------------------------------
assert_match "2: ren HTTP til tillatt IP-literal" origin-home "$(via "$B_ENF" "http://$O_IP:8080/")"
assert_match "2: CONNECT til tillatt IP-literal"  origin-home "$(via "$B_ENF" -p "http://$O_IP:8080/")"

# ---- 3. enforce -------------------------------------------------------------
out="$(via "$B_ENF" http://denied.example/)"
assert_match    "3: enforce: navn utenfor allowlisten avvist" 'X-Smokescreen-Error: [^[:cntrl:]]*denied\.example' "$out"
out="$(via "$B_ENF" http://127.0.0.1:9/)"
assert_match    "3: enforce: loopback avvist"                 'X-Smokescreen-Error' "$out"

# ---- 4. open ----------------------------------------------------------------
out="$(via "$B_OPEN" http://127.0.0.1:9/)"
assert_match "4: open: loopback avvist av IP-filteret" 'X-Smokescreen-Error: [^[:cntrl:]]*Not Global Unicast' "$out"
assert_match "4: open: tillatt mål nås"                origin-home "$(via "$B_OPEN" "http://$O_IP:8080/")"

# ---- 5. kanarisjekken -------------------------------------------------------
assert_ok    "5: enforce: kjedet Burp godkjennes" sbx_burp_chained "$ID-enf"  "127.0.0.1:$B_ENF"
assert_fails "5: enforce: direkte Burp avvises"   sbx_burp_chained "$ID-enf"  "127.0.0.1:$B_DIRECT"
assert_ok    "5: open: kjedet Burp godkjennes"    sbx_burp_chained "$ID-open" "127.0.0.1:$B_OPEN"
assert_fails "5: open: direkte Burp avvises"      sbx_burp_chained "$ID-open" "127.0.0.1:$B_DIRECT"

t_summary
