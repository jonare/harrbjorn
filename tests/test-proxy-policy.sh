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
  SBX_OPEN_NETWORK="$open"
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
warn_check "A: advarer host:port"      "github\.com:443"
warn_check "A: advarer skadepost"      "foo\.\.com"

# ---------------------------------------------------------------- scenario B
# open-modus: action open, tillitshost IKKE i ACL (default tillater alt),
# men port-unntaket står likevel (IP-filteret nekter link-local ellers).
LIST_B="$T/b.txt"
printf 'api.github.com\n' > "$LIST_B"
OUT_B="$T/out-b"
run "B" "$OUT_B" "$LIST_B" 1 "host.containers.internal:443"

B="$OUT_B/acl.yaml" Q="$OUT_B/proxy.yaml"
check        "B: open action"          "$B" "action: open"
check_absent "B: tillitshost ikke i ACL" "$B" "host\.containers\.internal"
check        "B: tillitshost-unntak"   "$Q" "169\.254\.1\.2:443"
check_absent "B: ingen allow_ranges"   "$Q" "allow_ranges:"

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

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
