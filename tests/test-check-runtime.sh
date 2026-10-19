#!/usr/bin/env bash
# tests/test-check-runtime.sh — enhetstester for sbx_check_runtime
# (lib/sandbox.sh): val av OCI-runtime (SBX_RUNTIME) for sesjonscontainerne.
#
# Dekker:
#  - R1 ugyldig SBX_RUNTIME-verdi → exit 1 med røykteksn
#  - R2–R4 manglande runtime (crun/runsc/krun, RESTRICTED PATH) → exit 1,
#    kvart sin røykteksn
#  - R5–R6 stub-runtime crun/runsc på PATH → RUNTIME_ARGS == --runtime …
#  - R7 stub krun + røkt /dev/kvm → --runtime krun (kun assertert dersom
#    verten har tilgjengeleg /dev/kvm, elles hoppast med notis)
#  - R8 krun + utilgjengeleg /dev/kvm (sed-kopi som rewritear stien) →
#    exit 1 (selvverifiserande sed)
#
# Mekanikk: sbx_check_runtime bruker exit 1 — alle forventede-feil-kall
# kjører i subshell, elles dør testskallet. Sourcing av den rale
# lib/sandbox.sh slår på set -euo pipefail i testskallet; feil-tilfelle er
# subshell- eller "||"-sikra, suksess-tilfelle kjører direkte slik at
# RUNTIME_ARGS settest i testskallet.
#
# Krevd: bash. Ingen podman, ingen nettverk.
# Kjør: bash tests/test-check-runtime.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Den rale lib/sandbox.sh (kjelde endring = testendring, ingen sed-kopi
# bortsett frå R8). Source slår på set -euo pipefail her.
source "$REPO/lib/sandbox.sh"

pass=0 fail=0
check_rc() { # label expected actual
  if [[ "$3" -eq "$2" ]]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — return $3, venta $2"
  fi
}
check_args() { # label expected
  local actual="${RUNTIME_ARGS[*]-}"
  if [[ "$actual" == "$2" ]]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — RUNTIME_ARGS='$actual', venta '$2'"
  fi
}
check_err() { # label err-text pattern
  if printf '%s\n' "$2" | grep -q "$3"; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — ingen treff på '$3' i stderr:"; printf '%s\n' "$2"; echo "----"
  fi
}

# Feil-tilfelle: kjører sbx_check_runtime i subshell (exit 1 dreier berre
# subskallet); settest RC og ERR (stderr).
rt_error() { # label SBX_RUNTIME PATH
  local rt="$2" path="$3"
  ERR="$( SBX_RUNTIME="$rt" PATH="$path" sbx_check_runtime 2>&1 )" && RC=0 || RC=$?
}

# Suksess-tilfelle: direkte kall i testskallet slik at RUNTIME_ARGS settest
# her; settest RC (0 ventast).
rt_ok() { # SBX_RUNTIME PATH
  local rt="$1" path="$2"
  RUNTIME_ARGS=()
  RC=0
  SBX_RUNTIME="$rt" PATH="$path" sbx_check_runtime || RC=$?
}

# Stub-runtime på PATH (deterministisk suksess uavhengig av host-install).
mkdir -p "$T/bin"
for r in crun runsc krun; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$r"
  chmod +x "$T/bin/$r"
done

# RESTRICTED PATH (tomt) for «runtime manglar»-tilfelle — command -v er
# builtin, så funksjonen fungerer med kva som helst PATH.
mkdir -p "$T/empty"

# ---------------------------------------------------------------- scenario R1
# Ugyldig SBX_RUNTIME-verdi (verdi som ikkje er krun/runsc/crun).
rt_error R1 bogus "$PATH"
check_rc  "R1: retur 1 (ugyldig SBX_RUNTIME)" 1 "$RC"
check_err "R1: røykteksn" "$ERR" "error: invalid SBX_RUNTIME 'bogus' (must be krun, runsc or crun)\."

# ---------------------------------------------------------------- scenario R2
# SBX_RUNTIME=crun, men crun finnast ikkje på PATH.
rt_error R2 crun "$T/empty"
check_rc  "R2: retur 1 (crun ikkje installert)" 1 "$RC"
check_err "R2: røykteksn" "$ERR" "error: SBX_RUNTIME=crun but crun is not installed\."

# ---------------------------------------------------------------- scenario R3
# SBX_RUNTIME=runsc, men runsc finnast ikkje på PATH.
rt_error R3 runsc "$T/empty"
check_rc  "R3: retur 1 (runsc ikkje installert)" 1 "$RC"
check_err "R3: røykteksn" "$ERR" "error: SBX_RUNTIME=runsc but the runsc (gVisor) runtime is not installed\."

# ---------------------------------------------------------------- scenario R4
# SBX_RUNTIME=krun, men krun finnast ikkje på PATH.
rt_error R4 krun "$T/empty"
check_rc  "R4: retur 1 (krun ikkje installert)" 1 "$RC"
check_err "R4: røykteksn" "$ERR" "error: SBX_RUNTIME=krun but the krun OCI runtime is not installed (Fedora: dnf install crun-krun)\."

# ---------------------------------------------------------------- scenario R5
# Stub crun på PATH → RUNTIME_ARGS for podman-run-linjene.
rt_ok crun "$T/bin:$PATH"
check_rc   "R5: retur 0 (stub crun)"            0 "$RC"
check_args "R5: RUNTIME_ARGS == --runtime crun" "--runtime crun"

# ---------------------------------------------------------------- scenario R6
# Stub runsc på PATH.
rt_ok runsc "$T/bin:$PATH"
check_rc   "R6: retur 0 (stub runsc)"              0 "$RC"
check_args "R6: RUNTIME_ARGS == --runtime runsc" "--runtime runsc"

# ---------------------------------------------------------------- scenario R7
# krun krev i tillegg tilgjengeleg /dev/kvm — kun assertert dersom verten
# har det (host-uavhengig), elles hoppast med notis.
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  rt_ok krun "$T/bin:$PATH"
  check_rc   "R7: retur 0 (krun + røkt /dev/kvm)"     0 "$RC"
  check_args "R7: RUNTIME_ARGS == --runtime krun" "--runtime krun"
else
  echo "SKIP  R7: /dev/kvm utilgjengeleg på verten — krun-suksess hoppast"
fi

# ---------------------------------------------------------------- scenario R8
# krun + utilgjengeleg /dev/kvm: sed-kopi som rewritear /dev/kvm → ein
# stie som ikkje finst (selvverifiserande sed). Sed-kopien rewritear òg
# røykteksna — markøren i stderr beiner difor at rewritea rakk sjekken.
sed "s|/dev/kvm|$T/kvm-missing|g" "$REPO/lib/sandbox.sh" > "$T/sandbox-kvm.sh"
if grep -q "$T/kvm-missing" "$T/sandbox-kvm.sh"; then pass=$((pass+1)); echo "PASS  R8: sed: stien rewritea til $T/kvm-missing"
else fail=$((fail+1)); echo "FAIL  R8: sed: $T/kvm-missing finnast ikkje i sed-kopien"; fi
if grep -q '/dev/kvm' "$T/sandbox-kvm.sh"; then fail=$((fail+1)); echo "FAIL  R8: sed: /dev/kvm overlever i sed-kopien"
else pass=$((pass+1)); echo "PASS  R8: sed: ingen /dev/kvm att"
fi

# Subshell som source sed-kopien (der set -euo pipefail slår att på):
# stub krun på PATH, men sjekken ser den ikkje-eksisterande kvm-stien.
R8_ERR="$( source "$T/sandbox-kvm.sh" && SBX_RUNTIME=krun PATH="$T/bin:$PATH" sbx_check_runtime 2>&1 )" && R8_RC=0 || R8_RC=$?
check_rc  "R8: retur 1 (/dev/kvm utilgjengeleg)" 1 "$R8_RC"
check_err "R8: røykteksn med rewritea stie" "$R8_ERR" "$T/kvm-missing is not accessible"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
