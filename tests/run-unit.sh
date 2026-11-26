#!/usr/bin/env bash
# tests/run-unit.sh — kjør alle enhetstester (tests/test-*.sh unntatt
# *-integration.sh). Ingen podman, ingen nettverk.
# Kjør: bash tests/run-unit.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
failed=()
for t in tests/test-*.sh; do
  [[ "$t" == *-integration.sh ]] && continue
  echo "=== $t"
  bash "$t" || failed+=("$t")
done
echo
if (( ${#failed[@]} )); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all unit tests passed"
