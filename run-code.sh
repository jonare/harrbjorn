#!/usr/bin/env bash
# run-code.sh — kodeagent-sandbox: dev-miljø + agent-CLIer (claude, pi).
#
# Usage:
#   harrbjorn code [-w <workdir>] [--net LIST]... [--work MODE]
#                  [-p host:port] [--ca-cert file]... [--rebuild]
#                  [--resume[=ID]] [--sessions]
#                  [--] [<cmd> [args...]]
#   (equivalent to ./run-code.sh; <workdir> defaults to the current
#   directory, and `--` is optional — the first non-flag argument
#   starts the command. With no command, an interactive bash opens in
#   the workdir)
#
#   Modell: pi mot et OpenAI-kompatibelt endepunkt fra SBX_MODEL_BASE_URL,
#   SBX_MODEL og SBX_MODEL_API_KEY (env/.env), injisert som env-vars;
#   loopback -> host.containers.internal.
#
#   Nett (--net LISTE, kan gjentas, kommaseparert): uten --net er bare
#   modellendepunktet åpent — den lokale modellserveren (trusted port),
#   eller hosten i en ekstern base-URL (et navn på private adresser får dem
#   på modellporten). Alt annet åpnes eksplisitt per økt, aldri via env/.env
#   (SBX_OPEN_NETWORK ignoreres):
#     vert, *.domene, IP, IP:port, [IPv6]:port
#              allowlistpost; porten håndheves bare for private IP-er
#              (navn:port gir alle porter, med advarsel)
#     host:PORT
#              hosttjeneste på http://host.containers.internal:PORT; ellers
#              er hosten stengt (link-local, også som IP-literal)
#     @navn    sett fra ~/.config/harrbjorn/net/<navn>, ellers net/<navn>:
#              @anthropic @github @npm @pypi @maven @debian, og @dev (alle
#              unntatt @anthropic)
#     @sti     sett fra fil (inneholder /), f.eks. @../scope; nektes inne i
#              workdir, der agenten skriver
#     @all     åpen utgang: alle offentlige mål (logget; private, loopback og
#              link-local er fortsatt stengt); bare sammen med host:PORT
#   En settfil har én eller flere poster per linje (#-kommentarer) og kan
#   inkludere @navn, men ikke @all eller @sti.
#
#   Ekstern proxy: -p 127.0.0.1:4321 sender trafikken gjennom en ekstern
#   forward-proxy (f.eks. Burp Suite), og allowlisten gjelder fortsatt:
#   harrbjorns proxy er den eksterne proxyens upstream, publisert på
#   127.0.0.1:3129 (SBX_UPSTREAM_PORT). I Burp: Settings > Network >
#   Connections > Upstream proxy servers: destination host *, proxy
#   127.0.0.1:3129. Nettet er fortsatt --internal: en relay videresender
#   kun til proxyen, modellporten og hostportene. Proxyen må lytte utover
#   loopback. Fail-closed: svarer ingenting på porten, eller sender ikke
#   proxyen videre til harrbjorns proxy (kanarisjekk), startes ikke
#   sesjonen. Burp-CA auto-installas dersom proxyen detekteres.
#   host.containers.internal peker på relayen.
#
#   Workdir (--work MODE): hva sandboxen får av workdir, på /work.
#     overlay  (default) workdir røres ikke under økten, heller ikke .git;
#              agenten kan committe i overlayen. Etterpå lages en patch
#              (.sandbox/overlay/<sesjon>.patch) du ser over og bruker med
#              `git apply`; filer hosten kjører (.envrc, Makefile,
#              package.json, IDE- og agent-config, kjørbare filer,
#              symlenker) flagges. Filer ignorert av .gitignore og nestede
#              repoer er ikke med i patchen.
#     ro       workdir read-only; agenten skriver resultater til /out
#              (.sandbox/out/<sesjon>/, vises etter økten).
#     none     workdir monteres ikke (/work er tom); /out som for ro.
#     rw       workdir skrivbar — hosten kjører senere det agenten legger
#              der (Makefile, scripts, .envrc). En eksisterende .git-
#              katalog øverst i workdir mountes read-only; en .git agenten
#              lager (også i underkataloger) eller en .git-fil er skrivbar,
#              og git på hosten kjører det som plantes der.
#     rw+git   som rw, men også .git er skrivbar: hooks og config agenten
#              planter, kjører når du bruker git på hosten.
#   Workdir kan ikke være /, $HOME (eller en forelder) eller harrbjorn-
#   repoet (eller over/inne i det, med .env) — heller ikke med ro/none,
#   for workdir er nøkkelen til øktene.
#
#   Økter: hver kjøring får en ny, tom HOME (seedet fra bildet) — tidligere
#   økter påvirker den ikke. --resume gjenbruker HOME-en til sist brukte økt
#   i samme workdir (som den var), --resume=ID en bestemt; --sessions
#   lister dem. Samtalen gjenopptas med agentens eget flagg, f.eks.
#   `harrbjorn code --resume claude -c` / `pi -c`. SBX_KEEP_SESSIONS
#   (default 10) økter beholdes per workdir. Med --work rw bærer workdir
#   (/work) også endringer mellom økter.
#
#   --ca-cert FILE (kan gjentas) / SBX_CA_CERTS=fil:fil (env/.env): ekstra
#   CA-sertifikater (PEM/DER) å stole på, f.eks. roten til en TLS-
#   inspiserende mellomboks. Gjelder bildebyggene (build-secret, aldri i et
#   lag) og sandboxen (samlet bunt: SSL_CERT_FILE, NODE_EXTRA_CA_CERTS,
#   REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE, GIT_SSL_CAINFO).
#
# Eksempler:
#   harrbjorn code                          # interaktiv bash i cwd (default)
#   harrbjorn code bash                     # samme, eksplisitt
#   harrbjorn code claude                   # interaktiv claude i cwd
#   harrbjorn code claude -p "Refaktoriser auth-modulen"
#   (containernens claude kjører med bypassPermissions som default — ingen
#    --dangerously-skip-permissions-flagg nødvendig)
#   harrbjorn code -w ~/proj claude         # annen workdir enn cwd
#   harrbjorn code pi                       # interaktiv pi i cwd (samme modellkonfig som claude)
#   harrbjorn code pi -p "Fix the failing tests"
#   harrbjorn code --net @dev --work rw claude  # pakkeregistre + GitHub, skrivbar workdir
#   harrbjorn code --net host:8080 claude   # + testinstans på hosten
#   harrbjorn code -w ../grepa --net @all --work rw  # åpen utgang
#   harrbjorn code -p 127.0.0.1:4321 claude -p "Test via Burp"  # ekstern proxy
#
# Isolasjonslag (rootless podman, ingen sudo; se README for hva de ikke dekker):
#   1. sandbox kjører kun på sesjonens internal-nett (ingen direkte utgang)
#   2. forward-proxy er eneste utgang; allowlist håndheves, audit-logg (også med -p)
#   3. container-hardening: read-only, cap-drop ALL, no-new-privileges, limits
#   4. microVM via krun (eget kernel — KVM; SBX_RUNTIME)
#   5. keep-id user-namespace, per-sesjon proxy + nett, automatisk opprydding

set -euo pipefail
sbx_usage() { sed -n '2,/^[^#]/{/^#/p}' "$0"; exit "${1:-0}"; }
export SBX_USECASE=code
export SBX_IMAGE=harrbjorn/code:latest
export SBX_CONTEXT=code
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sandbox.sh"
sbx_main "$@"
