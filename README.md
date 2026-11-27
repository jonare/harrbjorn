# harrbjorn — isolert sandbox for autonome agenter

## ADVARSEL: VIBEKODET TULLBALL
**Dette prosjektet er et vibekodet eksperiment! Det har kjente mangler, sårbarheter og problemer og kan ikke brukes i noe produksjonsmijø!**

## Oppsett

Et rootless Podman-oppsett der agenter (Claude Code CLI, pi) kan kjøre autonomt mot
en bind-mounted workspace, med begrenset mulighet til å skade hosten og
nettet (se [Trusselmodell](#trusselmodell) for hva som ikke dekkes). Ingen sudo noe
sted — hele isolasjonen kjører i brukerens rootless netns/userns. Én CLI
(`harrbjorn`), to usecases, hver med sitt oppstartsscript og sitt bilde:

| Usecase | CLI | Wrapper | Bilde | Tooling |
|---|---|---|---|---|
| Kodeagent | `harrbjorn code` | `run-code.sh` | `harrbjorn/code:latest` | node, python3, git, build-essential, claude + pi |
| Sikkerhetstesting | `harrbjorn security` | `run-pentest.sh` | `harrbjorn/pentest:latest` | ovenstående + nmap, sqlmap, hydra, ffuf, whatweb |

Isolasjonskjernen (per-sesjon nett, proxy, host-isolasjon via proxy-policy,
model-injeksjon, agent-HOME) deles via `lib/sandbox.sh`; wrappers er tynne og
setter bare `SBX_USECASE`/`SBX_IMAGE`/`SBX_CONTEXT`. Usecasen velger bildet
(verktøyene); hva økten får av nett og workdir, er capabilities fra
kommandolinja: `--net` (standard: bare modellen) og `--work` (standard:
overlay).

## Trusselmodell

**Angriperen er agenten selv:** en modell som er prompt-injisert av noe den
leser (mål, nettsider, repo-filer, verktøyoutput), eller en lokal modell
uten sikkerhetstrening som gjør destruktive ting. harrbjorn begrenser hva
en slik agent kan gjøre mot hosten og nettet.

**Betrodd** (utenfor angriperens kontroll): hostbrukeren og hosten;
`.env` (sources av bash på hosten, og har modellnøkkelen); modellserveren
og svarene dens (de styrer en agent med `bypassPermissions`); byggeinputene
(basebilder, npm- og apt-pakker); Smokescreen, socat-relayen,
podman/pasta/netavark og krun/libkrun; den eksterne proxyen med `-p`.

**Det harrbjorn gir:**

- **Nettverk:** ingen rå utgang. All trafikk går via proxyen (med `-p`:
  relayen og den eksterne proxyen, som har harrbjorns proxy som upstream),
  allowlisten håndheves (også med `-p`; åpen kun med `--net @all`), og
  private, loopback-, link-local- og CGNAT-adresser avvises med mindre en
  IP-literal i allowlisten eller trusted-settet slipper dem. Uten `--net` er
  bare modellendepunktet åpent. Hostens tjenester nås bare via
  trusted-portene (modellport, `--net host:PORT`).
- **Filsystem:** agenten skriver bare i `/work` (som standard en overlay:
  workdir på hosten røres ikke, se [Workdir](#workdir---work)), `/out`
  (med `--work ro`/`none`) og sin økts HOME
  (`.sandbox/agent-home/<usecase>/<basename>-<hash>/<økt>`); rotfilsystemet
  er read-only. En ny økt starter med tom HOME, så tidligere økter påvirker
  den ikke; `--resume` gjenbruker en økt eksplisitt (se
  [Økter](#økter-og-resume)).
- **Kjøring:** microVM via krun som standard (se isolasjonslag 5 for hva
  som gjelder inne i gjesten).

**Det harrbjorn ikke beskytter mot:**

- **Kode agenten legger i workdir.** Hosten kjører senere det som ligger
  der: `Makefile`, `package.json`-scripts, `.envrc`, IDE-oppgaver,
  pre-commit-hooks. I overlay-modus (default) kommer det som en patch du
  må lese før du bruker den; med `--work rw` skriver agenten rett i workdir.
- **`.git` utenfor den beskyttede katalogen (`--work rw`).** Bare en
  eksisterende `.git`-katalog øverst i workdir monteres read-only. En `.git` agenten
  lager (også i underkataloger, eller når workdir ikke er et repo), og en
  `.git`-fil (worktree/submodul), er skrivbar — git på hosten kjører det
  som plantes der (`core.fsmonitor`, hooks), f.eks. ved neste `git status`.
- **Exfiltrering via tillatte mål.** Allowlisten er ikke exfil-vern: GitHub
  (push/gist med egen token), LLM-API-er (med egen nøkkel),
  pakkeregistre og alle andre `--net`-mål kan motta data — også
  modellendepunktet. CONNECT gir vilkårlig TCP
  til en tillatt vert på alle porter (f.eks. SSH til github.com:22), ikke
  bare HTTP(S). Modellnøkkelen er lesbar i sandboxen.
- **Modellserveren.** Trusted-porten åpner hele tjenesten på porten, ikke
  bare modell-API-et — f.eks. beskytter vLLMs `--api-key` bare `/v1`-rutene.
- **Hosten via egne adresser.** En IP-literal i allowlisten for hostens LAN-
  eller offentlige adresse gjør hosten nåbar på de portene (link-local-
  adressen 169.254.1.2 avvises).
- **Upstream-reglene i den eksterne proxyen (`-p`).** harrbjorn stoler på at
  den eksterne proxyen sender *alt* videre til harrbjorns proxy.
  Kanarisjekken ved oppstart fanger en proxy som ikke er kjedet, men ikke
  upstream-regler som bare dekker noen verter: de andre når Burp direkte,
  også hostens loopback-tjenester, LAN og VPN.
- **Prosjektconfig i `/work`.** Claude Code kjører med `bypassPermissions`
  og `/work` er forhåndsgodkjent: hooks og MCP-config i prosjektets
  `.claude/settings.json` kjøres i sandboxen uten spørsmål, og følger
  workdir til neste økt.
- **Terminalen.** Interaktivt (`-it`) går gjestens utdata rett til
  hostterminalen, så escape-sekvenser (f.eks. OSC 52 til utklippstavla) er
  en kanal ut. Les patcher og logger med `less` eller `git apply --stat`,
  ikke `cat`.
- **Workdir-sperren er en kort nektliste:** `/`, `$HOME` og forelderne,
  og harrbjorn-repoet (med `.env`). Andre kataloger (f.eks.
  `~/.config`, `~/.ssh`, `~/.local/bin`) godtas — velg workdir med omhu.
- **Proxyen og relayen er ett punkt.** Kompromitteres Smokescreen eller
  socat-relayen, har angriperen reell utgang. De henger også på podmans
  standardnett og lytter på alle grensesnitt, så andre containere der kan
  bruke dem. Med `-p` er proxyen i tillegg publisert på hostens
  `127.0.0.1`, så alle prosesser på hosten kan bruke den.
- **Forsyningskjeden.** Basebildene og Claude Code-/pi-versjonene er
  pinnet, men transitive npm-avhengigheter og apt-pakker flyter og
  installeres med lifecycle-scripts. Byggene kjører med podmans vanlige
  runtime og fullt nett, utenfor proxyen.
- **Ressurser:** ingen diskkvote på workdir, økt-HOME-er eller overlay.
- **Tjenester på hosten** som sandboxen skal nå, må lytte utover loopback
  og er da nåbare fra LAN-et med mindre brannmuren stopper det (se
  [Host-tjenester](#host-tjenester)).

Model-backend:

Modellen er **pi** mot et OpenAI-kompatibelt endepunkt (vLLM, llama.cpp,
…), satt med `SBX_MODEL_*` i miljøet eller `.env` — aldri i repoet:

| Variabel | Innhold |
|---|---|
| `SBX_MODEL_BASE_URL` | Endepunktet med `/v1`, f.eks. `https://llm.example.net/v1` eller `http://localhost:8000/v1` |
| `SBX_MODEL` | Modell-ID-en serveren bruker (vLLM: `--served-model-name`) |
| `SBX_MODEL_API_KEY` | Nøkkelen (vLLM: `--api-key`); valgfri |
| `SBX_MODEL_CONTEXT_WINDOW`, `SBX_MODEL_MAX_TOKENS` | Valgfrie; ellers antar pi 128k/16k |

Variablene injiseres som env-vars i containeren — ingen fil monteres inn,
og verdiene står aldri i podmans argv. En loopback-base-URL
(`http://localhost:PORT`/`http://127.0.0.1:PORT`) skrives om til
`host.containers.internal` (podmans pasta-hostadresse, 169.254.1.2), slik at
containeren når hostens modellserver via det riktige grensesnittet.

Bildets init-steg (`code/sbx-init.sh`) skriver pi-modellkonfigen
(`~/.pi/agent/models.json` + `settings.json`) med `api:
"openai-completions"` og modellen som standard. pi sender nøkkelen som
`Authorization: Bearer`, som er det vLLMs `--api-key` sjekker. Nøkkelen
ligger aldri som tekst i `models.json` — den refereres med env-interpolering
(`${SBX_MODEL_API_KEY}`). vLLM må startes med `--enable-auto-tool-choice
--tool-call-parser <parser>` for at pi skal få verktøykall.

Claude Code ligger fortsatt i bildet, men får ingen modellinnstillinger:
logg inn i økta og åpne `--net @anthropic` hvis du vil bruke den.

**pi-extensions** bakes inn i bildet: `code/Dockerfile` tar env-argumentet
`PI_EXTENSIONS` (mellomromskoddet liste av pi-pakkessilder, f.eks.
`npm:pi-subagents`) og installerer dem ved build til det skrivebeskyttede
`/usr/local/share/pi/agent/npm`. `/home/agent` er en bindmount, så den
bakede store-en når aldri agent-HOME direkte — init-steget kopyerer den til
`~/.pi/agent/npm` ved hver kjør og smelter den sammen med eventuell
eksisterende store (både node_modules og storens `package.json`, slik at
pi-egne `npm install`-kjør ikke pruner de bakede pakker). Bildet er
source of truth: hver kjøring erstatter de bakede pakkene helt (også en
pakke agenten har endret eller byttet ut med en symlenke), og tvinger
bakede spesifikatorer og låsefila tilbake; agentens egne pakker beholdes. Tillegg: legg til kilden i `PI_EXTENSIONS`,
bygg på nytt (`--rebuild`).

For en lokal modell parses porten i base-URL-en ut og gjøres til en
**trusted upstream** i proxyens policy — et runtime-unntak som slår over
IP-filteret og DNS-rebinding-vernet for akkurat den porten, aldri en
allowlistpost. En ekstern base-URL åpner hosten i den; peker navnet på
private adresser (en intern modellserver over https), åpnes de adressene
navnet slår opp til på hosten ved oppstart — bare på modellporten (eksplisitt,
ellers 443/80), aldri loopback eller link-local.

Uten `SBX_MODEL_BASE_URL` starter sandboxen likevel, med en advarsel og uten
modellinnstillinger — f.eks. for bash, eller pi mot en leverandør du logger
inn hos i økta (åpne den med `--net`).

Merk: model-nøkkel/base-URL er lesbare fra innsiden av sandboxen (det er et
krav, ikke et hull) — hold ikke noe annet hemmelig i workspace-direktivet.

## Arkitektur

Per sesjon `S` (`S = <usecase>-<ts>-<pid>`):

```
host
└─ podman (rootless, ingen sudo)
   ├─ sbx-<S>-int    podman network --internal (ingen utgang, ingen host-route)
   ├─ sbx-<S>-proxy  pasta-standardnett (reell egress + host.containers.internal)
   │                 + sbx-<S>-int; forward-proxy :3128; allowlist eller åpen
   │                 utgang per sesjon; audit-logg alltid; per-sesjon
   │                 allowlist + resolv.conf bind-montert
   └─ sbx-<S>        sandbox (code- eller pentest); kun sbx-<S>-int;
                     HTTP(S)_PROXY→proxy:3128; --rm; keep-id uid 1000
```

Hver sesjon får sitt eget nettverk og sin egen proxy, så samtidige sesjoner
(code + pentest) har hver sin policy — ingen delt proxy, ingen
label-hash-sammenligning. Ressursene fjernes automatisk ved avslutning
(EXIT-trapp), og stoppede foreldreløse `sbx-*`-containere/nettverk fra
avbrutte kjør ryddes ved neste oppstart. En proxy eller relay som fortsatt
kjører fordi wrapperen ble drept med SIGKILL, ryddes ikke automatisk (se
[Fjerne](#fjerne-hvis-du-sletter-oppsettet-helt)).

Variant — ekstern proxy (`-p`): sesjonsnettet er fortsatt `--internal`.
En per-sesjon relay (`sbx-<S>-relay`) videresender kun til den eksterne
proxyen, modellporten og hostportene, og harrbjorns proxy er den eksterne
proxyens upstream: publisert på `127.0.0.1:3129`, kun på pasta-nettet, ikke
på sesjonsnettet (se [Ekstern proxy](#ekstern-proxy--p)):

```
sandbox ─ int ─ relay ─ Burp (host) ─ 127.0.0.1:3129 ─ sbx-<S>-proxy ─ mål
```

Isolasjonslag — uavhengige der det er mulig. Lag 2 og 3 er samme
komponent (Smokescreen), og proxyen er ett punkt for utgangspolicyen (med
`-p` i tillegg relayen og den eksterne proxyen); under krun gjelder lag 4 for VMM-prosessen, ikke i gjesten:

1. **Per-sesjon internal-nettverk** (rootless netavark) — kjernepolitikk:
   agenten kan fysisk ikke åpne en rå socket til internett. Nettverket lever
   i brukerens rootless netns, og gatewayen er ikke hostens nettverksstack —
   verken gateway-IP-hulet fra docker-æraen eller noen iptables-kjede trengs
   (se [Host-isolasjon](#host-isolasjon)). Verktøy som ignorerer
   proxy-env-vars feiler trygt — også med `-p`, der relayen er eneste
   vei ut (se [Ekstern proxy](#ekstern-proxy--p)).
2. **Proxy-utgang** — eneste utgang; allowlisten fra `--net` (pluss
   modellendepunktet) håndheves. Åpen utgang er `--net @all`, aldri en
   env-innstilling. Åpen modus: IP-filteret (loopback, link-local,
   private, CGNAT) og DNS-rebinding-vernet gjelder fortsatt, og alle
   beslutninger logges.
   CONNECT-tunnel for HTTPS (ingen MITM); hver beslutning (tillatt/avvist,
   med grunn) logges som JSON og lagres i `.sandbox/logs/<sesjon>.jsonl`.
3. **Hosten er link-local** — `host.containers.internal` (169.254.1.2)
   avvises av IP-filteret, både som navn og som IP-literal i allowlisten.
   Hostens tjenester nås via trusted-settet (modellport + `host:PORT`), se
   [Host-tjenester](#host-tjenester). Unntak: hostens LAN- eller offentlige
   adresse som IP-literal, og med `-p` det den eksterne proxyen når uten å
   gå via harrbjorns proxy (upstream-regler som ikke dekker alt).
4. **Container-hardening** — `--read-only`, `--cap-drop ALL`,
   `--security-opt no-new-privileges`, keep-id user-namespace (hostbrukeren
   blir uid 1000 i containeren, så bindmounter eies av hostbrukeren utenfor),
   tmpfs over /tmp og /var/tmp, agent-HOME per økt
   (`.sandbox/agent-home/<usecase>/<basename>-<hash>/<økt>` — flat nøkkel på
   usecase + workdir, så en underkatalogs HOME aldri ligger inne i
   forelderens; en ny økt får tom HOME, kun `--resume` gjenbruker en;
   Claude Code sitt onboarding/settings-state, seedes ved hver kjør av
   bildets init-steg (`code/sbx-init.sh`) INNE i containeren — aldri av en
   hostprosess: mellom kjør eier agenten agent-HOME-katalogen og kan plante
   symlenker der (f.eks. `~/.claude -> /work/...`), og en host-side seeder
   ville fulgt dem og skrevet der lenken pekte; inne i containeren når
   skrivene kun monteringer agenten allerede fullt kontrollerer.
   Seeden setter onboarding fullført, `/work`-trust-dialog acceptert
   og permission-mode til `bypassPermissions`
   (containernens claude kjører altså uten `--dangerously-skip-permissions`-flagg;
   gjelder KUN denne user-level-configen i agent-HOME — hostens `~/.claude`
   røres ikke), slik at first-run-vizarden ikke vises; den skriver i tillegg
   pi-modellkonfig (`~/.pi/agent/models.json` + `settings.json`) fra
   `SBX_MODEL_*` (nøkkelen kun som `${SBX_MODEL_API_KEY}`-interpolering),
   og kopyerer de bakede pi-extensions fra
   `/usr/local/share/pi/agent/npm` til `~/.pi/agent/npm`
   (se «Model-backend» over); pids/memory/cpu-limit.
5. **MicroVM via krun** (default-runtime) — sandboxen (og proxyen) kjører
   som microVM-er på KVM: eget kernel, egne prosesser, eget /tmp. Inne i
   gjesten finnes ingen containergrense; grensen er gjestekjernen mot
   VMM-prosessen, og et utbrudd derfra lander i en rootless hostprosess
   uten caps, med seccomp og `no-new-privileges`. `SBX_RUNTIME` velger runtime (`krun` default / `runsc` /
   eksplisitt `crun`) — wrapperen feiler ved oppstart hvis valgt runtime
   (resp. `/dev/kvm` for krun) mangler; aldri stille fallback til `crun`.
   Under krun gjelder lag 4 for VMM-prosessen på hosten (ingen caps,
   `no-new-privileges`, seccomp), ikke inne i gjesten: der får en
   root-prosess alle capabilities, og verken `no-new-privileges` eller
   `nosuid` stopper setuid-binærer i bildet. `--user 1000` gjelder, så
   agenten starter uten caps. Root i gjesten gir likevel ikke mer på
   hosten: all fil- og nett-I/O går gjennom VMM-prosessen, og read-only-
   monteringer og `--read-only` holder også mot root i gjesten. `--memory`
   blir gjestens RAM; `--pids-limit` begrenser VMM-trådene, ikke gjestens
   prosesser; `--cpus` begrenser ikke antall vCPU-er; `--sysctl` når ikke
   gjestekjernen. `runsc` er ikke testet.

## Setup

```bash
cp .env.example .env                        # valgfrie limit/overrides
```

Krever Podman (rootless) + crun (standard på Fedora), samt KVM + krun
(`dnf install crun-krun`) — krun-microVM-er er default-runtime; uten KVM
settes `SBX_RUNTIME=crun` i `.env` (vanlig container, eksplisitt valgt).
Ingen sudo, ingen daemon. Alt annet (bilder bygges ved behov, per-sesjon
nettverk, proxy) settes opp automatisk av `harrbjorn` (resp. wrapperne) —
idempotent.

CLI-en krever ingen installasjon: kjør `./harrbjorn` i repo-rotten, eller
symlink den inn i en mappe som allerede er i PATH (`~/.local/bin/harrbjorn`),
eller legg repo-rotten i PATH. Autocomplete (bash) eval-eres i `~/.bashrc`:

```bash
eval "$(harrbjorn completion)"
```

## Bruk

```bash
harrbjorn code <args>      # kodeagent-sandbox (run-code.sh)
harrbjorn security <args>  # sikkerhetstest-sandbox (run-pentest.sh)
```

`<args>` går uendret til usecase-wrapperen; den første non-flag-argen starter
kommandoen, så `--` er valgfri. Med ingen kommando åpnes en interaktiv bash i
workdir (default). Wrapperne kan også kjøres direkte:

```bash
./run-code.sh    [-w <workdir>] [--flagg] [--] [kommando [args...]]
./run-pentest.sh [-w <workdir>] [--flagg] [--] [kommando [args...]]
```

Flagg (identiske i begge):

| Flag | Effekt |
|---|---|
| `-w DIR` | Workdir (`/work`, se `--work`). Default: gjeldende katalog. |
| `--work MODE` | Hva sandboxen får av workdir: `overlay` (default; workdir urørt, endringene som patch), `ro` (read-only + skrivbar `/out`), `none` (ikke montert; `/out`), `rw` (skrivbar, `.git` read-only) eller `rw+git` (også `.git` skrivbar; wrapperen advarer). Se [Workdir](#workdir---work). |
| `--net LISTE` | Hva økten når av nett (kan gjentas, kommaseparert): `vert`, `IP[:port]`, `host:PORT` (hosttjeneste), `@sett`, `@sti/til/fil` eller `@all` (åpen utgang). Uten `--net`: bare modellendepunktet. Se [Nett](#nett---net). |
| `-p host:port` | Ekstern forward-proxy (f.eks. Burp Suite; den må lytte utover loopback, se [Host-tjenester](#host-tjenester)) med harrbjorns proxy som upstream på `127.0.0.1:3129` — allowlisten gjelder. Nettet er fortsatt `--internal`, og en relay videresender kun til proxyen, modellporten og hostportene. Fail-closed — se [Ekstern proxy](#ekstern-proxy--p). |
| `--ca-cert FILE` | Ekstra CA-sertifikat (PEM/DER, kan gjentas) å stole på i bildebyggene og i sandboxen, f.eks. roten til en TLS-inspiserende mellomboks. Se [Ekstra CA](#ekstra-ca---ca-cert). |
| `--resume[=ID]` | Gjenbruk HOME-en til sist brukte økt (eller økt `ID`) i samme workdir og usecase, som den var. Uten flagget får økten en ny, tom HOME. Se [Økter](#økter-og-resume). |
| `--sessions` | List øktene for workdir + usecase (ID, sist brukt, størrelse) og avslutt. |
| `--rebuild` | Bygg bilder + proxy på nytt (claude/pi låses ved build; se Begrensninger). |

Miljøvariabler (`env`/`.env`, vinner over wrapper-default):

| Variable | Verdi | Effekt |
|---|---|---|
| `SBX_OPEN_NETWORK` | — | Fjernet og ignoreres (med advarsel): nettet følger `--net`, åpen utgang er `--net @all`. |
| `SBX_LOCALE` | `nb_NO.UTF-8` | Terminal-lokal (injectert som `LANG`). Norsk tastatur å/ø/æ i interaktiv modus. Default. |
| | `en_US.UTF-8` | Nøytralt UTF-8-alternativ. Må være generert i bildet (se `code/Dockerfile`). |
| `SBX_MEMORY` / `SBX_CPUS` / `SBX_PIDS` | f.eks. `4g` / `2` / `1024` | Ressursgrenser for sandboxen (wrapper-defaults i `.env.example`). |
| `SBX_MODEL_BASE_URL`, `SBX_MODEL`, `SBX_MODEL_API_KEY` | URL, ID, nøkkel | pi-modellen (OpenAI-kompatibel), se «Model-backend». Valgfrie: `SBX_MODEL_CONTEXT_WINDOW`, `SBX_MODEL_MAX_TOKENS`. |
| `SBX_RUNTIME` | `krun` | OCI-runtime for sandbox (og proxy): `krun` (microVM via KVM, default) / `runsc` (gVisor) / `crun` (eksplisitt — aldri stille fallback). Wrapperen feiler ved oppstart hvis valgt runtime (resp. `/dev/kvm` for krun) mangler. |
| `SBX_CA_CERTS` | — | Kolonseparerte CA-filer, som `--ca-cert` (praktisk i `.env` når nettet alltid krever det). |
| `SBX_UPSTREAM_PORT` | `3129` | Porten harrbjorns proxy publiseres på (`127.0.0.1`) som den eksterne proxyens upstream med `-p`. Fast, så upstream-oppsettet i Burp kan stå; én `-p`-sesjon om gangen per port. |
| `SBX_KEEP_SESSIONS` | `10` | Antall økt-HOME-er som beholdes per workdir + usecase (sist brukte); eldre slettes ved oppstart av en ny. En økt i bruk slettes aldri. |

Proxyen startes per sesjon — wrapperen viser navnet
(`sbx-<usecase>-<ts>-<pid>-proxy`) ved start.

Eksempler — kodeagent (kjører i gjeldende workdir; `-w` for annen workdir):

```bash
# Interaktiv bash i gjeldende workdir (default — ingen kommando)
harrbjorn code

# Interaktiv Claude Code-sesjon i et prosjekt
cd ~/proj && harrbjorn code claude

# Énkjørs-agenter (pi: samme modellkonfig som claude)
harrbjorn code -w ~/proj claude -p "Refaktoriser auth-modulen"
harrbjorn code -w ~/proj pi -p "Refaktoriser auth-modulen"

# Pakkeregistre + GitHub, og agenten skriver rett i workdir
harrbjorn code --net @dev --work rw claude

# Åpen utgang og skrivbar workdir i et annet prosjekt
harrbjorn code -w ../grepa --net @all --work rw

# Via ekstern proxy (Burp lytter på *:4321; dens CA auto-installas)
harrbjorn code -p 127.0.0.1:4321 claude -p "Test via Burp"
```

Eksempler — sikkerhetstesting (målene åpnes med `--net` ved kjør):

```bash
# Interaktiv bash i gjeldende workdir (default — ingen kommando)
harrbjorn security

# agent-drevet pentest (i målets workspace; pi: samme modellkonfig som claude)
harrbjorn security -w ~/pentest --net 192.168.50.10:8080,192.168.50.10:443 \
  claude -p "Portscan og test 192.168.50.10"
harrbjorn security -w ~/pentest --net @../scope pi -p "Test målene i scope"

# direkte verktøy (HTTP-vedkommende verktøy kun — se Begrensninger)
harrbjorn security -w ~/pentest --net 192.168.50.10:8080 curl -sI http://192.168.50.10:8080/
harrbjorn security -w ~/pentest --net 192.168.50.10:8080 sh -c \
  'sqlmap --proxy "$HTTP_PROXY" -u "http://192.168.50.10:8080/admin" --batch'

# Via ekstern proxy (Burp med harrbjorns proxy som upstream): allowlisten gjelder
harrbjorn security --net @npm,target.example.com:8080 -p localhost:4321
```

Utgress-audit:

```bash
podman logs -f sbx-<usecase>-<ts>-<pid>-proxy     # live; navnet skrives ut av wrapperen
jq . .sandbox/logs/<usecase>-<ts>-<pid>.jsonl      # etter sesjonen (også krasjede sesjoner)
# Smokescreen logger én JSON-linje per beslutning: mål, tillatt/avvist og grunn.
```

## Nett (`--net`)

Uten `--net` er bare **modellendepunktet** åpent. Det avledes av
`SBX_MODEL_BASE_URL` og er aldri en `--net`-post:

| `SBX_MODEL_BASE_URL` | Åpent |
|---|---|
| lokal (`http://localhost`/`127.0.0.1:PORT`) | modellporten på hosten (trusted, se [Host-tjenester](#host-tjenester)) |
| ekstern | hosten i URL-en (en IP-literal beholder porten); et navn på private adresser får dem i tillegg, bare på modellporten |
| ikke satt | ingenting |

Alt annet åpnes eksplisitt per økt med `--net LISTE` (kan gjentas,
kommaseparert), aldri via env/`.env`:

| Post | Betyr |
|---|---|
| `vert` | alle porter (Smokescreens ACL har ingen portdimensjon) |
| `vert:port` | **også alle porter**; wrapperen advarer |
| `*.example.com` | subdomener av `example.com`, ikke `example.com` selv |
| `10.1.2.3` | IP-literal på alle porter (pentest-mål; private ranges tillatt) |
| `10.1.2.3:port`, `[fd00::1]:port` | kun den porten **for private/loopback/link-local IP-er** (IP-filteret håndhever porten). For en offentlig IP gjelder posten alle porter, og wrapperen advarer; avtalt port-scope mot offentlige mål må håndheves et annet sted. |
| `host:PORT` | hosttjeneste på `host.containers.internal:PORT`, se [Host-tjenester](#host-tjenester) |
| `@navn` | sett: `~/.config/harrbjorn/net/<navn>`, ellers `net/<navn>` i repoet |
| `@sti/til/fil` | sett fra fil (posten inneholder `/`; relativ til gjeldende katalog) |
| `@all` | åpen utgang: alle offentlige mål (IP-filteret og loggingen gjelder fortsatt); kan bare kombineres med `host:PORT` |

Settene i `net/`:

| Sett | Innhold |
|---|---|
| `@anthropic` | Claude Code: API-et, innlogging og CLI-infrastruktur |
| `@github` | `github.com`, API, arkiver, rå filer, release-nedlastinger |
| `@npm` | `registry.npmjs.org` |
| `@pypi` | `pypi.org`, `files.pythonhosted.org` |
| `@maven` | Maven Central |
| `@debian` | Debian-speilene (apt) |
| `@dev` | `@github @npm @pypi @maven @debian` — ikke `@anthropic`, modellen er åpen uansett |

En settfil har én eller flere poster per linje (`#`-kommentarer) og kan
inkludere andre `@navn`, men ikke `@all` eller `@sti`: det som åpnes
utover navngitte sett, står på kommandolinja. Egne sett legges i
`~/.config/harrbjorn/net/` og vinner over repoets med samme navn; hvilken
fil som ble brukt, logges ved start. **Ingen settfil kan ligge i workdir**
(heller ikke via symlenke): agenten skriver der og kunne utvidet neste økt.
Legg scope-fila for en pentest ved siden av workdir, f.eks. `--net
@../scope`.

Postene slås sammen til en per-sesjon-allowlist
(`.sandbox/allowlist-<S>.txt`), så samtidige sesjoner ikke deler en fil.

IP-filter og DNS-rebinding-vern (Smokescreen): proxyen resolver navnet selv
og kobler til den resolverte adressen, så et navn kan ikke peke om mellom
sjekk og kobling. Loopback, link-local, private (10/8, 172.16/12,
192.168/16, fc00::/7), CGNAT (100.64/10) og uspesifiserte adresser avvises —
i begge moduser — med mindre en IP-literal i allowlisten (eller
trusted-settet) slipper akkurat den adressen (og porten) gjennom. Det
innebærer at `host.containers.internal` (169.254.1.2, link-local) aldri
slippes gjennom av allowlisten — verken som navn eller IP-literal (den
hoppes over med advarsel) — host-tjenester kun via trusted-settet
(nedenfor).

## Host-tjenester

Sandboxen kan nå spesifikke tjenester på selve hosten (her: en lokal
modellserver) — men kun via `host.containers.internal` (podmans pasta-
hostadresse, 169.254.1.2) og kun via proxyens **trusted-sett**:

1. **Modellserveren** legges til automatisk: porten parses fra en lokal
   `SBX_MODEL_BASE_URL` (se ovenfor).
2. **Andre host-tjenester** (testinstanser på hosten) legges til eksplisitt,
   port for port, med `host:PORT`: `harrbjorn code -w ~/proj --net host:8080,host:9443 claude ...`.
   Hver port blir en trusted upstream for `host.containers.internal:<port>` —
   et eksplisitt, port-for-port-runtime-unntak, aldri en allowlistpost.
   Hosten er link-local, så IP-filteret og DNS-rebinding-vernet avslår den
   uansett hva allowlisten (eller open-modus) sier: `host:PORT` er veien til
   host-tjenester, i begge moduser (se [Trusselmodell](#trusselmodell) om
   hostens andre adresser).

Merk: tjenester på hosten må lytte på et grensesnitt utover loopback
(f.eks. `0.0.0.0` eller LAN-IP), ikke bare `127.0.0.1`: pasta mapper
`host.containers.internal` til hostens primæradresse. **Da er de også
nåbare fra LAN-et** med mindre brannmuren stopper det — Fedora
Workstations default-sone (`FedoraWorkstation`) slipper inn 1025–65535.
En modellserver, hosttjeneste eller Burp-listener (`-p`) på `*:<port>`
er dermed åpen for alle på samme nett (Burp: en åpen proxy inn til alt
hosten når, inkl. VPN). Steng porten mot eksterne grensesnitt, f.eks. med
en firewalld-regel som kun slipper til lokale kilder, eller bind tjenesten
til en adresse som ikke ligger på det eksterne grensesnittet.

Trusted-porten åpner hele tjenesten på porten, ikke bare modell-API-et:
en modellserver med administrasjons-endepunkter (f.eks. nedlasting/sletting
av modeller, pause/vekting) eller nøkler til skytjenester er nåbar for
agenten i sin helhet. vLLMs `--api-key` beskytter bare `/v1`-rutene; sett
en filtrerende proxy foran om dette betyr noe for deg.

```bash
# fra sandboxen:
curl http://host.containers.internal:8000/v1/models   # OK (modellserver, auto-trusted)
curl --max-time 5 http://host.containers.internal:22/ # 502 (link-local, aldri i allowlist)
```

## Ekstern proxy (`-p`)

`-p host:port` sender containerens utgang gjennom en ekstern
forward-proxy (f.eks. Burp Suite på `127.0.0.1:4321`), med harrbjorns egen
proxy som dens upstream:

```
sandbox ─ int ─ relay ─ Burp (host) ─ 127.0.0.1:3129 ─ sbx-<S>-proxy ─ mål
```

Oppsett i Burp (én gang): Settings > Network > Connections > Upstream
proxy servers: destination host `*`, proxy `127.0.0.1`, port `3129`
(`SBX_UPSTREAM_PORT`). Regelen gjelder all trafikk Burp sender — også din
egen nettleser via Burp — og den feiler når ingen `-p`-sesjon kjører; bruk
gjerne et eget Burp-prosjekt for agentøkter.

- **Sesjonsnettet er fortsatt `--internal`.** Proxy-env-vars er bare et
  hint en fiendtlig agent kan ignorere, så «ingen rå utgang» kan ikke
  avhenge av dem. En per-sesjon **relay** (`harrbjorn/sbx-relay`, socat,
  read-only, uid 65534 — root i gjesten under krun, se lag 5) på internal-nettet + pasta-nettet er sandboxens
  eneste vei ut, og videresender kun faste porter: den eksterne proxyen,
  modellporten og hostportene. Agenten når ingenting annet direkte —
  verken internett, LAN eller andre host-porter.
- **Allowlisten gjelder** — Burp sender videre til harrbjorns proxy, som
  slår opp og kobler til målet selv: ACL, IP-filter og audit-logg gjelder
  som uten `-p` (`--net`, også `@all`), og Burps
  egne DNS-oppslag spiller ingen rolle. Proxyen er publisert kun på
  hostens `127.0.0.1` (ikke LAN) og sitter ikke på sesjonsnettet, så
  sandboxen når den bare gjennom Burp. Trafikk til modellporten og
  hostportene går direkte gjennom relayen og logges ikke.
- **Fail-closed** — før noe sesjonsressurs lages, TCP-prober wrapperen
  `host:port` fra hosten (timeout 5 s). Svarer ingenting: hard feil,
  sesjonen startes ikke — ingen fallback. Før sandboxen startes sender
  wrapperen en forespørsel til et tilfeldig kanarinavn gjennom den
  eksterne proxyen fra hosten; dukker den ikke opp i harrbjorns proxy-logg
  (Burp er ikke kjedet), avbrytes sesjonen. Kanarien fanger ikke
  upstream-regler som bare dekker noen verter.
- **Host-tjenester via relayen** — i sandboxen peker
  `host.containers.internal` på relayen (`--add-host`) og står i
  `NO_PROXY`, så modellserveren og hosttjenester nås på samme URL som
  ellers, direkte gjennom relayen og ikke via den eksterne proxyen (som
  kjører på hosten og ikke kan løse navnet). En hostport lik proxyens
  port avvises hvis proxyen ikke selv ligger på hosten.
- **Burp CA auto-installas** — svarer proxyen med et parsbart
  X.509-sertifikat på `http://<proxy>/cert` (Burp Suites selvsignerte CA),
  henter init-steget i containeren (`code/sbx-init.sh`) det gjennom relayen
  (`--noproxy`), slår det sammen med system-CA-storen og eksporterer
  resultatet som `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` /
  `NODE_EXTRA_CA_CERTS` / `CURL_CA_BUNDLE` / `GIT_SSL_CAINFO` (bunken i
  `~/.sbx-ca-bundle.pem`, 0600, hentes på nytt hver kjøring). Serveres det
  ingen CA, skippes dette stillferdig. CA-en hentes over ren HTTP og
  tillites for all TLS — bruk `-p` bare mot en proxy du kontrollerer.
- **LAN-eksponering** — en proxy på hosten må lytte på et grensesnitt
  relayen når (ikke bare `127.0.0.1`), se [Host-tjenester](#host-tjenester).

```bash
# Burp lytter på *:4321, upstream 127.0.0.1:3129 (målene med --net):
harrbjorn code -p 127.0.0.1:4321 claude -p "Test via Burp"
harrbjorn security -p 127.0.0.1:4321 claude -p "Test målet via Burp"
```

## Økter og resume

Hver kjøring er en økt med sin egen HOME
(`.sandbox/agent-home/<usecase>/<basename>-<hash>/<økt-ID>`). Uten
`--resume` er HOME-en tom og seedes fra bildet: tidligere økters
config, hooks, auto-minne, cacher og installerte verktøy påvirker den
ikke. Med `--resume` gjenbrukes HOME-en til sist brukte økt i samme workdir
og usecase — som den var, inkludert det agenten installerte; `--resume=ID`
velger en bestemt (`--sessions` lister dem). Samtalen gjenopptas med
agentens eget flagg:

```bash
harrbjorn code claude                       # ny økt
harrbjorn code --resume claude -c           # fortsett siste samtale i siste økt
harrbjorn code --sessions                   # list økter
harrbjorn code --resume=code-1795694761-1318814 pi -r
```

- Rekkefølgen («sist brukt») og en lås per økt ligger på hosten, ved siden
  av øktene og utenfor det som monteres — agenten kan ikke påvirke hvilken
  økt `--resume` velger. Samme økt kan ikke kjøres to ganger samtidig.
- Resume tar med alt økta hadde, også det et mål eventuelt plantet
  (prompt injection i samtalen, hooks, verktøy). Det er det eksplisitte
  valget; en ny økt er ren.
- Capabilities arves ikke: hver kjøring får dem fra sin egen kommandolinje
  (`--net`, `--work`). Hva en HOME har hatt (unionen over øktene som har
  brukt den), lagres på hosten ved siden av øktene (`.<ID>.caps`). Gir en
  `--resume` HOME-en mer enn det, f.eks. en HOME fra `--net @all`
  gjenopptatt med `--work rw`, advarer wrapperen før noe startes og
  lister utvidelsene (`work rw`, `@all`, `host:PORT`, nye poster). Etter
  `@all` regnes navn som dekket, IP-literaler ikke (private adresser er
  stengt også i åpen modus). Økter fra før dette ble lagret, gir en egen
  advarsel ved første resume.
- Workdir (`/work`) er ikke en del av økta: med `--work rw` ser også neste
  nye økt endringer der (f.eks. prosjektets `.claude/settings.json` eller
  `CLAUDE.md`). I overlay-modus (default) når de workdir bare når du
  bruker patchen.
- Økter fra før denne ordningen ligger på den gamle stien og vises ikke.

## Workdir (`--work`)

`--work MODE` bestemmer hva sandboxen får av workdir (`-w`, ellers
gjeldende katalog). Workdir er alltid definert, også med `none`: den er
nøkkelen til øktene og prosjektets identitet, og workdir-sperren gjelder i
alle moduser.

| Modus | `/work` | Ut av sandboxen |
|---|---|---|
| `overlay` (default) | overlay over workdir; workdir urørt | patch (`.sandbox/overlay/<sesjon>.patch`) |
| `ro` | workdir read-only | `/out` (`.sandbox/out/<sesjon>/`) |
| `none` | ikke montert (tom) | `/out` (`.sandbox/out/<sesjon>/`) |
| `rw` | workdir skrivbar, eksisterende `.git` øverst read-only | direkte i workdir |
| `rw+git` | workdir skrivbar, også `.git` (wrapperen advarer) | direkte i workdir, også hooks og git-config |

Med `ro` og `none` får økten en tom, skrivbar `/out`. Etter økten skrives
stien og innholdet ut; skrev agenten ingenting der, fjernes katalogen.

```bash
harrbjorn code claude                        # overlay
harrbjorn code --work ro claude -p "Gå gjennom koden, skriv funnene til /out/review.md"
harrbjorn code --work rw claude              # agenten skriver rett i workdir
```

### Overlay

`/work` monteres som en overlay over workdir med
en upperdir per sesjon (`.sandbox/overlay/<sesjon>/`). Agenten ser og
endrer workdir som vanlig, men alle skriv havner i upperdir: workdir på
hosten — også `.git` — røres ikke og relabeles ikke (SELinux).

Etter økten bygger en nettløs hjelpecontainer (samme runtime og bilde) en
git-patch av endringene med `lib/overlay-diff.sh` — med eget `GIT_DIR`, så
ingenting agenten skrev (`.git/config`, hooks, attributter med drivere)
konfigurerer git. Patchen lagres som `.sandbox/overlay/<sesjon>.patch`,
upperdir slettes, og hosten skriver ut diffstat, apply-kommando og en
liste over filer hosten kjører eller følger (`.envrc`, `Makefile`,
`package.json`, IDE-, CI- og agent-config, kjørbare filer, symlenker).
Lista er en hjelp ved gjennomgangen, ikke en garanti: den fanger ikke alt
som kan kjøres (f.eks. låsefiler, `*.config.js`, testfiler), og binære
differ kan ikke leses:

```bash
harrbjorn code claude
# …
git -C <workdir> apply .sandbox/overlay/<sesjon>.patch
```

`git apply` nekter stier gjennom `.git` og forbi symlenker.

Hva det løser:

- `rm -rf /work` og annen ødeleggelse rammer bare upperdir.
- Hooks og git-config agenten skriver når aldri hostens `.git`.
- Endringene blir et konkret artefakt å se over før hosten kjører dem.

Hva det ikke løser:

- Det du bruker av patchen, kjører hosten: en ondsinnet `.envrc` eller
  `Makefile` er like farlig etter `git apply` — gjennomgangen er vernet.
- Lesing: agenten ser hele workdir (som før).
- Diskkvote: upperdir er ubegrenset.

Kjente ulemper:

- Hosten ser ingenting under økten (editor, `git status`, tester), og neste
  økt ser ikke forrige økts arbeid før patchen er brukt.
- Endringer i workdir fra hosten mens økten kjører gir udefinert
  oppførsel i overlayen.
- `rename(2)` av en katalog som fantes fra før gir `EXDEV`; `mv` faller
  tilbake til kopi, verktøy som ikke håndterer det, feiler.
- Første skriv til en fil kopierer hele fila til upperdir.
- Filer ignorert av `.gitignore` (bygg, `node_modules`) og nestede repoer
  er ikke med i patchen; agentens commits heller ikke.
- Avbrytes sesjonen før patchen er bygd, ligger endringene igjen i
  upperdir (`podman unshare rm -rf` for å fjerne).

## Ekstra CA (`--ca-cert`)

I et nett der en TLS-inspiserende mellomboks signerer HTTPS på nytt med
egen CA, feiler både bildebygg (npm, GitHub-nedlastinger) og HTTPS fra
sandboxen. `--ca-cert FILE` (kan gjentas) eller `SBX_CA_CERTS=fil:fil`
(env/`.env`) legger CA-ene til:

- Filene valideres med openssl før sesjonen starter (PEM — også bunter —
  eller DER).
- **Bildebygg:** CA-ene går inn som build-secret (`podman build --secret
  id=sbx_ca`) og brukes bare av stegene som henter over HTTPS; de skrives
  aldri til et lag. Bygget skjer når et bilde mangler eller med `--rebuild`.
- **Sandbox:** CA-ene sendes som env (`SBX_EXTRA_CA_PEM`, verdien utenfor
  kommandolinjen), og init-steget lager en samlet bunt (systemlager + CA-ene)
  i `$HOME/.sbx-ca-bundle.pem`. `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
  `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` og `GIT_SSL_CAINFO` peker på den;
  Burp-CA-en med `-p` havner i samme bunt.
- Proxyen trenger dem ikke: den tunnelerer TLS uten å terminere det.

```bash
harrbjorn code --rebuild --ca-cert /path/to/root-ca.crt true   # bygg
harrbjorn code --ca-cert /path/to/root-ca.crt claude
```

## Host-isolasjon

Docker-oppsettet behøvde en sudo-iptables-kjede mot gateway-IP-hulet til
`--internal`-bridgen (172.28.0.1 = hosten). Under rootless Podman er det
hullet borte: per-sesjons internal-nettverk lever i brukerens rootless
netns, og gatewayen er ikke hostens nettverksstack. Fra sandboxen er
hostadressen (169.254.1.2) verken løselig eller rutebar
(`Network is unreachable`) — hosten nås aldri direkte, med eller uten
proxy-env-vars. Hostens tjenester nås via proxyens trusted-sett (se
[Host-tjenester](#host-tjenester); om hostens andre adresser, se
[Trusselmodell](#trusselmodell)).

Det er ingen iptables, ingen sudo og ingen sudoers-drop-in i dette oppsettet
(`etc/harrbjorn-sbx.sudoers`, `--no-host-isolation`/`HOST_ISOLATION` og
`SBX_HOST_PORTS` er fjernet).

## Self-test (end-til-end)

```bash
# CLI-inngangen: workdir = cwd, ingen -w, ingen --
mkdir -p /tmp/sbx-test && cd /tmp/sbx-test
touch cwd-marker
harrbjorn code sh -c 'test "$(pwd)" = /work && test -e /work/cwd-marker && rm /work/cwd-marker && echo CLI-CWD-OK'
cd -

mkdir -p /tmp/sbx-test
./run-code.sh -w /tmp/sbx-test -- sh -c '
  set -x
  uname -r                                                   # ≠ host-kernel (microVM; krun)
  curl -sI "$SBX_MODEL_BASE_URL/models" | head -1             # via proxy → OK (modellendepunktet)
  curl -sI https://example.com | head -1                       # → avvist (ikke i --net)
  curl -s --max-time 5 http://host.containers.internal/ || true      # host port 80 → 502 (IP-filteret)
  curl -s --max-time 5 http://host.containers.internal:8000/ || true # modellserver → OK (auto-trusted)
  curl -s --max-time 5 "http://[::ffff:127.0.0.1]/" || true     # loopback → 502 (IP-filteret)
  echo x > /etc/test || true                            # → Read-only file system
  echo x > /work/test && stat -c "%U" /work/test         # OK, i overlayen (patch etterpå)
'
podman logs "$(podman ps --filter name=sbx- --format '{{.Names}}' | grep -m1 proxy)" | tail
# én JSON-linje per beslutning: modellhosten tillatt,
# host.containers.internal:80 avvist (link-local, ikke trusted)

# host:PORT: eksplisitt host-port (annen port enn modellserveren)
./run-code.sh -w /tmp/sbx-test --net host:9443 -- sh -c '
  curl -s --max-time 5 http://host.containers.internal:9443/ || true   # OK hvis hosten lytter
  curl -s --max-time 5 http://host.containers.internal:8080/ || true   # 502 (ikke åpnet)
'

# Sett og åpen utgang
./run-code.sh -w /tmp/sbx-test --net @pypi -- sh -c '
  curl -sI https://pypi.org | head -1            # → OK (@pypi)
  curl -sI https://github.com | head -1          # → avvises (ikke i --net)
'
./run-code.sh -w /tmp/sbx-test --net @all -- curl -sI https://example.com   # → OK (åpen utgang)

# Valgt runtime mangler → hard feil, ingen stille fallback til crun
SBX_RUNTIME=runsc ./run-code.sh -w /tmp/sbx-test -- sh -c 'true' 2>&1 \
  | grep -F 'error: SBX_RUNTIME=runsc'                         # → match (exit 1)

# Agent kjører via proxy
./run-code.sh -w /tmp/sbx-test -- pi -p "Svar bare: OK"
# (pi bruker models.json-configurationen som sbx-init.sh skriver fra
# SBX_MODEL_*)

# -p: ekstern proxy — fail-closed hvis porten ikke svarer (ingen sesjon, ingen fallback)
./run-code.sh -w /tmp/sbx-test -p 127.0.0.1:9 -- sh -c 'true' 2>&1 \
  | grep -F 'error: -p: no forward proxy answering'   # → match (exit 1)

# -p: Burp uten upstream-regel → kanarien kommer aldri fram (exit 1)
./run-code.sh -w /tmp/sbx-test -p 127.0.0.1:4321 -- true 2>&1 \
  | grep -F 'canary never arrived'                       # → match

# -p: working path (Burp lytter på *:4321, upstream 127.0.0.1:3129)
./run-code.sh -w /tmp/sbx-test -p 127.0.0.1:4321 --net example.com -- sh -c '
  echo "$HTTP_PROXY"                     # → http://sbx-<S>-relay:4321
  ls -l ~/.sbx-ca-bundle.pem 2>/dev/null # → 0600, system-CAs + Burp CA
  curl -sI https://example.com | head -1 # → OK (TLS via Burp CA; --net)
  curl -sI https://example.org | head -1 # → avvist av harrbjorns proxy
'
```

Pentest-variant (målet via `--net`, ingenting annet):

```bash
./run-pentest.sh -w /tmp/sbx-test --net example.com -- sh -c '
  curl -sI https://example.com | head -1   # → OK (--net)
  curl -sI https://pypi.org | head -1      # → avvises (ikke i --net)
  curl -s --max-time 5 http://10.0.0.1/ || true   # → 502 (RFC1918-mål uten --net)
'
podman logs "$(podman ps --filter name=sbx- --format '{{.Names}}' | grep -m1 proxy)" | tail
```

Agent-HOME-isolasjon (én HOME per økt; kun `--resume` gjenbruker en):

```bash
mkdir -p /tmp/sbx-a
./run-code.sh -w /tmp/sbx-a -- sh -c 'echo marker > ~/.cross'
./run-code.sh -w /tmp/sbx-a -- sh -c 'test ! -e ~/.cross && echo FRESH'
# → FRESH (ny økt: tom HOME, uansett workdir/usecase)
./run-code.sh -w /tmp/sbx-a --resume -- sh -c 'test ! -e ~/.cross && echo FRESH-AGAIN'
# → FRESH-AGAIN (--resume tar sist brukte økt — den forrige, som var tom)
./run-code.sh -w /tmp/sbx-a --sessions            # list; --resume=<ID> for den første
```

## Begrensninger

- Allowlist-håndhevingen ligger i proxy-prosessen. Mitigering: Smokescreen
  (stripe) — et Go-forward-proxy som er bygget til dette formålet,
  static-binær fra pinnet release (SHA256-verifisert ved bilde-build),
  `FROM scratch`-bilde, read-only, uprivilegert (uid 65534 i containeren),
  ingen publiserte porter. Den lytter på alle grensesnitt, så den nås fra
  sesjonens internal-nettverk og fra podmans standardnett.
  Kjernesiden («sandboxen når bare proxyen») er nettverksarkitekturens
  garant.
- Utgang er **proxy-kun**, ikke «proxy-fremst»: rå TCP uten proxy
  feiler trygt (ingen route), også med `-p` (relayen videresender kun
  faste porter). Med `-p` gjelder audit-loggen også (harrbjorns proxy er
  Burps upstream), unntatt trafikken til modellporten og hostportene,
  som går direkte gjennom relayen. Audit-loggen
  registrerer beslutninger (mål, tillatt/avvist, grunn), ikke innhold.
- Åpen utgang (`--net @all`) er et bevisst valg per økt: alle beslutninger
  logges fortsatt, og IP-filteret (loopback, link-local, private, CGNAT),
  DNS-rebinding-vernet og container-hardening holder likevel. Det er ikke
  exfil-vern — det er heller ikke settene.
- Proxy-utgang betyr at **HTTP-vedkommende verktøy** i pentest-sandboxen er
  de som når målene: curl, python, git m.fl. bruker
  `HTTP(S)_PROXY`-env-vars automatisk. **sqlmap** må få proxyen eksplisitt:
  `--proxy "$HTTP_PROXY"` (inne i sandboxen, f.eks. via `sh -c '…'`). **nmap/hydra** (rått socket) når **ikke**
  målene i denne arkitekturen — sikkerhetstesting er agent-/HTTP-drevet.
- Fire bilder: `harrbjorn/code:latest`, `harrbjorn/pentest:latest` (bygges
  `FROM` code, så code bygges alltid først), `harrbjorn/sbx-proxy:latest` og
  `harrbjorn/sbx-relay:latest` (kun med `-p`).
  Bildene bygges automatisk ved første kjør — men **bare hvis bildet mangler**.
  Allerede bygd bilder bygges ikke på nytt, så endringer i kilde som bakker inn
  i bildene (`code/sbx-init.sh`, `code/Dockerfile`, `pentest/Dockerfile`,
  `proxy/Dockerfile`, `relay/`) **fungerer ikke** inntil du bygger med `--rebuild`. Et
  stiltstående bilde er altså stale selv om kilden har endret seg.
- Fordi `harrbjorn/pentest:latest` bygger `FROM harrbjorn/code:latest`, plukker
  pentest endringer i code-bildet (f.eks. `code/sbx-init.sh`) opp **kun** når
  pentest bygges på nytt *etter* code. Endrer du noe som bakker inn i begge
  bildene, bygg **begge** på nytt (`harrbjorn code --rebuild` og
  `harrbjorn security --rebuild`) i den rekkefølgen — code først.
- Claude Code- og pi-versjonene låses ved bilde-build (auto-update er slått
  av); gjelder begge sandbox-bildene — bygg på nytt med `--rebuild` for
  oppdateringer. Pi-extensions følger samme lås: listen står i
  `code/Dockerfile` (`PI_EXTENSIONS`) og endres ved rebuild; agenten kan
  installere/oppdatere egne pakker i en økts HOME (`pi install`/
  `pi update`) — de følger med ved `--resume`, men bakede pakker erstattes
  ved hver kjøring.
- keep-id user-namespace (`keep-id:uid=1000`): hostbrukeren — uansett uid —
  blir uid 1000 i containeren, så workspace-filer eies av hostbrukeren
  utenfor. (tmpfs-monter slipper `uid=`/`gid=`-oppsjørs — rootless
  podman avviser dem i det hele tatt.)
- Per-sesjonstate under `.sandbox/`: sammensmeltet allowlisten, per-sesjons
  proxy-policy (Smokescreen `proxy.yaml` + `acl.yaml`), per-sesjons proxy
  `resolv.conf`, agent-HOME per økt (de `SBX_KEEP_SESSIONS`, default 10,
  sist brukte per workdir+usecase beholdes; `rm -rf .sandbox` fjerner
  alt), og per-sesjons
  audit-log fra proxyen (allow/deny-beslutninger som JSON) under
  `logs/<session>.jsonl`. `.env` (nøkler) er git-ignoreret.
- Bindmounts får `:z` (SELinux-relabel) — nødvendig på SELinux-hosts
  (f.eks. Fedora) for mounter fra home-direkter. Det relabeler workdir og
  økt-HOME varig til en delt containerlabel (ingen SELinux-separasjon
  mellom økter); med `--work overlay` (default) og `none` relabeles ikke
  workdir.
- krun-microVM-er (default-runtime): ~90 MB minne per VM (sandbox + proxy)
  og oppstarts-tak i sekunder; bindmounter går via virtio-fs.
  `SBX_RUNTIME=crun` (eksplisitt) fjerner VM-laget — en container-escape
  lander da på host-kernelen.

## Fjerne (hvis du sletter oppsettet helt)

Wrapperens egen opprydding fjerner sesjonens proxy + nettverk ved avslutning
og foreldreløse `sbx-*`-ressurser ved neste oppstart. For full fjerning:

```bash
podman rm -f $(podman ps -a --filter name=sbx- --format '{{.Names}}' 2>/dev/null)
podman network ls --format '{{.Name}}' | grep -E '^sbx-.*-int$' | xargs -r -n1 podman network rm
podman rmi harrbjorn/code:latest harrbjorn/pentest:latest harrbjorn/sbx-proxy:latest harrbjorn/sbx-relay:latest
rm -rf .sandbox
```
