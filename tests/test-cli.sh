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
  for f in -w -p --rebuild --net --work --ca-cert --resume --sessions; do
    assert_match "$w -h nevner $f" "(^|[[ ])$f([] ]|$)" "$out"
  done
done

# --net-postene står i hjelpen; åpen utgang er --net @all, ikke
# SBX_OPEN_NETWORK — wrapperne setter den ikke.
for w in run-code.sh run-pentest.sh; do
  out="$(bash "$T_REPO/$w" -h 2>&1)"
  for e in @all host:PORT @dev '@sti'; do
    assert_match  "$w -h nevner --net $e"          "$e" "$out"
  done
  assert_no_match "$w setter ikke SBX_OPEN_NETWORK" 'SBX_OPEN_NETWORK' "$(grep -v '^#' "$T_REPO/$w")"
done

# --work-modusene står i hjelpen; de fjernede flaggene står ingen steder.
for w in run-code.sh run-pentest.sh; do
  out="$(bash "$T_REPO/$w" -h 2>&1)"
  for m in overlay ro rw rw+git none; do
    assert_match "$w -h nevner --work $m" "(^|[^a-z+])${m//+/\\+}([^a-z+]|$)" "$out"
  done
done
# -a/-f/-H: i kall til harrbjorn/wrapperne, i usage-linjer og som `-a`.
for w in run-code.sh run-pentest.sh harrbjorn README.md .env.example; do
  assert_no_match "$w nevner ikke de fjernede flaggene" \
    '(--overlay|--git-rw|--no-default-allowlist)([^-a-z]|$)|(harrbjorn (code|security)|run-(code|pentest)\.sh)[^'$'\n'']* -[afH] |\[-[afH] |`-[afH]`|allowlist\.[a-z]+\.default' "$(cat "$T_REPO/$w")"
done

comp="$(bash "$T_REPO/harrbjorn" completion)"
for f in -w -p --rebuild --net --work --ca-cert --resume --sessions; do
  assert_match "completion har $f" "(^|[\" ])$f( |\")" "$comp"
done

t_summary
