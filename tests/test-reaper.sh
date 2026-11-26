#!/usr/bin/env bash
# tests/test-reaper.sh — opprydding av foreldreløse sesjonsressurser.
#
#  - kun harrbjorns egne navn røres: sbx-<usecase>-<ts>-<pid>[-proxy] og
#    sbx-<usecase>-<ts>-<pid>-int — aldri andre containere/nett med
#    «sbx-» i navnet
#  - kjørende containere røres ikke
#  - en død proxys audit-logg lagres til .sandbox/logs/<sesjon>.jsonl før
#    containeren fjernes (ellers tapes loggen for krasjede sesjoner); en
#    logg som allerede finnes overskrives ikke
# Kjør: bash tests/test-reaper.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

PODMAN="$T_REPO/tests/fake-podman"
export FAKE_PODMAN_LOG="$T_TMP/podman.log"
STATE_DIR="$T_TMP/state"; mkdir -p "$STATE_DIR/logs"
echo "existing" > "$STATE_DIR/logs/code-5-6.jsonl"

reap() { : > "$FAKE_PODMAN_LOG"; sbx_reap_orphans >/dev/null 2>&1; }
removed() { grep -qxF "rm -f $1" "$FAKE_PODMAN_LOG"; }

export FAKE_PODMAN_PS="sbx-code-1-2-proxy sbx-pentest-3-4 my-sbx-db sbx-code-5-6-proxy sbx-tool"
export FAKE_PODMAN_NETS="sbx-code-1-2-int my-sbx-net-int sbx-int podman"
reap

if removed sbx-code-1-2-proxy; then ok "død proxy fjernes"; else bad "død proxy fjernes" "$(cat "$FAKE_PODMAN_LOG")"; fi
if removed sbx-pentest-3-4;   then ok "død sandbox fjernes"; else bad "død sandbox fjernes" "ikke fjernet"; fi
if removed my-sbx-db;         then bad "fremmed container røres ikke" "my-sbx-db fjernet"; else ok "fremmed container røres ikke"; fi
if removed sbx-tool;          then bad "sbx-tool røres ikke" "fjernet"; else ok "sbx-tool røres ikke"; fi
if grep -qxF "network rm sbx-code-1-2-int" "$FAKE_PODMAN_LOG"; then ok "eget nett fjernes"; else bad "eget nett fjernes" "ikke fjernet"; fi
if grep -qE "network rm (my-sbx-net-int|sbx-int|podman)$" "$FAKE_PODMAN_LOG"; then bad "fremmede nett røres ikke" "$(grep 'network rm' "$FAKE_PODMAN_LOG")"; else ok "fremmede nett røres ikke"; fi

assert_eq "proxyens logg lagres før rm" "log-of sbx-code-1-2-proxy" "$(cat "$STATE_DIR/logs/code-1-2.jsonl" 2>/dev/null)"
logs_line="$(grep -n '^logs sbx-code-1-2-proxy$' "$FAKE_PODMAN_LOG" | cut -d: -f1)"
rm_line="$(grep -n '^rm -f sbx-code-1-2-proxy$' "$FAKE_PODMAN_LOG" | cut -d: -f1)"
if [[ -n "$logs_line" && -n "$rm_line" && "$logs_line" -lt "$rm_line" ]]; then ok "logs før rm"; else bad "logs før rm" "logs=$logs_line rm=$rm_line"; fi
assert_eq "eksisterende logg overskrives ikke" "existing" "$(cat "$STATE_DIR/logs/code-5-6.jsonl")"
if [[ -e "$STATE_DIR/logs/pentest-3-4.jsonl" ]]; then bad "ingen logg for sandbox-container" "laget"; else ok "ingen logg for sandbox-container"; fi

FAKE_PODMAN_RUNNING=true FAKE_PODMAN_PS="sbx-code-7-8-proxy" reap
if removed sbx-code-7-8-proxy; then bad "kjørende container røres ikke" "fjernet"; else ok "kjørende container røres ikke"; fi

t_summary
