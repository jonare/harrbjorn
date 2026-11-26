#!/usr/bin/env bash
# tests/test-net.sh — --net: oppslag av nettsett og poster (sbx_resolve_net).
#
# --net LISTE (kan gjentas, kommaseparert) gir sesjonens nett-capabilities:
#  - vert, *.domene, IP, IP:port, [IPv6]:port → allowlistposter
#  - host:PORT → hostport via host.containers.internal (ikke en post)
#  - @navn → sett fra ~/.config/harrbjorn/net/<navn>, ellers net/<navn> i
#    repoet; settfiler kan inkludere andre @navn
#  - @sti (inneholder /) → sett fra fil; ingen settfil kan ligge i workdir
#  - @all → åpen utgang; kan bare kombineres med host:PORT, og bare på
#    kommandolinja (ikke i en settfil)
# Kjør: bash tests/test-net.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

WD="$T_TMP/wd"; mkdir -p "$WD"
export HOME="$T_TMP/home"; mkdir -p "$HOME"
# net ITEM... — resolve; result in R_ENTRIES / R_PORTS / R_OPEN / R_SETS, stderr in T_ERR
net() {
  local out
  out="$( (
    sbx_resolve_net "$WD" "$@" || exit 1
    printf 'E %s\n' ${NET_ENTRIES[@]+"${NET_ENTRIES[@]}"}
    printf 'P %s\n' ${HOST_PORTS[@]+"${HOST_PORTS[@]}"}
    printf 'O %s\n' "$OPEN_EGRESS"
    printf 'S %s\n' ${NET_SETS[@]+"${NET_SETS[@]}"}
  ) 2>"$T_TMP/err")"; R_RC=$?
  T_ERR="$(cat "$T_TMP/err")"
  R_ENTRIES="$(sed -n 's/^E //p' <<< "$out" | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
  R_PORTS="$(sed -n 's/^P //p' <<< "$out" | grep -v '^$' | tr '\n' ' ')"
  R_OPEN="$(sed -n 's/^O //p' <<< "$out")"
  R_SETS="$(sed -n 's/^S //p' <<< "$out")"
}

# ---------------------------------------------------------------- poster
net
assert_eq "ingen --net: exit 0"                 0 "$R_RC"
assert_eq "ingen --net: ingen poster"           "" "$R_ENTRIES"
assert_eq "ingen --net: lukket"                 0 "$R_OPEN"

net example.com
assert_eq "vert"                                "example.com " "$R_ENTRIES"
net 'b.example, a.example' c.example
assert_eq "komma, mellomrom og gjentatt --net"  "a.example b.example c.example " "$R_ENTRIES"
net 'a.example,,b.example,'
assert_eq "tomme poster ignoreres"              "a.example b.example " "$R_ENTRIES"
net '*.example.org,10.0.0.5:8080,[fd00::1]:443,192.0.2.7'
assert_eq "wildcard, IP:port, [IPv6]:port, IP"  "*.example.org 10.0.0.5:8080 192.0.2.7 [fd00::1]:443 " "$R_ENTRIES"
net target.example.com:8080
assert_eq "navn:port slippes gjennom (porten håndheves ikke; policyen advarer)" "target.example.com:8080 " "$R_ENTRIES"

net '*'
assert_ne    "'*' avvises"                      0 "$R_RC"
assert_match "'*': melding peker på @all"       '@all' "$T_ERR"

# ------------------------------------------------------------- host:PORT
net host:8080 host:9443,example.com
assert_eq "host:PORT er hostport"               "8080 9443 " "$R_PORTS"
assert_eq "host:PORT er ikke en post"           "example.com " "$R_ENTRIES"
for bad in host:0 host:70000 host:x host:; do
  net "$bad"
  assert_ne "$bad avvises"                      0 "$R_RC"
done

# ------------------------------------------------------------------ @all
net @all
assert_eq "@all: åpen"                          1 "$R_OPEN"
net @all,host:8080
assert_eq "@all + host:PORT: exit 0"            0 "$R_RC"
assert_eq "@all + host:PORT: hostporten med"    "8080 " "$R_PORTS"
for other in @npm example.com 10.0.0.5:80; do
  net @all "$other"
  assert_ne    "@all + $other avvises"          0 "$R_RC"
  assert_match "@all + $other: melding"         '@all.*host:PORT' "$T_ERR"
done

# ---------------------------------------------------------- sett i repoet
net @npm
assert_eq    "@npm"                             "registry.npmjs.org " "$R_ENTRIES"
assert_match "@npm: settet logges med fila"     "@npm .*net/npm" "$R_SETS"
net @anthropic
assert_match "@anthropic: API-hosten"           '(^| )api\.anthropic\.com ' "$R_ENTRIES"
assert_match "@anthropic: innlogging"           '(^| )claude\.ai ' "$R_ENTRIES"
net @dev
for h in github.com registry.npmjs.org pypi.org files.pythonhosted.org repo1.maven.org deb.debian.org; do
  assert_match "@dev har $h"                    "(^| )${h//./\\.} " "$R_ENTRIES"
done
assert_no_match "@dev har ikke Anthropic (modellen er implisitt)" 'anthropic|claude' "$R_ENTRIES"
# GitHub videresender release-nedlastinger (github.com/.../releases/download)
# til egne CDN-verter; uten dem feiler f.eks. pi sin nedlasting av fd.
net @github
for h in release-assets.githubusercontent.com objects.githubusercontent.com; do
  assert_match "@github har $h (release-nedlastinger)" "(^| )${h//./\\.} " "$R_ENTRIES"
done
for f in "$T_REPO"/net/*; do
  if grep -qE '^[[:space:]]*(\*|@all)[[:space:]]*$' "$f"; then bad "$(basename "$f"): ingen '*'/@all" "har"; else ok "$(basename "$f"): ingen '*'/@all"; fi
done

net @nope
assert_ne    "ukjent sett avvises"              0 "$R_RC"
assert_match "ukjent sett: melding"             "@nope" "$T_ERR"
for bad in @ @.. @-x '@a b'; do
  net "$bad"
  assert_ne "ugyldig settnavn '$bad' avvises"   0 "$R_RC"
done

# ---------------------------------------------------- brukerens egne sett
UD="$HOME/.config/harrbjorn/net"; mkdir -p "$UD"
printf '# mine\nmine.example  # kommentar\n@npm\nhost:7000\n' > "$UD/mine"
net @mine
assert_eq "brukersett: poster og inkludert sett" "mine.example registry.npmjs.org " "$R_ENTRIES"
assert_eq "brukersett: host:PORT i settfil"      "7000 " "$R_PORTS"
printf 'own-npm.example\n' > "$UD/npm"
net @npm
assert_eq "brukersett overstyrer repoets"        "own-npm.example " "$R_ENTRIES"
rm "$UD/npm"

# --------------------------------------------------------------- @sti
printf 'scope.example\n@pypi\n' > "$T_TMP/scope"
net "@$T_TMP/scope"
assert_eq    "@sti: fil som sett"               "files.pythonhosted.org pypi.org scope.example " "$R_ENTRIES"
( cd "$T_TMP" && net @./scope; [[ "$R_ENTRIES" == "files.pythonhosted.org pypi.org scope.example " ]] ) \
  && ok "@./sti: relativt til cwd" || bad "@./sti: relativt til cwd" "feilet"
net "@$T_TMP/missing"
assert_ne    "@sti: manglende fil avvises"      0 "$R_RC"

printf 'x.example\n' > "$WD/scope"
net "@$WD/scope"
assert_ne    "@sti i workdir avvises"           0 "$R_RC"
assert_match "@sti i workdir: melding"          'workdir' "$T_ERR"
ln -s "$WD/scope" "$T_TMP/scope-link"
net "@$T_TMP/scope-link"
assert_ne    "@sti: symlenke inn i workdir avvises" 0 "$R_RC"
printf '@inwd\n' > "$T_TMP/outer"; mkdir -p "$WD/.cfg"; printf 'y.example\n' > "$WD/.cfg/inwd"
rm -rf "$UD"; ln -s "$WD/.cfg" "$UD"
net @inwd
assert_ne    "brukersett som ligger i workdir avvises" 0 "$R_RC"
rm "$UD"; mkdir -p "$UD"

printf '@all\n' > "$T_TMP/open"
net "@$T_TMP/open"
assert_ne    "@all i settfil avvises"           0 "$R_RC"
printf '@%s\n' "$T_TMP/scope" > "$T_TMP/pathinc"
net "@$T_TMP/pathinc"
assert_ne    "@sti i settfil avvises"           0 "$R_RC"
printf '*\n' > "$T_TMP/star"
net "@$T_TMP/star"
assert_ne    "'*' i settfil avvises"            0 "$R_RC"

printf 'a.example\n@cyc-b\n' > "$UD/cyc-a"; printf 'b.example\n@cyc-a\n' > "$UD/cyc-b"
net @cyc-a
assert_eq "sirkulær inkludering stopper"        "a.example b.example " "$R_ENTRIES"

t_summary
