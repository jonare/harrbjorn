#!/usr/bin/env bash
# tests/test-sbx-init.sh — init-steget i bildet (code/sbx-init.sh), kjørt
# på hosten med en midlertidig HOME (ingen container).
#
# Bildet er source of truth for bakte pi-extensions. En økts HOME kan
# gjenbrukes (--resume) og er agent-kontrollert mellom kjøringer, så hver
# kjøring skal:
#  - erstatte en bakt pakke helt (endrede filer tilbake, ekstra filer bort,
#    også når pakken er byttet ut med en symlenke)
#  - tvinge bakte pakkers spesifikator i store-ens package.json og
#    låsefila tilbake til den bakte (ellers kan pi sin `npm install` hente
#    noe annet)
#  - beholde agentens egne pakker
# Kjør: bash tests/test-sbx-init.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

B="$T_TMP/baked"; H="$T_TMP/home"; ST="$H/.pi/agent/npm"
mkdir -p "$B/node_modules/pi-subagents" "$B/node_modules/@scope/pkg" \
         "$ST/node_modules/pi-subagents" "$ST/node_modules/agent-own" "$T_TMP/elsewhere"
echo '{"dependencies":{"pi-subagents":"^1.0.0","@scope/pkg":"^2.0.0"}}' > "$B/package.json"
echo '{"lockfileVersion":3,"from":"baked"}' > "$B/package-lock.json"
echo baked        > "$B/node_modules/pi-subagents/index.js"
echo baked-scoped > "$B/node_modules/@scope/pkg/index.js"

# Agentens tilstand fra en tidligere kjøring:
echo modified > "$ST/node_modules/pi-subagents/index.js"
echo extra    > "$ST/node_modules/pi-subagents/extra.js"
echo own      > "$ST/node_modules/agent-own/index.js"
mkdir -p "$ST/node_modules/@scope"
ln -s "$T_TMP/elsewhere" "$ST/node_modules/@scope/pkg"
echo '{"name":"pi-extensions","dependencies":{"pi-subagents":"file:../somewhere","agent-own":"^3.0.0"}}' > "$ST/package.json"
echo '{"lockfileVersion":3,"from":"agent"}' > "$ST/package-lock.json"

init() { HOME="$H" SBX_PI_BAKED_STORE="$B" sh "$T_REPO/code/sbx-init.sh" true; }
assert_ok "init kjører" init

assert_eq "endret fil tilbakestilt"        baked "$(cat "$ST/node_modules/pi-subagents/index.js")"
if [[ -e "$ST/node_modules/pi-subagents/extra.js" ]]; then bad "ekstra fil fjernet" "finnes"; else ok "ekstra fil fjernet"; fi
if [[ -L "$ST/node_modules/@scope/pkg" ]]; then bad "symlenke erstattet med ekte katalog" "fortsatt symlenke"; else ok "symlenke erstattet med ekte katalog"; fi
assert_eq "scoped pakke gjenopprettet"     baked-scoped "$(cat "$ST/node_modules/@scope/pkg/index.js" 2>/dev/null)"
assert_eq "agentens egen pakke beholdt"    own "$(cat "$ST/node_modules/agent-own/index.js")"
spec() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"].get(sys.argv[2],""))' "$ST/package.json" "$1"; }
assert_eq "bakt spesifikator tvunget"      '^1.0.0' "$(spec pi-subagents)"
assert_eq "bakt scoped spesifikator"       '^2.0.0' "$(spec @scope/pkg)"
assert_eq "agentens spesifikator beholdt"  '^3.0.0' "$(spec agent-own)"
assert_match "låsefila er den bakte"       '"from": ?"baked"' "$(cat "$ST/package-lock.json")"
assert_match "pakkelisten i pi-settings"   'npm:pi-subagents' "$(cat "$H/.pi/agent/settings.json")"

# API-nøkkelen godkjennes slik Claude Code selv lagrer det: de siste 20
# tegnene (key.trim().slice(-20)) — aldri hele nøkkelen på disk.
KEY="sk-ant-test-0123456789-ABCDEFGHIJKLMNOPQRST"
HOME="$H" SBX_PI_BAKED_STORE="$B" ANTHROPIC_API_KEY="$KEY" sh "$T_REPO/code/sbx-init.sh" true 2>/dev/null
approved() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["customApiKeyResponses"]["approved"]))' "$H/.claude.json"; }
assert_eq       "nøkkel: godkjent som de siste 20 tegnene" "${KEY: -20}" "$(approved)"
assert_no_match "nøkkel: aldri hele nøkkelen i .claude.json" "sk-ant-test" "$(cat "$H/.claude.json")"

# Tom HOME: første kjøring seeder alt.
rm -rf "$H"; mkdir -p "$H"
assert_ok "init på tom HOME" init
assert_eq "seedet på tom HOME"             baked "$(cat "$ST/node_modules/pi-subagents/index.js" 2>/dev/null)"

# Ekstra CA fra hosten (SBX_EXTRA_CA_PEM, fra --ca-cert/SBX_CA_CERTS): en
# samlet bunt (systemlager + CA) i $HOME, og verktøyenes CA-variabler peker
# på den. Uten CA røres ingenting.
echo SYSTEM-STORE > "$T_TMP/system.pem"
pem="$(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null \
       -out /dev/stdout -days 2 -subj /CN=extra 2>/dev/null)"
CA_VARS="SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE GIT_SSL_CAINFO"
show_ca_env() { # -> VAR=verdi per linje, sett fra kommandoen init exec-er
  env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u NODE_EXTRA_CA_CERTS -u CURL_CA_BUNDLE -u GIT_SSL_CAINFO \
    HOME="$H" SBX_PI_BAKED_STORE="$B" SBX_SYSTEM_CA_BUNDLE="$T_TMP/system.pem" "$@" \
    sh "$T_REPO/code/sbx-init.sh" sh -c 'for v in '"$CA_VARS"'; do eval "echo $v=\${$v:-}"; done'
}
out="$(show_ca_env SBX_EXTRA_CA_PEM="$pem" 2>"$T_TMP/init.err")"
for v in $CA_VARS; do
  assert_match "CA: $v peker på bunten"     "(^|"$'\n'")$v=$H/\.sbx-ca-bundle\.pem($|"$'\n'")" "$out"
done
assert_eq    "CA: bunten starter med systemlageret" SYSTEM-STORE "$(head -1 "$H/.sbx-ca-bundle.pem" 2>/dev/null)"
assert_match "CA: bunten har CA-en"         'BEGIN CERTIFICATE' "$(cat "$H/.sbx-ca-bundle.pem" 2>/dev/null)"
assert_match "CA: melding på stderr"        '>> extra CA installed' "$(cat "$T_TMP/init.err")"
rm -f "$H/.sbx-ca-bundle.pem"
out="$(show_ca_env 2>/dev/null)"
assert_match "CA: uten CA ingen SSL_CERT_FILE" '(^|'$'\n'')SSL_CERT_FILE=($|'$'\n'')' "$out"
if [[ -e "$H/.sbx-ca-bundle.pem" ]]; then bad "CA: uten CA ingen bunt" "finnes"; else ok "CA: uten CA ingen bunt"; fi

t_summary
