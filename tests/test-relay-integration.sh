#!/usr/bin/env bash
# tests/test-relay-integration.sh — integrasjonstest for -p-relayen:
# ekte podman, produksjonens sbx_start_relay.
#
# Oppsett som i en -p-sesjon: --internal sesjonsnett, relay på internal +
# podman-nettet, klienten (sandbox-stand-in) kun på internal-nettet med
# host.containers.internal -> relayen. To testservere på hosten
# (tests/origin.py): A relayes (på sin egen port og på 443), B ikke.
#
# Dekker:
#  1. relayet port når A (også port < 1024 — uprivilegert relay)
#  2. ikke-relayet host-port (B) er ikke nåbar
#  3. ingen direkte utgang til internett fra klienten
#  4. uten relay når klienten heller ikke hosten (lag 1, kontroll)
#  5. relayen er herdet (read-only rootfs, uid 65534; root i krun-gjesten)
#
# Readiness sjekkes med curl (HTTP mot testserveren) i stedet for
# sbx_wait_tcp: testen trenger bare «relayen videresender», og vanlige
# HTTP-klienter holder testen fri for rå socket-triks.
#
# Krevd: podman, python3, harrbjorn/sbx-relay:latest (bygges fra relay/ ved
# behov), curl-klientbilde (SBX_CLIENT_IMAGE). Runtime som i produksjon
# (SBX_RUNTIME, default krun; SBX_RUNTIME=crun uten KVM).
# Kjør: bash tests/test-relay-integration.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PODMAN="${PODMAN:-podman}"
CLIENT="${SBX_CLIENT_IMAGE:-docker.io/curlimages/curl:latest}"
die() { echo "ABORT $1" >&2; exit 1; }
command -v "$PODMAN" >/dev/null || die "podman finnes ikke"

source "$T_REPO/lib/sandbox.sh"
set +e
RUNTIME_ARGS=()
SBX_RUNTIME="${SBX_RUNTIME:-krun}"
sbx_check_runtime
echo ">> runtime: $SBX_RUNTIME"

$PODMAN image inspect harrbjorn/sbx-relay:latest >/dev/null 2>&1 \
  || $PODMAN build -q -t harrbjorn/sbx-relay:latest "$T_REPO/relay" >/dev/null \
  || die "kunne ikke bygge harrbjorn/sbx-relay:latest"
$PODMAN image inspect "$CLIENT" >/dev/null 2>&1 || $PODMAN pull -q "$CLIENT" >/dev/null \
  || die "kunne ikke hente $CLIENT"

# ---- testservere på hosten ---------------------------------------------------
ORIGINS=()
start_origin() { # -> port på stdout
  local out="$T_TMP/origin-$1.out"
  python3 "$T_REPO/tests/origin.py" > "$out" 2>&1 &
  ORIGINS+=($!)
  for _ in $(seq 1 25); do grep -q '^origin-port=' "$out" && break; sleep 0.2; done
  sed -n 's/^origin-port=//p' "$out"
}
PA="$(start_origin a)"; PB="$(start_origin b)"
[[ -n "$PA" && -n "$PB" ]] || die "testserverne startet ikke"
echo ">> testservere: A=:$PA (relayes), B=:$PB (relayes ikke)"

S="relaytest-$(date +%s)-$$"
NET_NAME="sbx-$S-int"
cleanup() {
  [[ -n "$RELAY_NAME" ]] && $PODMAN rm -f "$RELAY_NAME" >/dev/null 2>&1
  $PODMAN network rm "$NET_NAME" >/dev/null 2>&1
  for p in "${ORIGINS[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$T_TMP"
}
trap cleanup EXIT

sbx_wait_tcp() { # net ip port... — HTTP-readiness via curl (se header)
  local net="$1" ip="$2" p; shift 2
  for p in "$@"; do
    $PODMAN run --rm --network "$net" --entrypoint sh "$CLIENT" -c '
      for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 2 "http://$1:$2/" && exit 0; sleep 0.5
      done; exit 1' _ "$ip" "$p" || return 1
  done
}

$PODMAN network create --internal "$NET_NAME" >/dev/null || die "network create"
RELAY_NAME="sbx-$S-relay"   # før subshellen: cleanup skal finne den også når oppstarten feiler
( sbx_start_relay "$S" "$PA:host.containers.internal:$PA" "443:host.containers.internal:$PA" ) \
  || die "relayen startet ikke"
RELAY_IP="$($PODMAN inspect -f "{{(index .NetworkSettings.Networks \"$NET_NAME\").IPAddress}}" "$RELAY_NAME")"
echo ">> relay: $RELAY_NAME ($RELAY_IP)"

client() { # curl-args... — klient på internal-nettet, host -> relay; samme
           # runtime som sandboxen (--add-host må virke inne i krun-gjesten)
  $PODMAN run --rm "${RUNTIME_ARGS[@]}" --network "$NET_NAME" --add-host "host.containers.internal:$RELAY_IP" \
    "$CLIENT" -sS --noproxy '*' --max-time 5 "$@" 2>&1
}

# 1. relayet port
assert_eq "1: relayet port når A"            "origin-home" "$(client "http://host.containers.internal:$PA/")"
assert_eq "1: relayet port 443 når A"        "origin-home" "$(client "http://host.containers.internal:443/")"

# 2. ikke-relayet host-port
out="$(client "http://host.containers.internal:$PB/")"; rc=$?
assert_ne    "2: ikke-relayet port: feiler"     0 "$rc"
assert_no_match "2: ikke-relayet port: ingen respons fra B" 'origin-home' "$out"

# 3. ingen direkte utgang
out="$(client -I https://example.com/)"; rc=$?
assert_ne    "3: ingen direkte utgang til internett" 0 "$rc"

# 4. kontroll: uten relay når klienten ikke hosten
out="$($PODMAN run --rm "${RUNTIME_ARGS[@]}" --network "$NET_NAME" "$CLIENT" -sS --noproxy '*' --max-time 5 "http://host.containers.internal:$PA/" 2>&1)"; rc=$?
assert_ne    "4: uten relay: hosten ikke nåbar"  0 "$rc"

# 5. herding
assert_eq "5: read-only rootfs" true    "$($PODMAN inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$RELAY_NAME")"
# krun: root i gjesten (gjestekjernen ignorerer --sysctl), se sbx_start_relay
want_user=65534:65534; [[ "$SBX_RUNTIME" == krun ]] && want_user=0:0
assert_eq "5: bruker ($SBX_RUNTIME)" "$want_user" "$($PODMAN inspect -f '{{.Config.User}}' "$RELAY_NAME")"

t_summary
