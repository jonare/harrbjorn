#!/usr/bin/env bash
# tests/test-ca.sh — ekstra CA-sertifikater (--ca-cert / SBX_CA_CERTS) for
# nett med TLS-inspiserende mellomboks.
#
#  - sbx_ca_pem: leser PEM (én eller flere i en bunt, med tekst rundt) og
#    DER, skriver kun sertifikatblokkene; feiler på manglende fil,
#    katalog og fil uten sertifikat
#  - Dockerfilene: hvert RUN-steg som henter over HTTPS (npm, pi install,
#    wget, curl) monterer build-secreten sbx_ca og bruker den
# Sertifikatene genereres i en tempkatalog. Kjør: bash tests/test-ca.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$T_REPO/lib/sandbox.sh"
set +e

mkca() { # name -> $T_TMP/name.pem (selvsignert test-CA)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$T_TMP/$1.key" -out "$T_TMP/$1.pem" -days 2 -subj "/CN=$1" \
    -addext basicConstraints=critical,CA:TRUE 2>/dev/null
}
mkca ca-a; mkca ca-b
ncert() { grep -c -- '-----BEGIN CERTIFICATE-----' <<< "$1"; }
fp() { openssl x509 -noout -fingerprint -sha256 <<< "$1" 2>/dev/null; }

out="$(sbx_ca_pem "$T_TMP/ca-a.pem")"
assert_eq "PEM: ett sertifikat"              1 "$(ncert "$out")"
assert_eq "PEM: samme sertifikat"            "$(fp "$(cat "$T_TMP/ca-a.pem")")" "$(fp "$out")"

cat "$T_TMP/ca-a.pem" "$T_TMP/ca-b.pem" > "$T_TMP/bundle.pem"
assert_eq "bunt: begge sertifikatene"        2 "$(ncert "$(sbx_ca_pem "$T_TMP/bundle.pem")")"
assert_eq "to filer: begge"                  2 "$(ncert "$(sbx_ca_pem "$T_TMP/ca-a.pem" "$T_TMP/ca-b.pem")")"

openssl x509 -in "$T_TMP/ca-a.pem" -text > "$T_TMP/text.pem"
out="$(sbx_ca_pem "$T_TMP/text.pem")"
assert_eq       "tekst rundt: ett sertifikat" 1 "$(ncert "$out")"
assert_no_match "tekst rundt: kun blokker"    'Issuer|Subject' "$out"

openssl x509 -in "$T_TMP/ca-a.pem" -outform DER -out "$T_TMP/ca-a.der"
out="$(sbx_ca_pem "$T_TMP/ca-a.der")"
assert_eq "DER: konvertert til PEM"          "$(fp "$(cat "$T_TMP/ca-a.pem")")" "$(fp "$out")"

echo garbage > "$T_TMP/junk.pem"
assert_fails "fil uten sertifikat feiler"    sbx_ca_pem "$T_TMP/junk.pem"
assert_match "melding: ingen sertifikat"     'no certificate' "$T_ERR"
assert_fails "manglende fil feiler"          sbx_ca_pem "$T_TMP/nope.pem"
assert_match "melding: ikke lesbar"          'not readable' "$T_ERR"
assert_fails "katalog feiler"                sbx_ca_pem "$T_TMP"
assert_fails "én dårlig av to feiler"        sbx_ca_pem "$T_TMP/ca-a.pem" "$T_TMP/junk.pem"

# ---------------------------------------------------------- Dockerfilene
# RUN-instruksjoner (med fortsettelseslinjer) som henter over HTTPS.
runs() { awk '/^RUN /{r=$0; while (r ~ /\\$/ && (getline l) > 0) r = r "\n" l; print r; printf "\0"}' "$1"; }
for df in code/Dockerfile pentest/Dockerfile proxy/Dockerfile relay/Dockerfile; do
  while IFS= read -r -d '' r; do
    [[ "$r" =~ (npm\ install|pi\ install|wget\ |curl\ ) ]] || continue
    what="$(head -1 <<< "$r" | cut -c1-50)"
    assert_match "$df: HTTPS-steg monterer sbx_ca ($what)" '^RUN --mount=type=secret,id=sbx_ca' "$r"
    assert_match "$df: HTTPS-steg bruker sbx_ca ($what)"   '/run/secrets/sbx_ca' "$r"
  done < <(runs "$T_REPO/$df")
done

t_summary
