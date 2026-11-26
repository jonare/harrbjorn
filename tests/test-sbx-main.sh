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

# ------------------------------------------------- .git read-only
run_main true
assert_no_match "workdir: uten .git ingen .git-mount"   '/work/\.git' "$(sandbox_run)"

mkdir -p "$HH/proj/.git"
run_main true
assert_match "workdir: .git montert read-only"          "-v $HH/proj/\.git:/work/\.git:ro " "$(sandbox_run)"

run_main --git-rw true
assert_eq    "workdir: --git-rw: exit 0"                0 "$MAIN_RC"
assert_no_match "workdir: --git-rw: ingen ro-mount"     '/work/\.git:ro' "$(sandbox_run)"
assert_match "workdir: --git-rw advarer"                'warn: --git-rw' "$MAIN_ERR"
rmdir "$HH/proj/.git"

# ------------------------------------------- -p beholder --internal
# Med ekstern proxy (Burp) forblir sesjonsnettet --internal: en relay
# (socat) på internal + podman-nettet videresender KUN faste porter — den
# eksterne proxyen, modellporten og -H-portene. I sandboxen peker
# host.containers.internal på relayen, så modell-URL-er og -H-URL-er virker
# uendret, og agenten når ingenting annet direkte.
printf 'export ANTHROPIC_BASE_URL=http://localhost:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
relay_run() { grep -E '^run -d --name sbx-code-[0-9]+-[0-9]+-relay ' "$PLOG" | tail -1; }

run_main -p 127.0.0.1:4321 -H 9443 true
assert_eq    "-p: exit 0"                          0 "$MAIN_RC"
if plog_has "network create --internal sbx-code-"; then ok "-p: nettet er --internal"; else bad "-p: nettet er --internal" "$(grep '^network create' "$PLOG")"; fi
if plog_has "harrbjorn/sbx-proxy:latest"; then bad "-p: Smokescreen startes ikke" "startet"; else ok "-p: Smokescreen startes ikke"; fi
R="$(relay_run)"
assert_match "-p: relay-bildet"                    ' harrbjorn/sbx-relay:latest ' "$R"
assert_match "-p: relay på podman + internal"      '--network podman --network sbx-code-[0-9]+-[0-9]+-int ' "$R"
for f in '--read-only' '--cap-drop ALL' '--security-opt no-new-privileges' '--user 65534:65534' '--pids-limit [0-9]+' '--memory [0-9]+m'; do
  assert_match "-p: relay herdet ($f)"             " $f " "$R"
done
assert_match "-p: relay -> Burp"                   ' 4321:host\.containers\.internal:4321( |$)' "$R"
assert_match "-p: relay -> modellport"             ' 8000:host\.containers\.internal:8000( |$)' "$R"
assert_match "-p: relay -> -H-port"                ' 9443:host\.containers\.internal:9443( |$)' "$R"
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
# (-H 443). Host-siden (VMM-prosessen) er fortsatt uten caps, NNP, seccomp.
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

run_main -p 192.0.2.10:8080 true
assert_match "-p: ikke-loopback-proxy relayes til sin adresse" ' 8080:192\.0\.2\.10:8080( |$)' "$(relay_run)"

run_main -p 192.0.2.10:8000 true
assert_ne    "-p: portkollisjon med modellporten avvises" 0 "$MAIN_RC"
assert_match "-p: kollisjonsmelding"               'port 8000' "$MAIN_ERR"

FAKE_TCP_PROBE_RC=1 run_main -p 127.0.0.1:4321 true
assert_ne    "-p: fail-closed når proxyen ikke svarer" 0 "$MAIN_RC"
if plog_has "network create"; then bad "-p: fail-closed: ingenting opprettet" "nett laget"; else ok "-p: fail-closed: ingenting opprettet"; fi
rm -f "$HH/claude.sh"

# ------------------------------------- --no-default-allowlist (lokal modell)
# Håndhevet modus uten default-allowlisten: kun trusted modellport og
# eksplisitte -a/-f. Default-hostene (Anthropic, GitHub, npm, PyPI) er
# exfil-kapable og trengs ikke mot en lokal modell.
printf 'export ANTHROPIC_BASE_URL=http://localhost:8000\nexport ANTHROPIC_API_KEY=k\n' > "$HH/claude.sh"
acl() { cat "$PLOG.config/acl.yaml" 2>/dev/null; }
run_main true
assert_match "--no-default-allowlist: uten flagg: default-hostene med" 'api\.anthropic\.com' "$(acl)"
run_main --no-default-allowlist -a 192.0.2.7 true
assert_eq       "--no-default-allowlist: exit 0"                       0 "$MAIN_RC"
assert_no_match "--no-default-allowlist: ingen default-hoster"         'anthropic|github|npmjs|pypi' "$(acl)"
assert_match    "--no-default-allowlist: -a gjelder fortsatt"          "192\.0\.2\.7" "$(acl)"
assert_match    "--no-default-allowlist: modellporten fortsatt trusted" '169\.254\.1\.2:8000' "$(cat "$PLOG.config/proxy.yaml" 2>/dev/null)"
run_main --no-default-allowlist -a '*' true
assert_match    "--no-default-allowlist: advarer i åpen modus"         'warn: --no-default-allowlist' "$MAIN_ERR"
rm -f "$HH/claude.sh"

# ------------------------------------------- håndhevet som standard
# Begge usecases håndhever allowlisten. Åpen utgang er en allowlistpost,
# '*' (f.eks. -a '*' eller i -f-fila), ikke en env-innstilling:
# SBX_OPEN_NETWORK fra env/.env ignoreres med advarsel, så en eksport fra
# én økt kan ikke stille åpne en annen.
acl_action() { sed -n 's/^ *action: *//p' "$PLOG.config/acl.yaml" 2>/dev/null | head -1; }
run_main true
assert_eq       "utgang: code håndhever som standard"  enforce "$(acl_action)"
assert_no_match "utgang: ingen advarsel om åpen utgang" 'open egress' "$MAIN_ERR"
SBX_OPEN_NETWORK=1 run_main true
assert_eq       "utgang: SBX_OPEN_NETWORK åpner ikke"  enforce "$(acl_action)"
assert_match    "utgang: SBX_OPEN_NETWORK gir advarsel" 'warn: SBX_OPEN_NETWORK is ignored.*open egress: -a' "$MAIN_ERR"
run_main -a '*' true
assert_eq       "utgang: -a '*' gir åpen utgang"       open "$(acl_action)"
assert_match    "utgang: åpen utgang varsles"          'warn: open egress' "$MAIN_ERR"
assert_no_match "utgang: '*' ikke i allowed_domains"   "'\\*'|- \\*\$" "$(cat "$PLOG.config/acl.yaml" 2>/dev/null)"
printf 'example.org\n  *  \n' > "$T_TMP/open.list"
run_main -f "$T_TMP/open.list" true
assert_eq       "utgang: '*' i -f-fila gir åpen utgang" open "$(acl_action)"
run_main -a '*.example.org' true
assert_eq       "utgang: '*.x' er fortsatt bare et domene" enforce "$(acl_action)"
for f in "$T_REPO"/allowlist.*.default; do
  if grep -qxE '[[:space:]]*\*[[:space:]]*' "$f"; then bad "utgang: $(basename "$f") har ikke '*'" "har"; else ok "utgang: $(basename "$f") har ikke '*'"; fi
done

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

for _ in 1 2 3; do SBX_KEEP_SESSIONS=2 run_main true; done
assert_eq       "økter: SBX_KEEP_SESSIONS beholder de nyeste" 2 "$(find "$HBASE"/proj-* -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_match    "økter: nyeste beholdt"               "$(basename "$(home_of)")" "$(ls "$HBASE"/proj-*)"
rm -rf "$HBASE"

# ------------------------------------------------- --overlay (opt-in)
# /work er en overlay: workdir på hosten røres ikke under økten, og agenten
# kan skrive .git (i overlayen). Etterpå lager en nettløs hjelpecontainer
# en patch (lib/overlay-diff.sh); hosten viser sammendrag og apply-kommando.
OVL="$HR/\.sandbox/overlay/code-[0-9]+-[0-9]+"
helper_run() { grep -E '^run --rm .*:/lower:O ' "$PLOG" | tail -1; }
mkdir -p "$HH/proj/.git"
run_main --overlay true
SR="$(sandbox_run)"
assert_match    "overlay: /work som overlay"       "-v $HH/proj:/work:O,upperdir=$OVL/up,workdir=$OVL/wk " "$SR"
assert_no_match "overlay: ingen rw-bind av workdir" ':/work:z' "$SR"
assert_no_match "overlay: ingen egen .git-mount"   '/work/\.git' "$SR"
H="$(helper_run)"
assert_match    "overlay: hjelper nettløs, samme runtime" '--runtime crun --network none ' "$H"
assert_match    "overlay: hjelper ser lower og merged" "-v $HH/proj:/lower:O -v $HH/proj:/merged:O,upperdir=$OVL/up,workdir=$OVL/wk " "$H"
assert_match    "overlay: hjelper herdet"          ' --read-only .*--cap-drop ALL --security-opt no-new-privileges ' "$H"
assert_match    "overlay: hjelper kjører overlay-diff" ' --entrypoint bash harrbjorn/code:latest -c ' "$H"
# Fake-podman lager ingen patch: feilmelding, endringene beholdes.
assert_ne       "overlay: uten patch: exit ≠ 0"    0 "$MAIN_RC"
assert_match    "overlay: uten patch: feil med upperdir" "overlay: could not build the patch.*$OVL/up" "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*/up" >/dev/null; then ok "overlay: upperdir beholdt ved feil"; else bad "overlay: upperdir beholdt ved feil" "borte"; fi
rm -rf "$HR/.sandbox/overlay"

mkdir -p "$T_TMP/pl" "$T_TMP/pm"; echo x > "$T_TMP/pm/.envrc"
bash "$T_REPO/lib/overlay-diff.sh" "$T_TMP/pl" "$T_TMP/pm" "$T_TMP/fake.patch"
FAKE_PODMAN_PATCH="$T_TMP/fake.patch" run_main --overlay true
assert_eq       "overlay: exit 0"                  0 "$MAIN_RC"
assert_match    "overlay: rapport"                 '>> overlay: the workdir was not touched' "$MAIN_ERR"
assert_match    "overlay: sensitiv fil flagget"    '! \.envrc' "$MAIN_ERR"
assert_match    "overlay: patch lagret ved siden av" "patch: +$OVL\.patch" "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*.patch" >/dev/null; then ok "overlay: patchfil finnes"; else bad "overlay: patchfil finnes" "mangler"; fi
if grep -qE "^unshare rm -rf $OVL$" "$PLOG"; then ok "overlay: upperdir ryddes med podman unshare"; else bad "overlay: upperdir ryddes med podman unshare" "$(grep unshare "$PLOG")"; fi
rm -rf "$HR/.sandbox/overlay"

: > "$T_TMP/empty.patch"
FAKE_PODMAN_PATCH="$T_TMP/empty.patch" run_main --overlay true
assert_match    "overlay: ingen endringer"         'overlay: no changes' "$MAIN_ERR"
if compgen -G "$HR/.sandbox/overlay/code-*.patch" >/dev/null; then bad "overlay: ingen tom patchfil" "finnes"; else ok "overlay: ingen tom patchfil"; fi

FAKE_PODMAN_SANDBOX_RC=3 FAKE_PODMAN_PATCH="$T_TMP/empty.patch" run_main --overlay true
assert_eq       "overlay: agentens exit-kode beholdes" 3 "$MAIN_RC"
if [[ -n "$(helper_run)" ]]; then ok "overlay: patch lages også når agenten feiler"; else bad "overlay: patch lages også når agenten feiler" "ingen hjelper"; fi

FAKE_PODMAN_PATCH="$T_TMP/empty.patch" run_main --overlay --git-rw true
assert_match    "overlay: --git-rw advarer"        'warn: --git-rw has no effect with --overlay' "$MAIN_ERR"
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

FAKE_PODMAN_SANDBOX_RC=4 run_main true
assert_eq       "uten overlay: exit-koden beholdes" 4 "$MAIN_RC"
if [[ -z "$(helper_run)" ]]; then ok "uten overlay: ingen hjelper"; else bad "uten overlay: ingen hjelper" "kjørte"; fi

t_summary
