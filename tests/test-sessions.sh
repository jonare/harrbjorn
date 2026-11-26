#!/usr/bin/env bash
# tests/test-sessions.sh — én agent-HOME per økt: hver økt får sin
# egen HOME under nøkkelen for usecase + workdir; resume er et eksplisitt
# valg. Metadata ligger på hosten utenfor det som monteres (<base>/.index i
# sist-brukt-rekkefølge, <base>/.<ID>.lock mens en kjøring bruker økta),
# så agenten kan ikke påvirke hvilken økt --resume velger. Ved siden av ligger
# <base>/.<ID>.caps: capabilities HOME-en har hatt (unionen over øktene som
# brukte den), så en --resume som utvider dem kan varsles.
# Kjør: bash tests/test-sessions.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

B="$T_TMP/base"; mkdir -p "$B"
mk() { mkdir -p "$B/$1"; sbx_session_touch "$B" "$1" "$2"; }

assert_fails "tom: ingen siste økt"            sbx_session_latest "$B"

mk code-100-1 100; mk code-200-2 200; mk code-300-3 300
assert_eq "siste økt"                          code-300-3 "$(sbx_session_latest "$B")"
sbx_session_touch "$B" code-100-1 400
assert_eq "resume flytter økta sist"           code-100-1 "$(sbx_session_latest "$B")"
assert_eq "hver økt én gang i indeksen"        1 "$(grep -c '^code-100-1 ' "$B/.index")"

rm -rf "$B/code-100-1"
assert_eq "slettet katalog hoppes over"        code-300-3 "$(sbx_session_latest "$B")"
printf '../evil 999\nnot-an-id 998\n' >> "$B/.index"; mkdir -p "$B/not-an-id"
assert_eq "ugyldige ID-er i indeksen ignoreres" code-300-3 "$(sbx_session_latest "$B")"

out="$(sbx_session_list "$B")"
assert_eq    "liste: nyeste først"             "code-300-3 code-200-2" "$(awk '{print $1}' <<< "$out" | tr '\n' ' ' | sed 's/ $//')"
assert_match "liste: tidspunkt og størrelse"   '^code-300-3[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}[[:space:]]+[0-9.]+[KMG]?' "$out"

# Opprydding: behold de KEEP sist brukte; aldri en låst (i bruk) økt.
mk code-400-4 400
sbx_session_prune "$B" 2 2>"$T_TMP/prune.err"
if [[ -d "$B/code-200-2" ]]; then bad "prune: eldste fjernet" "finnes"; else ok "prune: eldste fjernet"; fi
assert_eq    "prune: indeksen oppdatert"       "code-300-3 code-400-4" "$(awk '{print $1}' "$B/.index" | grep -E '^code-' | tr '\n' ' ' | sed 's/ $//')"
assert_match "prune: melder hva som fjernes"   'code-200-2' "$(cat "$T_TMP/prune.err")"
mkdir -p "$B/code-400-4/ro"; touch "$B/code-400-4/ro/f"; chmod 0500 "$B/code-400-4/ro"; touch "$B/code-300-3/x"

exec 9>"$B/.code-300-3.lock"; flock -n 9
sbx_session_prune "$B" 1 2>/dev/null
if [[ -d "$B/code-300-3" ]]; then ok "prune: låst økt beholdes"; else bad "prune: låst økt beholdes" "slettet"; fi
assert_fails "lås: økt i bruk avvises"         sbx_session_lock "$B" code-300-3
exec 9>&-
assert_ok    "lås: ledig økt"                  sbx_session_lock "$B" code-300-3

mk code-500-5 500
sbx_session_prune "$B" 1 2>/dev/null
if [[ -d "$B/code-400-4" ]]; then bad "prune: skrivebeskyttet underkatalog fjernes også" "finnes"; else ok "prune: skrivebeskyttet underkatalog fjernes også"; fi

# Lenker inne i en økt følges ikke ved sletting.
mkdir -p "$T_TMP/outside"; echo keep > "$T_TMP/outside/f"
mk code-600-6 600; ln -s "$T_TMP/outside" "$B/code-500-5/link"
sbx_session_prune "$B" 1 2>/dev/null
assert_eq "prune: følger ikke symlenker"       keep "$(cat "$T_TMP/outside/f" 2>/dev/null)"

# Metadatafilene følger ikke symlenker (en tidligere montert HOME kan ha
# blitt nøkkelkatalog): en lås- eller tmp-lenke til en annen fil skal
# verken avkorte eller skrive i den.
B2="$T_TMP/base2"; mkdir -p "$B2/code-1-1"; echo precious > "$T_TMP/victim"
ln -s "$T_TMP/victim" "$B2/.index.lock"; ln -s "$T_TMP/victim" "$B2/.index.tmp"
ln -s "$T_TMP/victim" "$B2/.code-1-1.lock"
sbx_session_touch "$B2" code-1-1 100
( sbx_session_lock "$B2" code-1-1 )
sbx_session_prune "$B2" 5 2>/dev/null
assert_eq "metadata: lenkemål urørt"           precious "$(cat "$T_TMP/victim")"
printf 'code-1-1 100\n$(id) junk\n' > "$B2/.index"
sbx_session_touch "$B2" code-1-1 200
assert_no_match "metadata: ugyldige linjer forkastes ved touch" 'junk' "$(cat "$B2/.index")"

# ------------------------------------------------------- capabilities
caps() { sbx_caps_lines "$@" | tr '\n' '|'; }
assert_eq "caps: linjer"  "host 8000|host 9443|net example.com|net registry.npmjs.org|work overlay|" \
  "$(caps overlay 0 host.containers.internal:8000,host.containers.internal:9443 registry.npmjs.org example.com)"
assert_eq "caps: @all"    "open|work rw|" "$(caps rw 1 "")"

C="$T_TMP/caps"; mkdir -p "$C/code-1-1"
assert_fails "caps: ingen fil ved første gangs lasting"  sbx_session_caps_load "$C" code-1-1
sbx_session_caps_save "$C" code-1-1 "$(sbx_caps_lines overlay 0 "" a.example)"
assert_eq "caps: lagret og lastet" "net a.example|work overlay|" "$(sbx_session_caps_load "$C" code-1-1 | tr '\n' '|')"
sbx_session_caps_save "$C" code-1-1 "$(sbx_caps_lines rw 0 "" b.example)"
assert_eq "caps: lagring er union" "net a.example|net b.example|work overlay|work rw|" "$(sbx_session_caps_load "$C" code-1-1 | tr '\n' '|')"
printf 'work overlay\n$(id) junk\nwork bogus\n' > "$C/.code-1-1.caps"
assert_eq "caps: ugyldige linjer forkastes" "work overlay|" "$(sbx_session_caps_load "$C" code-1-1 | tr '\n' '|')"
echo precious > "$T_TMP/victim2"; rm -f "$C/.code-1-1.caps"; ln -s "$T_TMP/victim2" "$C/.code-1-1.caps"
sbx_session_caps_save "$C" code-1-1 "work ro"
assert_eq "caps: lagring følger ikke symlenke" precious "$(cat "$T_TMP/victim2")"

# widened OLD-ARGS... -- NEW-ARGS... (argumentene til sbx_caps_lines)
widened() {
  local o=(); while [[ "$1" != -- ]]; do o+=("$1"); shift; done; shift
  sbx_caps_widened "$(sbx_caps_lines "${o[@]}")" "$(sbx_caps_lines "$@")" | tr '\n' ' '
}
assert_eq "utvidet: like caps"                  "" "$(widened overlay 0 "" -- overlay 0 "")"
assert_eq "utvidet: smalere work"               "" "$(widened rw 0 "" -- ro 0 "")"
assert_eq "utvidet: none < ro < overlay"        "work overlay " "$(widened ro 0 "" -- overlay 0 "")"
assert_eq "utvidet: rw etter overlay"           "work rw " "$(widened overlay 0 "" -- rw 0 "")"
assert_eq "utvidet: rw+git etter rw"            "work rw+git " "$(widened rw 0 "" -- rw+git 0 "")"
assert_eq "utvidet: @all"                       "@all " "$(widened overlay 0 "" -- overlay 1 "")"
assert_eq "utvidet: ny hostport"                "host:9443 " "$(widened overlay 0 host.containers.internal:8000 -- overlay 0 host.containers.internal:8000,host.containers.internal:9443)"
assert_eq "utvidet: ny post"                    "b.example " "$(widened overlay 0 "" a.example -- overlay 0 "" a.example b.example)"
assert_eq "utvidet: navn etter @all er dekket"  "" "$(widened overlay 1 "" -- overlay 0 "" github.com)"
assert_eq "utvidet: IP-literal etter @all er ny (private stengt i åpen modus)" "10.0.0.5:8080 [fd00::1]:443 " \
  "$(widened overlay 1 "" -- overlay 0 "" 10.0.0.5:8080 '[fd00::1]:443')"

# Opprydding fjerner også caps-fila.
mk code-700-7 700; mk code-800-8 800
sbx_session_caps_save "$B" code-700-7 "work ro"
sbx_session_prune "$B" 1 2>/dev/null
if [[ -e "$B/.code-700-7.caps" ]]; then bad "prune: caps-fila fjernes" "finnes"; else ok "prune: caps-fila fjernes"; fi

t_summary
