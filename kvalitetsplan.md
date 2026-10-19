# Kvalitetsplan: bedre testdekning (fire nye enhetstester)

## Context

Kvalitetsturn: «Bedre testdekning. Se CLAUDE.md». I dag er kun `sbx_write_proxy_policy` dekket av enhetstest (`tests/test-proxy-policy.sh`). Funksjonene `sbx_uplink_dns`, `sbx_check_runtime` og `sbx_main` i `lib/sandbox.sh`, og `code/sbx-init.sh`, er i praksis testbare på vertsen uten podman og uten ekstern nettverk (bash + python3, self-contained).

Mål: fire nye self-contained testfiler under `tests/` som låser inn oppførsel i disse funksjonene.

**Red-green:** oppførselen eksisterer allerede, så hver ny testcase er red-steget; grønt ved første kjør = låser inn korrekt oppførsel. En test som feiler ved første kjør avdekker en reel bug → minimalt produksjonsfix, der grønt. Planen forutsetter ellers ingen produksjonsendringer.

**Ingen gjenbygging av bilder** (test-only). Egen branch; merge til main avgjøres av brukeren. Hver commit slutter med `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

### Oppgavedeling (spar som `kvalitetsplan.md` i repo-rotten, del 0)

| Del | Innhold |
|-----|---------|
| 0 | Lagre denne planen som `kvalitetsplan.md` |
| 1 | `tests/test-uplink-dns.sh` |
| 2 | `tests/test-check-runtime.sh` |
| 3 | `tests/test-sbx-main.sh` |
| 4 | `tests/test-sbx-init.sh` |

Hver del: skriv test → kjør → grønt (eller red → minimal fix → grønt) → commit.

## Felles konvensjoner (alle fire filer)

Stil fra `tests/test-proxy-policy.sh`: header «Dekker/Krevd/Kjør», `set -uo pipefail` (ikke `-e` — feiltilfeller er forventet), `REPO` fra BASH_SOURCE, `T=$(mktemp -d)` + `trap 'rm -rf "$T"' EXIT`, pass/fail-tellere, `check`/`check_absent`/`warn_check` (grep-baserte), avsluttende `echo "$pass passed, $fail failed"; [[ "$fail" -eq 0 ]]`, norske kommentarer.

Viktig: `sbx_check_runtime` bruker `exit 1` — alle forventede-feil-kall må kjøre i **subshell** (ellars dør testskallet). `sbx_uplink_dns` bruker `return 1` og kan kalles direkte med `|| true`.

## Del 1: tests/test-uplink-dns.sh — `sbx_uplink_dns` (lib/sandbox.sh:102)

- Source en sed-kopi: `sed "s|/etc/resolv.conf|$T/resolv.conf|g" lib/sandbox.sh > $T/sandbox-test.sh` (selvverifiserende: endrer den litt ralestien endrast testene). Krev python3 (mottar `resolvectl` på PATH).
- Fake `resolvectl` i `$T/bin` (PATH foran), greiner på argumenter:
  - **U1 JSON-pas** (`--json=short` → `{"link":[{"currentServer":{"addressString":"10.99.99.99"},"servers":[{"addressString":"10.99.99.99"},{"addressString":"127.0.0.53"},{"addressString":"2606:4700:4700::1111"}]}]}`) → nøyaktig `10.99.99.99` + `2606:4700:4700::1111` (dedup + loopback filtrert).
  - **U2 fallback** (menneskeformat): `--json=short` → ugyldig JSON (python gir av); plain `status` → `    DNS Servers: 1.2.3.4 5.6.7.8 127.0.0.53` → `1.2.3.4` + `5.6.7.8`.
  - **U3 resolv.conf-fallback** (sed-redirect): ingen resolvectl-utdata; `$T/resolv.conf` med `nameserver 8.8.8.8`, `nameserver 127.0.0.53`, `# nameserver 9.9.9.9` → kun `8.8.8.8` (kommentar + loopback fjernet).
  - **U4 alt filtrert**: `$T/resolv.conf` med bare `nameserver 127.0.0.53` → retur 1, tom utdata (likewise tom fil).

## Del 2: tests/test-check-runtime.sh — `sbx_check_runtime` (lib/sandbox.sh:414)

- Source den rale `lib/sandbox.sh` (slår på `set -euo pipefail` i testskallet — alle feil-tilfelle i subshell med fanget stderr).
- Feil-tilfelle (subshell, sjekk exit 1 + røykteksn på stderr):
  - **R1** `SBX_RUNTIME=bogus` → `error: invalid SBX_RUNTIME 'bogus' (must be krun, runsc or crun).`
  - **R2** crun manglar (RESTRICTED PATH utan crun; `command -v` er builtin) → `error: SBX_RUNTIME=crun but crun is not installed.`
  - **R3** runsc manglar → `error: SBX_RUNTIME=runsc but the runsc (gVisor) runtime is not installed.`
  - **R4** krun manglar → `error: SBX_RUNTIME=krun but the krun OCI runtime is not installed (Fedora: dnf install crun-krun).`
- Suksess (stub-runtime på PATH; sjekk `RUNTIME_ARGS` i testskallet):
  - **R5** stub `crun` → `RUNTIME_ARGS == (--runtime crun)`
  - **R6** stub `runsc` → `--runtime runsc`
  - **R7** stub `krun` + røkt `/dev/kvm` → `--runtime krun` — **kun assertert dersom** `[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]`, elles hoppast med notis (host-uavhengig).
  - **R8** krun + `/dev/kvm` utilgjengeleg: sed-kopi som rewrite `/dev/kvm` → `$T/kvm-missing`; subshell som source sed-kopien → `error: SBX_RUNTIME=krun but /dev/kvm is not accessible ...` (selvverifiserande sed).

## Del 3: tests/test-sbx-main.sh — `sbx_main` via fake PODMAN (lib/sandbox.sh:452)

**Hermetisk harnes** (testskallet source IKKE sandbox.sh — alle assert mot subprocess-arkart):
- Kopier `run-code.sh`, `lib/sandbox.sh`, `allowlist.code.default` til `$T/repo/` → i subprocess `SCRIPT_DIR=$T/repo`, `STATE_DIR=$T/repo/.sandbox` (rører aldri røkt `.env` / `.sandbox`).
- **PODMAN-stubb** `$T/bin/podman` (settest `PODMAN=$T/bin/podman`, absolutt path akseptert av `command -v`):
  - Logg `PODMAN <args>` per kall til `$FAKE_PODMAN_LOG` (eitt linje per kall — ingen `-e`-verdi inneheldwhitespace, assertbart med grep).
  - `image`→0 (ingen bygg; `image_exists` grønt), `info`→0, `ps`→tom, `network`→0, `inspect`→`echo 10.0.0.2`, stop/rm/logs/build→0.
  - `run`: dersom ein `-v`-arg har target `/config` (proxyen sin kjør, `-v <dir>:/config:ro,z`), **kopier** `proxy.yaml`+`acl.yaml` frå `<dir>` til `$FAKE_PODMAN_CAPTURE` — må skje no, for `sbx_cleanup` (EXIT-trappen) slettar `POLICY_DIR` og `resolv-*.conf` ved avslutt; `allowlist-*.txt` og `agent-home/` overlever.
- Fake `resolvectl` på PATH (deterministisk uplink DNS: JSON med éin server `10.99.99.99`).
- Harnes-env per kjøring: `HOME=$T/home SBX_CLAUDE_CONFIG=$T/claude.sh SBX_RUNTIME=crun` (stub `crun` på PATH → deterministisk `--runtime crun`, uavhengig av host sin KVM), `unset SBX_MEMORY SBX_CPUS SBX_PIDS SBX_LOCALE`; wrapper-utdata til `$T/out-*.log`.

**Scenario** (session-navn `sbx-<S>` — grep `sbx-`-prefix, ikkje nøyaktig S):
- **M1 grunnleggende** (inga -p, med modellkonfig `$T/claude.sh` = `export ANTHROPIC_BASE_URL=http://localhost:8787` + nøkkelle): run-linje inneheld `run --rm -i` (ikkje-tty), `--runtime crun`, `--userns=keep-id:uid=1000,gid=1000`, `-v <work>:/work:z`, `-w /work`, `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges:true`, `--memory 4g`, `--pids-limit 1024`, `--cpus 2`, `harrbjorn/code:latest`; `network create --internal sbx-`; nøyaktig éi `run -d --name sbx-...-proxy` med `--config-file /config/proxy.yaml`; fanget `proxy.yaml` er gyldig YAML med `port: 3128`, `acl_file: /config/acl.yaml`, `169.254.1.2:8787` (trusted frå konfigporten, open-modus: IKKE i acl.yaml); `agent-home/code<work>` finst med mode 700; run-linje inneheld `-e ANTHROPIC_BASE_URL=http://host.containers.internal:8787` (loopback-rewrite).
- **M2 -p suksess**: loopback-lyttar (python3 socket-server) på 127.0.0.1:PORT; `-p 127.0.0.1:PORT` → `network create sbx-` **utan** `--internal`; ingen proxy-`run -d`; run-linje inneheld `-e HTTP_PROXY=http://host.containers.internal:PORT`, `NO_PROXY=localhost,127.0.0.1,::1,host.containers.internal`, `-e SBX_EXTERNAL_PROXY=http://host.containers.internal:PORT`. Kill lyttaren etterpå.
- **M3 -p fail-closed**: `-p 127.0.0.1:<lukka port>` (funne via `/dev/tcp`-probe) → exit 1, stderr `error: -p: no forward proxy answering at ... (fail-closed ...)`; ingen `network create` i loggen, ingen run-linje.
- **M4 -p ugyldig**: `-p localhost` (ingen port) og `-p h:99999` → exit 1, `error: -p: bad proxy`.
- **M5 -H**: `-H 8080 -H 8080` → fanget proxy.yaml med **nøyaktig éi** `169.254.1.2:8080` (dedup); `-H abc` → exit 1, `error: -H: bad port`.
- **M6 .env-preferanse**: `$T/repo/.env` med `SBX_MEMORY=7g SBX_PIDS=42` → run-linje `--memory 7g`, `--pids-limit 42`.
- **M7 ingen modellkonfig + nøkkelen i .env**: `SBX_CLAUDE_CONFIG`→finast; `.env` med `ANTHROPIC_API_KEY=test-key` → run-linje `-e ANTHROPIC_API_KEY=test-key`, stderr `warn: no model config at`.
- **M8 ingen modellkonfig, ingen nøkkelen** → exit 1, stderr `set ANTHROPIC_API_KEY in .env, or provide a model config`.

Note: M2/M3 sin loopback-lyttar er lokal TCP (self-contained, ikkje «nettverk» i CLAUDE.md si forstand).

## Del 4: tests/test-sbx-init.sh — `code/sbx-init.sh` (container-init)

Kjøre `sh $T/sbx-init-test.sh` direkte på vertsen med `HOME=$T/home` (scriptet er vanleg sh + python3; berre to host-spesifikke stiar sed-rewriteast: `/etc/ssl/certs/ca-certificates.crt` → `$T/ca-bundle.crt` og `/usr/local/share/pi` → `$T/bake`). `set -u` i scriptet; miljø settest per scenario.

**Claude/pi-seeding** (ikkje sed-nødvendig):
- **P1 fersk HOME**: `.claude.json` — `hasCompletedOnboarding: true`, `customApiKeyResponses.approved` inneheld `test-key-123` (frå env), `projects["/work"].hasTrustDialogAccepted: true`, mode 0600.
- **P2 merge**: pre-eksisterande `.claude.json` + `.claude/settings.json` med eigne nøkkelar → bevarte; `skipDangerousModePermissionPrompt: true` + `permissions.defaultMode: bypassPermissions` lagt til.
- **P3 pi**: env `ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL` + `CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000` + `CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000` → `.pi/agent/models.json` `providers.harrbjorn`: baseUrl, **`apiKey` er litteralt `"${ANTHROPIC_API_KEY}"`** (assert litteralet, aldri nøkkelen si verdi), `models[0].id` + `contextWindow`/`maxTokens`; `settings.json` `defaultProvider`/`defaultModel`.
- **P4 pi merge**: pre-eksisterande models.json med annan provider + gammal harrbjorn-inngang → harrbjorn re-avleid frå env, annan provider bevart.
- **P5 pi advarsel**: base_url utan model → stderr `warn: ANTHROPIC_BASE_URL set but no ANTHROPIC_MODEL`, ingen models.json.
- **P6 extension** (sed): `$T/bake/agent/npm/{package.json (deps: ext-a, @scope/ext-b), node_modules/{ext-a, @scope/ext-b, .hidden, file.txt}, package-lock.json}` → `$T/home/.pi/agent/npm`: `node_modules/ext-a` + `node_modules/@scope/ext-b` (IKKE `.hidden`/`file.txt`), package.json-avhengigheit mergea, settings.json `packages: ["npm:ext-a","npm:@scope/ext-b"]`, lock kopiert.
- **P7 extension merge**: eksisterande HOME-npm-store med eigen package.json (ext-a @ anna spec) + `node_modules/agent-ext` → agent sin spec vinn (setdefault), agent-ext bevart.
- **P8 exec**: `sh sbx-init-test.sh env` → køyrer `env` (assert output inneheld `HOME=`) — den fjesa `exec "$@"` fungerer.

**Burp CA (-p)** — loopback HTTP-server (python3) som serverer `/cert`; DER-sertifikat generert ved setup (`openssl req -x509 -newkey rsa:2048` → `openssl x509 -outform DER`):
- **B1 install**: `SBX_EXTERNAL_PROXY=http://127.0.0.1:PORT` → stderr `>> Burp CA installed from http://127.0.0.1:PORT/cert`; `$T/home/.sbx-ca-bundle.pem` finst, 0600, inneheld `$T/ca-bundle.crt` sin innhald (markør) + `BEGIN CERTIFICATE` (proxy-CAa bak system-bundlea); `sh sbx-init-test.sh env` viser `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`/`NODE_EXTRA_CA_CERTS` alle = bundle-sti.
- **B2 trailing slash**: `SBX_EXTERNAL_PROXY=http://127.0.0.1:PORT/` → same install (URL blir framleis `.../cert`, ikkje `/cert/`).
- **B3 ingen env**: `SBX_EXTERNAL_PROXY` usettest → ingen markør, ingen bundle.
- **B4 404**: serveren gjev ikkje `/cert` → stille skip.
- **B5 skada**: `/cert` returnerer ikkje-sertifikat → stille skip (openssl feilar).
- **B6 PEM-fallback**: `/cert` returnerer PEM (ikkje DER) → install suksess (DER-attempt feilar, PEM-fallback fungerer).

## Kjøre / red-green-flyt

**Utførelse med subagenter (sekvensielt):** vertssessjonen har liten kontekst (lokal LLM, ~110k) — hovudsessjonen delegerer kvar del til ein fersk subagent (general-purpose), ein del per løp, i rekkjefølgje 1 → 4. Hovudsessjonen held seg tynn: opprettar branch, startar subagentane med ein kompakt prompt (delens planseksjon + konvensjonar + stiar til kjeldefilane), og verifiserer etter kvart (kjør testfila sjølv, `git status`), før neste del startar.

1. Opprett branch `kvalitet-testdekning` (hovudsessjon).
2. **Del 0** (hovudsessjon, kjappt): skriv `kvalitetsplan.md` (innhald = denne planen) i repo-rotten; commit.
3. Del 1–4 i rekkjefølgje, kvar som eitt subagent-løp: skriv testfila → `bash tests/<fil>.sh` → grønt (lås inn) eller red → avdekt bug → minimalt produksjonsfix → grønt → commit (med `Co-Authored-By`-linja). Subagenten rapporterer kort: testnavn, grønt/red-avslutning, evt. produksjonsfix.
4. Hovudsessjon verifiserer kvar del før neste startar.
5. Berre testfiler (og evt. minimal fixes) — ingen endring av kode som bakkar inn i bildene, difor ingen `--rebuild`.

## Verifikasjon

- `for t in test-uplink-dns test-check-runtime test-sbx-main test-sbx-init test-proxy-policy; do bash tests/$t.sh || echo "FAIL $t"; done` — alle grønne (inkludert den eksisterende suitten).
- Teste er self-contained: kjører utan podman (stubbane erstatter det), utan ekstern nettverk (berre 127.0.0.1-lyttarar).
- Konfirmere at ingenting endra utanfor `tests/` (og `kvalitetsplan.md`) med `git status` — elles har ein red-test avdekt ein bug, og da dokumenterast den i commit-meddelandet.
