#!/usr/bin/env bash
# tests/test-agent-home.sh — agent-HOME-nøkkelen.
#
# Krav:
#  - flat: agent-HOME ligger alltid rett under agent-home/<usecase>/, så en
#    workdir og en underkatalog av den aldri får nestede HOME-er (en
#    sesjon har rw på sin HOME og skal ikke nå en annen sesjons HOME)
#  - stabil (samme workdir -> samme HOME) og unik per usecase + workdir
#  - lesbar: basename av workdir inngår i nøkkelen
#  - en agent-HOME som er (eller ligger under) en symlenke avvises før mount
# Kjør: bash tests/test-agent-home.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

S="$T_TMP/state"

a="$(sbx_agent_home "$S" code /home/u/proj)"
b="$(sbx_agent_home "$S" code /home/u/proj/sub)"
p="$(sbx_agent_home "$S" pentest /home/u/proj)"

assert_eq "flat: forelder er agent-home/code"   "$S/agent-home/code" "$(dirname "$a")"
assert_eq "flat: underkatalog også rett under"  "$S/agent-home/code" "$(dirname "$b")"
assert_no_match "underkatalogens HOME ligger ikke under forelderens" "^$a/" "$b"
assert_ne "ulik workdir -> ulik HOME"           "$a" "$b"
assert_ne "ulik usecase -> ulik HOME"           "$a" "$p"
assert_eq "stabil"                              "$a" "$(sbx_agent_home "$S" code /home/u/proj)"
assert_match "basename inngår"                  '/proj-[0-9a-f]{16}$' "$a"
assert_ne "samme basename, ulik sti -> ulik HOME" "$a" "$(sbx_agent_home "$S" code /other/proj)"
assert_match "rare tegn i basename saneres"     '/a_b_c-[0-9a-f]{16}$' "$(sbx_agent_home "$S" code '/x/a b$c')"
assert_match "rot-workdir har en nøkkel"        '/root-[0-9a-f]{16}$' "$(sbx_agent_home "$S" code /)"

# --- symlenke-sjekk før mount ---------------------------------------------
mkdir -p "$S/agent-home/code/real-0000000000000000"
assert_ok    "vanlig katalog godtas" sbx_check_agent_home "$S" "$S/agent-home/code/real-0000000000000000"

mkdir -p "$T_TMP/elsewhere"
ln -s "$T_TMP/elsewhere" "$S/agent-home/code/link-0000000000000000"
assert_fails "symlenke avvises"     sbx_check_agent_home "$S" "$S/agent-home/code/link-0000000000000000"
assert_match "feilmeldingen nevner symlenke" 'symlink' "$T_ERR"

mkdir -p "$T_TMP/other-state"
ln -s "$T_TMP/other-state" "$S/agent-home/pentest"
mkdir -p "$T_TMP/other-state/x-0000000000000000"
assert_fails "symlenke i en forelder under STATE_DIR avvises" \
  sbx_check_agent_home "$S" "$S/agent-home/pentest/x-0000000000000000"

t_summary
