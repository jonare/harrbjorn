#!/usr/bin/env bash
# tests/test-image-pins.sh — forsyningskjeden i bildene.
#
#  - alle pi-extensions i code/Dockerfile (PI_EXTENSIONS) har eksakt
#    versjon (kilde@X.Y.Z): de installeres som root med lifecycle-scripts
#    og kjører med agentens rettigheter
#  - alle eksterne basebilder (FROM) er pinnet med digest; unntak: scratch
#    og egne harrbjorn/*-bilder
# Kjør: bash tests/test-image-pins.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ext="$(sed -n 's/^ARG PI_EXTENSIONS=//p' "$T_REPO/code/Dockerfile")"
assert_ne "PI_EXTENSIONS er satt" "" "$ext"
for src in $ext; do
  assert_match "pi-extension pinnet: $src" '@[0-9]+\.[0-9]+\.[0-9]+$' "$src"
done

for df in "$T_REPO"/*/Dockerfile; do
  while read -r _ img _; do
    case "$img" in scratch|harrbjorn/*) continue ;; esac
    assert_match "${df#"$T_REPO"/}: $img pinnet med digest" '@sha256:[0-9a-f]{64}$' "$img"
  done < <(grep -E '^FROM ' "$df")
done

t_summary
