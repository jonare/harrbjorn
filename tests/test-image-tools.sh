#!/usr/bin/env bash
# tests/test-image-tools.sh — verktøy agentene forventer i code-bildet.
#
# pi bruker rg og fd fra PATH (fd også som Debians fdfind) og laster dem
# ellers ned fra GitHub releases ved første bruk. I bildet slipper økten
# da å åpne GitHub for det (uten --net er bare modellen åpen).
# Kjør: bash tests/test-image-tools.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

apt="$(sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt\/lists/p' "$T_REPO/code/Dockerfile")"
for pkg in ripgrep fd-find; do
  assert_match "code/Dockerfile installerer $pkg" "(^|[[:space:]])$pkg([[:space:]]|\\\\|$)" "$apt"
done

t_summary
