#!/usr/bin/env bash
# tests/test-sbx-init.sh — enhetstester for code/sbx-init.sh (container-init):
# Claude/pi-seeding i agent-HOME (scenario P1–P8) og Burp-CA-installasjon
# mot SBX_EXTERNAL_PROXY (-p) (scenario B1–B6).
#
#
# Dekker:
#  - P1 fersk HOME: .claude.json seedast (onboarding, API-nøkkel, /work-tillit), mode 0600
#  - P2 merge: pre-eksisterande .claude.json/.claude/settings.json — eigne
#    nøklar bevarte, sandbox-nøkler lagt til
#  - P3 pi: models.json providers.harrbjorn frå env; apiKey er litteralt
#    ${ANTHROPIC_API_KEY} (aldri nøkkelen si verdi); settings.json
#    defaultProvider/defaultModel
#  - P4 pi merge: harrbjorn re-avleid frå env, andre providerar bevart
#  - P5 pi-advarsel: base_url utan model → advarsel, ingen models.json
#  - P6 extension: bakea store seedast til $HOME/.pi/agent/npm (berre
#    katalogar, avhengigheitene mergea, packages, lock-fil)
#  - P7 extension-merge: agent sin eigen package.json-spec vinn (setdefault),
#    agent sine eigne pakke bevarte
#  - P8 exec: sh sbx-init-test.sh env kjører env
#  - B1 install: SBX_EXTERNAL_PROXY → Burp-CA frå /cert (DER); bundle
#    $HOME/.sbx-ca-bundle.pem 0600 = systembundle + proxy-CA;
#    SSL_CERT_FILE/REQUESTS_CA_BUNDLE/NODE_EXTRA_CA_CERTS = bundle-sti
#  - B2 trailing slash: URL blir framleis .../cert (ikkje /cert/)
#  - B3 ingen env: ingen install, ingen bundle
#  - B4 404: serveren gjev ikkje /cert → stille skip
#  - B5 skada: /cert er ikkje eit sertifikat → stille skip
#  - B6 PEM-fallback: /cert serverast som PEM (ikkje DER) → install suksess
#
# Harnes: kjører `sh $T/sbx-init-test.sh` direkte på verten med HOME=$T/home.
# Berre dei to host-spesifikke stiane i code/sbx-init.sh sed-rewriteast
# (/etc/ssl/certs/ca-certificates.crt og /usr/local/share/pi).
# Burp-CA-delen (B1–B6) nyttar i tillegg ein loopback HTTP-server (python3)
# på 127.0.0.1 som serverer /cert, og openssl for test-CA-en.
#
# Krevd: bash, python3, curl, openssl. Ingen podman, ingen ekstern nettverk
# (berre 127.0.0.1-lyttar).
# Kjør: bash tests/test-sbx-init.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { # label file pattern (grep -q)
  if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — mangler '$3' i $(basename "$2")"; echo "--- $(basename "$2"):"; cat "$2"; echo "----"
  fi
}
check_absent() { # label file pattern
  if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 — '$3' finnes i $(basename "$2")"; cat "$2"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}
jcheck() { # label file python-uttrykk (d = JSON-dokket, evals)
  local label="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then pass=$((pass+1)); echo "PASS  $label"
  else fail=$((fail+1)); echo "FAIL  $label — JSON-assert '$expr' i $(basename "$file")"; cat "$file" 2>/dev/null; echo "----"
  fi
}
mcheck() { # label path mode (oktal)
  local label="$1" path="$2" mode="$3" m
  m="$(stat -c %a "$path" 2>/dev/null || echo missing)"
  if [ "$m" = "$mode" ]; then pass=$((pass+1)); echo "PASS  $label"
  else fail=$((fail+1)); echo "FAIL  $label — mode '$m', venta '$mode'"
  fi
}
fcheck() { # label path
  if [ -e "$2" ]; then pass=$((pass+1)); echo "PASS  $1"
  else fail=$((fail+1)); echo "FAIL  $1 — '$2' finst ikkje"
  fi
}
fcheck_absent() { # label path
  if [ -e "$2" ]; then fail=$((fail+1)); echo "FAIL  $1 — '$2' finst, skulle ikkje gjere det"
  else pass=$((pass+1)); echo "PASS  $1"
  fi
}

# ------------------------------------------------------------------- harnes
# Sed-kopi av container-initet: berre dei to host-spesifikke stiast
# rewriteast, slik at Burp-CA-bundlea og den bakea pi-extension-storen
# peiker inn i $T. Self-verifiserande: rewriteastene må vere synlege.
sed -e "s|/etc/ssl/certs/ca-certificates.crt|$T/ca-bundle.crt|g" \
    -e "s|/usr/local/share/pi|$T/bake|g" \
    "$REPO/code/sbx-init.sh" > "$T/sbx-init-test.sh"
check "harnes: ca-bundle-sti rewritea"    "$T/sbx-init-test.sh" "$T/ca-bundle.crt"
check_absent "harnes: ingen system-bundle-sti" "$T/sbx-init-test.sh" "/etc/ssl/certs/ca-certificates.crt"
check "harnes: pi-bake-sti rewritea"      "$T/sbx-init-test.sh" "$T/bake"
check_absent "harnes: ingen bakea pi-sti"  "$T/sbx-init-test.sh" "/usr/local/share/pi"
# Markør for system-bundlea (Burp-delen brukar same fil i nære framtid).
printf 'MARKER-SYSTEM-BUNDLE\n' > "$T/ca-bundle.crt"

run_init() { # home [ekstra env-tildelingar] — kjører initet med env, fanget utdata
  local home="$1"; shift
  # Vertsmiljøet (f.eks. Claude Code) kan sjølve setje ANTHROPIC_*-var:
  # alle relevante var settest eksplisitt tomme her og overriddes per
  # scenario. Kommandoen er alltid 'env', slik at den fjesa exec-utgangen
  # verifiseres i kvart scenario (P8) og inga scenario hangar i exec bash.
  env HOME="$home" \
      ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" ANTHROPIC_MODEL="" \
      CLAUDE_CODE_MAX_CONTEXT_TOKENS="" CLAUDE_CODE_MAX_OUTPUT_TOKENS="" \
      SBX_EXTERNAL_PROXY="" "$@" \
      sh "$T/sbx-init-test.sh" env > "$T/out" 2> "$T/err"
}

# ---------------------------------------------------------------- scenario P1
# Fersk HOME: .claude.json seedast med onboarding, API-nøkkel og /work-tillit.
P1H="$T/home-p1"; mkdir -p "$P1H"
run_init "$P1H" ANTHROPIC_API_KEY=test-key-123
CJ="$P1H/.claude.json"
fcheck  "P1: .claude.json lagd"          "$CJ"
jcheck  "P1: hasCompletedOnboarding"      "$CJ" 'd["hasCompletedOnboarding"] is True'
jcheck  "P1: API-nøkkel godkjent"        "$CJ" '"test-key-123" in d["customApiKeyResponses"]["approved"]'
jcheck  "P1: /work-tillit"                "$CJ" 'd["projects"]["/work"]["hasTrustDialogAccepted"] is True'
mcheck  "P1: .claude.json mode 0600"      "$CJ" 600
jcheck  "P1: .claude/settings.json"       "$P1H/.claude/settings.json" \
        'd["skipDangerousModePermissionPrompt"] is True and d["permissions"]["defaultMode"] == "bypassPermissions"'

# ---------------------------------------------------------------- scenario P2
# Merge: pre-eksisterande .claude.json + .claude/settings.json med eigne
# noklar — bevarte, sandbox-nyklar lagt til.
P2H="$T/home-p2"; mkdir -p "$P2H/.claude"
cat > "$P2H/.claude.json" <<'EOF'
{"hasCompletedOnboarding": false, "theme": "light",
 "customApiKeyResponses": {"approved": ["old-key"]},
 "projects": {"/work": {"hasTrustDialogAccepted": false}}}
EOF
cat > "$P2H/.claude/settings.json" <<'EOF'
{"theme": "dark", "custom": {"x": 1}}
EOF
run_init "$P2H" ANTHROPIC_API_KEY=key-p2
CJ="$P2H/.claude.json"; SS="$P2H/.claude/settings.json"
jcheck  "P2: .claude.json: eigne noklar bevarte" "$CJ" 'd.get("theme") == "light"'
jcheck  "P2: gammal nøkkel bevart"        "$CJ" '"old-key" in d["customApiKeyResponses"]["approved"]'
jcheck  "P2: ny nøkkel lagt til"          "$CJ" '"key-p2" in d["customApiKeyResponses"]["approved"]'
jcheck  "P2: onboarding fullført"             "$CJ" 'd["hasCompletedOnboarding"] is True'
jcheck  "P2: settings: eigne noklar bevarte" "$SS" 'd.get("theme") == "dark" and d["custom"]["x"] == 1'
jcheck  "P2: settings: skipDangerousModePermissionPrompt" "$SS" 'd["skipDangerousModePermissionPrompt"] is True'
jcheck  "P2: settings: defaultMode bypassPermissions" "$SS" 'd["permissions"]["defaultMode"] == "bypassPermissions"'

# ---------------------------------------------------------------- scenario P3
# pi: models.json + settings.json seedast frå env. API-nøkkelen refereres
# gjennom env-interpolering, aldri skrive til disk.
P3H="$T/home-p3"; mkdir -p "$P3H"
run_init "$P3H" ANTHROPIC_API_KEY=secret-key-p3 \
    ANTHROPIC_BASE_URL=http://localhost:8787 ANTHROPIC_MODEL=test-model \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000
MJ="$P3H/.pi/agent/models.json"; PS3="$P3H/.pi/agent/settings.json"
fcheck  "P3: models.json lagd"           "$MJ"
jcheck  "P3: baseUrl"                     "$MJ" 'd["providers"]["harrbjorn"]["baseUrl"] == "http://localhost:8787"'
jcheck  'P3: apiKey er litteralt ${ANTHROPIC_API_KEY}' "$MJ" 'd["providers"]["harrbjorn"]["apiKey"] == "${ANTHROPIC_API_KEY}"'
check_absent "P3: nøkkel-verdi ikkje på disk" "$MJ" "secret-key-p3"
jcheck  "P3: models[0].id"                "$MJ" 'd["providers"]["harrbjorn"]["models"][0]["id"] == "test-model"'
jcheck  "P3: contextWindow"               "$MJ" 'd["providers"]["harrbjorn"]["models"][0]["contextWindow"] == 200000'
jcheck  "P3: maxTokens"                   "$MJ" 'd["providers"]["harrbjorn"]["models"][0]["maxTokens"] == 32000'
jcheck  "P3: defaultProvider"             "$PS3" 'd["defaultProvider"] == "harrbjorn"'
jcheck  "P3: defaultModel"                "$PS3" 'd["defaultModel"] == "test-model"'

# ---------------------------------------------------------------- scenario P4
# pi merge: pre-eksisterande models.json med annan provider og gammal
# harrbjorn-inngang — harrbjorn re-avleid fra env, annan provider bevart.
P4H="$T/home-p4"; mkdir -p "$P4H/.pi/agent"
cat > "$P4H/.pi/agent/models.json" <<'EOF'
{"providers": {"other": {"baseUrl": "http://other:9999"},
                "harrbjorn": {"baseUrl": "http://stale:1",
                               "models": [{"id": "old-model"}]}}}
EOF
run_init "$P4H" ANTHROPIC_API_KEY=k ANTHROPIC_BASE_URL=http://new:2 ANTHROPIC_MODEL=new-model
MJ4="$P4H/.pi/agent/models.json"
jcheck "P4: harrbjorn re-avleid" "$MJ4" \
    'd["providers"]["harrbjorn"]["baseUrl"] == "http://new:2" and d["providers"]["harrbjorn"]["models"][0]["id"] == "new-model"'
jcheck "P4: annan provider bevart" "$MJ4" 'd["providers"]["other"]["baseUrl"] == "http://other:9999"'

# ---------------------------------------------------------------- scenario P5
# pi-advarsel: ANTHROPIC_BASE_URL satt men ingen ANTHROPIC_MODEL — advarsel
# på stderr, ingen models.json.
P5H="$T/home-p5"; mkdir -p "$P5H"
run_init "$P5H" ANTHROPIC_API_KEY=k ANTHROPIC_BASE_URL=http://localhost:8787
check "P5: pi-advarsel på stderr" "$T/err" "ANTHROPIC_BASE_URL set but no ANTHROPIC_MODEL"
fcheck_absent "P5: ingen models.json" "$P5H/.pi/agent/models.json"

# ------------------------------------------------------ pi-extension (P6/P7)
# Bakea extension-store i sed-rewritea pi-sti: node_modules-katalogar
# (inkl. scopade), package.json-avhengigheitene og ein lock-fil. Delte av
# P6 (fersk HOME) og P7 (merge med agent si eigen store).
BAKE="$T/bake/agent/npm"
mkdir -p "$BAKE/node_modules/ext-a" "$BAKE/node_modules/@scope/ext-b" "$BAKE/node_modules/.hidden"
printf 'module.exports = 1\n' > "$BAKE/node_modules/ext-a/index.js"
printf 'module.exports = 2\n' > "$BAKE/node_modules/@scope/ext-b/index.js"
printf 'hidden\n' > "$BAKE/node_modules/.hidden/x"
printf 'not a dir\n' > "$BAKE/node_modules/file.txt"
cat > "$BAKE/package.json" <<'EOF'
{"name": "baked", "dependencies": {"ext-a": "^1.0.0", "@scope/ext-b": "2.0.0"}}
EOF
printf '{"lock": true}\n' > "$BAKE/package-lock.json"

# ---------------------------------------------------------------- scenario P6
# Fersk HOME: bakea store seedast til $HOME/.pi/agent/npm — kun
# node_modules-katalogar (ikkje .hidden, ikkje vanlege filer),
# avhengigheitene mergea, packages lista, lock-fila kopiert.
P6H="$T/home-p6"; mkdir -p "$P6H"
run_init "$P6H" ANTHROPIC_API_KEY=k
NPM6="$P6H/.pi/agent/npm"
fcheck        "P6: ext-a seedast"            "$NPM6/node_modules/ext-a/index.js"
check         "P6: ext-a-innhald"           "$NPM6/node_modules/ext-a/index.js" "module.exports = 1"
fcheck        "P6: @scope/ext-b seedast"     "$NPM6/node_modules/@scope/ext-b/index.js"
fcheck_absent "P6: .hidden ikkje kopiert"    "$NPM6/node_modules/.hidden"
fcheck_absent "P6: vanleg fil ikkje kopiert" "$NPM6/node_modules/file.txt"
jcheck        "P6: avhengigheitene mergea"   "$NPM6/package.json" \
              'd["dependencies"] == {"ext-a": "^1.0.0", "@scope/ext-b": "2.0.0"}'
jcheck        "P6: packages"                 "$P6H/.pi/agent/settings.json" \
              'sorted(d["packages"]) == ["npm:@scope/ext-b", "npm:ext-a"]'
fcheck        "P6: lock-fil kopiert"         "$NPM6/package-lock.json"
check         "P6: lock-innhald"            "$NPM6/package-lock.json" '"lock": true'

# ---------------------------------------------------------------- scenario P7
# Merge med eksisterande HOME-npm-store: agent si eigen package.json-spec
# vinn (setdefault), agent si eige pakke bevart, bakea pakke seedast.
P7H="$T/home-p7"; mkdir -p "$P7H/.pi/agent/npm/node_modules/agent-ext"
cat > "$P7H/.pi/agent/npm/package.json" <<'EOF'
{"name": "pi-extensions", "private": true, "dependencies": {"ext-a": "latest"}}
EOF
printf 'agent-ext file\n' > "$P7H/.pi/agent/npm/node_modules/agent-ext/own.js"
run_init "$P7H" ANTHROPIC_API_KEY=k
NPM7="$P7H/.pi/agent/npm"
jcheck  "P7: agent spec vinn (ext-a)"  "$NPM7/package.json" 'd["dependencies"]["ext-a"] == "latest"'
jcheck  "P7: bakea spec lagt til"      "$NPM7/package.json" 'd["dependencies"]["@scope/ext-b"] == "2.0.0"'
fcheck  "P7: agent-ext bevart"         "$NPM7/node_modules/agent-ext/own.js"
check   "P7: agent-ext-innhald"        "$NPM7/node_modules/agent-ext/own.js" "agent-ext file"
fcheck  "P7: ext-a seedast"            "$NPM7/node_modules/ext-a/index.js"
fcheck  "P7: @scope/ext-b seedast"     "$NPM7/node_modules/@scope/ext-b/index.js"
jcheck  "P7: packages"                 "$P7H/.pi/agent/settings.json" \
        'sorted(d["packages"]) == ["npm:@scope/ext-b", "npm:ext-a"]'

# ---------------------------------------------------------------- scenario P8
# exec: initet med argument kjører nettopp argumentet (exec "$@").
P8H="$T/home-p8"; mkdir -p "$P8H"
run_init "$P8H" ANTHROPIC_API_KEY=k
check "P8: exec kjører env (HOME= på stdout)" "$T/out" "HOME=$P8H"

# ---------------------------------------------------------- Burp CA (B1–B6)
# Med SBX_EXTERNAL_PROXY (-p) bør initet installere Burp sin CA som samla
# bundle (systembundle + proxy-CA) i $HOME/.sbx-ca-bundle.pem og eksportere
# SSL_CERT_FILE/REQUESTS_CA_BUNDLE/NODE_EXTRA_CA_CERTS. Loopback HTTP-server
# (python3) serverer /cert på 127.0.0.1; DER-sertifikatet genererast ved
# setup (openssl req -x509 → openssl x509 -outform DER).
command -v curl >/dev/null 2>&1 \
  || { echo "error: curl is required (Burp CA scenarios B1–B6)." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 \
  || { echo "error: openssl is required (Burp CA scenarios B1–B6)." >&2; exit 1; }

# Test-CA: PEM frå req, DER frå x509 -outform DER.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$T/burp.key" -out "$T/burp.pem" -days 2 -subj "/CN=Burp Test CA" \
    2>/dev/null
openssl x509 -in "$T/burp.pem" -outform DER -out "$T/burp.der"
[[ -s "$T/burp.der" && -s "$T/burp.pem" ]] \
  || { echo "error: could not generate test CA" >&2; exit 1; }

# HTTP-server: serverer /cert frå fil i $T/certsrv; 404 når fila manglar.
cat > "$T/certsrv.py" <<'EOF'
import http.server, os, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = os.path.join(root, self.path.lstrip("/"))
        if os.path.isfile(p):
            b = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
mkdir -p "$T/certsrv"
python3 "$T/certsrv.py" "$T/certsrv" > "$T/bport.txt" 2> "$T/certsrv.log" &
HTTPD_PID=$!
for _ in $(seq 1 50); do [[ -s "$T/bport.txt" ]] && break; sleep 0.1; done
BPORT="$(head -n1 "$T/bport.txt")"
[[ -n "$BPORT" ]] || { echo "error: cert-serveren starta ikkje" >&2; exit 1; }
BURL="http://127.0.0.1:$BPORT"

# ---------------------------------------------------------------- scenario B1
# Install: SBX_EXTERNAL_PROXY → Burp-CA frå /cert (DER). Bundle finst med
# mode 0600, inneheld systembundle si markør + proxy-CAa, og env-variablane
# peiker på bundle-stia.
B1H="$T/home-b1"; mkdir -p "$B1H"
cp "$T/burp.der" "$T/certsrv/cert"
run_init "$B1H" SBX_EXTERNAL_PROXY="$BURL"
B1B="$B1H/.sbx-ca-bundle.pem"
check     "B1: install-meddelande"     "$T/err" ">> Burp CA installed from $BURL/cert"
fcheck    "B1: bundle finst"           "$B1B"
mcheck    "B1: bundle mode 0600"       "$B1B" 600
check     "B1: bundle inneheld systembundle" "$B1B" "MARKER-SYSTEM-BUNDLE"
check     "B1: bundle inneheld proxy-CA"     "$B1B" "BEGIN CERTIFICATE"
check     "B1: SSL_CERT_FILE = bundle-sti"   "$T/out" "SSL_CERT_FILE=$B1B"
check     "B1: REQUESTS_CA_BUNDLE = bundle"  "$T/out" "REQUESTS_CA_BUNDLE=$B1B"
check     "B1: NODE_EXTRA_CA_CERTS = bundle" "$T/out" "NODE_EXTRA_CA_CERTS=$B1B"

# ---------------------------------------------------------------- scenario B2
# Trailing slash: URL-en blir framleis .../cert (ikkje /cert/).
B2H="$T/home-b2"; mkdir -p "$B2H"
run_init "$B2H" SBX_EXTERNAL_PROXY="$BURL/"
B2B="$B2H/.sbx-ca-bundle.pem"
check        "B2: install-meddelande (/cert)" "$T/err" ">> Burp CA installed from $BURL/cert"
check_absent "B2: ikkje /cert/ i URL"         "$T/err" "/cert/"
fcheck       "B2: bundle finst"               "$B2B"
check        "B2: bundle inneheld proxy-CA"   "$B2B" "BEGIN CERTIFICATE"
check        "B2: SSL_CERT_FILE = bundle-sti" "$T/out" "SSL_CERT_FILE=$B2B"

# ---------------------------------------------------------------- scenario B3
# Ingen SBX_EXTERNAL_PROXY: ingen install, ingen bundle, ingen env-var.
B3H="$T/home-b3"; mkdir -p "$B3H"
run_init "$B3H"
fcheck_absent "B3: ingen bundle"             "$B3H/.sbx-ca-bundle.pem"
check_absent  "B3: ikkje install-meddelande" "$T/err" "Burp CA installed"
check_absent  "B3: ikkje SSL_CERT_FILE"      "$T/out" "SSL_CERT_FILE=$B3H"

# ---------------------------------------------------------------- scenario B4
# 404: serveren gjev ikkje /cert → stille skip.
rm -f "$T/certsrv/cert"
B4H="$T/home-b4"; mkdir -p "$B4H"
run_init "$B4H" SBX_EXTERNAL_PROXY="$BURL"
fcheck_absent "B4: ingen bundle (404)"       "$B4H/.sbx-ca-bundle.pem"
check_absent  "B4: stille skip"              "$T/err" "Burp CA installed"

# ---------------------------------------------------------------- scenario B5
# Skada: /cert returnerer ikkje-sertifikat → stille skip (openssl feilar).
printf 'this is not a certificate\n' > "$T/certsrv/cert"
B5H="$T/home-b5"; mkdir -p "$B5H"
run_init "$B5H" SBX_EXTERNAL_PROXY="$BURL"
fcheck_absent "B5: ingen bundle (skada)"     "$B5H/.sbx-ca-bundle.pem"
check_absent  "B5: stille skip"              "$T/err" "Burp CA installed"

# ---------------------------------------------------------------- scenario B6
# PEM-fallback: /cert returnerer PEM (ikkje DER) → install suksess.
cp "$T/burp.pem" "$T/certsrv/cert"
B6H="$T/home-b6"; mkdir -p "$B6H"
run_init "$B6H" SBX_EXTERNAL_PROXY="$BURL"
B6B="$B6H/.sbx-ca-bundle.pem"
check     "B6: install-meddelande"       "$T/err" ">> Burp CA installed from $BURL/cert"
fcheck    "B6: bundle finst"             "$B6B"
mcheck    "B6: bundle mode 0600"         "$B6B" 600
check     "B6: bundle inneheld systembundle" "$B6B" "MARKER-SYSTEM-BUNDLE"
check     "B6: bundle inneheld proxy-CA"     "$B6B" "BEGIN CERTIFICATE"
check     "B6: SSL_CERT_FILE = bundle-sti"   "$T/out" "SSL_CERT_FILE=$B6B"

# Stopp cert-serveren.
kill "$HTTPD_PID" 2>/dev/null; wait "$HTTPD_PID" 2>/dev/null

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
