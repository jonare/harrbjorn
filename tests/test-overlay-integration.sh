#!/usr/bin/env bash
# tests/test-overlay-integration.sh — integrasjonstest for --overlay:
# ekte podman, produksjonens mount-streng og sbx_overlay_finish.
#
# En «økt» (container i valgt runtime) skriver i /work via overlayen; så
# bygger sbx_overlay_finish patchen i hjelpecontaineren. Dekker:
#  1. workdir på hosten (også .git) er urørt etter økten
#  2. patchen inneholder endringene, ikke .git; sensitive filer flagges
#  3. upperdir er ryddet (whiteouts eies av en subuid)
#  4. git apply av patchen på hosten gir agentens resultat
#
# Bilde: SBX_IMAGE (bash + git), default harrbjorn/code:latest; finnes det
# ikke, bygges et minimalt debian+git-testbilde. Runtime som i produksjon
# (SBX_RUNTIME, default krun; SBX_RUNTIME=crun uten KVM).
# Kjør: bash tests/test-overlay-integration.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PODMAN="${PODMAN:-podman}"
die() { echo "ABORT $1" >&2; exit 1; }
command -v "$PODMAN" >/dev/null || die "podman finnes ikke"

source "$T_REPO/lib/sandbox.sh"
set +e
RUNTIME_ARGS=()
SBX_RUNTIME="${SBX_RUNTIME:-krun}"
sbx_check_runtime
echo ">> runtime: $SBX_RUNTIME"

SBX_IMAGE="${SBX_IMAGE:-harrbjorn/code:latest}"
if ! $PODMAN image inspect "$SBX_IMAGE" >/dev/null 2>&1; then
  SBX_IMAGE=harrbjorn/sbx-test-git:latest
  if ! $PODMAN image inspect "$SBX_IMAGE" >/dev/null 2>&1; then
    printf '%s\n' \
      'FROM docker.io/library/debian:bookworm-slim@sha256:311f7a192fd9a92b165a86b32fa3aae9005b11849bfb1db2d4fd784559ee464f' \
      'RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*' \
      > "$T_TMP/Dockerfile"
    $PODMAN build -q -t "$SBX_IMAGE" "$T_TMP" >/dev/null || die "kunne ikke bygge $SBX_IMAGE"
  fi
fi
echo ">> bilde: $SBX_IMAGE"

# ---- workdir og overlay som i sbx_main ---------------------------------------
WD="$T_TMP/wd"; OVL="$T_TMP/state/overlay/s1"; PATCH="$T_TMP/state/overlay/s1.patch"
mkdir -p "$WD/.git" "$WD/src" "$WD/gone" "$OVL/up" "$OVL/wk" "$OVL/out"
echo ref  > "$WD/.git/HEAD"
echo old  > "$WD/src/mod.txt"
echo bye  > "$WD/gone/x.txt"
before="$(cd "$WD" && find . -type f -exec sha256sum {} + | sort)"
trap '$PODMAN unshare rm -rf "$T_TMP"' EXIT

$PODMAN run --rm "${RUNTIME_ARGS[@]}" --network none \
  --userns=keep-id:uid=1000,gid=1000 --user 1000:1000 \
  -v "$WD:/work:O,upperdir=$OVL/up,workdir=$OVL/wk" -w /work \
  --entrypoint sh "$SBX_IMAGE" -c '
    echo new > src/mod.txt; echo hi > src/added.txt; rm -r gone
    echo "export X=1" > .envrc; echo planted > .git/HEAD' \
  || die "økten feilet"

# 1. workdir urørt
assert_eq "1: workdir urørt (også .git)" "$before" "$(cd "$WD" && find . -type f -exec sha256sum {} + | sort)"

# 2. patch + rapport
rep="$(sbx_overlay_finish "$OVL" "$WD" "$PATCH" 2>&1)"; rc=$?
echo "$rep"
assert_eq    "2: finish ok"                0 "$rc"
files="$(git apply --numstat "$PATCH" 2>/dev/null | cut -f3 | sort | tr '\n' ' ')"
assert_eq    "2: endrede filer"            ".envrc gone/x.txt src/added.txt src/mod.txt " "$files"
assert_match "2: .envrc flagget"           '! \.envrc' "$rep"

# 3. upperdir ryddet
if [[ -e "$OVL" ]]; then bad "3: upperdir ryddet" "finnes"; else ok "3: upperdir ryddet"; fi

# 4. apply på hosten
assert_ok    "4: git apply"                git -C "$WD" apply "$PATCH"
assert_eq    "4: endret fil"               new "$(cat "$WD/src/mod.txt")"
assert_eq    "4: ny fil"                   hi  "$(cat "$WD/src/added.txt")"
if [[ -e "$WD/gone" ]]; then bad "4: slettet katalog borte" "finnes"; else ok "4: slettet katalog borte"; fi
assert_eq    "4: .git fortsatt urørt"      ref "$(cat "$WD/.git/HEAD")"

t_summary
