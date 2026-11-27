#!/usr/bin/env bash
# tests/main-harness.sh — hermetic harness for unit tests of sbx_main.
#
# Source after tests/lib.sh. Builds, under $T_TMP:
#   repo/   copy of lib/*.sh + net/ sets (SCRIPT_DIR; .sandbox/ lands here)
#   home/   fake $HOME;  home/proj = default workdir
#   bin/    fake crun + resolvectl first in PATH
# and provides run_main ARGS... which runs sbx_main (code usecase, crun,
# fake podman; the caller's env passes through) in a subshell, logging
# podman calls to $PLOG. Exit status in $MAIN_RC, stderr in $MAIN_ERR,
# stdout in $MAIN_OUT. Name lookups (_sbx_resolve) never hit DNS: they
# return $FAKE_RESOLVE (space-separated addresses), empty by default.
#
# Helpers: plog_has PATTERN (grep -F on the podman log), sandbox_run (the
# final `podman run` line of the sandbox container).

HR="$T_TMP/repo"; HH="$T_TMP/home"; HB="$T_TMP/bin"; PLOG="$T_TMP/podman.log"
mkdir -p "$HR/lib" "$HH/proj" "$HB"
cp "$T_REPO"/lib/*.sh "$HR/lib/"
cp -r "$T_REPO/net" "$HR/"
cp "$T_REPO/tests/fake-podman" "$HB/podman"
printf '#!/bin/sh\nexit 0\n' > "$HB/crun"
printf '#!/bin/sh\necho %s\n' "'[{\"currentServer\":{\"addressString\":\"192.0.2.53\"},\"servers\":[]}]'" > "$HB/resolvectl"
chmod +x "$HB/podman" "$HB/crun" "$HB/resolvectl"

# shellcheck disable=SC2034  # MAIN_ERR/MAIN_RC/MAIN_OUT are read by the sourcing tests
run_main() {
  : > "$PLOG"
  MAIN_ERR="$(
    cd "$HH/proj" &&
    HOME="$HH" PATH="$HB:$PATH" PODMAN="$HB/podman" FAKE_PODMAN_LOG="$PLOG" \
    SBX_RUNTIME=crun SBX_USECASE=code SBX_IMAGE=harrbjorn/code:latest \
    SBX_CONTEXT=code \
    bash -c '
      source "$1/lib/sandbox.sh"
      sbx_usage() { exit "${1:-0}"; }
      sbx_tcp_probe() { return "${FAKE_TCP_PROBE_RC:-0}"; }
      sbx_http_probe() { return 0; }
      _sbx_resolve() { [[ -z "${FAKE_RESOLVE:-}" ]] || printf "%s\n" $FAKE_RESOLVE; }
      sbx_burp_chained() { echo "burp-chained $*" >> "$FAKE_PODMAN_LOG"; return "${FAKE_BURP_CHAINED_RC:-0}"; }
      shift; sbx_main "$@"
    ' _ "$HR" "$@" 2>&1 >"$T_TMP/main.out"
  )"
  MAIN_RC=$?
  MAIN_OUT="$(cat "$T_TMP/main.out")"
}
plog_has() { grep -qF -- "$1" "$PLOG"; }
sandbox_run() { grep -E '^run --rm -i --name sbx-code-[0-9]+-[0-9]+ ' "$PLOG" | tail -1; }
