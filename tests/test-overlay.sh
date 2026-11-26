#!/usr/bin/env bash
# tests/test-overlay.sh — --overlay: patchen som lages etter økten
# (lib/overlay-diff.sh) og sammendraget på hosten (sbx_overlay_report).
#
# overlay-diff.sh kjøres i produksjon i en nettløs hjelpecontainer med
# workdir (lower) og overlay-visningen (merged) montert; her kjøres den på
# hosten mot to vanlige kataloger. MERGED er agent-kontrollert: ingenting
# derfra skal konfigurere git, og .git skal aldri med i patchen.
# Kjør: bash tests/test-overlay.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

L="$T_TMP/lower"; M="$T_TMP/merged"; P="$T_TMP/changes.patch"
mkdir -p "$L/.git" "$L/src" "$L/gone"
echo ref        > "$L/.git/HEAD"
echo keep       > "$L/src/keep.txt"
echo old        > "$L/src/mod.txt"
echo bye        > "$L/gone/x.txt"
echo 'build/'   > "$L/.gitignore"
echo tracked    > "$L/ignored-later.txt"
cp -a "$L" "$M"

# Agentens endringer:
echo new        > "$M/src/mod.txt"
echo added      > "$M/src/with space.txt"
rm -r "$M/gone"
printf '\x00\x01bin' > "$M/blob.bin"
printf '#!/bin/sh\n' > "$M/run.sh"; chmod +x "$M/run.sh"
ln -s src/keep.txt "$M/link"
echo 'export X=1' > "$M/.envrc"
mkdir -p "$M/build";  echo out > "$M/build/artifact"          # ignorert
echo changed    > "$M/ignored-later.txt"
printf 'build/\nignored-later.txt\n' > "$M/.gitignore"         # ignorer en sporet fil
echo planted    > "$M/.git/HEAD"                               # .git aldri med
mkdir -p "$M/.git/hooks"; printf '#!/bin/sh\n' > "$M/.git/hooks/pre-commit"
MARK="$T_TMP/fsmonitor-ran"
printf '[core]\n\tfsmonitor = "touch %s"\n' "$MARK" > "$M/.git/config"

gen() { bash "$T_REPO/lib/overlay-diff.sh" "$L" "$M" "$P"; }
assert_ok "patch lages" gen
pf="$(cat "$P" 2>/dev/null)"

files="$(git apply --numstat "$P" 2>/dev/null | cut -f3)"
assert_match    "endret fil med"                  '(^|'$'\n'')src/mod\.txt($|'$'\n'')' "$files"
assert_match    "ny fil med mellomrom med"        'src/with space\.txt' "$files"
assert_match    "slettet fil med"                 'gone/x\.txt' "$files"
assert_match    "binærfil med"                    'blob\.bin' "$files"
assert_match    "symlenke med"                    '(^|'$'\n'')link($|'$'\n'')' "$files"
assert_no_match "ingenting fra .git"              '(^|/)\.git/' "$files"
assert_no_match "ignorert fil ikke med"           'build/artifact' "$files"
assert_match    "sporet fil forblir sporet selv om merged ignorerer den" 'ignored-later\.txt' "$files"
assert_match    "binær som git binary patch"      'GIT binary patch' "$pf"
if [[ -e "$MARK" ]]; then bad "merged/.git/config kjøres ikke" "fsmonitor kjørte"; else ok "merged/.git/config kjøres ikke"; fi

# Rundtur: patchen på en kopi av lower gir merged (utenom .git og ignorert).
A="$T_TMP/apply"; cp -a "$L" "$A"
assert_ok "git apply på kopi av lower" git -C "$A" apply "$P"
assert_eq "rundtur gir merged" "" "$(diff -r --no-dereference -x .git -x build "$A" "$M" 2>&1)"

# Uten endringer: tom patch.
rm -rf "$M"; cp -a "$L" "$M"
assert_ok "uten endringer: kjører" gen
assert_eq "uten endringer: tom patch" 0 "$(stat -c %s "$P")"

# ---------------------------------------------------- sammendrag på hosten
# Filer som kjøres på hosten (direnv, make, npm, IDE, agent-config ...),
# kjørbare filer og symlenker flagges for gjennomgang.
rm -rf "$M"; cp -a "$L" "$M"
echo 'export X=1' > "$M/.envrc"
mkdir -p "$M/.vscode"; echo '{}' > "$M/.vscode/tasks.json"
echo '{}' > "$M/sub-package.json"                                # ikke package.json
mkdir -p "$M/web"; echo '{}' > "$M/web/package.json"
printf '#!/bin/sh\n' > "$M/run.sh"; chmod +x "$M/run.sh"
ln -s /etc/passwd "$M/link"
echo plain > "$M/notes.txt"
# Et agentvalgt filnavn med terminalsekvenser (her: slett linja over)
# skal ikke kunne skjule et flagg i rapporten.
mkdir -p "$M/.vscode"; printf '{}' > "$M/.vscode/x"$'\e'"[1A"$'\e'"[2K.json"
gen
source "$T_REPO/lib/sandbox.sh"
set +e
rep="$(sbx_overlay_report "$P" /some/workdir 2>&1)"
assert_match    "rapport: .envrc flagget"         '! \.envrc' "$rep"
assert_match    "rapport: .vscode flagget"        '! \.vscode/tasks\.json' "$rep"
assert_match    "rapport: package.json i undermappe flagget" '! web/package\.json' "$rep"
assert_no_match "rapport: sub-package.json ikke flagget" '! sub-package\.json' "$rep"
assert_match    "rapport: kjørbar fil flagget"    '! run\.sh \(executable\)' "$rep"
assert_match    "rapport: symlenke flagget"       '! link \(symlink\)' "$rep"
assert_no_match "rapport: vanlig fil ikke flagget" '! notes\.txt' "$rep"
assert_match    "rapport: stat"                   'notes\.txt' "$rep"
assert_no_match "rapport: ingen rå escape-tegn"   $'\e' "$rep"
assert_match    "rapport: escape-navnet flagget synlig" '! \.vscode/x\?\[1A\?\[2K\.json' "$rep"
assert_match    "rapport: apply-kommando"         "git -C /some/workdir apply $P" "$rep"

t_summary
