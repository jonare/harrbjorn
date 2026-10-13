# harrbjorn — isolert sandbox for autonome agenter

## ADVARSEL: VIBEKODET TULLBALL
**Dette prosjektet er et vibekodet eksperiment! Det har kjente mangler, sårbarheter og problemer og kan ikke brukes i noe produksjonsmijø!**

## Oppsett

Et rootless Podman-oppsett der agenter (Claude Code CLI) kan kjøre autonomt mot
en bind-mounted workspace, uten å kunne skade hostsystemet. Ingen sudo noe
sted — hele isolasjonen kjører i brukerens rootless netns/userns. To usecases,
hver med sitt oppstartsscript og sitt bilde:

| Usecase | Wrapper | Bilde | Tooling |
|---|---|---|---|
| Kodeagent | `run-code.sh` | `harrbjorn/code:latest` | node, python3, git, build-essential, åpen nettverksutgang som standard |
| Sikkerhetstesting | `run-pentest.sh` | `harrbjorn/pentest:latest` | ovenstående + nmap, sqlmap, hydra, ffuf, whatweb; mål legges til med `-a` ved kjør |

Isolasjonskjernen (per-sesjon nett, proxy, host-isolasjon via proxy-policy,
model-injeksjon, agent-HOME) deles via `lib/sandbox.sh`; wrappers er tynne og
setter bare `SBX_USECASE`/`SBX_IMAGE`/`SBX_CONTEXT`/`SBX_ALLOWLIST_DEFAULT`.

## Trusselmodell

Den innsperrede agenten skal:

- **kun** skrive i den spesifiserte workspace-direktivet (rw-bindmount til `/work`)
  og sin egen agent-HOME (persistert under `.sandbox/agent-home/<usecase>/<workdir>`)
- **ikke** dele filsystem-state med andre instanser: agent-HOME-nøkkelen er
  usecase + workdir, så ulik workdir — eller ulik usecase i samme workdir —
  gir helt separate HOME-er (maven cache, agent-logger, o.l. deles aldri)
- **kun** ha nettverksutgang via forward-proxyen over http(s):
  - **kodeagent**: åpen utgang som standard (`SBX_OPEN_NETWORK=1`);
    `SBX_OPEN_NETWORK=0` gir klassisk host(:port)-whitelist
  - **sikkerhetstesting**: kun allowlistede mål (legges til med `-a`,
    inkl. IP-literaler)
- **ikke** nå hosten utover tillatne porter (modellserver-porten automatisk,
  andre porter kun med eksplisitt `-H`)
- **ikke** kunne skade hosten via filsystemet (read-only rootfs, unprivilegert
  keep-id user-namespace)

Model-backend:

Sandboxen rebruker **hostens egen Claude Code-modelconfig**
(`SBX_CLAUDE_CONFIG`, standard `~/claude.sh`) som kilde til
`ANTHROPIC_*`/`CLAUDE_CODE_*`-env-vars — samme modell, effort, kontekstvindu
og nøkkel som på hosten. Den eneste endringen er at en loopback-
`ANTHROPIC_BASE_URL` (`localhost`/`127.0.0.1`) skrives om til
`host.containers.internal` (podmans pasta-hostadresse, 169.254.1.2), slik at
containeren når hostens modellserver via det riktige grensesnittet. Configen
injiseres som env-vars i containeren (standalone) — ingen fil monteres inn.
Kun `export ...`-linjene leses, så filens kommentarer og avsluttende
`claude`-kommando ignoreres.

Porten i base-URL-en parsest ut og gjøres til en **trusted upstream** i
proxyens policy (`SBX_PROXY_TRUSTED`) — et runtime-unntak som slår over
alt-avvis-settet og DNS-rebinding-vernet, aldri en allowlistpost. Bytter du
port på hosten, trenger bare config-fila å oppdateres.

- **Sant Anthropic API**: endre hostconfigen (eller peke `SBX_CLAUDE_CONFIG`
  et annet sted / fjerne den og sette `ANTHROPIC_API_KEY` i `.env`);
  trafikken går via de allowlistede API-hosts.

Merk: model-nøkkel/base-URL er lesbare fra innsiden av sandboxen (det er et
krav, ikke et hull) — hold ikke noe annet hemmelig i workspace-direktivet.

## Arkitektur

Per sesjon `S` (`S = sbx-<usecase>-<ts>-<pid>`):

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
(EXIT-trapp), og foreldreløse `sbx-*`-containere/nettverk fra avbrutte kjør
ryddes ved neste oppstart.

Isolasjonslag — hvert holder selv hvis ett feiler:

1. **Per-sesjon internal-nettverk** (rootless netavark) — kjernepolitikk:
   agenten kan fysisk ikke åpne en rå socket til internett. Nettverket lever
   i brukerens rootless netns, og gatewayen er ikke hostens nettverksstack —
   verken gateway-IP-hulet fra docker-æraen eller noen iptables-kjede trengs
   (se [Host-isolasjon](#host-isolasjon)). Verktøy som ignorerer
   proxy-env-vars feiler trygt.
2. **Proxy-utgang** — eneste utgang; kodeagent har åpen utgang som standard
   (`SBX_OPEN_NETWORK=1`), sikkerhetstesting håndhever host(:port)-allowlisten.
   Åpen modus: permanent-avvis-settet (loopback, 0/8, 169.254/16) og
   DNS-rebinding-vern gjelder fortsatt, og all trafikk logges.
   CONNECT-tunnel for HTTPS (ingen MITM), logger `ALLOWED`/`DENIED` til stdout.
3. **Hosten er link-local** — `host.containers.internal` (169.254.1.2) ligger
   i proxyens permanent-avvis-sett, også for IP-literaler. Hosten er altså
   aldri nåbar via allowlist eller åpen modus; trusted-settet (modellport +
   `-H`) er den eneste veien (se [Host-tjenester](#host-tjenester)).
4. **Container-hardening** — `--read-only`, `--cap-drop ALL`,
   `--security-opt no-new-privileges`, keep-id user-namespace (containerens
   uid 1000 = hostens uid 1000, så bindmounter eies av hostbrukeren utenfor),
   tmpfs over /tmp og /var/tmp, persistent agent-HOME
   (`.sandbox/agent-home/<usecase>/<workdir>` — nøkkelset på usecase + workdir,
   kun instanser i samme workdir OG usecase deler state;
   Claude Code sitt onboarding/settings-state, seedes ved hver kjør av
   bildets init-steg (`code/sbx-init.sh`) INNE i containeren — aldri av en
   hostprosess: mellom kjør eier agenten agent-HOME-katalogen og kan plante
   symlenker der (f.eks. `~/.claude -> /work/...`), og en host-side seeder
   ville fulgt dem og skrevet der lenken pekte; inne i containeren når
   skrivene kun monteringer agenten allerede fullt kontrollerer.
   Seeden setter onboarding fullført, `/work`-trust-dialog acceptert,
   modelconfigens API-key approvet og permission-mode til `bypassPermissions`
   (containernens claude kjører altså uten `--dangerously-skip-permissions`-flagg;
   gjelder KUN denne user-level-configen i agent-HOME — hostens `~/.claude`
   røres ikke), slik at first-run-vizarden ikke vises),
   pids/memory/cpu-limit.

## Setup

```bash
cp .env.example .env                        # valgfrie limit/overrides
```

Krever bare Podman (rootless) + crun — standard på Fedora; ingen sudo, ingen
daemon. Alt annet (bilder bygges ved behov, per-sesjon nettverk, proxy)
settes opp automatisk av `run-code.sh` / `run-pentest.sh` — idempotent.

## Bruk

```bash
./run-code.sh    -w <workdir> [--flagg] -- <kommando> [args...]
./run-pentest.sh -w <workdir> [--flagg] -- <kommando> [args...]
```

Flagg (identiske i begge):

| Flag | Effekt |
|---|---|
| `-w DIR` | Workspace (bindmount til `/work`, rw). Obligatorisk. |
| `-a host[:port]` | Ekstra allowlist-oppføring (kan gjentas). Bare relevant i allowlist-modus. |
| `-H port` | Tillat en host-tjeneste på angitt port (kan gjentas): `host.containers.internal:<port>` blir en trusted upstream. Den eneste veien til hosten — se [Host-tjenester](#host-tjenester). |
| `-f FIL` | Ekstra allowlist-fil (samme format som default-allowlisten). Bare relevant i allowlist-modus. |
| `--rebuild` | Bygg bilder + proxy på nytt (Claude Code-låses ved build; se Begrensninger). |

Miljøvariabler (`env`/`.env`, vinner over wrapper-default):

| Variable | Verdi | Effekt |
|---|---|---|
| `SBX_OPEN_NETWORK` | `1` | Åpen utgang: proxyen logger all trafikk, men slår allowlisten. |
| | `0` | Allowlisten håndheves (default-allowlisten + `-a`/`-f`). |
| `SBX_LOCALE` | `nb_NO.UTF-8` | Terminal-lokal (injectert som `LANG`). Norsk tastatur å/ø/æ i interaktiv modus. Default. |
| | `en_US.UTF-8` | Nøytralt UTF-8-alternativ. Må være generert i bildet (se `code/Dockerfile`). |
| `SBX_MEMORY` / `SBX_CPUS` / `SBX_PIDS` | f.eks. `4g` / `2` / `1024` | Ressursgrenser for sandboxen (wrapper-defaults i `.env.example`). |
| `SBX_CLAUDE_CONFIG` | sti | Modelconfig (default `~/claude.sh`). |

Default: `code=1` (åpen), `pentest=0` (allowlist). Proxyen skrives opp per
sesjon — wrapperen viser navnet (`sbx-<usecase>-<ts>-<pid>-proxy`) på
start.

Eksempler — kodeagent:

```bash
# Interaktiv Claude Code-sesjon i et prosjekt
./run-code.sh -w ~/proj -- claude

# Énkjørs-agenter
./run-code.sh -w ~/proj -- claude -p "Refaktoriser auth-modulen"

# Vanlig dev-bruk
./run-code.sh -w ~/proj -- bash
```

Eksempler — sikkerhetstesting (målene ligger IKKE i default-allowlisten,
legges til med `-a` ved kjør):

```bash
# agent-drevet pentest
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 -a 192.168.50.10:443 \
  -- claude -p "Portscan og test 192.168.50.10"

# direkte verktøy (HTTP-vedkommende verktøy kun — se Begrensninger)
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 -- curl -sI http://192.168.50.10:8080/
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 \
  -- sqlmap --proxy http://sbx-pentest-<ts>-<pid>-proxy:3128 -u "http://192.168.50.10:8080/admin" --batch
```

Utgress-audit:

```bash
podman logs -f sbx-<usecase>-<ts>-<pid>-proxy     # navnet skrives ut av wrapperen
# 2026-01-01 12:00:00,000 client=<sandbox-ip> method=CONNECT target=192.168.50.10:443 action=ALLOWED
# 2026-01-01 12:00:01,000 client=<sandbox-ip> method=CONNECT target=example.com:443 action=DENIED reason=not in allowlist
```

## Allowlist-format

Én oppføring pr. linje, `#`-kommentarer:

- `host` → porter 80 og 443
- `host:port` → den porten bare
- `*.example.com` → subdomene-vildekart
- `10.1.2.3[:port]` → IP-literal (pentest-mål; private ranges tillatt)

To default-filer, én per usecase:

- `allowlist.code.default` — Claude Code-hosts + dev/PM-hosts (npm, pypi,
  github, apt). Brukes bare når kodeagent kjører med `SBX_OPEN_NETWORK=0`
  (default er åpen utgang).
- `allowlist.pentest.default` — kun Claude Code/LLM-hostene (bildet er
  prebygd); pentest-mål legges alltid til med `-a`/`-f` ved kjør.

`-a` og `-f` slås sammen med default-fila til en per-sesjon-allowlisten
(`.sandbox/allowlist-<S>.txt`), så samtidige sesjoner ikke deler en fil.

DNS-rebinding-vern: for hostname-oppføringer resolveres navnet før kobling,
og koblingen avslås hvis noen av adressene ligger i reserverte range
(10/8, 172.16/12, 192.168/16, 0/8, 127/8, 169.254/16, fc00::/7, fe80::/10,
::1/128, ::/128 samt de legacy sbx-subnettene 172.28.0.0/24 + 172.29.0.0/24) —
et hostname kan aldri peke mot disse. 0/8, 127/8, 169.254/16 (og ::1, ::)
avvises alltid, også for IP-literal-oppføringer. Det innebærer at
`host.containers.internal` (169.254.1.2, link-local) aldri kan slippes
gjennom som allowlistpost — host-tjenester kun via trusted-settet
(nedenfor).

## Host-tjenester

Sandboxen kan nå spesifikke tjenester på selve hosten (her: OpenAI-kompatibel
modellserver) — men kun via `host.containers.internal` (podmans pasta-
hostadresse, 169.254.1.2) og kun via proxyens **trusted-sett**:

1. **Modellserveren** legges til automatisk: porten parsest fra
   modelconfigens `ANTHROPIC_BASE_URL` (se ovenfor).
2. **Andre host-tjenester** (testinstanser på hosten) legges til eksplisitt,
   port for port, med `-H`: `./run-code.sh -w ~/proj -H 8080 -H 9443 -- ...`.
   Hver port blir en trusted upstream for `host.containers.internal:<port>` —
   et eksplisitt, port-for-port-runtime-unntak, aldri en allowlistpost.
   Hosten er link-local, så alt-avvis-settet og DNS-rebinding-vernet avslår
   den uansett hva allowlisten (eller open-modus) sier: `-H` er den eneste
   veien, i begge moduser.

Merk: tjenester på hosten må lytte på et grensesnitt utover loopback
(f.eks. `0.0.0.0` eller LAN-IP), ikke bare `127.0.0.1`.

```bash
# fra sandboxen:
curl http://host.containers.internal:8000/v1/models   # OK (modellserver, auto-trusted)
curl --max-time 5 http://host.containers.internal:22/ # 502 (link-local, aldri i allowlist)
```

## Host-isolasjon

Docker-oppsettet behøvde en sudo-iptables-kjede mot gateway-IP-hulet til
`--internal`-bridgen (172.28.0.1 = hosten). Under rootless Podman er det
hullet borte: per-sesjons internal-nettverk lever i brukerens rootless
netns, og gatewayen er ikke hostens nettverksstack. Fra sandboxen er
hostadressen (169.254.1.2) verken løselig eller rutebar
(`Network is unreachable`) — hosten nås aldri direkte, med eller uten
proxy-env-vars. Den eneste veien til hosten er proxyens trusted-sett
(se [Host-tjenester](#host-tjenester)).

Det er ingen iptables, ingen sudo og ingen sudoers-drop-in i dette oppsettet
(`etc/harrbjorn-sbx.sudoers`, `--no-host-isolation`/`HOST_ISOLATION` og
`SBX_HOST_PORTS` er fjernet).

## Self-test (end-til-end)

```bash
mkdir -p /tmp/sbx-test
./run-code.sh -w /tmp/sbx-test -- sh -c '
  set -x
  curl -sI https://api.anthropic.com | head -1                 # via proxy → OK
  curl -sI https://example.com | head -1                       # → OK (åpen utgang som standard)
  curl -s --max-time 5 http://host.containers.internal/ || true      # host port 80 → 502 (alt-avvis)
  curl -s --max-time 5 http://host.containers.internal:8000/ || true # modellserver → OK (auto-trusted)
  curl -s --max-time 5 "http://[::ffff:127.0.0.1]/" || true     # loopback → 502 (alt-avvis)
  echo x > /etc/test || true                            # → Read-only file system
  echo x > /work/test && stat -c "%U" /work/test         # OK, eies av hostbrukeren (keep-id)
'
podman logs "$(podman ps --filter name=sbx- --format '{{.Names}}' | grep -m1 proxy)" | tail
# ... target=api.anthropic.com:443 action=ALLOWED
# ... target=host.containers.internal:80 action=DENIED reason=...

# -H: eksplisitt host-port (annen port enn modellserveren)
./run-code.sh -w /tmp/sbx-test -H 9443 -- sh -c '
  curl -s --max-time 5 http://host.containers.internal:9443/ || true   # OK hvis hosten lytter
  curl -s --max-time 5 http://host.containers.internal:8080/ || true   # 502 (ikke -H-et)
'

# Allowlist-modus for kodeagent
SBX_OPEN_NETWORK=0 ./run-code.sh -w /tmp/sbx-test -- sh -c '
  curl -sI https://api.anthropic.com | head -1   # → OK (i allowlist.code.default)
  curl -sI https://example.com | head -1         # → avvises (ikke i allowlisten)
'

# Agent kjører via proxy
./run-code.sh -w /tmp/sbx-test -- claude -p "Svar bare: OK"
# (containernens claude kjører med bypassPermissions som default — se
# «Container-hardening»; ingen --dangerously-skip-permissions nødvendig)
```

Pentest-variant (mål i allowlisten via `-a`, dev-hosts skal være borte):

```bash
./run-pentest.sh -w /tmp/sbx-test -a example.com -- sh -c '
  curl -sI https://example.com | head -1   # → OK (-a tillatt)
  curl -sI https://pypi.org | head -1      # → avvises (dev-hosts borte i pentest-default)
  curl -s --max-time 5 http://10.0.0.1/ || true   # → 502 (RFC1918-mål uten -a)
'
podman logs "$(podman ps --filter name=sbx- --format '{{.Names}}' | grep -m1 proxy)" | tail
```

Agent-HOME-isolasjon (nøkkel = usecase + workdir; ulik nøkkel deler ingen
filsystem-state):

```bash
mkdir -p /tmp/sbx-a /tmp/sbx-b
./run-code.sh -w /tmp/sbx-a -- sh -c 'echo marker > ~/.cross; mkdir -p ~/.m2; echo x > ~/.m2/marker'
./run-code.sh -w /tmp/sbx-b -- sh -c 'test ! -e ~/.cross && test ! -e ~/.m2/marker && echo ISOLATED'
# → ISOLATED (annen workdir, samme usecase: egen agent-HOME)
./run-pentest.sh -w /tmp/sbx-a -- sh -c 'test ! -e ~/.cross && echo ISOLATED-USECASE'
# → ISOLATED-USECASE (samme workdir, annen usecase: egen agent-HOME)
./run-code.sh -w /tmp/sbx-a -- sh -c 'test -e ~/.cross && test -e ~/.m2/marker && echo SHARED'
# → SHARED (samme workdir+usecase: state overlever mellom kjør)
```

## Begrensninger

- Allowlist-håndhevingen ligger i proxy-prosessen. Mitigering: ~450 linjer
  kun-stdlib Python, read-only, uprivilegert (uid 65534 i containeren), ingen
  publiserte porter, kun nåbar fra sesjonens internal-nettverk. Kjernesiden
  («kun proxy kan nås») er nettverksarkitekturens garant.
- Utgang er **proxy-kun**, ikke «proxy-fremst»: rå TCP uten proxy
  feiler trygt (ingen route).
- Åpen utgang (`SBX_OPEN_NETWORK=1`) er et bevisst default for kodeagenten:
  all trafikk logges fortsatt, permanent-avvis-settet (loopback, 0/8,
  169.254/16), DNS-rebinding-vern og container-hardening holder likevel.
  `SBX_OPEN_NETWORK=0` gir klassisk allowlist-utgang.
- Proxy-utgang betyr at **HTTP-vedkommende verktøy** i pentest-sandboxen er
  de som når målene: curl, python, git m.fl. bruker
  `HTTP(S)_PROXY`-env-vars automatisk. **sqlmap** må få proxyen eksplisitt:
  `--proxy http://sbx-pentest-<ts>-<pid>-proxy:3128` (navnet skrives ut av
  wrapperen). **nmap/hydra** (rått socket) når **ikke**
  målene i denne arkitekturen — sikkerhetstesting er agent-/HTTP-drevet.
- Tre bilder: `harrbjorn/code:latest`, `harrbjorn/pentest:latest` (bygges
  `FROM` code, så code bygges alltid først) og `harrbjorn/sbx-proxy:latest`.
  Bildene bygges automatisk ved første kjør og med `--rebuild`.
- Claude Code-versjonen låses ved bilde-build (auto-update er slått av);
  gjelder begge sandbox-bildene — bygg på nytt med `--rebuild` for
  oppdateringer.
- keep-id user-namespace: containerens uid 1000 = hostens uid 1000, så
  workspace-filer eies av hostbrukeren utenfor. Kjøres hostbrukeren under
  et annet uid, juster `--userns=keep-id` og `--user` i `lib/sandbox.sh`.
  (tmpfs-monter slipper `uid=`/`gid=`-oppsjørs — rootless
  podman avviser dem i det hele tatt.)
- Per-sesjonstate under `.sandbox/`: sammensmeltet allowlisten, per-sesjons
  proxy `resolv.conf`, agent-HOME per workdir+usecase (akkumuleres —
  ryddes manuelt per key, `rm -rf .sandbox` fjerner alt). `.env` (nøkler)
  er git-ignoreret.
- Bindmounts får `:z` (SELinux-relabel) — nødvendig på SELinux-hosts
  (f.eks. Fedora) for mounter fra home-direkter.

## Fjerne (hvis du sletter oppsettet helt)

Wrapperens egen opprydding fjerner sesjonens proxy + nettverk ved avslutning
og foreldreløse `sbx-*`-ressurser ved neste oppstart. For full fjerning:

```bash
podman rm -f $(podman ps -a --filter name=sbx- --format '{{.Names}}' 2>/dev/null)
podman network ls --format '{{.Name}}' | grep -E '^sbx-.*-int$' | xargs -r -n1 podman network rm
podman rmi harrbjorn/code:latest harrbjorn/pentest:latest harrbjorn/sbx-proxy:latest
rm -rf .sandbox
```
