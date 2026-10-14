# Plan: rootless Podman, microVM-runtime, Smokescreen og copy-in/patch-out

Mål: erstatte mest mulig av den egenskrevne isolasjonskoden i `lib/sandbox.sh`
og `proxy/proxy.py` med ferdige komponenter, og lukke de alvorligste funnene
fra analysen. Kun lokal kjøring på Linux-laptop (Fedora).

| Funn | Løses av |
|---|---|
| Container-escape gir uid 1000 på host, rootful Docker | 1 (rootless), 2 (microVM) |
| uid 1000 vs. hostens uid, `chown` feiler | 1 (`--userns=keep-id`) |
| Open-modus når RFC1918, 172.29.0.1 og hostens IP-er | 3 (Smokescreen) + 4 (rootless netns) |
| Delt proxy med global policy | 4 (proxy per sesjon) |
| iptables fail-open, unødvendig port 53, bred sudoers | 4 (faller bort) |
| Workspace-skriv gir kodekjøring på host (hooks, `.envrc` o.l.) | 5 |
| Store HTTP-svar bufres og trunkeres i proxy | 3 |

Løst: symlink-angrepet mot host-seedingen av agent-HOME — seeding flyttet
fra hosten til init-steg i containeren (`code/sbx-init.sh`). Se «Relatert».

## Status (per 2026-10-14)

| Punkt | Status |
|---|---|
| 1. Rootless Podman | ✅ Løst (`e35f8af` + fiks `80b2605`, `9501dd8`, `e5b3352`) |
| 2. krun/gVisor-runtime | ✅ Løst (`eb59ba7`) — `SBX_RUNTIME` (`krun` default, `runsc`/`crun` eksplisitt), hard fail hvis valgt runtime (eller `/dev/kvm`) mangler |
| 3. Smokescreen | ❌ Ikke løst — `proxy/proxy.py` i bruk enda (`harrbjorn/sbx-proxy` er python-bilde) |
| 4. Nettverk per sesjon | ✅ Løst sammen med 1 — per-sesjon `--internal`-nett + proxy, per-sesjon `resolv.conf`/allowlist, orphan-reaping, `-H`, ingen iptables/sudo |
| 5. copy-in/patch-ut | ❌ Ikke løst — fortsatt rw-bindmount til `/work`; ingen `--mount-workspace`, ingen `-w`-sperre |

Relatert: agent-HOME-seeding inne i containeren ✅ (`3422ab5`,
`code/sbx-init.sh`); agent-HOME per usecase+workdir ✅ (`9fb7277`);
hemmeligheter via `--env-file`/`podman secret` ❌ (fortsatt `-e` på
kommandolinjen, inkl. modelconfigens env-vars).

Siden planen er skrevet (utenfor 1-5): `harrbjorn`-CLI-dispatcher med bash
autocompletion (`894b240`), interaktiv bash som default uten kommando
(`432e5d0`), norsk lokal `nb_NO.UTF-8` (`22891b0`). Åpne poster i
`issues.md`: pi agent-harness (installere + sette opp likt som claude i
begge sandboxene) og exit fra container henger; i `todo.md`: statusline i
container som native.

---

## 1. Rootless Podman i stedet for rootful Docker — ✅ LØST

Implementert i `e35f8af` (fiks i `80b2605`, `9501dd8`, `e5b3352`): podman
rootless uten sudo, `--userns=keep-id:uid=1000,gid=1000` + `--user 1000:1000`,
chown/tmpfs-`uid=`-hardkoding fjernet, hardening beholdt, base-images pinnet
på digest (`node:22-bookworm-slim@sha256:...`, `python:3.13-slim@sha256:...`)
og Claude Code låst til versjon (`@anthropic-ai/claude-code@2.1.296`),
`pentest/Dockerfile` bygger `FROM harrbjorn/code`.

**Endringer**
- Erstatt `$DOCKER`-logikken (inkl. `sudo docker`-fallback) med `podman`.
  Ingen sudo noe sted.
- Kjør sandboxen med `--userns=keep-id:uid=1000,gid=1000`: agenten er uid
  1000 i containeren, filene eies av hostbrukeren utenfor.
- Fjern `chown 1000:1000` og tmpfs-`uid=`/`gid=`-hardkodingen der keep-id
  gjør dem overflødige.
- Behold: `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`,
  `--pids-limit`, `--memory`, `--cpus` (krever cgroup v2-delegering, standard
  på Fedora).
- Dockerfiles kan beholdes (Containerfile-kompatible); bygg med `podman build`.
- Pin base-images på digest og Claude Code-versjon (`npm install -g
  @anthropic-ai/claude-code@<versjon>`), slik at bygg er reproduserbare.
- Slå sammen `code/` og `pentest/`: `pentest/Dockerfile` bygger `FROM
  harrbjorn/code`.

**Verifiser**
- `podman info` viser `rootless: true`, cgroup v2, `networkBackend: netavark`
  og pasta som rootless-nettverk.
- Fil skrevet i `/work` eies av hostbrukeren (`stat`).

## 2. Sterkere runtime: libkrun (primær), gVisor (fallback) — ✅ LØST

Implementert i `eb59ba7`: `SBX_RUNTIME` (`krun` | `runsc` | `crun`),
default `krun`, gjelder begge sesjonscontainerne (sandbox og proxy).
`sbx_check_runtime` feiler hardt før noen sesjonsressurs skapes hvis
valgt runtime mangler — og for krun kreves tilleggsvis `/dev/kvm`.
Ingen stille fallback til `crun`, som kun velges eksplisitt. To
krun-spesifikke tilpasninger funnet ved verifisering: readiness-proben
leser proxyens log-linje (krun implementerer ikke `podman exec`), og
cleanup bruker `stop -t 1` (krun rapporterer ikke SIGTERM-stopp innen
standard tidsgrense).

**Valg**
- Primær: `crun-krun` (`podman run --runtime krun` eller
  `--annotation run.oci.handler=krun`). Gir microVM via KVM med egen kjerne.
- Fallback: gVisor (`runsc`) hvis krun ikke fungerer med oppsettet under
  (rootless-støtten i gVisor må verifiseres).
- Kata vurderes ikke: tungt å installere og dårlig støtte for rootless Podman.

**Endringer**
- Ny variabel `SBX_RUNTIME` (`krun` | `runsc` | `crun`), default `krun`.
  Wrapperen feiler hvis valgt runtime mangler; ingen stille fallback til
  `crun`. `crun` kun med eksplisitt `SBX_RUNTIME=crun`.
- Sjekk `/dev/kvm` ved oppstart når `SBX_RUNTIME=krun`.

**Avklart (spike 2026-10-09, podman 5.8.7, Fedora 44, crun-krun 1.28)**
- krun + `--read-only` + tmpfs + `--userns=keep-id` + `--internal`
  fungerer: gjenkjern (6.12.109 vs. host 7.2.8), agent uid 1000, rootfs
  skrivebeskyttet, ingen utgang (IP-literaler → «Network is unreachable»).
- Podman 5.8 avviser `--tmpfs /tmp:uid=1000` og `--mount`-`uid=` som
  rootless; bruk `--mount type=tmpfs,destination=/tmp` (1777, eier 0:0).
  keep-id gjør uid-hardkoding overflødig — agent (1000) skriver fritt.
- Ytelse: tmpfs 449 MB/s skrive / 2.7 GB/s lese; bind-mount (virtio-fs)
  krever SELinux-`z` (sonst EACCES, også under crun); `npm install express`
  (65 moduler) totalt ~3,5 s inkl. oppstart. Oppstart ~0,6 s.
- Minne: ~88 MB RSS per hvilende VM (VmSize ~3,2 GB, reservert gjeast-RAM).
- Ressursgrenser (`--memory`, `--cpus`, `--pids-limit`) virker under krun
  (cgroup v2-delegering er i orden).

**Verifiser**
- `uname -r` i containeren er en annen kjerne enn hosten (krun).
- Self-testen fra punkt 4 består med valgt runtime.

## 3. Smokescreen i stedet for `proxy/proxy.py` — ❌ IKKE LØST

`proxy/proxy.py` er i bruk enda; `harrbjorn/sbx-proxy` er et python-bilde
(`python:3.13-slim` + `proxy.py`), ikke Smokescreen.

**Endringer**
- Nytt bilde `harrbjorn/sbx-proxy` bygget fra pinnet Smokescreen-release
  (Go, statisk binær), read-only, uprivilegert, ingen publiserte porter.
- Slett `proxy/proxy.py`.
- Generer konfig per sesjon fra eksisterende allowlist-filer
  (`allowlist.*.default`, `-a`, `-f`), slik at allowlist-formatet for
  brukeren beholdes:
  - hostnavn og `*.domene` → Smokescreen ACL (`allowed_domains`)
  - IP-literaler (pentest-mål) → `--allow-range <ip>/32` (eller CIDR)
  - modellserver på hosten → eksplisitt `--allow-address` for host-adressen
    fra punkt 4 og porten fra modelconfigen
- Open-modus (`SBX_OPEN_NETWORK=1`): ACL med default action `open`.
  Smokescreens standard deny for private, loopback-, link-local- og
  metadata-adresser gjelder fortsatt, også for IP-literaler (lukker hullet
  med 10/8, 192.168/16, 172.29.0.1 osv.).
- Begrens open-modus til porter 80/443 (`--allow-port`-oppsett e.l., må
  sjekkes mot Smokescreen-flaggene). Andre porter krever allowlist-oppføring.
- Audit: Smokescreen logger JSON til stdout; `podman logs` for sesjonens
  proxy erstatter `docker logs sbx-proxy`. Behold mulighet for å kopiere
  loggen til `.sandbox/logs/<sesjon>.jsonl` ved avslutning.

**Avklares**
- Eksakt mapping fra dagens port-semantikk (`host` = 80/443, `host:port`)
  til Smokescreen-konfig.
- Plain HTTP-forwarding og strømming (SSE) mot modellserveren over `http://`.
  Alternativ: la modellserveren nås direkte og ikke via proxy (se punkt 4).

**Verifiser (nye negative tester)**
- Open-modus: `curl -x ... https://10.0.0.1`, `https://192.168.1.1`,
  `https://<hostens LAN-IP>:22`, `http://[::ffff:127.0.0.1]/`,
  `http://169.254.169.254/` → alle avvist.
- Allowlist-modus: ikke-listet domene → avvist; listet domene → OK.

## 4. Nettverk: rootless netns, proxy per sesjon, ingen iptables — ✅ LØST

Implementert i `e35f8af` (sammen med punkt 1): per-sesjon `sbx-$S-int`
(`--internal`) + per-sesjon proxy med bindet per-sesjons `resolv.conf`
(hostens oppstrøms-DNS, glibc-first-NS-funnet håndtert), `EXIT`-trap +
orphan-reaping, modellport auto-trusted fra modelconfigen, `-H` for
eksplisitte host-porter (`9501dd8`, fiks i `e5b3352`). SBX-ISOLATE-kjeden,
sudoers, bridge- og `--no-host-isolation`-logikken er fjernet.

**Merk:** containere i samme Podman-pod deler nettverksnavnerom, så
«sandbox og proxy i én pod» gir sandboxen samme utgang som proxyen. Det
fungerer ikke; bruk separate nettverk som under.

**Design**
- Per sesjon `S` (f.eks. `sbx-<usecase>-<ts>`):
  - `podman network create --internal sbx-$S-int`
  - proxy-container `sbx-$S-proxy` på standard rootless-nett (pasta) +
    `sbx-$S-int`, med bindet per-sesjons `resolv.conf` der hostens
    oppstrøms-DNS er den(e) eneste namneserveren(e) (aardvark må aldri
    stå først — se «Avklart» nedenfor)
  - sandbox-container kun på `sbx-$S-int`, `HTTP(S)_PROXY=http://sbx-$S-proxy:3128`
- `trap` i wrapperen fjerner proxy og nettverk ved avslutning (også ved
  feil/Ctrl-C). Opprydding av foreldreløse `sbx-*`-ressurser ved oppstart.
- Konsekvens: samtidige sesjoner har hver sin policy (lukker «delt proxy»),
  og label-hash-logikken for gjenbruk av proxy kan slettes.
- Rootless netavark-nettverk lever i brukerens rootless netns. Gatewayen til
  `--internal`-nettverket er ikke hostens nettverksstack, så
  SBX-ISOLATE-kjeden, `etc/harrbjorn-sbx.sudoers`, bridge-oppslaget og
  `--no-host-isolation`/`HOST_ISOLATION` faller bort.
- Hosttjenester (modellserveren): nås kun via pastas mapping av host
  (`host.containers.internal`), og kun fra proxyen, og kun den eksplisitte
  `adresse:port` fra punkt 3. Base-URL-omskrivingen endres fra
  `172.28.0.1` til denne adressen.

**Avklart (spike 2026-10-09)**
- Hosten synes som `host.containers.internal` → **169.254.1.2** (stabil,
  bekreftet i to containere); pastas DNS-forwarder er 169.254.1.1.
  Fra sandboxen (kun `--internal`) er 169.254.1.1/169.254.1.2 uløsbare og
  uregable («Network is unreachable») — hosten nås aldri direkte.
  Begrensning til modellserverporten gjøres altså i proxyens policy, ikke
  i pasta-flagg.
- DNS på `--internal`: aardvark løser `sbx-$S-proxy` ✓, eksterne navn →
  NXDOMAIN ✓ (ingen DNS-tunnel fra sandboxen).
- **Funn:** multi-homed proxy (internal + default) får resolv.conf fra det
  primære nettverket (internal), så proxyens egen eksterne DNS bryter
  (502 på alt). Røtt: glibc behandler den *første* namneserverens svar som
  endelig — aardvark svarer NXDOMAIN på alle eksterne namn, og glibc
  fell aldri tilbake til neste NS (kontrollkjøring: NS-rekkefølge
  avgjør resultatet). Løst med bindet per-sesjons `resolv.conf` der
  hostens oppstrøms-DNS er einaste namneserver. Pasta-forwarderen
  (169.254.1.1) trengst ikkje: glibc sender ikkje EDNS0 på vanlege
  A-lookup, og forwarderens EDNS0-bug (FORMERR) slår derfor ikkje til.
- **Funn:** allowlistposten `host.containers.internal:8000` avvises av
  proxy.py-s DNS-rebindingsvern (169.254.1.2 er link-local). Modellserveren
  må derfor behandles som konfigurasjonsnivå-unntak
  (f.eks. `SBX_PROXY_TRUSTED_ADDR` / Smokescreen `--allow-address`), ikke
  som en brukerkommentert allowlistpost.
- **Løst:** øvrige host-porter kan eksplisitt tillates via
  `-H 8080 -H 9443` (CLI-flagg i run-code.sh/run-pentest.sh) —
  lib/sandbox.sh vedlegger `host.containers.internal:<port>` til
  `SBX_PROXY_TRUSTED`. Blir et port-for-port-runtime-unntak, aldri en
  allowlistpost, og host-tjenesten må lytte på noe annet enn loopback.
- Strømming mot modellserveren: proxy.py bufres/trunkerer HTTP-svar
  (kjent funn); plain-HTTP over proxy krever strømande proxy —
  verifiseres mot Smokescreen i punkt 3.
- **Funn:** proxy.py avslutter ikke på SIGTERM (ThreadingHTTPServer-tråder
  er ikke-daemon) → ryddingen tar 10 s + SIGKILL. Smokescreen erstatter
  den; trap må likevel forvente hard kill ved cleanup.

**Verifiser**
- Fra sandboxen: rå TCP til internett, til `host.containers.internal:22`,
  til gatewayen og til hostens LAN-IP → feiler.
- `nslookup example.com` fra sandboxen → feiler; `sbx-$S-proxy` → løses.
- To samtidige sesjoner (code open + pentest allowlist): pentest-sesjonen
  får fortsatt avslag på ikke-listede domener.

## 5. Workspace: copy-in / patch-ut — ❌ IKKE LØST

Workspace er fortsatt rw-bindmount til `/work` (`-v "$WORKDIR_ABS:/work:z"`);
ingen copy-in, patch-ut, `--mount-workspace` eller `-w`-sperre.

**Design**
- Default: workspace mountes **ikke**. I stedet:
  1. Copy-in: `git clone --no-hardlinks` (git-repo) eller `tar` (ikke-git) av
     `-w`-katalogen til en sesjonsvolum eller `.sandbox/sessions/$S/work`,
     montert som `/work`. `.git/hooks` og lokal `.git/config` tas ikke med
     ukritisk (klon gir rene hooks).
  2. Agenten jobber fritt i kopien.
  3. Patch-ut ved avslutning: `git -C /work format-patch` / `git diff
     --binary` mot startcommit → `.sandbox/sessions/$S/out.patch`.
     Ikke-git: `diff -ruN` eller tar av endrede filer til en separat
     ut-katalog, aldri tilbake i originalen.
  4. Brukeren ser gjennom og bruker `git apply --check` + `git apply`/`git am`
     selv. Wrapperen skriver ut liste over endrede «farlige» stier
     (`.envrc`, `.vscode/`, `.idea/`, `Makefile`, `package.json`-scripts,
     `.github/workflows/`, `.pre-commit-config.yaml`, `.gitattributes`,
     filmodus-endringer) som advarsel.
- Opt-in `--mount-workspace` beholder dagens rw-bindmount for interaktiv
  bruk, med tydelig advarsel.
- Sperre i begge moduser: avvis `-w` lik `/`, `$HOME`, en forelder av
  `$HOME`, harrbjorn-repoet selv eller en forelder av det, og kataloger som
  inneholder `$SBX_CLAUDE_CONFIG`.
- Ikke bruk `:z` på brukerens katalog i copy-in-modus (sesjonskopien
  relabeles i stedet). Med `--mount-workspace`: behold `:z`, men sperren
  over hindrer relabel av `$HOME`.

**Verifiser**
- Agent som skriver `.git/hooks/pre-commit` og `.envrc` i `/work`:
  originalen er urørt; hooken finnes ikke i patchen; `.envrc` vises i
  advarselslisten.
- `-w ~` og `-w <repo-rot>` avvises.

---

## Relatert (ikke del av 1-5)

- **Løst:** Agent-HOME-seeding flyttet fra hosten til et init-steg inne i
  containeren: `code/sbx-init.sh` som `ENTRYPOINT` i `harrbjorn/code`
  (arves av `harrbjorn/pentest`); seedes fra `HOME`/`ANTHROPIC_API_KEY` i
  containerens env, før `exec "$@"`. Hostprosessen rører kun
  `mkdir -p`/`chmod` av selve AGENT_HOME-veien under `.sandbox/` (aldri
  montert i containeren, så ingen agent-kjører kan plante lenker der) —
  ingen host-skriver faller lenger i agentkontrollert katalog.
- **Løst (`9fb7277`):** Agent-HOME per workspace i stedet for felles for
  alle sesjoner og begge usecases — nøkkelt på usecase + absolutt workdir
  (`.sandbox/agent-home/<usecase>/<workdir>`).
- Hemmeligheter via `--env-file` (0600) eller `podman secret`, ikke `-e` på
  kommandolinjen. **Ikke løst:** modelconfigens env-vars (inkl.
  `ANTHROPIC_API_KEY`) injiseres fortsatt med `-e` i `lib/sandbox.sh`.

## Rekkefølge

1. Spike: krun + rootless netns + pasta-hostmapping (avklaringer i 2 og 4).
   Avgjør runtime og hvordan modellserveren nås før resten bygges.
   ✅ Gjennomført 2026-10-09 (se «Avklart» i 2 og 4).
2. Punkt 1 og 4 sammen (Podman + nettverk per sesjon), med dagens
   `proxy.py` midlertidig. ✅ `e35f8af` (+ fiks `80b2605`, `9501dd8`,
   `e5b3352`); `proxy.py` er fremdeles midlertidig.
3. Punkt 3 (Smokescreen), slett `proxy.py`. ⏳ Ikke påbegynt.
4. Punkt 2 (runtime på som default). ✅ `eb59ba7`.
5. Punkt 5 (copy-in/patch-ut). ⏳ Ikke påbegynt.
6. Skriv om README (trusselmodell, arkitektur, self-test) og slett
   iptables/sudoers-seksjonene. ✅ `9501dd8` — README skrevet om for
   rootless podman; iptables/sudoers-seksjonene erstattet av
   «Host-isolasjon»-avsnittet (ingen iptables).

## Hva som slettes

- `etc/harrbjorn-sbx.sudoers` ✅ Slettet.
- `proxy/proxy.py` ❌ Eksisterer fremdeles (avventer punkt 3).
- iptables-, bridge-, sudo-docker- og label-hash-logikken i `lib/sandbox.sh`
  ✅ Fjernet.
- `HOST_ISOLATION`, `SBX_HOST_PORTS`, `--no-host-isolation` ✅ Fjernet
  (erstattet av eksplisitt `-H <port>`).
