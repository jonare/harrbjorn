#!/usr/bin/env bash
# tests/test-cli.sh — CLI-overflaten: hjelpetekst og autocomplete.
#
# Hjelpeteksten er kommentarblokken øverst i hver fil. Den skal skrives ut
# hel (ikke et fast linjeintervall som brekker når headeren endres), og
# aldri lekke kode. Alle flagg sbx_main godtar skal stå i hjelpen og i
# completion.
# Kjør: bash tests/test-cli.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for w in run-code.sh run-pentest.sh harrbjorn; do
  out="$(bash "$T_REPO/$w" -h 2>&1)"; rc=$?
  assert_eq       "$w -h: exit 0"                 0 "$rc"
  assert_no_match "$w -h: ingen kode lekker"      'set -euo|^export |sbx_main' "$out"
  last="$(printf '%s\n' "$out" | tail -1)"
  assert_match    "$w -h: siste linje er hjelpetekst" '^#' "$last"
done

for w in run-code.sh run-pentest.sh; do
  out="$(bash "$T_REPO/$w" -h 2>&1)"
  for f in -w -a -H -f -p --rebuild --git-rw --no-default-allowlist --overlay --ca-cert --resume --sessions; do
    assert_match "$w -h nevner $f" "(^|[[ ])$f([] ]|$)" "$out"
  done
done

# åpen utgang er -a '*', ikke SBX_OPEN_NETWORK — wrapperne setter den ikke.
for w in run-code.sh run-pentest.sh; do
  assert_match    "$w -h nevner -a '*'"            "-a '\*'" "$(bash "$T_REPO/$w" -h 2>&1)"
  assert_no_match "$w setter ikke SBX_OPEN_NETWORK" 'SBX_OPEN_NETWORK' "$(grep -v '^#' "$T_REPO/$w")"
done

comp="$(bash "$T_REPO/harrbjorn" completion)"
for f in -w -a -H -f -p --rebuild --git-rw --no-default-allowlist --overlay --ca-cert --resume --sessions; do
  assert_match "completion har $f" "(^|[\" ])$f( |\")" "$comp"
done

t_summary
