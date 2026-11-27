#!/usr/bin/env bash
# tests/test-model-config.sh — modellendepunktet (pi) fra SBX_MODEL_*.
#
#  - sbx_trusted_model_port URL: porten blir trusted host-port KUN når
#    hosten er host.containers.internal, også med sti i URL-en
#  - sbx_model_url URL: en loopback-http-URL pekes mot
#    host.containers.internal (pastas hostadresse); alt annet urørt
#  - sbx_url_port URL: eksplisitt port, ellers skjemaets (443/80)
#  - sbx_private_addrs NAVN: bare de private adressene (RFC 1918, CGNAT,
#    ULA) navnet slår opp til — aldri loopback eller link-local (proxyen
#    selv, hosten, metadata)
#  - i sbx_main står verdiene aldri i podmans argv: kun -e NAVN; verdien
#    ligger i podmans miljø.
# Kjør: bash tests/test-model-config.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

# ------------------------------------------------------------- trust
p() { sbx_trusted_model_port "$1"; }
assert_eq "hci med port"            8000 "$(p http://host.containers.internal:8000)"
assert_eq "hci med port og sti"     8000 "$(p http://host.containers.internal:8000/v1)"
assert_eq "hci med port og /"       8000 "$(p http://host.containers.internal:8000/)"
assert_eq "ekstern host gir ingen trust" "" "$(p https://api.example.com:8443)"
assert_eq "hci uten port gir ingen trust" "" "$(p http://host.containers.internal)"
assert_eq "tom URL"                 ""   "$(p '')"
assert_eq "ugyldig port"            ""   "$(p http://host.containers.internal:99999)"

# ----------------------------------------------------------- loopback
u() { sbx_model_url "$1"; }
assert_eq "localhost skrives om"    http://host.containers.internal:8000/v1 "$(u http://localhost:8000/v1)"
assert_eq "127.0.0.1 skrives om"    http://host.containers.internal:8000/v1 "$(u http://127.0.0.1:8000/v1)"
assert_eq "ekstern URL urørt"       https://llm.example.net/v1 "$(u https://llm.example.net/v1)"
assert_eq "tom URL urørt"           "" "$(u '')"

# --------------------------------------------------------------- port
assert_eq "eksplisitt port"         8443 "$(sbx_url_port https://llm.example.net:8443/v1)"
assert_eq "https uten port: 443"    443  "$(sbx_url_port https://llm.example.net/v1)"
assert_eq "http uten port: 80"      80   "$(sbx_url_port http://llm.example.net/v1)"
assert_eq "userinfo er ikke port"   443  "$(sbx_url_port https://u:p@llm.example.net/v1)"

# ---------------------------------------------------- private adresser
_sbx_resolve() { printf '%s\n' 10.1.2.3 192.0.2.1 127.0.0.1 169.254.169.254 169.254.1.2 \
                                172.16.0.1 100.64.0.1 192.168.1.1 fd00::5 ::1 fe80::1 2001:db8::1; }
assert_eq "bare private adresser" "10.1.2.3 172.16.0.1 100.64.0.1 192.168.1.1 fd00::5" \
  "$(sbx_private_addrs llm.example.net | tr '\n' ' ' | sed 's/ $//')"
_sbx_resolve() { :; }
assert_eq "ukjent navn: ingenting" "" "$(sbx_private_addrs nope.example.net)"

# ------------------------------------------- verdier ikke i podman-argv
source "$T_REPO/tests/main-harness.sh"
SBX_MODEL_BASE_URL=http://localhost:8000/v1 SBX_MODEL=qwen SBX_MODEL_API_KEY=sk-test-value \
FAKE_PODMAN_ENV_KEYS="SBX_MODEL_API_KEY SBX_MODEL_BASE_URL SBX_MODEL" run_main true
assert_eq       "sbx_main: exit 0"                 0 "$MAIN_RC"
assert_no_match "API-nøkkel ikke i argv"           'sk-test-value' "$(grep -v '^env:' "$PLOG")"
assert_match    "-e SBX_MODEL_API_KEY uten verdi"  '-e SBX_MODEL_API_KEY ' "$(sandbox_run)"
if grep -qxF 'env:SBX_MODEL_API_KEY=sk-test-value' "$PLOG"; then ok "verdien ligger i podmans miljø"
else bad "verdien ligger i podmans miljø" "$(grep '^env:' "$PLOG")"; fi
if grep -qxF 'env:SBX_MODEL_BASE_URL=http://host.containers.internal:8000/v1' "$PLOG"; then ok "base-URL skrevet om i containeren"
else bad "base-URL skrevet om i containeren" "$(grep '^env:' "$PLOG")"; fi
if grep -qxF 'env:SBX_MODEL=qwen' "$PLOG"; then ok "modellen med"; else bad "modellen med" "$(grep '^env:' "$PLOG")"; fi
assert_match    "trusted port fra URL med sti"     "169\.254\.1\.2:8000" "$(cat "$PLOG.config/proxy.yaml" 2>/dev/null || echo "<ingen policy>")"

SBX_MODEL_BASE_URL=https://llm.example.net/v1 run_main true
assert_no_match "uten nøkkel: ingen -e SBX_MODEL_API_KEY" '-e SBX_MODEL_API_KEY' "$(sandbox_run)"

t_summary
