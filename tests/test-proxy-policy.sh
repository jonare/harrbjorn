#!/usr/bin/env bash
# tests/test-proxy-policy.sh — enhetstester for sbx_write_proxy_policy
# (lib/sandbox.sh): genereringen av per-sesjon Smokescreen-konfig
# (proxy.yaml + acl.yaml).
#
# Dekker:
#  - inngangstyper: hostname, *.wildcard, IP, IP:port, [IPv6]:port,
#    hostname:port (med advarsel — ACL har ingen portdimensjon)
#  - open- vs enforce-modus (action + om tillitshosten havner i ACL)
#  - tillitshost-unntak: host.containers.internal:PORT -> 169.254.1.2:PORT
#  - ugyldige poster (allowlist + trusted) avvises med advarsel, ikke crash
#  - all generert YAML parseres (PyYAML som speiling av Smokescreens loader)
#
# Krevd: bash, python3 (med PyYAML). Ingen podman, ingen nettverk.
# Kjør: bash tests/test-proxy-policy.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
source "$REPO/lib/sandbox.sh"
PROXY_PORT=3128

pass=0 fail=0
check() { # label file pattern (grep -q)
  if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — mangler '$3' i $(basename "$2")"; echo "--- $(basename "$2"):"; cat "$2"; echo "----"
  fi
}
check_absent() { # label file pattern
  if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 — '$3' finnes i $(basename "$2")"; cat "$2"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}
run() { # label outdir allowlist open trusted
  local label="$1" out="$2" list="$3" open="$4" trusted="$5"
  mkdir -p "$out"
  cp "$list" "$MERGED"
  OPEN_EGRESS="$open"
  PROXY_TRUSTED="$trusted"
  ERR="$(sbx_write_proxy_policy "$out" 2>&1 || true)"
  # All genererte filer må være gyldig YAML.
  for f in "$out/acl.yaml" "$out/proxy.yaml"; do
    if python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null; then
      pass=$((pass+1)); echo "PASS  $label — $(basename "$f") er gyldig YAML"
    else fail=$((fail+1)); echo "FAIL  $label — $(basename "$f") er ugyldig YAML"; cat "$f"
    fi
  done
  WARN="$(printf '%s\n' "$ERR")"
}
warn_absent() { # label pattern-not-in-warn-output
  if printf '%s\n' "$WARN" | grep -q "$2"; then fail=$((fail+1)); echo "FAIL  $1 — uventet advarsel '$2'"; printf '%s\n' "$WARN"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}
warn_check() { # label pattern-in-warn-output
  if printf '%s\n' "$WARN" | grep -q "$2"; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — ingen advarsel som samsvarer med '$2'"; echo "--- stderr:"; printf '%s\n' "$WARN"; echo "----"
  fi
}

MERGED="$T/merged.txt"

# ---------------------------------------------------------------- scenario A
# enforce-modus, alle inngangstyper, én skadepost, tillitshost-port.
LIST_A="$T/a.txt"
cat > "$LIST_A" <<'EOF'
api.github.com
*.example.com
9.9.9.9
8.8.8.8:53
[2001:4860:4860::8888]:53
2606:4700:4700::1111
github.com:443
foo..com
EOF
OUT_A="$T/out-a"
run "A" "$OUT_A" "$LIST_A" 0 "host.containers.internal:8787"

A="$OUT_A/acl.yaml" P="$OUT_A/proxy.yaml"
check    "A: enforce action"           "$A" "action: enforce"
check    "A: vanlig host"              "$A" "api\.github\.com"
check    "A: wildcard"                 "$A" '\*\.example\.com'
check    "A: bar IPv4"                 "$A" "9\.9\.9\.9"
check    "A: IPv4:port holder host"    "$A" "8\.8\.8\.8"
check    "A: IPv6:port holder host"    "$A" "2001:4860:4860::8888"
check    "A: hostname:port depotet"    "$A" "github\.com"
check    "A: tillitshost i ACL"        "$A" "host\.containers\.internal"
check    "A: bar IPv6 i ACL"           "$A" "2606:4700:4700::1111"
check_absent "A: skadepost fjernet"    "$A" "foo\.\.com"
check_absent "A: ingen rå host:port"  "$A" "github\.com:443"

check    "A: portskopet IPv4"          "$P" "8\.8\.8\.8:53"
check    "A: portskopet IPv6"          "$P" "2001:4860:4860::8888:53"
check    "A: tillitshost-unntak"       "$P" "169\.254\.1\.2:8787"
check    "A: bar IPv4-område"          "$P" "9\.9\.9\.9/32"
check    "A: bar IPv6-område"          "$P" "2606:4700:4700::1111/128"
check    "A: missing role tillatt"     "$P" "allow_missing_role: true"
check    "A: acl-påtte"                "$P" "acl_file: /config/acl.yaml"
check    "A: port"                     "$P" "port: 3128"
check    "A: idle timeout"             "$P" "idle_timeout: 10m"
check_absent "A: ingen action-nøkkel i proxy.yaml" "$P" "action:"
check_absent "A: ingen alt-åpne områder" "$P" "0\.0\.0\.0/0"
warn_check "A: advarer host:port"      "github\.com:443"
warn_check "A: advarer skadepost"      "foo\.\.com"

# ---------------------------------------------------------------- scenario B
# open-modus (@all er alt): action open, tillitshost IKKE i ACL (default
# tillater alt), og IP-filteret slipper alle adresser — private, loopback
# og link-local (hosten) også.
LIST_B="$T/b.txt"
printf 'api.github.com\n' > "$LIST_B"
OUT_B="$T/out-b"
run "B" "$OUT_B" "$LIST_B" 1 "host.containers.internal:443"

B="$OUT_B/acl.yaml" Q="$OUT_B/proxy.yaml"
check        "B: open action"          "$B" "action: open"
check_absent "B: tillitshost ikke i ACL" "$B" "host\.containers\.internal"
check        "B: tillitshost-unntak"   "$Q" "169\.254\.1\.2:443"
check        "B: alle IPv4-adresser"   "$Q" "'0\.0\.0\.0/0'"
check        "B: alle IPv6-adresser"   "$Q" "'::/0'"

# ---------------------------------------------------------------- scenario C
# ugyldige trusted-poster avvises alle med advarsel; inget genereres.
LIST_C="$T/c.txt"
printf 'example.org\n' > "$LIST_C"
OUT_C="$T/out-c"
run "C" "$OUT_C" "$LIST_C" 0 "example.com:8080,host.containers.internal:99999,host.containers.internal:abc"

R="$OUT_C/proxy.yaml"
check_absent "C: ingen adresse for dårlig trusted" "$R" "allow_addresses:"
warn_check "C: advarer feil host"     "example\.com:8080"
warn_check "C: advarer port for stor" "host\.containers\.internal:99999"
warn_check "C: advarer ikke-numerisk" "host\.containers\.internal:abc"

# ---------------------------------------------------------------- scenario D
# IP:port for en offentlig IP — ACL-en har ingen portdimensjon, og
# IP-filteret (som håndhever porten for private IP-er via allow_addresses)
# slipper offentlige IP-er på alle porter. Det skal advares om; private
# IP:port skal ikke gi advarsel.
LIST_D="$T/d.txt"
printf '%s\n' 203.0.113.5:443 '[2001:db8::1]:443' 192.168.50.10:8080 10.0.0.1:80 '[fd00::1]:443' > "$LIST_D"
OUT_D="$T/out-d"
run "D" "$OUT_D" "$LIST_D" 0 ""
warn_check  "D: offentlig IPv4:port advarer"  "203\.0\.113\.5:443.*all ports"
warn_check  "D: offentlig IPv6:port advarer"  "2001:db8::1.*all ports"
warn_absent "D: privat IPv4:port advarer ikke" "192\.168\.50\.10"
warn_absent "D: privat 10/8 advarer ikke"     "10\.0\.0\.1"
warn_absent "D: ULA advarer ikke"             "fd00::1"

# ---------------------------------------------------------------- scenario E
# Hostadressen (169.254.1.2 = host.containers.internal) som IP-literal ville
# gitt et unntak fra IP-filteret for ALLE hostporter. Hosten nås kun via
# trusted-settet (--net host:PORT / modellporten): posten hoppes over med advarsel.
LIST_E="$T/e.txt"
printf '%s\n' 169.254.1.2 169.254.1.2:22 example.org > "$LIST_E"
OUT_E="$T/out-e"
run "E" "$OUT_E" "$LIST_E" 0 ""
check_absent "E: hostadressen ikke i allow_ranges"    "$OUT_E/proxy.yaml" "169\.254\.1\.2/32"
check_absent "E: hostadressen ikke i allow_addresses" "$OUT_E/proxy.yaml" "169\.254\.1\.2:22"
check_absent "E: hostadressen ikke i ACL-en"          "$OUT_E/acl.yaml" "169\.254\.1\.2"
warn_check   "E: advarer og viser til host:PORT"      "169\.254\.1\.2.*--net host:PORT"
check        "E: andre poster beholdes"               "$OUT_E/acl.yaml" "example\.org"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
