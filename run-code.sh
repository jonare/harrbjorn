#!/usr/bin/env bash
# run-code.sh — kodeagent-sandbox: dev-miljø + agent-CLIer (claude, pi).
#
# Usage:
#   harrbjorn code [-w <workdir>] [-a host[:port]]... [-H port]...
#                  [-f extra-allowlist] [-p host:port] [--rebuild] [--] [<cmd> [args...]]
#   (equivalent to ./run-code.sh; <workdir> defaults to the current
#   directory, and `--` is optional — the first non-flag argument
#   starts the command. With no command, an interactive bash opens in
#   the workdir)
#
#   Model config: hostens Claude-config (SBX_CLAUDE_CONFIG, default
#   ~/claude.sh) injiseres som env-vars; loopback -> host.containers.internal.
#
#   Nettverk: åpen utgang som standard (SBX_OPEN_NETWORK=1) — proxyen logger
#   all trafikk, men håndhever ikke allowlisten. SBX_OPEN_NETWORK=0 (env/.env)
#   gir klassisk allowlist-adgang (allowlist.code.default + -a/-f).
#
#   Ekstern proxy: -p 127.0.0.1:4321 bruker en ekstern forward-proxy
#   (f.eks. Burp Suite) som utgang — harrbjorns proxy startes ikke, og
#   allowlisten gjelder ikke (firewall-logikken er proxyens jobb).
#   Fail-closed: svarer ingenting på porten, avsluttes sesjonen (ingen
#   fallback). Burp-CA auto-installas dersom proxyen detekteres.
#   host.containers.internal er i NO_PROXY: hosttrafikk (især
#   modellserveren) går rett til hosten, ikke gjennom proxyen.
#
#   Host-tjenester (testinstanser på hosten): -H 8080 -H 9443
#   tillater eksplisitt, port for port, nåing av hosten via
#   http://host.containers.internal:<port>. Hosten er ellers alltid nektet
#   (link-local, både i open- og allowlist-modus); flagget er den eneste
#   veien, og ikke en allowlistpost.
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
#   harrbjorn code -p 127.0.0.1:4321 claude -p "Test via Burp"  # ekstern proxy
#
# Isolasjonslag (rootless podman, ingen sudo; hvert holder selv hvis ett feiler):
#   1. sandbox kjører kun på sesjonens internal-nett (ingen direkte utgang)
#   2. forward-proxy er eneste utgang; åpen som standard, audit-logg alltid
#   3. container-hardening: read-only, cap-drop ALL, no-new-privileges, limits
#   4. microVM via krun (eget kernel — KVM; SBX_RUNTIME)
#   5. keep-id user-namespace, per-sesjon proxy + nett, automatisk opprydding

set -euo pipefail
sbx_usage() { sed -n '2,50p' "$0"; exit "${1:-0}"; }
export SBX_USECASE=code
export SBX_IMAGE=harrbjorn/code:latest
export SBX_CONTEXT=code
export SBX_ALLOWLIST_DEFAULT=allowlist.code.default
# Dev-usecase: åpen utgang som standard (proxy-logging beholdes).
# .env/env med SBX_OPEN_NETWORK=0 vinner, og gir allowlist-adgang.
export SBX_OPEN_NETWORK="${SBX_OPEN_NETWORK:-1}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sandbox.sh"
sbx_main "$@"
