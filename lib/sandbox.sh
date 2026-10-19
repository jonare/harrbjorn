#!/usr/bin/env bash
# lib/sandbox.sh — harrbjorn-sandboxens felles kjerne.
#
# Kjent av wrappers (run-code.sh, run-pentest.sh) som setter usecase-kontrakt
# før de kjører `source lib/sandbox.sh; sbx_main "$@"`:
#   SBX_USECASE            code|pentest (logglinjer + container-navn)
#   SBX_IMAGE              bildet som bygges ved behov og kjøres
#   SBX_CONTEXT            build-kontekst (direktori med Dockerfile)
#   SBX_ALLOWLIST_DEFAULT  default-allowlisten (fil i repo-rotten)
#   SBX_OPEN_NETWORK       1 = åpen utgang (proxyen slår allowlisten, dev-default)
#                          0 = allowlisten håndheves (pentest)
# Wrapperen definerer i tillegg sbx_usage() som skriver sin egen hjelpetekst
# og avslutter med gitt exit-kode.
#
# Runtime: rootless Podman, --userns=keep-id, per-sesjon nett (podman network
# --internal) med per-sesjon proxy som eneste utgang. Med -p har sesjon-nettet
# egress i stedet, og den eksterne proxyen er firevallen (fail-closed: ingen
# fallback hvis den ikke svarer). Ingen sudo: hosten berøres aldri
# (nattverks-isolasjon kjører i nettverket, ikke i iptables).
#
# OCI-runtime (SBX_RUNTIME): krun (microVM via KVM, default), runsc (gVisor)
# eller crun (eksplisitt valgt — aldri stille fallback). Wrapperen feiler
# hvis valgt runtime (eller /dev/kvm for krun) mangler.

set -euo pipefail

# Repo-rotten = forelderen til lib/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$SCRIPT_DIR/.sandbox"

# Kontrakten — wrappers setter disse; fallbackene er code-usecasen.
SBX_USECASE="${SBX_USECASE:-code}"
SBX_IMAGE="${SBX_IMAGE:-harrbjorn/code:latest}"
SBX_CONTEXT="${SBX_CONTEXT:-code}"
SBX_ALLOWLIST_DEFAULT="${SBX_ALLOWLIST_DEFAULT:-allowlist.code.default}"
SBX_OPEN_NETWORK="${SBX_OPEN_NETWORK:-1}"

# Porten harrbjorns egen proxy lytter på (container-side). Ved -p er den
# eksterne proxyens port den som gjelder i stedet, og denne brukes ikke.
PROXY_PORT=3128

# Per-sesjon ressurser (globale slik at EXIT-trappen kan rømme dem).
PROXY_NAME=""
NET_NAME=""
RESOLV_CONF=""
POLICY_DIR=""
SESSION_LOG=""

sbx_cleanup() {
  # stop -t 1 instead of rm -f: krun does not report a SIGTERM stop within
  # the default 10s stop timeout, so rm -f would make every session teardown
  # pay ~10s before its own SIGKILL fallback. With -t 1 the SIGKILL fallback
  # is reached in ~1s — and the session is being torn down either way.
  # (For crun the SIGTERM stops the proxy promptly; same fast path.)
  $PODMAN stop -t 1 "$PROXY_NAME" >/dev/null 2>&1 || true

  # Audit log: the proxy's JSON lines (per-request allow/deny decisions,
  # with the reason) are kept at .sandbox/logs/<session>.jsonl for later
  # debugging — captured while the proxy container still exists.
  if [[ -n "$PROXY_NAME" && -n "$SESSION_LOG" ]]; then
    mkdir -p "$(dirname "$SESSION_LOG")" 2>/dev/null || true
    $PODMAN logs "$PROXY_NAME" >"$SESSION_LOG" 2>&1 || true
  fi

  $PODMAN rm "$PROXY_NAME" >/dev/null 2>&1 || true
  $PODMAN network rm "$NET_NAME" >/dev/null 2>&1 || true
  rm -f "$RESOLV_CONF"
  rm -rf "$POLICY_DIR"
}

# Hent tilbake ressurser fra avbrutte kjør: døde sbx-* containere og ubrukte
# sbx-*-int nettverk. Rende containere er alltid i live-sesjoner — røres ikke.
sbx_reap_orphans() {
  local c running n
  for c in $($PODMAN ps -a --filter 'name=sbx-' --format '{{.Names}}' 2>/dev/null); do
    running="$($PODMAN inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)"
    [[ "$running" == "true" ]] && continue
    echo ">> cleanup: removing orphan container $c"
    $PODMAN rm -f "$c" >/dev/null 2>&1 || true
  done
  for n in $($PODMAN network ls --format '{{.Name}}' 2>/dev/null | grep -E '^sbx-.*-int$' || true); do
    $PODMAN network rm "$n" >/dev/null 2>&1 || true
  done
  # Stale per-session proxy resolv.conf files (crashed/aborted sessions).
  # Age-gated: a session under an hour may still be between writing the
  # file and mounting it; a live older session keeps its mount alive
  # through the underlying inode either way.
  find "$STATE_DIR" -maxdepth 1 \
    \( -name 'resolv-*.conf' -o -name 'allowlist-*.txt' \) -mmin +60 -delete \
    >/dev/null 2>&1 || true
  # Stale per-session proxy policy dirs (crashed sessions).
  find "$STATE_DIR" -maxdepth 1 -type d -name 'proxy-*' -mmin +60 \
    -exec rm -rf -- {} + >/dev/null 2>&1 || true
}

image_exists() { $PODMAN image inspect "$1" >/dev/null 2>&1; }

# Print the host's upstream DNS servers, one per line, in system order.
# The proxy needs these as its only nameservers (not the loopback stubs in
# /etc/resolv.conf, not the internal net's aardvark). Stub/loopback
# addresses are filtered at every layer.
sbx_uplink_dns() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, subprocess, sys
try:
    data = json.loads(subprocess.run(
        ["resolvectl", "status", "--json=short"],
        capture_output=True, text=True, timeout=5).stdout)
except Exception:
    sys.exit(1)
seen = set()
def emit(a):
    if a and a not in seen and not a.startswith("127.") and a != "::1":
        seen.add(a)
        print(a)
if data and isinstance(data[0], dict):
    emit(data[0].get("currentServer", {}).get("addressString"))
for link in data:
    if isinstance(link, dict):
        for s in link.get("servers", []):
            emit(s.get("addressString"))
' 2>/dev/null && return 0
  fi
  # Fallbacks: human-readable resolvectl, then plain /etc/resolv.conf.
  local out
  out="$(resolvectl status 2>/dev/null \
    | sed -n 's/^[[:space:]]*DNS Servers:[[:space:]]*//p')"
  if [[ -n "$out" ]]; then
    echo "$out" | tr ' ' '\n' | grep -vE '^(127\.|::1$)' && return 0
  fi
  out="$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null)"
  if [[ -n "$out" ]]; then
    echo "$out" | tr ' ' '\n' | grep -vE '^(127\.|::1$)' && return 0
  fi
  return 1
}

# ------------------------------------------------------------ proxy policy
# Generate Smokescreen's per-session config under $1 (mounted ro at /config
# in the proxy container):
#   proxy.yaml — main config (port, ACL path, idle timeout, port-scoped
#                allow_addresses exceptions)
#   acl.yaml   — egress ACL (default action + allowed_domains)
#
# Semantics:
#  - allow_missing_role: true — no mTLS in the sandbox, so role "" matches
#    no service and the ACL's default rule applies to every client.
#  - open mode → default action open: the ACL allows everything and
#    Smokescreen's built-in IP filter still denies private/loopback/
#    link-local/CGNAT/metadata/IPv6-embedded. No port restriction for
#    domain destinations — Smokescreen's ACL has no port dimension,
#    same as the old proxy.py open mode.
#  - enforce mode → default action enforce with the merged allowlist as
#    allowed_domains.
#  - The trusted host (model server base_url port + -H ports) is a
#    port-scoped exception: 169.254.1.2 is the pasta link-local host
#    address (host.containers.internal) which the IP filter denies by
#    default, so allow_addresses opens just the listed ports — never
#    all ports. In enforce mode the hostname also goes into
#    allowed_domains so the ACL accepts it.
#
# Allowlist entries (unchanged user-facing format): host, *.wildcard,
# IP, IP:port, [IPv6]:port. Two semantic differences from proxy.py:
#  - hostname:port loses its port scoping (the ACL has no port dimension;
#    the entry grants the host on all ports, subject to the IP filter);
#  - wildcards *.x match only subdomains of x, not x itself.
sbx_write_proxy_policy() {
  local out="$1"
  command -v python3 >/dev/null 2>&1 \
    || { echo "error: python3 not found; cannot generate the proxy policy." >&2; return 1; }
  python3 - "$MERGED" "$SBX_OPEN_NETWORK" "$PROXY_TRUSTED" "$out" "$PROXY_PORT" <<'PY'
import ipaddress, re, sys

merged, open_mode, trusted_csv, outdir, port = sys.argv[1:6]

def warn(msg):
    print(f"warn: proxy policy: {msg}", file=sys.stderr)

acl_entries = []
allow_addresses = []
allow_ranges = []

def add_acl(entry):
    if entry not in acl_entries:
        acl_entries.append(entry)

HOST_RE = re.compile(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$')

def valid_host(h):
    return bool(HOST_RE.match(h))

for raw in open(merged):
    line = raw.strip()
    if not line or line.startswith('#'):
        continue
    host, portno = None, None
    m = re.match(r'^\[(.+)\]:(\d{1,5})$', line)      # [IPv6]:port
    if m:
        host, portno = m.group(1), int(m.group(2))
    elif line.count(':') == 1:
        host, port_s = line.rsplit(':', 1)
        portno = int(port_s) if port_s.isdigit() else None
    else:
        host = line

    ip = None
    try:
        if portno is not None and not (1 <= portno <= 65535):
            raise ValueError
        ip = ipaddress.ip_address(host)
    except ValueError:
        if portno is not None:
            # host:port — no port dimension for domains in Smokescreen:
            # keep the host, warn about the scoping difference.
            if host.startswith('*.'):
                warn(f"'{line}': wildcards with ports are unsupported — skipped")
                continue
            if not valid_host(host):
                warn(f"'{line}': not a hostname, IP, or [IPv6]:port — skipped")
                continue
            warn(f"'{line}': host:port entries grant the host on all ports "
                 "(Smokescreen ACL has no port dimension)")
        else:
            is_wild = host.startswith('*.') and valid_host(host[2:])
            if not is_wild and not valid_host(host):
                warn(f"'{line}': not a hostname, wildcard, or IP — skipped")
                continue

    if ip is not None:
        # IP literal: needs an ACL entry plus an IP-filter exception
        # (loopback/link-local/private are denied by default).
        add_acl(str(ip))
        if portno is not None:
            allow_addresses.append(f"{ip}:{portno}")
        else:
            allow_ranges.append(f"{ip}/{'128' if ip.version == 6 else '32'}")
    elif host is not None:
        add_acl(host)

# Trusted host: port-scoped exception (model server + -H ports).
for t in (x for x in trusted_csv.split(',') if x.strip()):
    t = t.strip()
    name, _, p = t.rpartition(':')
    if name != 'host.containers.internal' or not p.isdigit() or not (1 <= int(p) <= 65535):
        warn(f"trusted entry '{t}': expected host.containers.internal:PORT — skipped")
        continue
    if f"169.254.1.2:{p}" not in allow_addresses:
        allow_addresses.append(f"169.254.1.2:{p}")
    if open_mode != '1':
        add_acl(name)

def ylist(items, indent):
    # Quote every item: an unquoted *.glob is a YAML alias indicator and an
    # unquoted IPv6 literal is ambiguous; validated hosts/IPs never contain
    # quote characters.
    return "\n".join(f"{indent}- '{i}'" for i in items)

action = "open" if open_mode == "1" else "enforce"
acl = (
    "version: v1\n"
    "services: []\n"
    "default:\n"
    "  name: default\n"
    "  project: harrbjorn\n"
    f"  action: {action}\n"
)
if acl_entries:
    acl += "  allowed_domains:\n" + ylist(acl_entries, "    ") + "\n"
with open(f"{outdir}/acl.yaml", "w") as f:
    f.write(acl)

cfg = (
    "ip: 0.0.0.0\n"
    f"port: {port}\n"
    "allow_missing_role: true\n"
    "acl_file: /config/acl.yaml\n"
    # The IdleTimeout default is unset (0); a 10m cap on idle connections
    # mirrors the old proxy.py (CONNECT_IDLE_SECONDS=600) without cutting
    # streaming model responses mid-body (idle = no bytes in either
    # direction).
    "idle_timeout: 10m\n"
)
if allow_addresses:
    cfg += "allow_addresses:\n" + ylist(allow_addresses, "  ") + "\n"
if allow_ranges:
    cfg += "allow_ranges:\n" + ylist(allow_ranges, "  ") + "\n"
with open(f"{outdir}/proxy.yaml", "w") as f:
    f.write(cfg)
PY
}

# ------------------------------------------------------------ proxy
# Start harrbjorn's own egress: merged allowlist → Smokescreen policy →
# per-session resolv.conf → per-session proxy container → readiness probe.
# The whole section runs only when harrbjorn's proxy is the egress; with -p
# the external proxy is the firewall and none of this is created.
# RESOLV_CONF / POLICY_DIR / PROXY_NAME are globals so sbx_cleanup can
# release them (PROXY_PORT is a top-level constant).
sbx_start_proxy() {
  local S="$1" MODE_TAG="$2" MERGED

  # --------------------------------------------------------- allowlist
  mkdir -p "$STATE_DIR"
  [[ -f "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" ]] \
    || { echo "error: allowlist default '$SBX_ALLOWLIST_DEFAULT' not found" >&2; exit 1; }
  # Per-session merged allowlist: concurrent sessions (code + pentest) must
  # not share one file — each proxy loads whatever the other session wrote
  # last, and -a targets would be lost.
  MERGED="$STATE_DIR/allowlist-$S.txt"
  {
    echo "# merged at $(date -u +%Y-%m-%dT%H:%M:%SZ) by harrbjorn $SBX_USECASE"
    grep -vE '^\s*(#|$)' "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" || true
    for h in ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do echo "$h"; done
    if [[ -n "$EXTRA_ALLOWLIST" ]]; then
      grep -vE '^\s*(#|$)' "$EXTRA_ALLOWLIST" || true
    fi
  } | sort -u > "$MERGED"

  # -------------------------------------------------------- proxy policy
  # Smokescreen config (proxy.yaml + acl.yaml), generated from the merged
  # allowlist + egress mode + trusted host; mounted at /config in the proxy.
  # The allowlist keeps its user-facing format; only the generated policy
  # is new. Generation failure aborts before any session resource leaks
  # (the EXIT trap cleans up what exists so far).
  POLICY_DIR="$STATE_DIR/proxy-$S"
  mkdir -p "$POLICY_DIR"
  sbx_write_proxy_policy "$POLICY_DIR" || exit 1

  # ------------------------------------------------------------- proxy
  # Per-session proxy: one hop on pasta's default network (real egress +
  # host.containers.internal), one hop on the session's internal network
  # (reaches the sandbox).
  #
  # resolv.conf is bind-mounted, not left to the networks: a multi-homed
  # container's resolv.conf comes from the internal net, whose nameserver
  # (aardvark) answers NXDOMAIN for every external name — and glibc treats
  # the *first* nameserver's answer as final, no fallback. The host's real
  # upstream servers are the proxy's only nameservers. (No search domains:
  # the proxy only looks up fully qualified names; host.containers.internal
  # comes from /etc/hosts, not DNS.)
  local DNS
  DNS="$(sbx_uplink_dns)" || true
  if [[ -z "$DNS" ]]; then
    echo "error: could not determine the host's upstream DNS; the proxy would be blind to external names." >&2
    exit 1
  fi
  RESOLV_CONF="$STATE_DIR/resolv-$S.conf"
  {
    echo "# per-session proxy nameservers (written by harrbjorn $SBX_USECASE)"
    while IFS= read -r ns; do echo "nameserver $ns"; done <<< "$DNS"
  } > "$RESOLV_CONF"
  echo ">> proxy $PROXY_NAME: starting (net $NET_NAME${MODE_TAG}, dns: $(printf '%s' "$DNS" | tr '\n' ' '))"
  $PODMAN run -d --name "$PROXY_NAME" \
    "${RUNTIME_ARGS[@]}" \
    --userns=keep-id:uid=1000,gid=1000 \
    --network podman --network "$NET_NAME" \
    -v "$RESOLV_CONF:/etc/resolv.conf:ro,z" \
    -v "$POLICY_DIR:/config:ro,z" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --user 65534:65534 \
    --memory 256m --pids-limit 128 --ulimit nofile=65536:65536 \
    harrbjorn/sbx-proxy:latest \
    --config-file /config/proxy.yaml >/dev/null
  # Wait until the proxy is ready.
  #
  # Probe = a throwaway container on the session's internal net that does a
  # raw TCP connect to the proxy's IP — the exact path a sandboxed request
  # takes, so "answered" means "will serve". The alternatives are all
  # ruled out:
  #   * `podman exec` in the proxy: krun (microVM) has no exec.
  #   * polling the proxy's startup log line: krun's log channel is flaky —
  #     the line can stay invisible for minutes while the proxy is fully
  #     up and serving, so it cannot arbitrate.
  #   * a host-side connect: the host cannot reach a krun container on any
  #     network (pasta only bridges container→host, e.g. for
  #     host.containers.internal).
  # The helper reuses $SBX_IMAGE (already built above) — no extra image to
  # pull — with the entrypoint overridden, so sbx-init.sh never runs. It
  # polls for up to 90s and exits 0 on the first answered connect; the
  # proxy normally answers in ~1s, so the common case costs one brief
  # container start. A config/ACL that fails Validate never binds the
  # socket, so the deadline fires and the error path below does the rest.
  local PROXY_IP
  PROXY_IP="$($PODMAN inspect \
    -f "{{(index .NetworkSettings.Networks \"$NET_NAME\").IPAddress}}" "$PROXY_NAME")"
  if [[ -n "$PROXY_IP" ]] && $PODMAN run --rm --network "$NET_NAME" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint bash \
    "$SBX_IMAGE" \
    -c 'for _ in $(seq 1 180); do (exec 3<>/dev/tcp/'"$PROXY_IP"'/3128) 2>/dev/null && exit 0; sleep 0.5; done; echo "proxy never answered on '"$PROXY_IP"':3128"; exit 1'; then
    echo ">> proxy is up"
  else
    {
      echo "error: proxy failed to start (no answered connect to $PROXY_IP:3128 within 90s)." >&2
      echo "--- last proxy log lines:" >&2
      $PODMAN logs "$PROXY_NAME" 2>&1 | tail -5 >&2 || true
      echo "  (rerun to reproduce; the proxy container is removed on exit)" >&2
    }
    exit 1
  fi
}

# ----------------------------------------------------------------- runtime
# SBX_RUNTIME (env/.env) selects the OCI runtime for BOTH session containers
# (sandbox and proxy): krun (default — microVM via KVM, own kernel), runsc
# (gVisor) or crun (plain container, explicit opt-in only). The wrapper fails
# hard if the chosen runtime is unavailable — never a silent downgrade to
# crun: with krun a container escape lands in the VM's user namespace, not
# on the host kernel, and a quiet fallback would drop that boundary without
# saying so. Fills RUNTIME_ARGS (caller's local) for the `podman run` lines.
sbx_check_runtime() {
  local bin
  case "$SBX_RUNTIME" in
    krun)
      bin="$(command -v krun || true)"
      if [[ -z "$bin" ]]; then
        echo "error: SBX_RUNTIME=krun but the krun OCI runtime is not installed (Fedora: dnf install crun-krun)." >&2
        exit 1
      fi
      if [[ ! -c /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        echo "error: SBX_RUNTIME=krun but /dev/kvm is not accessible (KVM required — check virtualization support, or set SBX_RUNTIME=crun)." >&2
        exit 1
      fi
      RUNTIME_ARGS=(--runtime krun)
      ;;
    runsc)
      bin="$(command -v runsc || true)"
      if [[ -z "$bin" ]]; then
        echo "error: SBX_RUNTIME=runsc but the runsc (gVisor) runtime is not installed." >&2
        exit 1
      fi
      RUNTIME_ARGS=(--runtime runsc)
      ;;
    crun)
      bin="$(command -v crun || true)"
      if [[ -z "$bin" ]]; then
        echo "error: SBX_RUNTIME=crun but crun is not installed." >&2
        exit 1
      fi
      RUNTIME_ARGS=(--runtime crun)
      ;;
    *)
      echo "error: invalid SBX_RUNTIME '$SBX_RUNTIME' (must be krun, runsc or crun)." >&2
      exit 1
      ;;
  esac
}

sbx_main() {
  local WORKDIR="" EXT_PROXY="" EXTRA_HOSTS=() EXTRA_ALLOWLIST=""
  local HOST_PORTS=()
  local REBUILD=0 T CONFIG_ENV=() PROXY_ENV=()
  local S SBX_NAME PROXY_TRUSTED="" RUNTIME_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -w) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          WORKDIR="$2"; shift 2 ;;
      -a) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          EXTRA_HOSTS+=("$2"); shift 2 ;;
      -H) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          HOST_PORTS+=("$2"); shift 2 ;;
      -f) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          EXTRA_ALLOWLIST="$2"; shift 2 ;;
      -p) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          EXT_PROXY="$2"; shift 2 ;;
      --rebuild) REBUILD=1; shift ;;
      -h|--help) sbx_usage 0 ;;
      --) shift; break ;;
      -*) echo "error: unknown option: $1" >&2; sbx_usage 1 ;;
      *) break ;;  # first non-flag argument starts the command; `--` is optional
    esac
  done
  # No command → default to an interactive bash in the workdir: a bare
  # `harrbjorn code` / `harrbjorn security` drops you into a shell to poke
  # around (the TTY handling below attaches a terminal — -it — when one is
  # present, so bash is interactive). Passing a command runs it instead.
  if [[ $# -gt 0 ]]; then
    local CMD=("$@")
  else
    local CMD=(bash)
  fi
  # -w is optional: the workspace defaults to the current directory.
  WORKDIR="${WORKDIR:-$PWD}"
  [[ -d "$WORKDIR" ]] || { echo "error: workdir $WORKDIR does not exist" >&2; exit 1; }
  local WORKDIR_ABS="$(cd "$WORKDIR" && pwd)"

  # -------------------------------------------------------- external proxy
  # -p host:port: an external forward proxy (e.g. Burp Suite) takes over
  # egress: harrbjorn's Smokescreen proxy is NOT started and its allowlist
  # is NOT enforced — the firewall logic is the external proxy's job.
  # Consequences, both deliberate:
  #   * the session net gets egress (no --internal) so the sandbox can
  #     reach the proxy directly — a container on an internal net cannot
  #     even reach the host's address;
  #   * fail-closed: if nothing answers on the port, the session aborts.
  #     There is no fallback — not to the per-session proxy, not to an
  #     open network. The check runs from the host, which can reach every
  #     address the sandbox can (pasta only bridges container→host).
  local ext_host ext_port tcp_target
  if [[ -n "$EXT_PROXY" ]]; then
    ext_host="${EXT_PROXY%:*}"; ext_port="${EXT_PROXY##*:}"
    if [[ -n "$ext_host" && "$EXT_PROXY" == *":"* && "$ext_port" =~ ^[0-9]+$ ]] \
       && (( ext_port >= 1 && ext_port <= 65535 )); then
      :
    else
      echo "error: -p: bad proxy '$EXT_PROXY' (need host:port, port 1-65535)" >&2
      sbx_usage 1
    fi
    if (( ${#EXTRA_HOSTS[@]} )) || [[ -n "$EXTRA_ALLOWLIST" ]] || (( ${#HOST_PORTS[@]} )); then
      echo "warn: -a/-f/-H have no effect with -p (harrbjorn's proxy is not started; the external proxy is the firewall)." >&2
    fi
    # Fail-closed: probe from the host with the address as given. The probe
    # must run BEFORE the loopback rewrite — host.containers.internal only
    # resolves inside the container net, never on the host.
    tcp_target="$ext_host"
    case "$ext_host" in *:*) tcp_target="[$ext_host]" ;; esac
    if ! timeout 5 bash -c "exec 3<>/dev/tcp/$tcp_target/$ext_port" 2>/dev/null; then
      echo "error: -p: no forward proxy answering at $EXT_PROXY (fail-closed: no fallback, session not started)." >&2
      exit 1
    fi
    # Host loopback is reached from the container via host.containers.internal.
    case "$ext_host" in
      localhost|127.0.0.1|::1) ext_host="host.containers.internal" ;;
    esac
    EXT_PROXY_RW="http://$ext_host:$ext_port"
    echo ">> external proxy: $EXT_PROXY (container: $EXT_PROXY_RW; harrbjorn's proxy is not started)"
  fi

  # ---------------------------------------------------------------- .env
  # Wrapper-preset (f.eks. SBX_PIDS fra run-pentest.sh) er satt før source;
  # .env vinner alltid over preset, core-fallback vinner over ingenting.
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
  fi
  local SBX_MEMORY="${SBX_MEMORY:-4g}"
  local SBX_CPUS="${SBX_CPUS:-2}"
  local SBX_PIDS="${SBX_PIDS:-1024}"
  # Terminal locale, injected as -e LANG so the host keyboard's multi-byte
  # UTF-8 (å/ø/æ) works in interactive mode (the image defaults to the same).
  # Must be a locale the image generated: nb_NO.UTF-8 (default) / en_US.UTF-8.
  # .env wins; the value is not re-derived from the host on purpose (a C host
  # would silently re-break it).
  local SBX_LOCALE="${SBX_LOCALE:-nb_NO.UTF-8}"
  # .env (sourced above) may override the wrapper preset; the wrapper default
  # is the fallback (code: open egress, pentest: allowlist).
  local SBX_OPEN_NETWORK="${SBX_OPEN_NETWORK:-1}"
  # OCI runtime: krun (microVM, default) / runsc / crun. Checked hard in
  # sbx_check_runtime (below, after the podman checks) — no silent fallback.
  local SBX_RUNTIME="${SBX_RUNTIME:-krun}"
  local MODE_TAG=""
  [[ "$SBX_OPEN_NETWORK" == "1" ]] && MODE_TAG=", open network"
  [[ -n "$EXT_PROXY" ]] && MODE_TAG=", external proxy"

  # ----------------------------------------------- model config (injection)
  # The sandbox reuses the host's Claude Code model setup (SBX_CLAUDE_CONFIG,
  # default ~/claude.sh) — same model, effort, context window and key — with
  # one rewrite: a loopback ANTHROPIC_BASE_URL is pointed at the host through
  # host.containers.internal (pasta host address) instead of localhost. The
  # host address is a *trusted* proxy upstream (SBX_PROXY_TRUSTED below) —
  # it is a runtime exception, never a user allowlist entry. Only `export ...`
  # lines are evaluated, so the file's comments and trailing `claude ...`
  # invocation are ignored. The result is injected as env vars, standalone;
  # no file is mounted into the container. The container's claude reads them
  # directly; sbx-init.sh derives pi's models.json/settings.json from the
  # same vars, so both harnesses share the model.
  local SBX_CLAUDE_CONFIG="${SBX_CLAUDE_CONFIG:-$HOME/claude.sh}"
  local cfg_exports cfg_env cfg_url cfg_rest cfg_port
  if [[ -f "$SBX_CLAUDE_CONFIG" ]]; then
    cfg_exports="$(grep -E '^export[[:space:]]' "$SBX_CLAUDE_CONFIG" || true)"
    cfg_env="$(
      env -i sh -c '
        eval "$1"
        case "${ANTHROPIC_BASE_URL:-}" in
          http://localhost:*)   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL/localhost/host.containers.internal} ;;
          http://127.0.0.1:*)   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL/127.0.0.1/host.containers.internal} ;;
        esac
        export ANTHROPIC_BASE_URL
        env' sh "$cfg_exports"
    )"
    while IFS= read -r line; do
      [[ -n "$line" ]] && CONFIG_ENV+=(-e "$line")
    done <<< "$cfg_env"
    cfg_url="$(printf '%s\n' "$cfg_env" | sed -n 's/^ANTHROPIC_BASE_URL=//p')"
    cfg_rest="${cfg_url#*://}"
    cfg_rest="${cfg_rest%/}"
    cfg_port="${cfg_rest##*:}"
    if [[ "$cfg_rest" == *:* && "$cfg_port" =~ ^[0-9]+$ ]]; then
      PROXY_TRUSTED="host.containers.internal:$cfg_port"
    fi
    echo ">> model config: $SBX_CLAUDE_CONFIG (base_url=${cfg_url:-n/a})"
  else
    echo "warn: no model config at $SBX_CLAUDE_CONFIG; falling back to ANTHROPIC_API_KEY in .env." >&2
    CONFIG_ENV=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY in .env, or provide a model config via SBX_CLAUDE_CONFIG}")
  fi

  # ---------------------------------------------------- host ports (explicit)
  # -H <port>: host ports the sandbox may reach (test instances on the host,
  # e.g. 8080). Each port becomes a trusted proxy upstream for
  # host.containers.internal — an explicit, per-port runtime exception.
  # The host address is link-local, so the proxy's always-deny and
  # DNS-rebind guards refuse it no matter what the user allowlist (or open
  # network) says: the host is only ever reachable here.
  local p
  if (( ${#HOST_PORTS[@]} )); then
    for p in "${HOST_PORTS[@]}"; do
      p="${p//[[:space:]]/}"
      if [[ ! "$p" =~ ^[0-9]+$ ]] || ! (( p >= 1 && p <= 65535 )); then
        echo "error: -H: bad port '$p' (need 1-65535)" >&2
        sbx_usage 1
      fi
      case " $PROXY_TRUSTED " in
        *" host.containers.internal:$p "*) ;;
        *) PROXY_TRUSTED="${PROXY_TRUSTED:+$PROXY_TRUSTED,}host.containers.internal:$p" ;;
      esac
    done
    echo ">> host ports: ${HOST_PORTS[*]} (via host.containers.internal)"
  fi

  # ----------------------------------------------------------- podman check
  # PODMAN is global: the EXIT trap (sbx_cleanup) runs after this function
  # has returned, and still needs the runtime name.
  PODMAN="${PODMAN:-podman}"
  if ! command -v "$PODMAN" >/dev/null 2>&1; then
    echo "error: podman not found in PATH." >&2
    exit 1
  fi
  if ! $PODMAN info >/dev/null 2>&1; then
    echo "error: rootless podman unreachable (podman info failed)." >&2
    exit 1
  fi
  if [[ "$EUID" -eq 0 ]]; then
    echo "error: refusing to run rootful. Run as the sandbox user (no sudo)." >&2
    exit 1
  fi

  # ------------------------------------------------------------ runtime check
  # Fails hard, before any session resource is created, when the chosen
  # runtime or /dev/kvm is unavailable — a quiet fallback to crun would drop
  # the VM boundary without saying so.
  sbx_check_runtime
  echo ">> runtime: $SBX_RUNTIME"

  # ------------------------------------------------------------- session id
  # $S is namespaced per usecase+second+PID; concurrent sessions can't
  # collide, and sbx_reap_orphans only ever touches what it created.
  S="${SBX_USECASE}-$(date +%s)-$$"
  NET_NAME="sbx-$S-int"
  SBX_NAME="sbx-$S"
  SESSION_LOG="$STATE_DIR/logs/$S.jsonl"
  trap sbx_cleanup EXIT

  sbx_reap_orphans

  # ------------------------------------------------------------ build
  build_image() {
    local img="$1" ctx="$2"
    if [[ "$REBUILD" -eq 1 ]] || ! image_exists "$img"; then
      echo ">> building $img"
      $PODMAN build -t "$img" "$SCRIPT_DIR/$ctx"
    fi
  }
  # pentest is built FROM harrbjorn/code, so code must exist first.
  if [[ "$SBX_CONTEXT" == "pentest" ]]; then
    build_image harrbjorn/code:latest code
  fi
  build_image "$SBX_IMAGE" "$SBX_CONTEXT"
  # The Smokescreen image is only needed when harrbjorn runs its own proxy;
  # with -p the external proxy is the egress and the image is never pulled.
  if [[ -z "$EXT_PROXY" ]]; then
    build_image harrbjorn/sbx-proxy:latest proxy
  fi

  # ----------------------------------------------------------- network
  if [[ -n "$EXT_PROXY" ]]; then
    # -p: the sandbox must reach the external proxy directly, so the session
    # net has egress — a container on an internal net cannot even reach the
    # host's address. The "no raw egress" layer is replaced by the external
    # proxy being the firewall (README: «Ekstern proxy»).
    $PODMAN network create "$NET_NAME" >/dev/null
  else
    PROXY_NAME="sbx-$S-proxy"
    $PODMAN network create --internal "$NET_NAME" >/dev/null
  fi

  # ------------------------------------------------ allowlist + proxy
  # harrbjorn's own egress only: allowlist → policy → proxy → readiness.
  # With -p the external proxy is the firewall and the whole section is
  # skipped — no policy, no per-session DNS, no proxy container, no audit
  # log (see sbx_start_proxy).
  if [[ -z "$EXT_PROXY" ]]; then
    sbx_start_proxy "$S" "$MODE_TAG"
  fi

  # --------------------------------------------- persistent agent HOME
  # Claude Code keeps its onboarding/settings state in HOME (~/.claude.json
  # and ~/.claude/). Persist it on the host so state survives between runs;
  # the rest of the container filesystem stays read-only. keep-id maps
  # container uid 1000 to this user's host uid, so no chown is needed.
  #
  # Keyed by usecase + absolute workdir: instances in different workdirs —
  # or in different usecases with the same workdir — share no filesystem
  # state (a pentest agent must not read/write a code agent's maven cache,
  # agent logs, ...). Same usecase + workdir share the HOME, so caches and
  # agent state survive between runs. The path mirrors the workdir under
  # .sandbox/agent-home/<usecase>/ so each key is visible and deletable.
  local AGENT_HOME="$STATE_DIR/agent-home/$SBX_USECASE${WORKDIR_ABS}"
  mkdir -p "$AGENT_HOME"
  chmod 0700 "$AGENT_HOME"

  # Pre-seeding of Claude Code's interactive state (onboarding, /work trust
  # dialog, approved API key, permission mode) is done by the image's init
  # step (code/sbx-init.sh) INSIDE the container — never by a host process.
  # Between runs the agent owns this directory and can plant symlinks in it
  # (e.g. $HOME/.claude -> /work/...); a host-side seeder would follow them
  # and write wherever the link points. Inside the container the same writes
  # can only reach mounts the agent already fully controls.
  # The mkdir/chmod above are the only host-side touches, and are safe: the
  # path lives under .sandbox/ which is never mounted into the container, so
  # no agent run can pre-plant links along it.

  # ------------------------------------------------------- proxy env (container)
  # Where the container's traffic goes: the per-session Smokescreen by
  # default, or the user's external proxy with -p (rewritten above, loopback
  # → host.containers.internal). With -p we also pass SBX_EXTERNAL_PROXY so
  # sbx-init.sh can detect a Burp proxy and install its CA from
  # http://<proxy>/cert (the fetch bypasses the proxy env — the listener
  # itself serves the endpoint, and going through the proxy would loop).
  #
  # With -p, host.containers.internal goes into NO_PROXY: the external proxy
  # (Burp) runs on the host and cannot resolve that name, so host traffic —
  # notably the model server rewritten above — must go straight to the host
  # via the pasta link instead of through the proxy. The session net with -p
  # already has real egress, so this exposes nothing new. The default branch
  # must NOT list it there: on the --internal net the host is only reachable
  # through the Smokescreen, which carries the model traffic under
  # PROXY_TRUSTED.
  if [[ -n "$EXT_PROXY" ]]; then
    PROXY_ENV=(-e HTTP_PROXY="$EXT_PROXY_RW" -e http_proxy="$EXT_PROXY_RW"
               -e HTTPS_PROXY="$EXT_PROXY_RW" -e https_proxy="$EXT_PROXY_RW"
               -e NO_PROXY='localhost,127.0.0.1,::1,host.containers.internal' -e no_proxy='localhost,127.0.0.1,::1,host.containers.internal'
               -e SBX_EXTERNAL_PROXY="$EXT_PROXY_RW")
  else
    PROXY_ENV=(-e HTTP_PROXY="http://$PROXY_NAME:$PROXY_PORT" -e http_proxy="http://$PROXY_NAME:$PROXY_PORT"
               -e HTTPS_PROXY="http://$PROXY_NAME:$PROXY_PORT" -e https_proxy="http://$PROXY_NAME:$PROXY_PORT"
               -e NO_PROXY='localhost,127.0.0.1,::1' -e no_proxy='localhost,127.0.0.1,::1')
  fi

  # ------------------------------------------------------------- sandbox
  # -i is always required so stdin reaches the container; -t only with a TTY.
  # tmpfs mounts need no uid=/gid=: keep-id makes container 1000 == host
  # 1000, and rootless podman rejects uid=/gid= options anyway.
  T="-i"
  [[ -t 0 && -t 1 ]] && T="-it"

  echo ">> sandbox [$SBX_USECASE]: image=$SBX_IMAGE workdir=$WORKDIR_ABS agent_home=$AGENT_HOME cmd=${CMD[*]}${MODE_TAG}"
  $PODMAN run --rm $T --name "$SBX_NAME" \
    "${RUNTIME_ARGS[@]}" \
    --userns=keep-id:uid=1000,gid=1000 \
    --network "$NET_NAME" \
    --user 1000:1000 \
    -v "$WORKDIR_ABS:/work:z" -v "$AGENT_HOME:/home/agent:z" -w /work \
    "${CONFIG_ENV[@]}" \
    "${PROXY_ENV[@]}" \
    -e HOME=/home/agent \
    -e LANG="$SBX_LOCALE" \
    -e DISABLE_TELEMETRY=1 -e DO_NOT_TRACK=1 -e DISABLE_AUTOUPDATER=1 \
    -e PI_TELEMETRY=0 -e PI_SKIP_VERSION_CHECK=1 \
    --read-only \
    --tmpfs /tmp:size=1g,mode=1777 \
    --tmpfs /var/tmp:size=256m,mode=1777 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --pids-limit "$SBX_PIDS" --memory "$SBX_MEMORY" --cpus "$SBX_CPUS" \
    --ulimit nofile=65536:65536 \
    "$SBX_IMAGE" "${CMD[@]}"
  # (PI_*: same intent for pi — no install telemetry, no pi.dev version check;
  #  model-catalog refreshes stay possible and go through the proxy.)
}
