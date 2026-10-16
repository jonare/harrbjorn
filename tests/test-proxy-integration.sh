#!/usr/bin/env bash
# tests/test-proxy-integration.sh — integrasjonstester for egress-proxyen
# (Smokescreen, harrbjorn/sbx-proxy).
#
# Dekker de fire usecasene:
#  1. Happy — GET og CONNECT til tillitshosten (host.containers.internal)
#     i open- OG enforce-modus
#  2. Blokkering — det som skal blokkeres blokkeres: loopback, link-local,
#     metadata-IP, privat/CGNAT i open-modus; utenfor allowlisten og
#     upålitelig port i enforce-modus
#  3. Bypass — vanlige triks mot blokkeringen: direkte IP på upålitelig
#     port, desimal loopback, userinfo, mangelfull Host-header,
#     self-connection, CONNECT til nektede destinasjoner
#  4. Uforandring — proxyen må ikke endre requests eller responses:
#     body-bytt og header må komme uendra til/fra originen
#
# Testen bygger opp to uavhengige proxy-instanser (en per policy-modus),
# hver med sitt --internal nettverk — samme oppsette som produksjonen i
# lib/sandbox.sh, inkludert proxy run-kommando og readiness-probe. En
# deterministisk origin (tests/origin.py) kjører på hosten.
#
# Krevd: podman, python3, harrbjorn/sbx-proxy:latest (bygges fra
# proxy/ dersom mangelfull — krever nett til github.com), fedora:latest
# (klientbilder; settes med SBX_CLIENT_IMAGE). Runtime velges som i
# produksjon: SBX_RUNTIME, default krun.
# Kjør: bash tests/test-proxy-integration.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"

# ---- forutsetninger -------------------------------------------------------
PODMAN="${PODMAN:-podman}"
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_IMAGE="${SBX_PROXY_IMAGE:-harrbjorn/sbx-proxy:latest}"
CLIENT="${SBX_CLIENT_IMAGE:-fedora:latest}"

die() { echo "ABORT $1" >&2; exit 1; }

command -v podman >/dev/null || die "podman finnes ikke"
command -v python3 >/dev/null || die "python3 finnes ikke"

$PODMAN image inspect "$PROXY_IMAGE" >/dev/null 2>&1 || \
  { echo ">> bygger $PROXY_IMAGE (krever nett til github.com)"; \
    $PODMAN build -t "$PROXY_IMAGE" "$REPO/proxy" >/dev/null; } \
  || die "kunne ikke bygge $PROXY_IMAGE"
$PODMAN image inspect "$CLIENT" >/dev/null 2>&1 \
  || $PODMAN pull "$CLIENT" >/dev/null 2>&1 \
  || die "kunne ikke hente klientbildet $CLIENT"

# ---- opprydding ------------------------------------------------------------
ORIGIN_PID=""
OPEN_NET="" OPEN_PROXY="" OPEN_IP=""
ENF_NET="" ENF_PROXY="" ENF_IP=""

cleanup() {
  [[ -n "$ORIGIN_PID" ]] && kill "$ORIGIN_PID" 2>/dev/null
  for c in "$OPEN_PROXY" "$ENF_PROXY"; do
    [[ -n "$c" ]] && $PODMAN rm -f "$c" >/dev/null 2>&1
  done
  for n in "$OPEN_NET" "$ENF_NET"; do
    [[ -n "$n" ]] && $PODMAN network rm "$n" >/dev/null 2>&1
  done
  rm -rf "$T"
}
trap cleanup EXIT

# Rester fra tidligere avbrutte kjøringer
$PODMAN ps -a --format '{{.Names}}' 2>/dev/null | grep '^sbxtest-' \
  | xargs -r $PODMAN rm -f >/dev/null 2>&1 || true
$PODMAN network ls --format '{{.Name}}' 2>/dev/null | grep '^sbxtest-' \
  | xargs -r $PODMAN network rm >/dev/null 2>&1 || true

# ---- delte kjerner fra lib/sandbox.sh ---------------------------------------
source "$REPO/lib/sandbox.sh"

pass=0 fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1 — $2"; fail=$((fail+1)); }

RUNTIME_ARGS=()
SBX_RUNTIME="${SBX_RUNTIME:-krun}"
sbx_check_runtime   # exit 1 (med melding) hvis runtime-krav ikke er oppfylt
echo ">> runtime: $SBX_RUNTIME"

# ---- origin på hosten -------------------------------------------------------
# Må lytte på 0.0.0.0: containeren når hosten via 169.254.1.2
# (host.containers.internal), og et 127.0.0.1-bind når der ikke.
ORIGIN_OUT="$T/origin.out"
python3 "$REPO/tests/origin.py" > "$ORIGIN_OUT" 2>&1 &
ORIGIN_PID=$!
for _ in $(seq 1 50); do
  grep -q '^origin-port=' "$ORIGIN_OUT" && break
  sleep 0.2
done
grep -q '^origin-port=' "$ORIGIN_OUT" || die "origin startet ikke ($(cat "$ORIGIN_OUT"))"
ORIGIN_PORT="$(sed -n 's/^origin-port=//p' "$ORIGIN_OUT")"
ORIGIN_SHA="$(sed -n 's/^origin-sha256=//p' "$ORIGIN_OUT")"
echo ">> origin: 0.0.0.0:$ORIGIN_PORT (nås fra container som 169.254.1.2:$ORIGIN_PORT)"

# ---- proxy-stabler (produksjonstrosness) -------------------------------------
# start_stack <open|enforce> — nett + policy + proxy-container + readiness.
# Skriver "net proxy ip" til stdout. Speiler produksjonens proxy
# run-kommando i lib/sandbox.sh (dobbelt nettverk: podman-nettet for
# host-mappingen 169.254.1.2 + internartet som eneste utgang).
start_stack() {
  local mode="$1" open net proxy pol resolv dns merged ip
  case "$mode" in
    open)    open=1; net="sbxtest-open-$$"; proxy="sbxtest-open-proxy-$$";;
    enforce) open=0; net="sbxtest-enf-$$";  proxy="sbxtest-enf-proxy-$$";;
  esac
  $PODMAN network create --internal "$net" >/dev/null || die "network create ($mode)"

  # Allowlisten (samme brukerformat som produksjon). api.github.com er der
  # bare for at enforce-modusen har en ekte domme; testen når den aldri
  # (hermetisk oppsett — DNS kan feile uten å påvise resultatet).
  merged="$T/allow-$mode.txt"
  printf '%s\n' host.containers.internal api.github.com > "$merged"

  pol="$T/pol-$mode"; mkdir -p "$pol"
  MERGED="$merged" SBX_OPEN_NETWORK="$open" \
    PROXY_TRUSTED="host.containers.internal:$ORIGIN_PORT" \
    PROXY_PORT="$PROXY_PORT" \
    sbx_write_proxy_policy "$pol" || die "policy-generering feilet ($mode)"

  # DNS til proxyen: hostens oppstrøms. Testene i seg selv er hermetiske,
  # men enforce-tilfellet utenfor allowlisten løses DNS mot.
  resolv="$T/resolv-$mode.conf"
  dns="$(sbx_uplink_dns 2>/dev/null || true)"
  if [[ -n "$dns" ]]; then
    while IFS= read -r ns; do echo "nameserver $ns"; done <<< "$dns" > "$resolv"
  else
    printf '# ingen oppstrøms-DNS; hermetiske tester trenger ikke oppslag\n' > "$resolv"
  fi

  $PODMAN run -d --name "$proxy" \
    "${RUNTIME_ARGS[@]}" \
    --userns=keep-id:uid=$(id -u),gid=$(id -g) \
    --network podman --network "$net" \
    -v "$resolv:/etc/resolv.conf:ro,z" \
    -v "$pol:/config:ro,z" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --user 65534:65534 \
    --memory 256m --pids-limit 128 --ulimit nofile=65536:65536 \
    "$PROXY_IMAGE" --config-file /config/proxy.yaml >/dev/null \
    || die "proxy-container startet ikke ($mode)"

  ip="$($PODMAN inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$proxy")"

  # Readiness: TCP-probe fra hjelpecontainer på internartet — samme mønster
  # som produksjonens probe. Hosten har ingen rute til internartet, så
  # probben må kjøres fra en container der.
  $PODMAN run --rm --network "$net" --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint bash "$CLIENT" \
    -c "for _ in \$(seq 1 120); do
          (exec 3<>/dev/tcp/$ip/$PROXY_PORT) 2>/dev/null && exit 0
          sleep 0.5
        done
        echo \"proxy not ready after 60s ($mode)\"; exit 1" \
    || { echo ">> proxy logs ($mode):" >&2; $PODMAN logs "$proxy" 2>&1 | tail -n 20 >&2; \
         die "proxyen kom ikke opp ($mode)"; }

  echo "$net $proxy $ip"
}

echo ">> starter open-stack ..."
read -r OPEN_NET OPEN_PROXY OPEN_IP <<< "$(start_stack open)"
echo ">> starter enforce-stack ..."
read -r ENF_NET ENF_PROXY ENF_IP <<< "$(start_stack enforce)"

# ---- klient- og aviseringshjelpe ------------------------------------------------
# client <net> <proxy_ip> <probe-args...> — throwaway-klient på stackens
# nettverk; kjører tests/probe.sh (rå /dev/tcp, ingen curl i containeren).
client() {
  local net="$1"; shift
  timeout 60 $PODMAN run --rm --network "$net" \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$REPO/tests:/tests:ro,z" \
    "$CLIENT" /tests/probe.sh "$@" 2>&1
}

status_of() { sed -n 's/^STATUS: //p' <<< "$1" | head -n 1 | tr -d '\r'; }

expect_status() { # label probe-output kode
  local st
  st="$(status_of "$2")"
  if [[ "$st" == HTTP/*"$3 "* || "$st" == HTTP/*"$3" ]]; then
    ok "$1: $st"
  else
    bad "$1" "forventet $3, fikk: ${st:-<ingen svar>}"
  fi
}

expect_blocked() { # label probe-output — en blokk må aldri la 2xx/3xx gjennom
  local st code
  st="$(status_of "$2")"
  case "$st" in
    "")        bad "$1" "ingen svar (når klienten proxyen?)" ;;
    HTTP/*)
      code="${st#* }"; code="${code%% *}"          # bare statuskoden, f.eks 407/502
      case "$code" in
        2*|3*) bad "$1" "blokkering slått gjennom: $st" ;;
        *)     ok "$1: $st" ;;
      esac ;;
    *)        bad "$1" "uventet svar: $st" ;;
  esac
}

body_b64()    { awk '/^BODY_BEGIN$/{f=1;next} /^BODY_END$/{f=0} f' <<< "$1" | tr -d '\n'; }
body_sha()    { body_b64 "$1" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}'; }
body_text()   { body_b64 "$1" | base64 -d 2>/dev/null; }

expect_body_sha() { # label probe-output forventet-sha256
  local sha
  sha="$(body_sha "$2")"
  [[ "$sha" == "$3" ]] && ok "$1: body sha256-identisk med origin" \
    || bad "$1" "body endret av proxyen (origin $3, via proxy ${sha:-<tom>})"
}

expect_body_eq() { # label probe-output forventet-tekst
  local got
  got="$(body_text "$2")"
  [[ "$got" == "$3" ]] && ok "$1: body som forventet" \
    || bad "$1" "forventet '$3', fikk '${got}'"
}

expect_hdr() { # label probe-output header forventet-verdi
  local v
  v="$(grep -m1 -i "^HDR: $3:" <<< "$2" | sed -E 's/^HDR: [^:]+: *//')"
  [[ "$v" == "$4" ]] && ok "$1: $3: $v" \
    || bad "$1" "$3 forventet '$4', fikk '${v}'"
}

expect_body_contains() { # label probe-output mønster
  if grep -q "$3" <(body_text "$2"); then
    ok "$1: inneholder '$3'"
  else
    bad "$1" "mangler '$3' i: $(body_text "$2" | tr '\n' '|')"
  fi
}

# ================================================================ 1. happy ====
echo
echo "== 1. Happy cases =="

OUT="$(client "$OPEN_NET" "$OPEN_IP" get "http://host.containers.internal:$ORIGIN_PORT/known.txt" || true)"
expect_status "open: GET til tillitshost" "$OUT" 200

OUT="$(client "$OPEN_NET" "$OPEN_IP" connect "host.containers.internal:$ORIGIN_PORT" || true)"
expect_status "open: CONNECT til tillitshost" "$OUT" 200
expect_body_eq "open: CONNECT-tunnelen når origin" "$OUT" "origin-home"

OUT="$(client "$ENF_NET" "$ENF_IP" get "http://host.containers.internal:$ORIGIN_PORT/known.txt" || true)"
expect_status "enforce: GET til tillatt domene" "$OUT" 200

OUT="$(client "$ENF_NET" "$ENF_IP" connect "host.containers.internal:$ORIGIN_PORT" || true)"
expect_status "enforce: CONNECT til tillatt domene" "$OUT" 200

# ========================================================== 2. blokkering ====
echo
echo "== 2. Blokkering =="

expect_blocked "open: loopback 127.0.0.1" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://127.0.0.1:$ORIGIN_PORT/known.txt" || true)"
expect_blocked "open: loopback [::1]" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://[::1]:$ORIGIN_PORT/known.txt" || true)"
expect_blocked "open: metadata-IP 169.254.169.254" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://169.254.169.254:80/latest/meta-data/" || true)"
expect_blocked "open: privat 10.x" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://10.1.2.3:80/" || true)"
expect_blocked "open: CGNAT 100.64.x" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://100.64.0.1:8080/" || true)"
expect_blocked "open: 0.0.0.0" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://0.0.0.0:$ORIGIN_PORT/known.txt" || true)"
expect_blocked "open: CONNECT til loopback" \
  "$(client "$OPEN_NET" "$OPEN_IP" connect "127.0.0.1:$ORIGIN_PORT" || true)"

expect_blocked "enforce: utenfor allowlisten (example.com)" \
  "$(client "$ENF_NET" "$ENF_IP" get "http://example.com:80/" || true)"
expect_blocked "enforce: tillitshost på upålitt port (:80)" \
  "$(client "$ENF_NET" "$ENF_IP" get "http://host.containers.internal:80/" || true)"

# ================================================================ 3. bypass ====
echo
echo "== 3. Bypass-forsøk =="

# Direkte IP på tillitshosten: unntaket er port-skopet, aldri «alle porter».
expect_blocked "open: 169.254.1.2:80 (direkte IP, upålitt port)" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://169.254.1.2:80/" || true)"
expect_blocked "enforce: 169.254.1.2:80 (direkte IP, upålitt port)" \
  "$(client "$ENF_NET" "$ENF_IP" get "http://169.254.1.2:80/" || true)"

# Ikke-normalisert loopback-form: må ikke lykkes (heller feile). Proxyen
# normaliserer ikke desimal IP til 127.0.0.1, så det faller gjennom til
# en feil (502) — likevel aldri 2xx/3xx.
expect_blocked "open: loopback som desimal IP" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://2130706433:$ORIGIN_PORT/known.txt" || true)"
expect_blocked "open: userinfo i URL" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://attacker@127.0.0.1:$ORIGIN_PORT/known.txt" || true)"
# Host-spoofing: URL peker på blokkert mål, men Host-headeren hevder en
# tillitt domene. Proxyen må rute på URL, ikke Host — så dette må blokkeres.
expect_blocked "open: Host-spoofing (URL loopback, Host tillitt domene)" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://127.0.0.1:$ORIGIN_PORT/known.txt" "host.containers.internal:$ORIGIN_PORT" || true)"
expect_blocked "open: self-connection til proxyens egen port" \
  "$(client "$OPEN_NET" "$OPEN_IP" get "http://$OPEN_IP:$PROXY_PORT/" || true)"

expect_blocked "open: CONNECT til [::1]" \
  "$(client "$OPEN_NET" "$OPEN_IP" connect "[::1]:$ORIGIN_PORT" || true)"
expect_blocked "open: CONNECT til metadata-IP" \
  "$(client "$OPEN_NET" "$OPEN_IP" connect "169.254.169.254:80" || true)"

# ===================================================== 4. uforandring ======
echo
echo "== 4. Request/response uforandret av proxyen =="

POST_BODY="the quick brown fox jumps over 42"
POST_SHA="$(printf '%s' "$POST_BODY" | sha256sum | awk '{print $1}')"

no_mutation() { # label net ip
  local OUT
  OUT="$(client "$2" "$3" get "http://host.containers.internal:$ORIGIN_PORT/known.txt" || true)"
  expect_status "$1: GET svar 200" "$OUT" 200
  expect_body_sha "$1: respons-body endret ikke (GET)" "$OUT" "$ORIGIN_SHA"
  expect_hdr "$1: respons-header slår gjennom" "$OUT" "X-Test-Header" "keepme-value"

  OUT="$(client "$2" "$3" post "http://host.containers.internal:$ORIGIN_PORT/echo" "$POST_BODY" || true)"
  expect_status "$1: POST svar 200" "$OUT" 200
  expect_body_contains "$1: request-body endret ikke (sha256)" "$OUT" "body-sha256=$POST_SHA"
  expect_body_contains "$1: request-header endret ikke" "$OUT" "x-test-header=keepme-value"
  expect_body_contains "$1: Host-header endret ikke" "$OUT" "host=host.containers.internal:$ORIGIN_PORT"
  expect_body_contains "$1: metode endret ikke" "$OUT" "method=POST"
}
no_mutation "open"    "$OPEN_NET" "$OPEN_IP"
no_mutation "enforce" "$ENF_NET"  "$ENF_IP"

# ---------------------------------------------------------------- resultat ---
echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
