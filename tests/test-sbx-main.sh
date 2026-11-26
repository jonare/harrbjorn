#!/usr/bin/env bash
# tests/test-sbx-main.sh — koblingen i sbx_main: hvilke podman-kall og
# -argumenter en sesjon faktisk genererer. Hermetisk: fake podman, fake
# crun/resolvectl, kopi av repoet i en tempkatalog (tests/main-harness.sh).
# Kjør: bash tests/test-sbx-main.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/tests/main-harness.sh"

# ---------------------------------------------------------------- baseline
run_main true
assert_eq    "baseline: exit 0"                    0 "$MAIN_RC"
if plog_has "network create --internal sbx-code-"; then ok "baseline: internal-nett"; else bad "baseline: internal-nett" "$(cat "$PLOG")"; fi
if plog_has "harrbjorn/sbx-proxy:latest"; then ok "baseline: proxy startes"; else bad "baseline: proxy startes" "mangler"; fi
assert_match "baseline: sandbox kjøres"            'harrbjorn/code:latest true$' "$(sandbox_run)"

# nofile: 65536, men aldri over hostens hard-grense — rootless podman kan
# ikke heve den, og setrlimit feiler da ved oppstart (krun og crun).
assert_eq "nofile: hard-grense over taket gir 65536" 65536 "$(bash -c 'source "$1/lib/sandbox.sh"; sbx_nofile_limit 1048576' _ "$HR")"
assert_eq "nofile: unlimited gir 65536"           65536 "$(bash -c 'source "$1/lib/sandbox.sh"; sbx_nofile_limit unlimited' _ "$HR")"
assert_eq "nofile: lavere hard-grense brukes"     16384 "$(bash -c 'source "$1/lib/sandbox.sh"; sbx_nofile_limit 16384' _ "$HR")"
( ulimit -Sn 2048 && ulimit -Hn 2048 && run_main true )
assert_match "nofile: sandboxen innenfor hostens grense" ' --ulimit nofile=2048:2048 ' "$(sandbox_run)"
assert_match "nofile: proxyen innenfor hostens grense"   ' --ulimit nofile=2048:2048 ' "$(grep 'harrbjorn/sbx-proxy:latest' "$PLOG")"

# Uten modelconfig og uten ANTHROPIC_API_KEY starter sandboxen likevel
# (bash, pi mot en annen leverandør, claude med egen innlogging): bare en
# advarsel. Finnes nøkkelen i env/.env, sendes den videre som før.
T_API_KEY= run_main true
assert_eq       "uten nøkkel: exit 0"                0 "$MAIN_RC"
assert_match    "uten nøkkel: advarsel"              'no model config.*no ANTHROPIC_API_KEY' "$MAIN_ERR"
assert_no_match "uten nøkkel: ingen ANTHROPIC_API_KEY til sandboxen" '-e ANTHROPIC_API_KEY' "$(sandbox_run)"
assert_match    "uten nøkkel: sandboxen kjøres"      'harrbjorn/code:latest true$' "$(sandbox_run)"
run_main true
assert_match    "med nøkkel i env: sendes videre"    ' -e ANTHROPIC_API_KEY ' "$(sandbox_run)"

# Readiness-proben (sbx_wait_tcp) bruker rå /dev/tcp. Den skal kjøre i samme
# runtime som sandboxen: under krun skjer socket-bruken inne i gjesten, ikke
# som en bash-prosess på host-kjernen.
probe_run() { grep -E '^run --rm .*--entrypoint bash ' "$PLOG" | head -1; }
assert_match "probe: samme runtime som sandboxen"  ' --runtime crun ' "$(probe_run)"

# ------------------------------------------------- workdir-sperre koblet
run_main -w "$HH" true
assert_ne    "workdir: -w \$HOME avvises"               0 "$MAIN_RC"
assert_match "workdir: melding"                         'refusing workdir' "$MAIN_ERR"
if plog_has "network create"; then bad "workdir: ingenting opprettet før sperren" "nettverk ble laget"; else ok "workdir: ingenting opprettet før sperren"; fi

run_main -w "$HR" true
assert_ne    "workdir: -w <harrbjorn-repo> avvises"     0 "$MAIN_RC"

# ---------------------------------------------- flat agent-HOME montert
run_main true
assert_match "agent-HOME: flat agent-HOME montert (én per økt under workdir-nøkkelen)" \
  "-v $HR/.sandbox/agent-home/code/proj-[0-9a-f]{16}/code-[0-9]+-[0-9]+:/home/agent:z" "$(sandbox_run)"

# ------------------------------------------------- --work (workdir-modus)
# Workdir er en capability: overlay er default (workdir urørt, endringer
# som patch), ro og none gir en skrivbar /out per økt i stedet, rw er
# skrivbar med .git read-only, og rw+git slår av .git-sperren (advarsel).
OUTD="$HR/\.sandbox/out/code-[0-9]+-[0-9]+"
run_main true
SR="$(sandbox_run)"
assert_match    "work: overlay er default"          "-v $HH/proj:/work:O,upperdir=" "$SR"
assert_no_match "work: default ingen rw-bind"       ':/work:z' "$SR"
assert_no_match "work: default ingen /out"          ':/out:' "$SR"

run_main --work rw true
assert_eq       "work rw: exit 0"                   0 "$MAIN_RC"
assert_match    "work rw: workdir rw"               "-v $HH/proj:/work:z " "$(sandbox_run)"
assert_no_match "work rw: uten .git ingen .git-mount" '/work/\.git' "$(sandbox_run)"
assert_no_match "work rw: ingen /out"               ':/out:' "$(sandbox_run)"

mkdir -p "$HH/proj/.git"
run_main --work rw true
assert_match    "work rw: .git montert read-only"   "-v $HH/proj/\.git:/work/\.git:ro " "$(sandbox_run)"
run_main --work rw+git true
assert_eq       "work rw+git: exit 0"               0 "$MAIN_RC"
assert_match    "work rw+git: workdir rw"           "-v $HH/proj:/work:z " "$(sandbox_run)"
assert_no_match "work rw+git: ingen ro-mount"       '/work/\.git:ro' "$(sandbox_run)"
assert_match    "work rw+git: advarer"              'warn: --work rw\+git' "$MAIN_ERR"
run_main --work ro true
assert_no_match "work ro: ingen egen .git-mount"    '/work/\.git' "$(sandbox_run)"
rmdir "$HH/proj/.git"

rm -rf "$HR/.sandbox/out"
run_main --work ro true
SR="$(sandbox_run)"
assert_eq       "work ro: exit 0"                   0 "$MAIN_RC"
assert_match    "work ro: workdir read-only"        "-v $HH/proj:/work:ro,z " "$SR"
assert_match    "work ro: skrivbar /out per økt"    "-v $OUTD:/out:z " "$SR"
assert_match    "work ro: tom /out meldes"          'out: nothing written to /out' "$MAIN_ERR"
if compgen -G "$HR/.sandbox/out/code-*" >/dev/null; then bad "work ro: tom /out fjernes" "finnes"; else ok "work ro: tom /out fjernes"; fi

FAKE_PODMAN_OUT_FILE=result.txt run_main --work none true
SR="$(sandbox_run)"
assert_eq       "work none: exit 0"                 0 "$MAIN_RC"
assert_no_match "work none: workdir ikke montert"   ':/work' "$SR"
# podman avviser -w /work når ingenting er montert der (stat mot rootfs),
# så /work blir en tom, read-only tmpfs.
assert_match    "work none: tom read-only /work"    ' --tmpfs /work:ro,size=1m,mode=0555 ' "$SR"
assert_match    "work none: arbeidskatalog /work"   ' -w /work ' "$SR"
assert_match    "work none: skrivbar /out per økt"  "-v $OUTD:/out:z " "$SR"
assert_match    "work none: /out vises etterpå"     "out: .*$OUTD" "$MAIN_ERR"
assert_match    "work none: innholdet listes"       'result\.txt' "$MAIN_ERR"
if compgen -G "$HR/.sandbox/out/code-*/result.txt" >/dev/null; then ok "work none: /out beholdes"; else bad "work none: /out beholdes" "borte"; fi
assert_match    "work none: workdir er sesjonsnøkkelen" "-v $HR/\.sandbox/agent-home/code/proj-[0-9a-f]{16}/" "$SR"
rm -rf "$HR/.sandbox/out"

run_main --work bogus true
assert_ne       "work: ukjent modus avvises"        0 "$MAIN_RC"
assert_match    "work: melding om modus"            "--work.*bogus" "$MAIN_ERR"
if plog_has "network create"; then bad "work: ukjent modus: ingenting opprettet" "nett laget"; else ok "work: ukjent modus: ingenting opprettet"; fi
run_main --work
assert_ne       "work: uten argument avvises"       0 "$MAIN_RC"
for f in --overlay --git-rw; do
  run_main "$f" true
  assert_ne     "work: $f finnes ikke lenger"       0 "$MAIN_RC"
  assert_match  "work: $f er ukjent"                "unknown option: $f" "$MAIN_ERR"
done

# ------------------------------------------- -p beholder --internal
# Med ekstern proxy (Burp) forblir sesjonsnettet --internal: en relay
# (socat) på internal + podman-nettet videresender KUN faste porter — den
# eksterne proxyen, modellporten og hostportene (--net host:PORT). I sandboxen peker
# host.containers.internal på relayen, så modell-URL-er og host:PORT-URL-er virker
# uendret, og agenten når ingenting annet direkte.
#
# Allowlisten gjelder også med -p: harrbjorns Smokescreen er Burps
# upstream-proxy (sandbox → relay → Burp → Smokescreen → mål), publisert
# kun på hostens loopback og ikke koblet til sesjonsnettet — sandboxen når
# den bare gjennom Burp. Trusted host-porter går via relayen, aldri via
# Smokescreen. Før sandboxen starter sjekkes det at Burp faktisk sender
# videre til Smokescreen (kanari); ellers fail-closed.
printf 'export ANTHROPIC_BASE_URL=http://localhost:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
relay_run() { grep -E '^run -d --name sbx-code-[0-9]+-[0-9]+-relay ' "$PLOG" | tail -1; }
upstream_run() { grep -E '^run -d --name sbx-code-[0-9]+-[0-9]+-proxy ' "$PLOG" | tail -1; }

run_main -p 127.0.0.1:4321 --net host:9443 true
assert_eq    "-p: exit 0"                          0 "$MAIN_RC"
if plog_has "network create --internal sbx-code-"; then ok "-p: nettet er --internal"; else bad "-p: nettet er --internal" "$(grep '^network create' "$PLOG")"; fi
U="$(upstream_run)"
assert_match    "-p: Smokescreen startes"                   ' harrbjorn/sbx-proxy:latest ' "$U"
assert_match    "-p: Smokescreen publisert kun på loopback" ' -p 127\.0\.0\.1:3129:3128 ' "$U"
assert_match    "-p: Smokescreen på podman-nettet"          ' --network podman ' "$U"
assert_no_match "-p: Smokescreen ikke på sesjonsnettet"     '--network sbx-code-[0-9]+-[0-9]+-int' "$U"
for f in '--read-only' '--cap-drop ALL' '--security-opt no-new-privileges' '--user 65534:65534'; do
  assert_match  "-p: Smokescreen herdet ($f)"               " $f " "$U"
done
assert_no_match "-p: ingen trusted host-porter i Smokescreen" '169\.254\.1\.2' "$(cat "$PLOG.config/proxy.yaml" 2>/dev/null)"
assert_match    "-p: allowlisten håndheves"                 'action: enforce' "$(cat "$PLOG.config/acl.yaml" 2>/dev/null)"
assert_no_match "-p: bare modellen som default (lokal modell)" 'allowed_domains' "$(cat "$PLOG.config/acl.yaml" 2>/dev/null)"
if plog_has "burp-chained sbx-code-" && grep -qE '^burp-chained sbx-code-[0-9]+-[0-9]+-proxy 127\.0\.0\.1:4321$' "$PLOG"; then
  ok "-p: kanarisjekk mot Burp på hostens adresse"; else bad "-p: kanarisjekk mot Burp på hostens adresse" "$(grep '^burp-chained' "$PLOG")"; fi
lc="$(grep -nE '^burp-chained ' "$PLOG" | cut -d: -f1)"; ls="$(grep -nE '^run --rm -i --name sbx-code-[0-9]+-[0-9]+ ' "$PLOG" | cut -d: -f1)"
if [[ -n "$lc" && -n "$ls" ]] && (( lc < ls )); then
  ok "-p: kanarisjekk før sandboxen"; else bad "-p: kanarisjekk før sandboxen" "kanari linje '${lc}', sandbox linje '${ls}'"; fi
if grep -qE '^logs sbx-code-[0-9]+-[0-9]+-proxy$' "$PLOG" && grep -qE '^rm sbx-code-[0-9]+-[0-9]+-proxy$' "$PLOG"; then
  ok "-p: Smokescreen ryddes, audit-logg lagres"; else bad "-p: Smokescreen ryddes, audit-logg lagres" "$(grep -E '^(logs|rm) ' "$PLOG")"; fi
R="$(relay_run)"
assert_match "-p: relay-bildet"                    ' harrbjorn/sbx-relay:latest ' "$R"
assert_match "-p: relay på podman + internal"      '--network podman --network sbx-code-[0-9]+-[0-9]+-int ' "$R"
for f in '--read-only' '--cap-drop ALL' '--security-opt no-new-privileges' '--user 65534:65534' '--pids-limit [0-9]+' '--memory [0-9]+m'; do
  assert_match "-p: relay herdet ($f)"             " $f " "$R"
done
assert_match "-p: relay -> Burp"                   ' 4321:host\.containers\.internal:4321( |$)' "$R"
assert_match "-p: relay -> modellport"             ' 8000:host\.containers\.internal:8000( |$)' "$R"
assert_match "-p: relay -> hostport"               ' 9443:host\.containers\.internal:9443( |$)' "$R"
assert_no_match "-p: ingen andre porter"           ' [0-9]+:[^ ]+:(22|80|443)( |$)' "$R"
SR="$(sandbox_run)"
assert_match "-p: HTTP_PROXY -> relay"             '-e HTTP_PROXY=http://sbx-code-[0-9]+-[0-9]+-relay:4321 ' "$SR"
assert_match "-p: SBX_EXTERNAL_PROXY -> relay"     '-e SBX_EXTERNAL_PROXY=http://sbx-code-[0-9]+-[0-9]+-relay:4321 ' "$SR"
assert_match "-p: host.containers.internal -> relay" '--add-host host\.containers\.internal:10\.89\.0\.2 ' "$SR"
assert_match "-p: NO_PROXY har host.containers.internal" '-e NO_PROXY=[^ ]*host\.containers\.internal' "$SR"
assert_match "-p: sandbox kun på internal-nettet"  '--network sbx-code-[0-9]+-[0-9]+-int ' "$SR"
if plog_has "stop -t 1 sbx-code-" && grep -qE '^rm sbx-code-[0-9]+-[0-9]+-relay$' "$PLOG"; then ok "-p: relay ryddes"; else bad "-p: relay ryddes" "$(grep -E '^(stop|rm) ' "$PLOG")"; fi

# Under krun gjelder --sysctl nettnavnerommet på hosten, ikke gjestekjernen
# (der er ip_unprivileged_port_start 1024), og --cap-drop/--user gir ingen
# caps i gjesten: relayen må kjøre som root i gjesten for å lytte på < 1024
# (--net host:443). Host-siden (VMM-prosessen) er fortsatt uten caps, NNP, seccomp.
start_relay_with() { # runtime -> podman-loggen for relay-kallet
  : > "$PLOG"
  ( PODMAN="$HB/podman" FAKE_PODMAN_LOG="$PLOG" bash -c '
      source "$1/lib/sandbox.sh"
      SBX_RUNTIME="$2"; RUNTIME_ARGS=(--runtime "$2"); NET_NAME=sbx-t-int
      sbx_wait_tcp() { return 0; }
      sbx_start_relay t 443:host.containers.internal:9443
    ' _ "$HR" "$1" >/dev/null 2>&1 )
  grep -E '^run -d --name sbx-t-relay ' "$PLOG"
}
R="$(start_relay_with krun)"
assert_match    "-p/krun: relay som root i gjesten" ' --user 0:0 ' "$R"
assert_match    "-p/krun: VMM fortsatt uten caps"   ' --cap-drop ALL --security-opt no-new-privileges ' "$R"
R="$(start_relay_with crun)"
assert_match    "-p/crun: relay som 65534"          ' --user 65534:65534 ' "$R"
assert_match    "-p/crun: sysctl for lave porter"   ' --sysctl net\.ipv4\.ip_unprivileged_port_start=0 ' "$R"

# En hostport lik modellporten er samme port: én relay-lytter, ikke to
# (socat kan ikke lytte to ganger på samme port).
run_main -p 127.0.0.1:4321 --net host:9443,host:8000 true
assert_eq    "-p: hostport = modellport relayes én gang" 1 "$(relay_run | grep -oE ' 8000:host\.containers\.internal:8000( |$)' | wc -l)"

run_main -p 192.0.2.10:8080 true
assert_match "-p: ikke-loopback-proxy relayes til sin adresse" ' 8080:192\.0\.2\.10:8080( |$)' "$(relay_run)"

run_main -p 192.0.2.10:8000 true
assert_ne    "-p: portkollisjon med modellporten avvises" 0 "$MAIN_RC"
assert_match "-p: kollisjonsmelding"               'port 8000' "$MAIN_ERR"

FAKE_TCP_PROBE_RC=1 run_main -p 127.0.0.1:4321 true
assert_ne    "-p: fail-closed når proxyen ikke svarer" 0 "$MAIN_RC"
if plog_has "network create"; then bad "-p: fail-closed: ingenting opprettet" "nett laget"; else ok "-p: fail-closed: ingenting opprettet"; fi

run_main -p 127.0.0.1:4321 --net example.com true
assert_no_match "-p: --net gir ingen «no effect»-advarsel" 'no effect' "$MAIN_ERR"
assert_match    "-p: --net havner i allowlisten"      "'example\.com'" "$(cat "$PLOG.config/acl.yaml" 2>/dev/null)"
run_main -p 127.0.0.1:4321 --net @all true
assert_match    "-p: --net @all gir åpen utgang"      'action: open' "$(cat "$PLOG.config/acl.yaml" 2>/dev/null)"
assert_match    "-p: åpen utgang varsles"             'warn: open egress' "$MAIN_ERR"
run_main -p localhost:4321 true
assert_match    "-p localhost: kanari til localhost:4321" '^burp-chained [^ ]+ localhost:4321$' "$(grep '^burp-chained' "$PLOG")"

SBX_UPSTREAM_PORT=4000 run_main -p 127.0.0.1:4321 true
assert_match "-p: SBX_UPSTREAM_PORT velger porten"    ' -p 127\.0\.0\.1:4000:3128 ' "$(upstream_run)"
SBX_UPSTREAM_PORT=0 run_main -p 127.0.0.1:4321 true
assert_ne    "-p: ugyldig SBX_UPSTREAM_PORT avvises"  0 "$MAIN_RC"
if plog_has "network create"; then bad "-p: ugyldig port: ingenting opprettet" "nett laget"; else ok "-p: ugyldig port: ingenting opprettet"; fi

FAKE_BURP_CHAINED_RC=1 run_main -p 127.0.0.1:4321 true
assert_ne    "-p: fail-closed når Burp ikke er kjedet" 0 "$MAIN_RC"
assert_match "-p: meldingen peker på upstream-oppsettet" 'Upstream proxy servers.*127\.0\.0\.1:3129' "$MAIN_ERR"
assert_eq    "-p: sandboxen kjøres ikke uten kjede"   "" "$(sandbox_run)"
rm -f "$HH/claude.sh"

# ------------------------------------------- --net: bare modellen som default
# Uten --net er bare modellendepunktet åpent, avledet fra modelconfigen:
# lokal modell → trusted port; ekstern base-URL → API-hosten; ingen
# base-URL → hele @anthropic (Claude Code med nøkkel eller innlogging).
# Alt annet er eksplisitt på kommandolinja: --net vert,@sett,host:PORT,@all.
acl() { cat "$PLOG.config/acl.yaml" 2>/dev/null; }
pyaml() { cat "$PLOG.config/proxy.yaml" 2>/dev/null; }
acl_action() { sed -n 's/^ *action: *//p' "$PLOG.config/acl.yaml" 2>/dev/null | head -1; }
run_main true
assert_eq       "net: håndhevet som standard"          enforce "$(acl_action)"
assert_match    "net: uten base-URL: @anthropic"       "'api\.anthropic\.com'" "$(acl)"
assert_match    "net: uten base-URL: innlogging med"   "'claude\.ai'" "$(acl)"
assert_no_match "net: ingen dev-hoster som standard"   'github|npmjs|pypi|debian' "$(acl)"
assert_no_match "net: ingen advarsel om åpen utgang"   'open egress' "$MAIN_ERR"

printf 'export ANTHROPIC_BASE_URL=http://localhost:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
run_main true
assert_eq       "net: lokal modell: exit 0"            0 "$MAIN_RC"
assert_no_match "net: lokal modell: ingen hoster"      'anthropic|claude|github|npmjs|pypi' "$(acl)"
assert_match    "net: lokal modell: modellporten trusted" '169\.254\.1\.2:8000' "$(pyaml)"

printf 'export ANTHROPIC_BASE_URL=https://LLM.example.net:8443/v1\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
run_main true
assert_match    "net: ekstern base-URL: API-hosten"    "'llm\.example\.net'" "$(acl)"
assert_no_match "net: ekstern base-URL: ikke @anthropic" 'anthropic|claude' "$(acl)"
assert_no_match "net: ekstern base-URL: ingen portadvarsel" 'all ports' "$MAIN_ERR"
printf 'export ANTHROPIC_BASE_URL=http://10.0.0.9:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
run_main true
assert_match    "net: base-URL på privat IP: porten beholdes" '10\.0\.0\.9:8000' "$(pyaml)"

printf 'export ANTHROPIC_BASE_URL=http://localhost:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
run_main --net @dev true
assert_match    "net: @dev åpner dev-hostene"          "'github\.com'.*" "$(acl | tr '\n' ' ')"
assert_match    "net: @dev: npm"                       "'registry\.npmjs\.org'" "$(acl)"
assert_match    "net: settene logges"                  '>> net: .*@dev' "$MAIN_OUT"
run_main --net example.com --net @npm,192.0.2.7 true
assert_match    "net: gjentatt --net, vert"            "'example\.com'" "$(acl)"
assert_match    "net: gjentatt --net, sett"            "'registry\.npmjs\.org'" "$(acl)"
assert_match    "net: gjentatt --net, IP"              "192\.0\.2\.7" "$(acl)"
run_main --net host:9443 true
assert_match    "net: host:PORT trusted"               '169\.254\.1\.2:9443' "$(pyaml)"
assert_match    "net: host:PORT logges"                'host ports: 9443' "$MAIN_OUT"
run_main --net @all true
assert_eq       "net: @all gir åpen utgang"            open "$(acl_action)"
assert_match    "net: @all varsles"                    'warn: open egress' "$MAIN_ERR"
assert_no_match "net: @all: ingen allowed_domains"     'allowed_domains' "$(acl)"
run_main --net @all,host:9443 true
assert_eq       "net: @all + host:PORT: åpen"          open "$(acl_action)"
assert_match    "net: @all + host:PORT: hostporten"    '169\.254\.1\.2:9443' "$(pyaml)"
run_main --net '*.example.org' true
assert_eq       "net: '*.x' er bare et domene"         enforce "$(acl_action)"
rm -f "$HH/claude.sh"

for bad in '*' @all,example.com @nope host:0; do
  run_main --net "$bad" true
  assert_ne     "net: --net $bad avvises"              0 "$MAIN_RC"
  if plog_has "network create"; then bad "net: --net $bad: ingenting opprettet" "nett laget"; else ok "net: --net $bad: ingenting opprettet"; fi
done
printf 'x.example\n' > "$HH/proj/scope"
run_main --net @./scope true
assert_ne       "net: settfil i workdir avvises"       0 "$MAIN_RC"
rm -f "$HH/proj/scope"
run_main --net
assert_ne       "net: uten argument avvises"           0 "$MAIN_RC"
for f in -a -f -H; do
  run_main "$f" x true
  assert_match  "net: $f finnes ikke lenger"           "unknown option: $f" "$MAIN_ERR"
done
run_main --no-default-allowlist true
assert_match    "net: --no-default-allowlist finnes ikke lenger" 'unknown option: --no-default-allowlist' "$MAIN_ERR"

# Åpen utgang er bare --net @all på kommandolinja, aldri env: SBX_OPEN_NETWORK
# fra env/.env ignoreres med advarsel, så en eksport fra én økt kan ikke
# stille åpne en annen.
SBX_OPEN_NETWORK=1 run_main true
assert_eq       "utgang: SBX_OPEN_NETWORK åpner ikke"  enforce "$(acl_action)"
assert_match    "utgang: SBX_OPEN_NETWORK gir advarsel" 'warn: SBX_OPEN_NETWORK is ignored.*open egress: --net @all' "$MAIN_ERR"

# ------------------------------- én HOME per økt; resume er eksplisitt
# En ny økt starter med tom HOME (seedet fra bildet): tidligere økter
# påvirker den ikke. --resume gjenbruker sist brukte økts HOME (som den var),
# --resume=ID en bestemt; --sessions lister. Øktene ligger side om side og
# ryddes etter SBX_KEEP_SESSIONS (sist brukte beholdes).
HBASE="$HR/.sandbox/agent-home/code"
home_of() { sed -nE 's/.* -v ([^ ]+):\/home\/agent:z .*/\1/p' <<< "$(sandbox_run)"; }
rm -rf "$HBASE"
run_main true; H1="$(home_of)"
assert_match    "økter: ny økt får egen HOME"         "^$HBASE/proj-[0-9a-f]{16}/code-[0-9]+-[0-9]+\$" "$H1"
assert_match    "økter: økt-ID vises ved slutt"       "session $(basename "$H1").*--resume" "$MAIN_ERR"
run_main true; H2="$(home_of)"
assert_ne       "økter: neste økt får ny HOME"        "$H1" "$H2"
run_main --resume true
assert_eq       "økter: --resume tar sist brukte"     "$H2" "$(home_of)"
run_main "--resume=$(basename "$H1")" true
assert_eq       "økter: --resume=ID tar den økta"     "$H1" "$(home_of)"
run_main --resume true
assert_eq       "økter: resume gjør økta sist brukt"  "$H1" "$(home_of)"

run_main --sessions
assert_eq       "økter: --sessions: exit 0"           0 "$MAIN_RC"
assert_match    "økter: --sessions lister øktene"     "$(basename "$H1").*"$'\n'".*$(basename "$H2")" "$MAIN_OUT"
if grep -q '^run ' "$PLOG"; then bad "økter: --sessions starter ingenting" "$(grep '^run ' "$PLOG")"; else ok "økter: --sessions starter ingenting"; fi

run_main --resume=code-1-1 true
assert_ne       "økter: ukjent økt avvises"           0 "$MAIN_RC"
assert_match    "økter: melding om ukjent økt"        'no session code-1-1' "$MAIN_ERR"
if plog_has "network create"; then bad "økter: ingenting opprettet for ukjent økt" "nett laget"; else ok "økter: ingenting opprettet for ukjent økt"; fi
run_main '--resume=../../x' true
assert_ne       "økter: ugyldig ID avvises"           0 "$MAIN_RC"

exec 9>"$(dirname "$H1")/.$(basename "$H1").lock"; flock -n 9
run_main "--resume=$(basename "$H1")" true
assert_ne       "økter: økt i bruk avvises"           0 "$MAIN_RC"
assert_match    "økter: melding om økt i bruk"        'in use' "$MAIN_ERR"
exec 9>&-

rm -rf "$HBASE"
run_main --resume true
assert_ne       "økter: --resume uten økter avvises"  0 "$MAIN_RC"
assert_match    "økter: melding uten økter"           'no session to resume' "$MAIN_ERR"

# Capabilities per økt: hostside (<base>/.<ID>.caps, aldri montert) og
# union over øktene som har brukt HOME-en. En --resume som gir HOME-en mer
# enn den har hatt (f.eks. en HOME fra --net @all gjenopptatt med --work
# rw), gir en advarsel som lister utvidelsene.
rm -rf "$HBASE"
run_main true; H1="$(home_of)"; ID1="$(basename "$H1")"
CAPS="$(dirname "$H1")/.$ID1.caps"
assert_eq       "caps: ny økt lagrer work"            "work overlay" "$(grep -x 'work overlay' "$CAPS" 2>/dev/null)"
assert_eq       "caps: ny økt lagrer nett"            "net api.anthropic.com" "$(grep -x 'net api\.anthropic\.com' "$CAPS" 2>/dev/null)"
run_main --resume true
assert_no_match "caps: resume med samme caps: ingen advarsel" 'capabilities' "$MAIN_ERR"
run_main --resume --work rw --net @all,host:9443 true
assert_match    "caps: utvidet resume advarer"        "warn: --resume: session $ID1 gets capabilities its HOME has not had" "$MAIN_ERR"
assert_match    "caps: advarselen lister work"        'capabilities .*work rw' "$MAIN_ERR"
assert_match    "caps: advarselen lister @all"        'capabilities .*@all' "$MAIN_ERR"
assert_match    "caps: advarselen lister hostporten"  'capabilities .*host:9443' "$MAIN_ERR"
assert_eq       "caps: resume kjøres likevel"         0 "$MAIN_RC"
run_main --resume --work rw true
assert_no_match "caps: unionen er lagret"             'capabilities' "$MAIN_ERR"
rm -f "$CAPS"
run_main --resume true
assert_match    "caps: økt uten caps-fil advarer"     "warn: --resume: session $ID1 has no recorded capabilities" "$MAIN_ERR"
assert_eq       "caps: caps-fila lages da"            "work overlay" "$(grep -x 'work overlay' "$CAPS" 2>/dev/null)"
rm -rf "$HBASE"

for _ in 1 2 3; do SBX_KEEP_SESSIONS=2 run_main true; done
assert_eq       "økter: SBX_KEEP_SESSIONS beholder de nyeste" 2 "$(find "$HBASE"/proj-* -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_match    "økter: nyeste beholdt"               "$(basename "$(home_of)")" "$(ls "$HBASE"/proj-*)"
rm -rf "$HBASE"

# ------------------------------------------------- overlay (default)
# /work er en overlay: workdir på hosten røres ikke under økten, og agenten
# kan skrive .git (i overlayen). Etterpå lager en nettløs hjelpecontainer
# en patch (lib/overlay-diff.sh); hosten viser sammendrag og apply-kommando.
OVL="$HR/\.sandbox/overlay/code-[0-9]+-[0-9]+"
helper_run() { grep -E '^run --rm .*:/lower:O ' "$PLOG" | tail -1; }
rm -rf "$HR/.sandbox/overlay"
mkdir -p "$HH/proj/.git"
FAKE_PODMAN_PATCH=none run_main true
SR="$(sandbox_run)"
assert_match    "overlay: /work som overlay"       "-v $HH/proj:/work:O,upperdir=$OVL/up,workdir=$OVL/wk " "$SR"
assert_no_match "overlay: ingen rw-bind av workdir" ':/work:z' "$SR"
assert_no_match "overlay: ingen egen .git-mount"   '/work/\.git' "$SR"
H="$(helper_run)"
assert_match    "overlay: hjelper nettløs, samme runtime" '--runtime crun --network none ' "$H"
assert_match    "overlay: hjelper ser lower og merged" "-v $HH/proj:/lower:O -v $HH/proj:/merged:O,upperdir=$OVL/up,workdir=$OVL/wk " "$H"
assert_match    "overlay: hjelper herdet"          ' --read-only .*--cap-drop ALL --security-opt no-new-privileges ' "$H"
assert_match    "overlay: hjelper kjører overlay-diff" ' --entrypoint bash harrbjorn/code:latest -c ' "$H"
# FAKE_PODMAN_PATCH=none: ingen patch — feilmelding, endringene beholdes.
assert_ne       "overlay: uten patch: exit ≠ 0"    0 "$MAIN_RC"
assert_match    "overlay: uten patch: feil med upperdir" "overlay: could not build the patch.*$OVL/up" "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*/up" >/dev/null; then ok "overlay: upperdir beholdt ved feil"; else bad "overlay: upperdir beholdt ved feil" "borte"; fi
rm -rf "$HR/.sandbox/overlay"

mkdir -p "$T_TMP/pl" "$T_TMP/pm"; echo x > "$T_TMP/pm/.envrc"
bash "$T_REPO/lib/overlay-diff.sh" "$T_TMP/pl" "$T_TMP/pm" "$T_TMP/fake.patch"
FAKE_PODMAN_PATCH="$T_TMP/fake.patch" run_main true
assert_eq       "overlay: exit 0"                  0 "$MAIN_RC"
assert_match    "overlay: rapport"                 '>> overlay: the workdir was not touched' "$MAIN_ERR"
assert_match    "overlay: sensitiv fil flagget"    '! \.envrc' "$MAIN_ERR"
assert_match    "overlay: patch lagret ved siden av" "patch: +$OVL\.patch" "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*.patch" >/dev/null; then ok "overlay: patchfil finnes"; else bad "overlay: patchfil finnes" "mangler"; fi
if grep -qE "^unshare rm -rf $OVL$" "$PLOG"; then ok "overlay: upperdir ryddes med podman unshare"; else bad "overlay: upperdir ryddes med podman unshare" "$(grep unshare "$PLOG")"; fi
rm -rf "$HR/.sandbox/overlay"

: > "$T_TMP/empty.patch"
FAKE_PODMAN_PATCH="$T_TMP/empty.patch" run_main true
assert_match    "overlay: ingen endringer"         'overlay: no changes' "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*.patch" >/dev/null; then bad "overlay: ingen tom patchfil" "finnes"; else ok "overlay: ingen tom patchfil"; fi

FAKE_PODMAN_SANDBOX_RC=3 FAKE_PODMAN_PATCH="$T_TMP/empty.patch" run_main true
assert_eq       "overlay: agentens exit-kode beholdes" 3 "$MAIN_RC"
if [[ -n "$(helper_run)" ]]; then ok "overlay: patch lages også når agenten feiler"; else bad "overlay: patch lages også når agenten feiler" "ingen hjelper"; fi

rmdir "$HH/proj/.git"; rm -rf "$HR/.sandbox/overlay"

# ------------------------------------- ekstra CA (--ca-cert / SBX_CA_CERTS)
# For nett med TLS-inspiserende mellomboks: CA-ene valideres før noe
# opprettes, går til sandboxen som env (verdien utenfor argv) og til
# bildebyggene som build-secret (aldri i et lag; fila slettes etterpå).
mkca() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$T_TMP/$1.key" -out "$T_TMP/$1.pem" -days 2 -subj "/CN=$1" 2>/dev/null; }
mkca ca1; mkca ca2
ca_count() { grep -c -- '-----BEGIN CERTIFICATE-----' "$PLOG"; }
FAKE_PODMAN_ENV_KEYS=SBX_EXTRA_CA_PEM run_main --ca-cert "$T_TMP/ca1.pem" true
assert_eq       "CA: exit 0"                       0 "$MAIN_RC"
assert_match    "CA: sandbox får SBX_EXTRA_CA_PEM ved navn" ' -e SBX_EXTRA_CA_PEM ' "$(sandbox_run)"
assert_no_match "CA: PEM ikke i argv"              'BEGIN CERTIFICATE' "$(grep -v '^env:' "$PLOG" | grep -v '^[A-Za-z0-9+/=]*$' | grep -v -- '-----END')"
assert_match    "CA: PEM i podmans miljø"          '^env:SBX_EXTRA_CA_PEM=-----BEGIN CERTIFICATE-----' "$(grep '^env:SBX_EXTRA_CA_PEM=' "$PLOG")"
assert_eq       "CA: ett sertifikat"               1 "$(ca_count)"
assert_no_match "CA: proxyen får den ikke"         'SBX_EXTRA_CA_PEM' "$(grep 'harrbjorn/sbx-proxy:latest' "$PLOG")"

FAKE_PODMAN_ENV_KEYS=SBX_EXTRA_CA_PEM SBX_CA_CERTS="$T_TMP/ca1.pem:$T_TMP/ca2.pem" run_main --ca-cert "$T_TMP/ca2.pem" true
assert_eq       "CA: SBX_CA_CERTS + --ca-cert"     3 "$(ca_count)"

run_main true
assert_no_match "CA: uten CA ingen variabel"       'SBX_EXTRA_CA_PEM' "$(sandbox_run)"

echo junk > "$T_TMP/junk.pem"
run_main --ca-cert "$T_TMP/junk.pem" true
assert_ne       "CA: ugyldig fil avvises"          0 "$MAIN_RC"
assert_match    "CA: melding"                      'no certificate' "$MAIN_ERR"
if plog_has "network create"; then bad "CA: ingenting opprettet før valideringen" "nett laget"; else ok "CA: ingenting opprettet før valideringen"; fi

rm -f "$PLOG.secret-sbx_ca"
run_main --rebuild --ca-cert "$T_TMP/ca1.pem" true
B="$(grep -E '^build ' "$PLOG")"
assert_match    "CA: code bygges med secret"       "^build --secret id=sbx_ca,src=$HR/\.sandbox/[^ ]+ -t harrbjorn/code:latest " "$B"
assert_match    "CA: proxy bygges med secret"      "build --secret id=sbx_ca,src=[^ ]+ -t harrbjorn/sbx-proxy:latest " "$B"
assert_eq       "CA: secreten er CA-en"            "$(cat "$T_TMP/ca1.pem")" "$(cat "$PLOG.secret-sbx_ca" 2>/dev/null)"
if compgen -G "$HR/.sandbox/build-ca-*" >/dev/null; then bad "CA: build-fila slettet" "finnes"; else ok "CA: build-fila slettet"; fi
run_main --rebuild true
assert_no_match "CA: uten CA ingen secret"         '--secret' "$(grep -E '^build ' "$PLOG")"

FAKE_PODMAN_SANDBOX_RC=4 run_main --work rw true
assert_eq       "uten overlay: exit-koden beholdes" 4 "$MAIN_RC"
if [[ -z "$(helper_run)" ]]; then ok "uten overlay: ingen hjelper"; else bad "uten overlay: ingen hjelper" "kjørte"; fi

t_summary
