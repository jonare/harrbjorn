#!/usr/bin/env bash
# tests/test-uplink-dns.sh — enhetstester for sbx_uplink_dns (lib/sandbox.sh):
# vertens upstream DNS-servere hentast til sesjons-proxyen.
#
# Dekker:
#  - U1 JSON-pas: resolvectl status --json=short (systemd sin reelle format —
#    liste av global + per-link objekt) → nøyaktig serverlisten, dedup,
#    loopback (127.* / ::1) filtrert
#  - U2 fallback: ugyldig JSON → menneskeformatet «DNS Servers: …»
#  - U3 resolv.conf-fallback (sed-redirect av /etc/resolv.conf): kommentar
#    + loopback fjernet
#  - U4 alt filtrert: berre loopback (og tom fil) → retur 1, tom utdata
#
# Krevd: bash, python3. Ingen podman, ingen nettverk (fake resolvectl på
# PATH, deterministisk via miljøvariablar).
# Kjør: bash tests/test-uplink-dns.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required." >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Sed-kopi med /etc/resolv.conf redirecta (selvverifiserande: endrast
# ralestien endrast testene).
sed "s|/etc/resolv.conf|$T/resolv.conf|g" "$REPO/lib/sandbox.sh" > "$T/sandbox-test.sh"
source "$T/sandbox-test.sh"
set +e # source slår på -e; feiltilfeller er forventet i testskallet

# Fake resolvectl foran på PATH: greiner på argument, oppførsel styrt av
# FAKE_JSON (utdata for --json=short) og FAKE_HUMAN (utdata for status).
mkdir -p "$T/bin"
cat > "$T/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
json=0
for a in "$@"; do
  [[ "$a" == --json=* ]] && json=1
done
if [[ "$json" -eq 1 ]]; then
  printf '%s\n' "${FAKE_JSON:-}"
  exit 0
fi
printf '%s\n' "${FAKE_HUMAN:-}"
exit 0
EOF
chmod +x "$T/bin/resolvectl"
export PATH="$T/bin:$PATH"

pass=0 fail=0
check_rc() { # label expected actual
  if [[ "$3" -eq "$2" ]]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — return $3, ventet $2"
  fi
}
check_exact() { # label actual-file expected-file
  if diff -q "$2" "$3" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — utdata avviker:"; echo "--- faktisk:"; cat "$2"; echo "--- venta:"; cat "$3"; echo "----"
  fi
}
check_absent() { # label file pattern
  if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 — '$3' finnes i $(basename "$2")"; cat "$2"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}

# run_dns "etikett" FAKE_JSON FAKE_HUMAN resolv.conf-innhold ("" = tom fil)
# → settest $RC og $OUT (resolv.conf-fallback leiest frå $T/resolv.conf).
run_dns() {
  local label="$1" json="$2" human="$3" conf="$4"
  if [[ -n "$conf" ]]; then printf '%s\n' "$conf" > "$T/resolv.conf"
  else : > "$T/resolv.conf"; fi
  RC=0
  OUT="$(FAKE_JSON="$json" FAKE_HUMAN="$human" sbx_uplink_dns 2>&1)" || RC=$?
}

# Selvverifisering av sed-kopien.
if grep -q "$T/resolv.conf" "$T/sandbox-test.sh"; then pass=$((pass+1)); echo "PASS  sed: ralestien redirecta til $T"
else fail=$((fail+1)); echo "FAIL  sed: $T/resolv.conf finnast ikkje i sed-kopien"; fi
if grep -q '/etc/resolv.conf' "$T/sandbox-test.sh"; then fail=$((fail+1)); echo "FAIL  sed: /etc/resolv.conf overlever i sed-kopien"
else pass=$((pass+1)); echo "PASS  sed: ingen /etc/resolv.conf att"
fi

# ---------------------------------------------------------------- scenario U1
# JSON-pasen: systemd si reelle format — liste der [0] er global-objekt
# (uten currentServer/servers) og resten er per-link. currentServer dukkar
# opp att i servers → dedup; 127.0.0.53 filtrert.
run_dns "U1" \
  '[{"resolvConfMode":"stub"},{"ifname":"eth1","currentServer":{"addressString":"10.99.99.99"},"servers":[{"addressString":"10.99.99.99"},{"addressString":"127.0.0.53"},{"addressString":"2606:4700:4700::1111"}]}]' \
  "" ""
printf '10.99.99.99\n2606:4700:4700::1111\n' > "$T/expect-u1"
check_rc    "U1: retur 0 (JSON-pasen)" 0 "$RC"
printf '%s\n' "$OUT" > "$T/actual-u1"
check_exact "U1: nøyaktig serverliste (dedup + loopback filtrert)" "$T/actual-u1" "$T/expect-u1"
check_absent "U1: loopback ikkje i utdata" "$T/actual-u1" '127\.'

# ---------------------------------------------------------------- scenario U2
# Fallback: --json=short gjev ugyldig JSON (python gjev av), menneskeformat
# i status utdata i staden.
run_dns "U2" 'not valid json {{{' \
  '    DNS Servers: 1.2.3.4 5.6.7.8 127.0.0.53' ""
printf '1.2.3.4\n5.6.7.8\n' > "$T/expect-u2"
printf '%s\n' "$OUT" > "$T/actual-u2"
check_rc    "U2: retur 0 (menneskeformat-fallback)" 0 "$RC"
check_exact "U2: servere haldne, loopback fjerna"   "$T/actual-u2" "$T/expect-u2"
check_absent "U2: loopback ikkje i utdata"           "$T/actual-u2" '127\.'

# ---------------------------------------------------------------- scenario U3
# Inga resolvectl-utdata → fallback til $T/resolv.conf (sed-redirecta).
# Kommentarlinje og loopback fjernast.
run_dns "U3" "" "" \
  'nameserver 8.8.8.8
nameserver 127.0.0.53
# nameserver 9.9.9.9'
printf '8.8.8.8\n' > "$T/expect-u3"
printf '%s\n' "$OUT" > "$T/actual-u3"
check_rc    "U3: retur 0 (resolv.conf-fallback)" 0 "$RC"
check_exact "U3: berre 8.8.8.8 (kommentar + loopback fjerna)" "$T/actual-u3" "$T/expect-u3"
check_absent "U3: kommentert nameserver ikkje i utdata" "$T/actual-u3" '9\.9\.9\.9'

# ---------------------------------------------------------------- scenario U4
# Alt filtrert: berre loopback i resolv.conf → retur 1, tom utdata.
# Likevel: totalt tom fil.
run_dns "U4" "" "" 'nameserver 127.0.0.53'
check_rc    "U4: retur 1 (berre loopback)" 1 "$RC"
if [[ -z "$OUT" ]]; then pass=$((pass+1)); echo "PASS  U4: tom utdata"
else fail=$((fail+1)); echo "FAIL  U4: venta tom utdata, fekk: $OUT"; fi

run_dns "U4b" "" "" ""
check_rc    "U4b: retur 1 (tom fil)" 1 "$RC"
if [[ -z "$OUT" ]]; then pass=$((pass+1)); echo "PASS  U4b: tom utdata"
else fail=$((fail+1)); echo "FAIL  U4b: venta tom utdata, fekk: $OUT"; fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
