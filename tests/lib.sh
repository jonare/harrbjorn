#!/usr/bin/env bash
# tests/lib.sh — felles hjelpere for enhetstestene (bash, ingen rammeverk).
#
# Bruk i en test:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   assert_eq "label" "forventet" "faktisk"
#   ...
#   t_summary          # skriver «N passed, M failed», exit 1 ved feil
#
# T_TMP er en per-test tempkatalog som fjernes ved exit.

# shellcheck disable=SC2034  # used by the sourcing tests
T_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T_TMP="$(mktemp -d)"
trap 'rm -rf "$T_TMP"' EXIT
t_pass=0 t_fail=0

ok()  { t_pass=$((t_pass+1)); echo "PASS  $1"; }
bad() { t_fail=$((t_fail+1)); echo "FAIL  $1 — $2"; }

assert_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "forventet '$2', fikk '$3'"; fi
}
assert_ne() { # label a b
  if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1" "skulle vært ulike, begge '$2'"; fi
}
assert_match() { # label regex actual
  if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1" "'$3' matcher ikke /$2/"; fi
}
assert_no_match() { # label regex actual
  if [[ "$3" =~ $2 ]]; then bad "$1" "'$3' matcher /$2/"; else ok "$1"; fi
}
# assert_ok / assert_fails: kjør kommandoen i en subshell (sandbox.sh-
# funksjoner kaller exit ved feil), fang stderr i T_ERR.
assert_ok() { # label cmd...
  local label="$1"; shift
  if T_ERR="$( ( "$@" ) 2>&1 >/dev/null )"; then ok "$label"
  else bad "$label" "feilet: ${T_ERR:-<ingen melding>}"; fi
}
assert_fails() { # label cmd...
  local label="$1"; shift
  if T_ERR="$( ( "$@" ) 2>&1 >/dev/null )"; then bad "$label" "skulle feilet, men lyktes"
  else ok "$label"; fi
}

t_summary() {
  echo
  echo "$t_pass passed, $t_fail failed"
  [[ "$t_fail" -eq 0 ]]
}
