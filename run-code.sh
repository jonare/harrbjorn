#!/usr/bin/env bash
# run-code.sh — kodeagent-sandbox: dev-miljø + Claude Code CLI.
#
# Usage:
#   ./run-code.sh -w <workdir> [-a host[:port]]... [-f extra-allowlist] \
#                 [--no-host-isolation] [--rebuild] -- <cmd> [args...]
#
#   Model config: hostens Claude-config (SBX_CLAUDE_CONFIG, default
#   ~/claude.sh) injiseres som env-vars; loopback -> 172.28.0.1 (host-gw).
#
# Eksempler:
#   ./run-code.sh -w ~/proj -- claude --dangerously-skip-permissions
#   ./run-code.sh -w ~/proj -- claude -p "Refaktoriser auth-modulen" --dangerously-skip-permissions
#   ./run-code.sh -w ~/proj -- bash
#
# Isolasjonslag (hvert holder selv hvis ett feiler):
#   1. sandbox kjører kun på --internal-nettverket (ingen direkte utgang)
#   2. forward-proxy er eneste utgang; håndhever allowlisten
#   3. host-iptables (sudo) blokkerer gateway-IP-holet i intern-bridgen
#   4. container-hardening: read-only, cap-drop ALL, no-new-privileges, limits

set -euo pipefail
sbx_usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }
export SBX_USECASE=code
export SBX_IMAGE=harrbjorn/code:latest
export SBX_CONTEXT=code
export SBX_ALLOWLIST_DEFAULT=allowlist.code.default
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sandbox.sh"
sbx_main "$@"
