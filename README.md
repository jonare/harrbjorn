# harrbjorn — isolert sandbox for autonome agenter

Et Docker-oppsett der agenter (Claude Code CLI) kan kjøre autonomt mot en
bind-mounted workspace, uten å kunne skade hostsystemet. To usecases, hver
med sitt oppstartsscript og sitt bilde:

| Usecase | Wrapper | Bilde | Tooling |
|---|---|---|---|
| Kodeagent | `run-code.sh` | `harrbjorn/code:latest` | node, python3, git, build-essential, åpen nettverksutgang som standard |
| Sikkerhetstesting | `run-pentest.sh` | `harrbjorn/pentest:latest` | ovenstående + nmap, sqlmap, hydra, ffuf, whatweb; mål legges til med `-a` ved kjør |

Isolasjonskjernen (nettverk, proxy, iptables, model-injeksjon, agent-HOME)
deles via `lib/sandbox.sh`; wrappers er tynne og setter bare
`SBX_USECASE`/`SBX_IMAGE`/`SBX_CONTEXT`/`SBX_ALLOWLIST_DEFAULT`.

## Trusselmodell

Den innsperrede agenten skal:

- **kun** skrive i den spesifiserte workspace-direktivet (rw-bindmount til `/work`)
  og sin egen agent-HOME (persistert under `.sandbox/agent-home`)
- **kun** ha nettverksutgang via forward-proxyen over http(s):
  - **kodeagent**: åpen utgang som standard (`SBX_OPEN_NETWORK=1`);
    `SBX_OPEN_NETWORK=0` gir klassisk host(:port)-whitelist
  - **sikkerhetstesting**: kun allowlistede mål (legges til med `-a`,
    inkl. IP-literaler)
- **ikke** nå hosten utover tillatne porter (`SBX_HOST_PORTS`)
- **ikke** kunne skade hosten via filsystemet (read-only rootfs, unprivilegert bruker)

Model-backend:

Sandboxen rebruker **hostens egen Claude Code-modelconfig**
(`SBX_CLAUDE_CONFIG`, standard `~/claude.sh`) som kilde til
`ANTHROPIC_*`/`CLAUDE_CODE_*`-env-vars — samme modell, effort, kontekstvindu
og nøkkel som på hosten. Den eneste endringen er at en loopback-
`ANTHROPIC_BASE_URL` (`localhost`/`127.0.0.1`) skrives om til
bridge-gatewayen `172.28.0.1`, slik at containeren når hostens modellserver
via det riktige grensesnittet. Configen injiseres som env-vars i containeren
(standalone) — ingen fil monteres inn. Kun `export ...`-linjene leses, så
filens kommentarer og avsluttende `claude`-kommando ignoreres.

Porten i base-URL-en parsest ut og legges automatisk til i
`SBX_HOST_PORTS` (iptables) og allowlisten (`172.28.0.1:<port>`), så bytter
du port på hosten trenger bare config-fila å oppdateres.

- **Sant Anthropic API**: endre hostconfigen (eller peke `SBX_CLAUDE_CONFIG`
  et annet sted / fjerne den og sette `ANTHROPIC_API_KEY` i `.env`);
  trafikken går via de allowlistede API-hosts.

Merk: model-nøkkel/base-URL er lesbare fra innsiden av sandboxen (det er et
krav, ikke et hull) — hold ikke noe annet hemmelig i workspace-direktivet.

## Arkitektur

```
host
└─ docker
   ├─ sbx-internal  (bridge, --internal, 172.28.0.0/24 — ingen utgang)
   ├─ sbx-egress    (bridge, 172.29.0.0/24)
   ├─ sbx-proxy     (internal + egress; forward-proxy; allowlist eller
   │                  åpen utgang per usecase, audit-logg alltid)
   └─ sandbox       (code- eller pentest-sandbox; kun internal;
                     HTTP(S)_PROXY→sbx-proxy:3128, --rm)
```

To bilder, én del: `harrbjorn/code:latest` og `harrbjorn/pentest:latest`
kjører begge på `sbx-internal` og deler én `sbx-proxy` og nettverkene.
Allowlisten og utgangsmoden (`SBX_OPEN_NETWORK`) er usecase-spesifikke
kjøreparametere, så bytter du usecase endres hashen og proxyen restartes
automatisk (label-hash-sammenligning). Containerenavnet viser usecase:
`sbx-code-<ts>` / `sbx-pentest-<ts>`.

Isolasjonslag — hvert holder selv hvis ett feiler:

1. **Internal-nettverk** — kjernepolitikk: agenten kan fysisk ikke åpne
   en rå socket til internett. Verktøy som ignorerer proxy-env-vars feiler trygt.
2. **Proxy-utgang** — eneste utgang; kodeagent har åpen utgang som standard
   (`SBX_OPEN_NETWORK=1`), sikkerhetstesting håndhever host(:port)-allowlisten.
   Åpen modus: permanent-avvis-settet (loopback, 0/8, 169.254/16) og
   DNS-rebinding-vern gjelder fortsatt, og all trafikk logges.
   CONNECT-tunnel for HTTPS (ingen MITM), logger ALLOWED/DENIED til stdout.
3. **Host-iptables** (sudo, idempotent) — blockerer gateway-IP-holet: selv et
   `--internal`-nettverk slupper gateway-IP (172.28.0.1 = hosten) gjennom til
   containeren. Kun rettet mot sandbox-bridgen. Enkelte tcp-porter på hosten
   kan slippes gjennom med `SBX_HOST_PORTS` (se [Host-tjenester](#host-tjenester)).
4. **Container-hardening** — `--read-only`, `--cap-drop ALL`,
   `--security-opt no-new-privileges`, uid 1000, tmpfs over /tmp og /var/tmp,
   persistent agent-HOME (`.sandbox/agent-home` — Claude Code sitt
   onboarding/settings-state, pre-seedet ved hver kjør: onboarding fullført,
   `/work`-trust-dialog acceptert, modelconfigens API-key approvet — så
   first-run-vizarden hoppes over helt), pids/memory/cpu-limit.

## Setup

```bash
sudo systemctl enable --now docker          # første gang
cp .env.example .env                        # valgfrie limit/overrides
```

Alt annet (bilder, nettverk, proxy, iptables) settes opp automatisk av
`run-code.sh` / `run-pentest.sh` — idempotent.

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
| `-f FIL` | Ekstra allowlist-fil (samme format som default-allowlisten). Bare relevant i allowlist-modus. |
| `--no-host-isolation` | Hopp over sudo-iptables-laget (default: på). |
| `--rebuild` | Bygg bilde + proxy på nytt (Claude Code-låses ved build; se Begrensninger). |

Miljøvariabel (`env`/`.env`, vinner over wrapper-default):

| Variable | Verdi | Effekt |
|---|---|---|
| `SBX_OPEN_NETWORK` | `1` | Åpen utgang: proxyen logger all trafikk, men slår allowlisten. |
| | `0` | Allowlisten håndheves (default-allowlisten + `-a`/`-f`). |

Default: `code=1` (åpen), `pentest=0` (allowlist). Bytter modus gir ny
hash → proxyen restartes automatisk.

Eksempler — kodeagent:

```bash
# Interaktiv Claude Code-sesjon i et prosjekt
./run-code.sh -w ~/proj -- claude --dangerously-skip-permissions

# Énkjørs-agenter
./run-code.sh -w ~/proj -- claude -p "Refaktoriser auth-modulen" --dangerously-skip-permissions

# Vanlig dev-bruk
./run-code.sh -w ~/proj -- bash
```

Eksempler — sikkerhetstesting (målene ligger IKKE i default-allowlisten,
legges til med `-a` ved kjør):

```bash
# agent-drevet pentest
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 -a 192.168.50.10:443 \
  -- claude -p "Portscan og test 192.168.50.10" --dangerously-skip-permissions

# direkte verktøy (HTTP-vedkommende verktøy kun — se Begrensninger)
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 -- curl -sI http://192.168.50.10:8080/
./run-pentest.sh -w ~/pentest -a 192.168.50.10:8080 \
  -- sqlmap --proxy http://sbx-proxy:3128 -u "http://192.168.50.10:8080/admin" --batch
```

Utgress-audit (pentest-bruk):

```bash
docker logs -f sbx-proxy
# 2026-01-01 12:00:00,000 client=172.28.0.2 method=CONNECT target=192.168.50.10:443 action=ALLOWED
# 2026-01-01 12:00:01,000 client=172.28.0.2 method=CONNECT target=example.com:443 action=DENIED reason=not in allowlist
```

## Allowlist-format

Én oppføring pr. linje, `#`-kommentarer:

- `host` → porter 80 og 443
- `host:port` → den porten bare
- `*.example.com` → subdomene-vildekart
- `10.1.2.3[:port]` → IP-literal (pentest-mål; private ranges tillatt)

Två default-filer, én per usecase:

- `allowlist.code.default` — Claude Code-hosts + dev/PM-hosts (npm, pypi,
  github, apt). Brukes bare når kodeagent kjører med `SBX_OPEN_NETWORK=0`
  (default er åpen utgang).
- `allowlist.pentest.default` — kun Claude Code/LLM-hostene (bildet er
  prebygd); pentest-mål legges alltid til med `-a`/-f ved kjør.

`-a` og `-f` legges til ved kjør. Proxyen restartes automatisk når
allowlisten endrer seg (label-hash-sammenligning); ellers gjenbrukes den.

DNS-rebinding-vern: for hostname-oppføringer resolveres navnet før kobling,
og koblingen avslås hvis noen av adressene ligger i reserverte range
(10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, fc00::/7, fe80::/10
samt de to sbx-subnettene) — et hostname kan aldri peke mot disse.
0/8, 127/8 og 169.254/16 avvises alltid, også for IP-literal-oppføringer.
De to sbx-subnettene er reserverte kun for hostnames: eksplicitte
IP-literaler (`172.28.0.1:<port>`) tillates, og det er inngangen til
host-tjenester (se nedenfor).

## Host-tjenester

Sandboxen kan nå spesifikke tjenester på selve hosten (her: OpenAI-kompatibel
modellserver, port parsest fra modelconfigens base URL). To lag må begge
slippe gjennom:

1. **iptables** (host-bridgen): `SBX_HOST_PORTS` legger til ACCEPT-regel for
   hver `tcp/<port>` i isolasjonskjeden, før DROP. Modellserver-porten legges
   til automatisk; andre tjenester legges til i `.env` (f.eks.
   `SBX_HOST_PORTS=8000,11434`).
2. **Allowlist**: `172.28.0.1:<port>` (bridge-gateway = hosten) legges
   automatisk til for modellserveren; andre host-tjenester må påsies med
   `-a 172.28.0.1:<port>` eller `-f`. Proxyen aksepterer IP-literaler kun
   dersom de er eksplisitt tillatt. Hostname-oppføringer kan aldri
   reserveres til 172.28.0.0/24 (DNS-rebinding-vern), så kun den
   eksplicitte IP-inngangen når hosten.

Merk: services på hosten må lytte på et grensesnitt utover loopback
(f.eks. `0.0.0.0` eller LAN-IP), ikke bare `127.0.0.1`.

```bash
# fra sandboxen:
curl http://172.28.0.1:8000/v1/models          # OK
curl http://172.28.0.1:22/                     # 403 (ikke i allowlist)
python3 -c "import socket; socket.create_connection(('172.28.0.1', 5432), 5)"
# ConnectionRefused/blocked — rått TCP til ikke-tillatt port (iptables DROP)
```

## Host-isolasjon (sudo-iptables)

På som standard (skipp: `--no-host-isolation` eller `HOST_ISOLATION=0` i `.env`).
Påvirker kun INPUT-kjeden for sandbox-bridgen; proxy-egress-nettverket
(172.29.0.0/24) er ikke berørt. Reglene (idempotent, ledd `SBX-ISOLATE`):

```
-i br-<sbx-internal> :
  ESTABLISHED,RELATED ACCEPT
  NEW udp/tcp:53 ACCEPT        # embedded-DNS fra containeren
  NEW tcp:<SBX_HOST_PORTS> ACCEPT   # f.eks. hostens modellserver :8000
  ellers DROP
```

Kjeden rebuildes fra bunnen ved hver kjør, så portsettet følger alltid
`SBX_HOST_PORTS`.

### Automatisk installasjon (sudoers-drop-in)

På hosts uten passordfritt sudo gir `etc/harrbjorn-sbx.sudoers` wrapperen
NOPASSWD-tilgang til akkurat de iptables-kommandoen wrapperen selv kjører
(kun SBX-ISOLATE-kjeden, kun mot sandbox-bridgen) — så laget installerer
automatisk ved hver kjør:

```bash
sed "s/#USER#/$(id -un)/" etc/harrbjorn-sbx.sudoers \
  | sudo tee /etc/sudoers.d/harrbjorn-sbx >/dev/null
sudo chmod 0440 /etc/sudoers.d/harrbjorn-sbx
sudo visudo -cf /etc/sudoers.d/harrbjorn-sbx     # må si "parsed OK"
```

Filen må ligge uten prikk i navnet, ellers ignorerer sudo den. Sjekk
`command -v iptables` først — hvis den bor andre stede enn
`/usr/bin/iptables`, juster pathen i drop-in-fila før install.

## Self-test (end-til-end)

```bash
mkdir -p /tmp/sbx-test
./run-code.sh -w /tmp/sbx-test -- sh -c '
  set -x
  curl -sI https://api.anthropic.com | head -1         # via proxy → OK
  curl -sI https://example.com | head -1               # → OK (åpen utgang som standard)
  curl -s --max-time 5 http://172.28.0.1/ || true      # host-gw port 80 → iptables DROP (timeout) eller 502
  curl -s --max-time 5 http://172.28.0.1:8000/ || true # host-modellserver → OK (SBX_HOST_PORTS)
  echo x > /etc/test || true                           # → Read-only file system
  echo x > /work/test && cat /work/test                # OK, eies av uid 1000 på hosten
'
docker logs sbx-proxy | tail                             # ALLOWED-linjer (logges også i åpen modus)

# Allowlist-modus for kodeagent (proxy restartes: ny hash — annen modus):
SBX_OPEN_NETWORK=0 ./run-code.sh -w /tmp/sbx-test -- sh -c '
  curl -sI https://api.anthropic.com | head -1           # → OK (i allowlist.code.default)
  curl -sI https://example.com | head -1                 # → 403 (avvist)
'
SBX_OPEN_NETWORK=0 ./run-code.sh -w /tmp/sbx-test -- true # proxy gjenbrukes (hash-match i allowlist-modus)
claude -p --dangerously-skip-permissions "Svar bare: OK"   # agent kjører via proxy
```

Pentest-variant (mål i allowlisten via `-a`, dev-hosts skal være borte):

```bash
./run-pentest.sh -w /tmp/sbx-test -a example.com -- sh -c '
  curl -sI https://example.com | head -1          # → OK (-a tillatt)
  curl -sI https://pypi.org | head -1             # → 403 (dev-hosts borte i pentest-default)
'
docker logs sbx-proxy | tail
./run-code.sh -w /tmp/sbx-test -- true            # cross-usecase: proxy restart (ny hash)
```

## Begrensninger

- Whitelist-håndhevingen ligger i proxy-prosessen. Mitigering: ~450 linjer
  kun-stdlib Python, read-only, uten privilegier, ingen publiserterte porter,
  kun nåbar fra sandbox-nettverket. Kjernesiden («kun proxy kan nås») er
  nettverksarkitekturens garant.
- Utgang er **proxy-kun**, ikke «proxy-fremst»: rå TCP uten proxy
  feiler trygt (ingen route).
- Åpen utgang (`SBX_OPEN_NETWORK=1`) er et bevisst default for kodeagenten:
  all trafikk logges fortsatt, permanent-avvis-settet (loopback, 0/8,
  169.254/16), DNS-rebinding-vern, host-iptables og container-hardening
  holder likevel. `SBX_OPEN_NETWORK=0` gir klassisk allowlist-utgang.
- Proxy-utgang betyr at **HTTP-vedkommende verktøy** i pentest-sandboxen er
  de som når målene: curl, python, git m.fl. bruker
  `HTTP(S)_PROXY`-env-vars automatisk. **sqlmap** må få proxyen eksplisitt:
  `--proxy http://sbx-proxy:3128`. **nmap/hydra** (rått socket) når **ikke**
  målene i denne arkitekturen — sikkerhetstesting er agent-/HTTP-drevet.
- To bilder; hver wrapper bygger sin egen (`--rebuild`). Det gamle
  `harrbjorn/sandbox:latest` kan prunes.
- Claude Code-versjonen låses ved bilde-build (auto-update er slått av);
  gjelder begge bildene — bygg på nytt med `--rebuild` for oppdateringer.
- Fast uid/gid 1000 samsvarer med denne hosten. Bindmounter fra andre
  uids: juster `--user` og tmpfs-`uid=`/`gid=` i `lib/sandbox.sh`.
- `.sandbox/` og `.env` er git-ignoreret (allowlist-sammensmeltning +
  agent-HOME + nøkkel).
- Bindmounts får `:z` (SELinux-relabel) — nødvendig på SELinux-hosts
  (f.eks. Fedora) for mounter fra home-direkter.

## Fjerne (hvis du sletter oppsettet helt)

```bash
sudo iptables -D INPUT -i br-<id12> -j SBX-ISOLATE   # br-<id12> fra:
docker network inspect -f '{{.Id}}' sbx-internal
sudo iptables -F SBX-ISOLATE && sudo iptables -X SBX-ISOLATE
sudo docker rm -f sbx-proxy
sudo docker network rm sbx-internal sbx-egress
docker rmi harrbjorn/code:latest harrbjorn/pentest:latest harrbjorn/sbx-proxy:latest
sudo rm /etc/sudoers.d/harrbjorn-sbx   # hvis sudoers-drop-inen er installert
rm -rf .sandbox
```
