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

# pi-modellen fra SBX_MODEL_*: et OpenAI-kompatibelt endepunkt (vLLM o.l.)
# som standardmodell. Nøkkelen refereres med env-interpolering — aldri som
# tekst på disk; uten nøkkel får pi en dummy (den krever en).
MJ="$H/.pi/agent/models.json"; SJ="$H/.pi/agent/settings.json"
jq_() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2:]: v=v[int(k)] if k.isdigit() else v[k]
print(v)' "$@" 2>/dev/null; }
model_init() { env HOME="$H" SBX_PI_BAKED_STORE="$B" "$@" sh "$T_REPO/code/sbx-init.sh" true 2>"$T_TMP/init.err"; }
echo '{"providers":{"egen":{"baseUrl":"http://x"}}}' > "$MJ"
model_init SBX_MODEL_BASE_URL=https://llm.example.net/v1 SBX_MODEL=m1 SBX_MODEL_API_KEY=sk-secret-x \
           SBX_MODEL_CONTEXT_WINDOW=65536 SBX_MODEL_MAX_TOKENS=8192
P=(providers harrbjorn)
assert_eq       "pi: OpenAI-kompatibelt API"   openai-completions        "$(jq_ "$MJ" "${P[@]}" api)"
assert_eq       "pi: base-URL"                 https://llm.example.net/v1 "$(jq_ "$MJ" "${P[@]}" baseUrl)"
assert_eq       "pi: nøkkel via env"           '${SBX_MODEL_API_KEY}'    "$(jq_ "$MJ" "${P[@]}" apiKey)"
assert_no_match "pi: nøkkelen ikke på disk"    'sk-secret-x'             "$(cat "$MJ" "$SJ")"
assert_eq       "pi: modell"                   m1                        "$(jq_ "$MJ" "${P[@]}" models 0 id)"
assert_eq       "pi: kontekstvindu"            65536                     "$(jq_ "$MJ" "${P[@]}" models 0 contextWindow)"
assert_eq       "pi: maks output"              8192                      "$(jq_ "$MJ" "${P[@]}" models 0 maxTokens)"
assert_eq       "pi: andre providere beholdt"  http://x                  "$(jq_ "$MJ" providers egen baseUrl)"
assert_eq       "pi: standardprovider"         harrbjorn                 "$(jq_ "$SJ" defaultProvider)"
assert_eq       "pi: standardmodell"           m1                        "$(jq_ "$SJ" defaultModel)"
model_init SBX_MODEL_BASE_URL=http://host.containers.internal:8000/v1 SBX_MODEL=m2
assert_eq       "pi: uten nøkkel: dummy"       none                      "$(jq_ "$MJ" "${P[@]}" apiKey)"
assert_eq       "pi: uten grenser: ingen"      ""                        "$(jq_ "$MJ" "${P[@]}" models 0 contextWindow)"
model_init SBX_MODEL_BASE_URL=https://llm.example.net/v1
assert_match    "pi: uten modell: advarsel"    'SBX_MODEL'               "$(cat "$T_TMP/init.err")"
rm -f "$MJ" "$SJ"
model_init ANTHROPIC_BASE_URL=https://llm.example.net ANTHROPIC_MODEL=m3 ANTHROPIC_API_KEY=k
assert_eq       "pi: ANTHROPIC_* brukes ikke"  ""                        "$(jq_ "$MJ" "${P[@]}" baseUrl)"

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
