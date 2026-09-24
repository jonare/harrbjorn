# harrbjorn — isolert sandbox for autonome kodeagenter

Et Docker-oppsett der kodeagenter (Claude Code CLI + generisk dev-miljø) kan
kjøre autonomt mot en bind-mounted workspace, uten å kunne skade hostsystemet.

## Trusselmodell

Den innsperrede agenten skal:

- **kun** skrive i den spesifiserte workspace-direktivet (rw-bindmount til `/work`)
  og sin egen agent-HOME (persistert under `.sandbox/agent-home`)
- **kun** ha nettverksutgang til en konfigurerbar host-whitelist over http(s)
  (fungerer også for sikkerhetstesting mot whitelistede mål, inkl. IP-literaler)
- **ikke** nå hosten eller internettet utover whitelisten
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
   ├─ sbx-proxy     (internal + egress; forward-proxy, allowlist, audit-logg)
   └─ sandbox       (kun internal; HTTP(S)_PROXY→sbx-proxy:3128, --rm)
```

Isolasjonslag — hvert holder selv hvis ett feiler:

1. **Internal-nettverk** — kjernepolitikk: agenten kan fysisk ikke åpne
   en rå socket til internett. Verktøy som ignorerer proxy-env-vars feiler trygt.
2. **Proxy-whitelist** — eneste utgang; håndhever host(:port)-whitelist,
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
`run-sandbox.sh` — idempotent.

## Bruk

```bash
./run-sandbox.sh -w <workdir> [--flagg] -- <kommando> [args...]
```

Flagg:

| Flag | Effekt |
|---|---|
| `-w DIR` | Workspace (bindmount til `/work`, rw). Obligatorisk. |
| `-a host[:port]` | Ekstra allowlist-oppføring (kan gjentas). |
| `-f FIL` | Ekstra allowlist-fil (samme format som `allowlist.default`). |
| `--no-host-isolation` | Hopp over sudo-iptables-laget (default: på). |
| `--rebuild` | Bygg bildene på nytt (Claude Code-låses ved build; se Begrensninger). |

Eksempler:

```bash
# Interaktiv Claude Code-sesjon i et prosjekt
./run-sandbox.sh -w ~/proj -- claude --dangerously-skip-permissions

# Énkjørs-agenter
./run-sandbox.sh -w ~/proj -- claude -p "Refaktoriser auth-modulen" --dangerously-skip-permissions

# Sikkerhetstesting mot et privat mål (IP-literal i allowlist)
./run-sandbox.sh -w ~/pentest -a 192.168.50.10:8080 -a 192.168.50.10:443 \
  -- python3 - <<'EOF'
import urllib.request
print(urllib.request.urlopen("http://192.168.50.10:8080/", timeout=10).status)
EOF

# Vanlig dev-bruk
./run-sandbox.sh -w ~/proj -- bash
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

`allowlist.default` inneholder Claude Code-hosts + dev/PM-hosts;
`-a` og `-f` legges til ved kjør. Proxyen restartes automatisk når
allowlisten endrer seg (label-hash-sammenligning); ellers gjenbrukes den.

DNS-rebinding-vern: for hostname-oppføringer reserveres navnet før framover,
og koplingen avslås hvis noe av adressene ligger i reserverte range
(10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, fc00::/7, fe80::/10
samt de to sbx-subnettene). 127/8, 0/8, 169.254/16 og de to sbx-subnettene
avvises alltid — også for IP-literal-oppføringer.

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
(172.29.0.0/24) er berørt. Reglene (idempotent, ledd `SBX-ISOLATE`):

```
-i br-<sbx-internal> :
  ESTABLISHED,RELATED ACCEPT
  NEW udp/tcp:53 ACCEPT        # embedded-DNS fra containeren
  NEW tcp:<SBX_HOST_PORTS> ACCEPT   # f.eks. hostens modellserver :8000
  ellers DROP
```

Kjeden rebuildes fra bunnen ved hver kjør, så portsettet følger alltid
`SBX_HOST_PORTS`.

Fjerne (hvis du sletter oppsettet helt):

```bash
sudo iptables -D INPUT -i br-<id12> -j SBX-ISOLATE   # br-<id12> fra:
docker network inspect -f '{{.Id}}' sbx-internal
sudo iptables -F SBX-ISOLATE && sudo iptables -X SBX-ISOLATE
sudo docker rm -f sbx-proxy
sudo docker network rm sbx-internal sbx-egress
```

## Self-test (end-til-end)

```bash
mkdir -p /tmp/sbx-test
./run-sandbox.sh -w /tmp/sbx-test -- sh -c '
  set -x
  curl -sI https://api.anthropic.com | head -1        # via proxy → OK
  curl -sI https://example.com | head -1              # → 403 (avvist)
  curl -s --max-time 5 http://172.28.0.1/ || true     # host-gateway (uten port) → 403 (proxy)
  curl -s --max-time 5 http://172.28.0.1:8000/ || true # host-modellserver → OK (SBX_HOST_PORTS)
  echo x > /etc/test || true                          # → Read-only file system
  echo x > /work/test && cat /work/test               # OK, eies av uid 1000 på hosten
'
docker logs sbx-proxy | tail                            # ALLOWED/DENIED-linjer
./run-sandbox.sh -w /tmp/sbx-test -- true               # proxy gjenbrukes (hash-match)
claude -p --dangerously-skip-permissions "Svar bare: OK"   # agent kjører via proxy
```

## Begrensninger

- Whitelist-håndhevingen ligger i proxy-prosessen. Mitigering: ~450 linjer
  kun-stdlib Python, read-only, uten privilegier, ingen publiserterte porter,
  kun nåbar fra sandbox-nettverket. Kjernesiden («kun proxy kan nås») er
  nettverksarkitekturens garant.
- Utgang er **proxy-kun**, ikke «proxy-fremst»: rå TCP uten proxy
  feiler trygt (ingen route).
- Claude Code-versjonen låses ved bilde-build (auto-update er slått av);
  bygg på nytt med `--rebuild` for oppdateringer.
- Fast uid/gid 1000 samsvarer med denne hosten. Bindmounter fra andre
  uids: juster `--user` og tmpfs-`uid=`/`gid=` i `run-sandbox.sh`.
- `.sandbox/` og `.env` er git-ignoreret (allowlist-sammensmeltning +
  agent-HOME + nøkkel).
- Bindmounts får `:z` (SELinux-relabel) — nødvendig på SELinux-hosts
  (f.eks. Fedora) for mounter fra home-direkter.
