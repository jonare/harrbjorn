#!/usr/bin/env bash
# tests/test-workdir-guard.sh — workdir-sperren.
#
# Workdir mountes rw i sandboxen. Sperren avviser workdirer der det gir
# sandboxen skrivetilgang til noe hosten selv kjører eller stoler på:
#  - / , $HOME og foreldre av $HOME
#  - harrbjorn-repoet, foreldre av det og alt inne i det (lib/, .env,
#    .sandbox/ med andre sesjoners HOME og audit-logger)
#  - kataloger som inneholder en beskyttet fil (modelconfigen, som
#    eval-es på hosten)
# Sammenligningen gjøres på fysiske stier (symlenker løses opp).
# Kjør: bash tests/test-workdir-guard.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

H="$T_TMP/home/u"; R="$H/git/harrbjorn"; C="$T_TMP/cfgdir/claude.sh"
mkdir -p "$H/proj/sub" "$R/lib" "$R/.sandbox" "$(dirname "$C")/sub"
touch "$C"
ln -s "$H" "$T_TMP/home-link"
ln -s "$R" "$H/proj/repo-link"

guard() { sbx_check_workdir "$1" "$H" "$R" "$C"; }

assert_fails "/ avvises"                         guard /
assert_fails "\$HOME avvises"                    guard "$H"
assert_match "melding nevner HOME"               'HOME' "$T_ERR"
assert_fails "forelder av \$HOME avvises"        guard "$T_TMP/home"
assert_fails "forelder av repoet avvises"        guard "$H/git"
assert_fails "repoet avvises"                    guard "$R"
assert_match "melding nevner harrbjorn"          'harrbjorn' "$T_ERR"
assert_fails "inne i repoet avvises"             guard "$R/lib"
assert_fails ".sandbox avvises"                  guard "$R/.sandbox"
assert_fails "katalog med modelconfigen avvises" guard "$(dirname "$C")"
assert_match "melding nevner fila"               'claude\.sh' "$T_ERR"
assert_fails "symlenke til \$HOME avvises"       guard "$T_TMP/home-link"
assert_fails "symlenke til repoet avvises"       guard "$H/proj/repo-link"
assert_ok    "vanlig prosjekt godtas"            guard "$H/proj"
assert_ok    "underkatalog godtas"               guard "$H/proj/sub"
assert_ok    "søsken av modelconfigen godtas"    guard "$(dirname "$C")/sub"
assert_ok    "manglende beskyttet fil er ok"     sbx_check_workdir "$H/proj" "$H" "$R" "$T_TMP/nope.sh"

t_summary
