#!/usr/bin/env bash
# tests/test-model-config.sh — modelconfig-injeksjonen.
#
#  - sbx_trusted_model_port URL: porten blir trusted host-port KUN når
#    hosten er host.containers.internal, også med sti i URL-en
#  - sbx_model_env FIL: kun modell-relaterte variabler injiseres;
#    loopback-base-URL skrives om; andre eksporter (tokens o.l.) og
#    shell-støy (PWD, SHLVL, _) slippes, med advarsel som nevner navnet,
#    aldri verdien. Utdata er NUL-terminerte NAVN=VERDI-poster, så verdier
#    med linjeskift overlever.
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

# ----------------------------------------------------------- filtering
CFG="$T_TMP/claude.sh"
cat > "$CFG" <<'EOF'
# modelconfig
export ANTHROPIC_BASE_URL=http://localhost:8000/v1
export ANTHROPIC_API_KEY=sk-test-value
export ANTHROPIC_MODEL=qwen
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000
export MAX_THINKING_TOKENS=4000
export GITHUB_TOKEN=ghp-secret-value
export ANTHROPIC_CUSTOM_HEADERS="$(printf 'X-A: 1\nX-B: 2')"
claude "$@"
EOF
ERR="$T_TMP/err"
mapfile -d '' REC < <(sbx_model_env "$CFG" 2>"$ERR")
joined="$(printf '%s|' "${REC[@]}")"
assert_match "base-URL skrevet om"   '\|ANTHROPIC_BASE_URL=http://host\.containers\.internal:8000/v1\|' "|$joined"
assert_match "API-nøkkel med"        '\|ANTHROPIC_API_KEY=sk-test-value\|' "|$joined"
assert_match "modell med"            '\|ANTHROPIC_MODEL=qwen\|' "|$joined"
assert_match "CLAUDE_CODE_* med"     '\|CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000\|' "|$joined"
assert_match "navngitt Claude-var med" '\|MAX_THINKING_TOKENS=4000\|' "|$joined"
assert_match "flerlinjeverdi intakt" $'\\|ANTHROPIC_CUSTOM_HEADERS=X-A: 1\nX-B: 2\\|' "|$joined"
assert_no_match "GITHUB_TOKEN slippes"  'GITHUB_TOKEN' "$joined"
assert_no_match "PWD slippes"           '(^|\|)PWD=' "$joined"
assert_no_match "SHLVL slippes"         '(^|\|)SHLVL=' "$joined"
assert_no_match "_ slippes"             '(^|\|)_=' "$joined"
assert_match    "advarsel nevner navnet" 'GITHUB_TOKEN' "$(cat "$ERR")"
assert_no_match "advarsel lekker ikke verdien" 'ghp-secret-value' "$(cat "$ERR")"
assert_no_match "ingen advarsel om shell-støy" 'PWD|SHLVL' "$(cat "$ERR")"

# ------------------------------------------- verdier ikke i podman-argv
source "$T_REPO/tests/main-harness.sh"
cp "$CFG" "$HH/claude.sh"
FAKE_PODMAN_ENV_KEYS="ANTHROPIC_API_KEY ANTHROPIC_BASE_URL" run_main true
assert_eq       "sbx_main: exit 0"                 0 "$MAIN_RC"
assert_no_match "API-nøkkel ikke i argv"           'sk-test-value' "$(grep -v '^env:' "$PLOG")"
assert_match    "-e ANTHROPIC_API_KEY uten verdi"  '-e ANTHROPIC_API_KEY ' "$(sandbox_run)"
if grep -qxF 'env:ANTHROPIC_API_KEY=sk-test-value' "$PLOG"; then ok "verdien ligger i podmans miljø"
else bad "verdien ligger i podmans miljø" "$(grep '^env:' "$PLOG")"; fi
assert_match    "trusted port fra URL med sti"     "169\.254\.1\.2:8000" "$(cat "$PLOG.config/proxy.yaml" 2>/dev/null || echo "<ingen policy>")"
rm -f "$HH/claude.sh"

t_summary
