#!/usr/bin/env bash
# lib/sandbox.sh — harrbjorn-sandboxens felles kjerne.
#
# Kjent av wrappers (run-code.sh, run-pentest.sh) som setter usecase-kontrakt
# før de kjører `source lib/sandbox.sh; sbx_main "$@"`:
#   SBX_USECASE            code|pentest (logglinjer + container-navn)
#   SBX_IMAGE              bildet som bygges ved behov og kjøres
#   SBX_CONTEXT            build-kontekst (direktori med Dockerfile)
#   SBX_ALLOWLIST_DEFAULT  default-allowlisten (fil i repo-rotten)
# Allowlisten håndheves alltid; åpen utgang er allowlistposten '*' (f.eks.
# -a '*'), aldri en env-innstilling (SBX_OPEN_NETWORK ignoreres).
# Wrapperen definerer i tillegg sbx_usage() som skriver sin egen hjelpetekst
# og avslutter med gitt exit-kode.
#
# Runtime: rootless Podman, --userns=keep-id, per-sesjon nett (podman network
# --internal) med per-sesjon proxy som eneste utgang. Med -p er nettet
# fortsatt --internal, og en relay til den eksterne proxyen (+ modellport og
# -H-porter) er eneste utgang (fail-closed: ingen fallback hvis proxyen ikke
# svarer). Ingen sudo: hosten berøres aldri
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
# Egress mode for the proxy policy: 1 only when the allowlist has '*'
# (set in sbx_main; internal, not read from env).
OPEN_EGRESS=0

# Porten harrbjorns egen proxy lytter på (container-side). Ved -p er den
# eksterne proxyens port den som gjelder i stedet, og denne brukes ikke.
PROXY_PORT=3128

# Per-sesjon ressurser (globale slik at EXIT-trappen kan rømme dem).
PROXY_NAME=""
RELAY_NAME=""
RELAY_IP=""
NET_NAME=""
RESOLV_CONF=""
POLICY_DIR=""
SESSION_LOG=""
OVL_PENDING=""   # --overlay upperdir whose patch is not built yet
BUILD_CA=""      # extra CAs for the image builds (build secret), removed after

sbx_cleanup() {
  # stop -t 1 instead of rm -f: krun does not report a SIGTERM stop within
  # the default 10s stop timeout, so rm -f would make every session teardown
  # pay ~10s before its own SIGKILL fallback. With -t 1 the SIGKILL fallback
  # is reached in ~1s — and the session is being torn down either way.
  # (For crun the SIGTERM stops the proxy promptly; same fast path.)
  local c
  for c in "$PROXY_NAME" "$RELAY_NAME"; do
    [[ -n "$c" ]] && { $PODMAN stop -t 1 "$c" >/dev/null 2>&1 || true; }
  done

  # Audit log: the proxy's JSON lines (per-request allow/deny decisions,
  # with the reason) are kept at .sandbox/logs/<session>.jsonl for later
  # debugging — captured while the proxy container still exists.
  if [[ -n "$PROXY_NAME" && -n "$SESSION_LOG" ]]; then
    mkdir -p "$(dirname "$SESSION_LOG")" 2>/dev/null || true
    $PODMAN logs "$PROXY_NAME" >"$SESSION_LOG" 2>&1 || true
  fi

  for c in "$PROXY_NAME" "$RELAY_NAME"; do
    [[ -n "$c" ]] && { $PODMAN rm "$c" >/dev/null 2>&1 || true; }
  done
  $PODMAN network rm "$NET_NAME" >/dev/null 2>&1 || true
  rm -f "$RESOLV_CONF"
  [[ -n "$BUILD_CA" ]] && rm -f "$BUILD_CA"
  if [[ -n "$OVL_PENDING" ]]; then
    echo "warn: overlay: the session ended before the patch was built; the agent's changes are in $OVL_PENDING/up (remove with: podman unshare rm -rf $OVL_PENDING)" >&2
  fi
  rm -rf "$POLICY_DIR"
}

# Session resource names: sbx-<usecase>-<ts>-<pid> (sandbox),
# ...-proxy (proxy), ...-relay (relay, -p) and ...-int (network). The reaper touches nothing else —
# other containers or networks that merely contain "sbx-" are not ours.
SBX_SESSION_CTR_RE='^sbx-[a-z]+-[0-9]+-[0-9]+(-proxy|-relay)?$'
SBX_SESSION_NET_RE='^sbx-[a-z]+-[0-9]+-[0-9]+-int$'

# Reclaim resources from aborted runs: dead session containers and unused
# session networks. Running containers belong to live sessions — untouched
# (so a proxy/relay left running by a wrapper killed with SIGKILL stays until
# removed by hand; see README «Fjerne»).
# A dead proxy's audit log is saved first (the EXIT trap that normally saves
# it never ran), unless that session's log already exists.
sbx_reap_orphans() {
  local c running n log
  for c in $($PODMAN ps -a --filter 'name=^sbx-' --format '{{.Names}}' 2>/dev/null); do
    [[ "$c" =~ $SBX_SESSION_CTR_RE ]] || continue
    running="$($PODMAN inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)"
    [[ "$running" == "true" ]] && continue
    if [[ "$c" == *-proxy ]]; then
      log="${c#sbx-}"; log="$STATE_DIR/logs/${log%-proxy}.jsonl"
      if [[ ! -e "$log" ]]; then
        mkdir -p "$STATE_DIR/logs" 2>/dev/null || true
        $PODMAN logs "$c" >"$log" 2>&1 || true
      fi
    fi
    echo ">> cleanup: removing orphan container $c"
    $PODMAN rm -f "$c" >/dev/null 2>&1 || true
  done
  for n in $($PODMAN network ls --format '{{.Name}}' 2>/dev/null); do
    [[ "$n" =~ $SBX_SESSION_NET_RE ]] || continue
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

# ------------------------------------------------------------ model config
# Names injected from the model config: model/endpoint settings only.
# Anything else the file exports (tokens for other services, ...) stays on
# the host. Shell noise that `env -i sh` adds by itself is dropped silently.
SBX_MODEL_ENV_RE='^(ANTHROPIC_[A-Z0-9_]*|CLAUDE_[A-Z0-9_]*|MAX_THINKING_TOKENS|MAX_MCP_OUTPUT_TOKENS|API_TIMEOUT_MS|BASH_DEFAULT_TIMEOUT_MS|BASH_MAX_TIMEOUT_MS|DISABLE_[A-Z0-9_]*)$'
SBX_SHELL_NOISE_RE='^(PWD|OLDPWD|SHLVL|_)$'

# sbx_model_env FILE — evaluate FILE's `export` lines in a clean shell and
# print the model variables as NUL-terminated NAME=VALUE records (values may
# contain newlines). A loopback ANTHROPIC_BASE_URL is pointed at the host
# via host.containers.internal (pasta's host address). Other names are
# dropped with a warning that names them — never their values. POSIX sh
# only inside: /bin/sh is dash on Debian-family hosts.
sbx_model_env() {
  local exports rec name dropped=()
  exports="$(grep -E '^export[[:space:]]' "$1" || true)"
  while IFS= read -r -d '' rec; do
    name="${rec%%=*}"
    if [[ "$name" =~ $SBX_MODEL_ENV_RE ]]; then
      printf '%s\0' "$rec"
    elif [[ ! "$name" =~ $SBX_SHELL_NOISE_RE ]]; then
      dropped+=("$name")
    fi
  done < <(env -i sh -c '
      eval "$1"
      case "${ANTHROPIC_BASE_URL:-}" in
        http://localhost:*) ANTHROPIC_BASE_URL="http://host.containers.internal:${ANTHROPIC_BASE_URL#http://localhost:}" ;;
        http://127.0.0.1:*) ANTHROPIC_BASE_URL="http://host.containers.internal:${ANTHROPIC_BASE_URL#http://127.0.0.1:}" ;;
      esac
      [ -n "${ANTHROPIC_BASE_URL:-}" ] && export ANTHROPIC_BASE_URL
      env -0' sh "$exports" | LC_ALL=C sort -z)
  if (( ${#dropped[@]} )); then
    echo "warn: model config $1: not injected (not model settings): ${dropped[*]}" >&2
  fi
  return 0
}

# sbx_trusted_model_port URL — print URL's port when URL points at the host
# (host.containers.internal with an explicit port, path allowed); nothing
# otherwise. Only then is the port a trusted host port for the proxy.
sbx_trusted_model_port() {
  local hostport port
  [[ "$1" == *://* ]] || return 0
  hostport="${1#*://}"; hostport="${hostport%%/*}"
  [[ "$hostport" =~ ^host\.containers\.internal:([0-9]{1,5})$ ]] || return 0
  port=$((10#${BASH_REMATCH[1]}))
  if (( port >= 1 && port <= 65535 )); then echo "$port"; fi
  return 0
}

# ------------------------------------------------------------ workdir guard
# _sbx_under A B — true if path A is B or lies below it.
_sbx_under() { [[ "$2" == / || "$1" == "$2" || "$1" == "$2"/* ]]; }

# sbx_check_workdir WORKDIR HOME_DIR REPO_DIR [PROTECTED_FILE...] — refuse a
# workdir that would give the sandbox rw on something the host runs or
# trusts: /, $HOME or a parent of it, the harrbjorn repo (lib/, .env,
# .sandbox/ with other sessions' HOMEs and audit logs) or anything above or
# inside it, and any directory containing a protected file (the model
# config is eval'ed on the host). Compared on physical paths.
sbx_check_workdir() {
  local wd home repo f fr
  wd="$(realpath -m -- "$1")"
  home="$(realpath -m -- "$2")"
  repo="$(realpath -m -- "$3")"
  shift 3
  local why=""
  if [[ "$wd" == / ]]; then
    why="it is the filesystem root"
  elif _sbx_under "$home" "$wd"; then
    why="it is \$HOME or a parent of it ($home)"
  elif _sbx_under "$repo" "$wd"; then
    why="it contains the harrbjorn repo ($repo)"
  elif _sbx_under "$wd" "$repo"; then
    why="it is inside the harrbjorn repo ($repo)"
  else
    for f in "$@"; do
      [[ -e "$f" ]] || continue
      fr="$(realpath -m -- "$f")"
      if _sbx_under "$fr" "$wd"; then
        why="it contains $f, which the host evaluates"
        break
      fi
    done
  fi
  if [[ -n "$why" ]]; then
    echo "error: refusing workdir $1: $why. The sandbox gets rw on the workdir; pick a project directory instead." >&2
    return 1
  fi
}

# ------------------------------------------------------------ agent HOME
# sbx_agent_home STATE_DIR USECASE WORKDIR_ABS — print the persistent agent
# HOME for usecase + workdir. Flat: always directly under
# agent-home/<usecase>/, keyed <basename>-<sha256(workdir)[:16]>. A workdir
# and its subdirectories therefore never get nested HOMEs: each session has
# rw on its own HOME and must not be able to reach (or plant links in)
# another session's.
sbx_agent_home() {
  local state="$1" usecase="$2" wd="$3" base hash
  base="$(basename -- "$wd")"
  [[ "$wd" == / ]] && base=root
  base="${base//[^A-Za-z0-9._-]/_}"
  hash="$(printf '%s' "$wd" | sha256sum)"
  printf '%s/agent-home/%s/%s-%s\n' "$state" "$usecase" "$base" "${hash:0:16}"
}

# sbx_check_agent_home STATE_DIR AGENT_HOME — refuse when AGENT_HOME, or any
# path component between it and STATE_DIR, is a symlink. Host-side mkdir/
# chmod and podman's bind mount all follow links, so a link here would
# redirect them to wherever it points.
sbx_check_agent_home() {
  local state="$1" p="$2"
  while [[ "$p" == "$state"/* ]]; do
    if [[ -L "$p" ]]; then
      echo "error: agent HOME path component '$p' is a symlink; refusing to use it." >&2
      return 1
    fi
    p="$(dirname -- "$p")"
  done
}

# ------------------------------------------------- sessions (one HOME each)
# <base> = sbx_agent_home (per usecase + workdir). Every session has its own
# HOME <base>/<ID> (ID = run id of the session that created it): a new
# session starts from the image alone, untouched by earlier ones, and
# --resume reuses one explicitly. Host-side metadata next to the HOMEs —
# <base> itself is never mounted, so the agent cannot touch it:
# <base>/.index ("ID EPOCH" lines, most recently used last) and
# <base>/.<ID>.lock (flock held by the run that uses the session).
# The metadata never writes through a link: locks are opened for append
# (no truncation, nothing written), the index is replaced via a fresh
# mktemp file + rename, and only well-formed index lines survive.
SBX_SESSION_ID_RE='^[a-z]+-[0-9]+-[0-9]+$'

# sbx_session_index_rewrite BASE DROP_ID [ADD_ID EPOCH] — rewrite the index
# keeping valid lines except DROP_ID, optionally appending ADD_ID.
sbx_session_index_rewrite() {
  local base="$1" drop="$2" add="${3:-}" now="${4:-}" tmp
  (
    flock 8
    tmp="$(mktemp "$base/.index.XXXXXX")" || exit 1
    {
      awk -v id="$drop" '$1 ~ /^[a-z]+-[0-9]+-[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF == 2 && $1 != id' \
        "$base/.index" 2>/dev/null || true
      [[ -n "$add" ]] && echo "$add $now"
    } > "$tmp"
    mv -f "$tmp" "$base/.index"
  ) 8>>"$base/.index.lock"
}

# sbx_session_touch BASE ID [EPOCH] — record ID as most recently used.
sbx_session_touch() { sbx_session_index_rewrite "$1" "$2" "$2" "${3:-$(date +%s)}"; }

# sbx_session_forget BASE ID — drop ID from the index.
sbx_session_forget() { sbx_session_index_rewrite "$1" "$2"; }

# sbx_session_ids BASE — sessions whose HOME exists, most recently used last.
sbx_session_ids() {
  local base="$1" id rest
  [[ -f "$base/.index" ]] || return 0
  while read -r id rest; do
    if [[ "$id" =~ $SBX_SESSION_ID_RE && -d "$base/$id" && ! -L "$base/$id" ]]; then echo "$id"; fi
  done < "$base/.index"
}

# sbx_session_latest BASE — the most recently used session; fails if none.
sbx_session_latest() {
  local id
  id="$(sbx_session_ids "$1" | tail -1)"
  [[ -n "$id" ]] && echo "$id"
}

# sbx_session_list BASE — "ID<TAB>last used<TAB>size", most recent first.
sbx_session_list() {
  local base="$1" id rest
  [[ -f "$base/.index" ]] || return 0
  tac "$base/.index" | while read -r id rest; do
    [[ "$id" =~ $SBX_SESSION_ID_RE && -d "$base/$id" && ! -L "$base/$id" ]] || continue
    printf '%s\t%s\t%s\n' "$id" "$(date -d "@$rest" '+%Y-%m-%d %H:%M' 2>/dev/null)" \
      "$(du -sh "$base/$id" 2>/dev/null | cut -f1)"
  done
}

# sbx_session_lock BASE ID — take the session's lock for this process (held
# until it exits); fails when another run holds it.
sbx_session_lock() {
  local fd
  exec {fd}>>"$1/.$2.lock" || return 1
  if ! flock -n "$fd"; then
    exec {fd}>&-
    echo "error: session $2 is in use by another harrbjorn run." >&2
    return 1
  fi
}

# sbx_session_prune BASE KEEP — remove the HOMEs of all but the KEEP most
# recently used sessions. A session in use (lock held) is kept. rm does not
# follow links inside a HOME; read-only directories the agent left are made
# writable first, and files owned by a subuid go through podman unshare.
sbx_session_prune() {
  local base="$1" keep="$2" ids=() i id
  # Compact first: drop index entries whose HOME vanished.
  mapfile -t ids < <(awk '{print $1}' "$base/.index" 2>/dev/null)
  for id in ${ids[@]+"${ids[@]}"}; do
    [[ "$id" =~ $SBX_SESSION_ID_RE && -d "$base/$id" && ! -L "$base/$id" ]] || sbx_session_forget "$base" "$id"
  done
  mapfile -t ids < <(sbx_session_ids "$base")
  for (( i = 0; i < ${#ids[@]} - keep; i++ )); do
    id="${ids[i]}"
    {
      flock -n 9 || continue
      echo ">> sessions: removing $id (SBX_KEEP_SESSIONS=$keep)" >&2
      rm -rf -- "${base:?}/$id" 2>/dev/null \
        || { chmod -R u+rwX -- "$base/$id" 2>/dev/null; rm -rf -- "${base:?}/$id" 2>/dev/null; } \
        || ${PODMAN:-podman} unshare rm -rf -- "$base/$id" \
        || echo "warn: sessions: could not remove $base/$id" >&2
      [[ -e "$base/$id" ]] || { sbx_session_forget "$base" "$id"; rm -f "$base/.$id.lock"; }
    } 9>>"$base/.$id.lock"
  done
}

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
  python3 - "$MERGED" "$OPEN_EGRESS" "$PROXY_TRUSTED" "$out" "$PROXY_PORT" <<'PY'
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

# Addresses Smokescreen's IP filter denies unless allow_addresses/
# allow_ranges let them through. Only for these does an IP:port entry stay
# port-scoped (the ACL itself has no port dimension).
HOST_ADDR = ipaddress.ip_address("169.254.1.2")   # pasta: host.containers.internal
FILTERED_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7")]

def ip_filtered(ip):
    return (ip.is_loopback or ip.is_link_local or ip.is_multicast
            or ip.is_unspecified
            or any(ip.version == n.version and ip in n for n in FILTERED_NETS))

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

    if ip is not None and ip == HOST_ADDR:
        warn(f"'{line}': {ip} is the host (host.containers.internal) — skipped; "
             "the host is reachable only through its trusted ports (-H PORT, model port)")
        continue
    if ip is not None:
        # IP literal: needs an ACL entry plus an IP-filter exception
        # (loopback/link-local/private are denied by default).
        add_acl(str(ip))
        if portno is not None:
            allow_addresses.append(f"{ip}:{portno}")
            if not ip_filtered(ip):
                warn(f"'{line}': {ip} is a public address — the port is NOT "
                     f"enforced; the entry grants {ip} on all ports "
                     "(Smokescreen ACL has no port dimension)")
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

# ------------------------------------------------------------ probes
# sbx_tcp_probe HOST PORT — true if something accepts a TCP connection at
# HOST:PORT within 5s, checked from the host (HOST may be an IPv6 literal).
# Arguments are passed as data, never spliced into the bash -c string.
sbx_tcp_probe() {
  local h="$1"
  [[ "$h" == *:* ]] && h="[$h]"
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$h" "$2" 2>/dev/null
}

# sbx_wait_tcp NET IP PORT... — wait (up to 90s) until every PORT answers on
# IP, probed from a throwaway container on NET: the exact path a sandboxed
# request takes, so "answered" means "will serve". The alternatives are
# ruled out: krun (microVM) has no `podman exec`; krun's log channel is too
# flaky to poll for a startup line; and the host cannot reach a krun
# container on any network (pasta only bridges container->host). The
# helper reuses $SBX_IMAGE (already built) with the entrypoint overridden,
# so sbx-init.sh never runs. It runs under the session's runtime, so under
# krun the raw-socket probe happens inside a guest, not on the host kernel.
sbx_wait_tcp() {
  local net="$1" ip="$2"; shift 2
  [[ -n "$ip" ]] || return 1
  $PODMAN run --rm "${RUNTIME_ARGS[@]}" --network "$net" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint bash \
    "$SBX_IMAGE" \
    -c 'ip="$1"; shift
        for p in "$@"; do
          for _ in $(seq 1 180); do (exec 3<>"/dev/tcp/$ip/$p") 2>/dev/null && continue 2; sleep 0.5; done
          echo "never answered on $ip:$p"; exit 1
        done' _ "$ip" "$@"
}

# sbx_nofile_limit HARD — nofile limit for the session containers: 65536,
# capped at the host's hard limit HARD (`ulimit -Hn`). Rootless podman
# cannot raise it, and setrlimit then fails at container start (krun and
# crun alike).
sbx_nofile_limit() {
  if [[ "$1" == unlimited ]] || (( $1 > 65536 )); then echo 65536; else echo "$1"; fi
}

# -------------------------------------------------- extra CAs (--ca-cert)
# sbx_ca_pem FILE... — print every certificate in FILEs as PEM blocks: PEM
# files (one certificate or a bundle, text around them is dropped) or a
# single DER certificate. Fails with a message on an unreadable file or one
# without a certificate. For networks whose TLS-inspecting middlebox
# re-signs HTTPS with its own CA.
sbx_ca_pem() {
  local f out
  for f in "$@"; do
    if [[ ! -f "$f" || ! -r "$f" ]]; then
      echo "error: --ca-cert/SBX_CA_CERTS: not readable: $f" >&2
      return 1
    fi
    out="$(openssl crl2pkcs7 -nocrl -certfile "$f" 2>/dev/null | openssl pkcs7 -print_certs 2>/dev/null \
           | sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p')"
    [[ -n "$out" ]] || out="$(openssl x509 -inform DER -in "$f" -outform PEM 2>/dev/null)"
    if [[ -z "$out" ]]; then
      echo "error: --ca-cert/SBX_CA_CERTS: no certificate in $f (PEM or DER expected)" >&2
      return 1
    fi
    printf '%s\n' "$out"
  done
}

# ------------------------------------------------------- overlay (--overlay)
# Paths whose content the host runs or loads without asking: direnv, make/
# just, npm, python build/test hooks, gradle/maven/cargo build scripts,
# version managers, pre-commit/husky, IDE and CI config, agent config. A
# review aid, not a guarantee.
SBX_OVERLAY_SENSITIVE_RE='(^|/)(\.envrc|\.env|[Mm]akefile|GNUmakefile|[Jj]ustfile|package\.json|\.npmrc|\.yarnrc(\.yml)?|setup\.py|conftest\.py|pyproject\.toml|\.pre-commit-config\.yaml|\.gitattributes|\.gitmodules|gradlew|mvnw|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|pom\.xml|build\.rs|\.?mise\.toml|\.tool-versions|CLAUDE\.md|AGENTS\.md|\.gitlab-ci\.yml)$|(^|/)(\.vscode|\.idea|\.claude|\.pi|\.github|\.husky|\.devcontainer|\.cargo|\.mvn|\.direnv)/'

# sbx_overlay_report PATCH WORKDIR — host-side summary of an --overlay
# patch: diffstat, paths to review before applying (sensitive names,
# executables, symlinks) and the apply command. Only parses the patch.
sbx_overlay_report() {
  local patch="$1" wd="$2" rec line p flagged=()
  # Paths are agent-chosen: control characters (terminal escapes that could
  # hide a flagged line) are shown as '?'.
  while IFS= read -r -d '' rec; do
    p="${rec#*$'\t'*$'\t'}"
    [[ "$p" =~ $SBX_OVERLAY_SENSITIVE_RE ]] && flagged+=("${p//[[:cntrl:]]/?}")
  done < <(git apply --numstat -z "$patch")
  while IFS= read -r line; do
    if [[ "$line" =~ ^\ (create\ mode|mode\ change\ [0-7]+\ =\>)\ (100755|120000)\ (.*)$ ]]; then
      p="${BASH_REMATCH[3]//[[:cntrl:]]/?}"
      if [[ "${BASH_REMATCH[2]}" == 100755 ]]; then flagged+=("$p (executable)")
      else flagged+=("$p (symlink)"); fi
    fi
  done < <(git apply --summary "$patch")
  echo ">> overlay: the workdir was not touched; the agent's changes are a patch"
  echo "   (files ignored by .gitignore and nested repositories are not included):"
  git apply --stat "$patch" | sed 's/^/   /'
  if (( ${#flagged[@]} )); then
    echo "   review before applying — the host runs or follows these:"
    printf '     ! %s\n' "${flagged[@]}"
  fi
  printf '   patch:   %q\n' "$patch"
  printf '   apply:   git -C %q apply %q\n' "$wd" "$patch"
}

# sbx_overlay_finish OVL WORKDIR PATCH — after an --overlay session: build
# the patch in a networkless helper (same runtime and image as the
# sandbox; lib/overlay-diff.sh with the untouched workdir as /lower and
# the overlay as /merged), save it as PATCH and remove the upperdir
# (whiteouts are owned by a subuid, hence podman unshare). On failure the
# upperdir is kept and its path printed.
sbx_overlay_finish() {
  local ovl="$1" wd="$2" patch="$3"
  OVL_PENDING=""
  echo ">> overlay: building the patch" >&2
  if ! $PODMAN run --rm "${RUNTIME_ARGS[@]}" --network none \
        --userns=keep-id:uid=1000,gid=1000 --user 1000:1000 \
        -v "$wd:/lower:O" \
        -v "$wd:/merged:O,upperdir=$ovl/up,workdir=$ovl/wk" \
        -v "$ovl/out:/out:z" \
        --read-only --tmpfs /tmp \
        --cap-drop ALL --security-opt no-new-privileges \
        --entrypoint bash "$SBX_IMAGE" \
        -c "$(<"$SCRIPT_DIR/lib/overlay-diff.sh")" _ /lower /merged /out/changes.patch \
     || [[ ! -f "$ovl/out/changes.patch" ]]; then
    echo "error: overlay: could not build the patch; the agent's changes are kept in $ovl/up (remove with: podman unshare rm -rf $ovl)" >&2
    return 1
  fi
  mv "$ovl/out/changes.patch" "$patch"
  $PODMAN unshare rm -rf "$ovl" || echo "warn: overlay: could not remove $ovl (podman unshare rm -rf $ovl)" >&2
  if [[ ! -s "$patch" ]]; then
    rm -f "$patch"
    echo ">> overlay: no changes" >&2
    return 0
  fi
  sbx_overlay_report "$patch" "$wd" >&2
}

# ------------------------------------------------------------ relay (-p)
# sbx_start_relay S SPEC... — start the per-session relay for -p: a fixed-
# target TCP forwarder (harrbjorn/sbx-relay, socat) on pasta's default net
# (reaches the host and the external proxy) + the session's --internal net
# (reaches the sandbox). Each SPEC is LISTEN:HOST:PORT. The sandbox reaches
# nothing but these ports. Sets RELAY_NAME (for cleanup) and RELAY_IP.
# Listening below 1024 (-H 443 etc.) as uid 65534 needs
# ip_unprivileged_port_start=0 in the relay's own netns. Under krun that
# sysctl only reaches the host-side netns — the guest kernel keeps 1024 and
# grants no capabilities from --cap-drop/--user — so the relay runs as root
# in the guest instead. That adds nothing on the host: the VMM process stays
# capless, no-new-privileges and seccomp-filtered, and all guest I/O goes
# through it.
sbx_start_relay() {
  local S="$1"; shift
  local user=65534:65534
  [[ "${SBX_RUNTIME:-}" == krun ]] && user=0:0
  RELAY_NAME="sbx-$S-relay"
  echo ">> relay $RELAY_NAME: starting (net $NET_NAME; $*)"
  $PODMAN run -d --name "$RELAY_NAME" \
    "${RUNTIME_ARGS[@]}" \
    --network podman --network "$NET_NAME" \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user "$user" \
    --memory 128m --pids-limit 256 \
    harrbjorn/sbx-relay:latest "$@" >/dev/null
  RELAY_IP="$($PODMAN inspect \
    -f "{{(index .NetworkSettings.Networks \"$NET_NAME\").IPAddress}}" "$RELAY_NAME")"
  local ports=() spec
  for spec in "$@"; do ports+=("${spec%%:*}"); done
  if sbx_wait_tcp "$NET_NAME" "$RELAY_IP" "${ports[@]}"; then
    echo ">> relay is up ($RELAY_IP)"
  else
    {
      echo "error: relay failed to start (no answered connect to $RELAY_IP on ${ports[*]} within 90s)."
      echo "--- last relay log lines:"
      $PODMAN logs "$RELAY_NAME" 2>&1 | tail -5 || true
    } >&2
    exit 1
  fi
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
  # --no-default-allowlist: only -a/-f (and the trusted host ports, which
  # are not allowlist entries) — the profile for a local model, where the
  # default hosts (LLM APIs, GitHub, package registries) are only exfil and
  # download channels.
  {
    echo "# merged at $(date -u +%Y-%m-%dT%H:%M:%SZ) by harrbjorn $SBX_USECASE"
    if (( ! NO_DEFAULT_ALLOWLIST )); then
      grep -vE '^\s*(#|$)' "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" || true
    fi
    for h in ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do echo "$h"; done
    if [[ -n "$EXTRA_ALLOWLIST" ]]; then
      grep -vE '^\s*(#|$)' "$EXTRA_ALLOWLIST" || true
    fi
  } | grep -vxE '[[:space:]]*\*[[:space:]]*' | sort -u > "$MERGED"   # '*' = mode, not a domain

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
    --memory 256m --pids-limit 128 --ulimit "nofile=$SBX_NOFILE:$SBX_NOFILE" \
    harrbjorn/sbx-proxy:latest \
    --config-file /config/proxy.yaml >/dev/null
  # Wait until the proxy is ready (see sbx_wait_tcp). A config/ACL that
  # fails Validate never binds the socket, so the deadline fires and the
  # error path below does the rest.
  local PROXY_IP
  PROXY_IP="$($PODMAN inspect \
    -f "{{(index .NetworkSettings.Networks \"$NET_NAME\").IPAddress}}" "$PROXY_NAME")"
  if sbx_wait_tcp "$NET_NAME" "$PROXY_IP" "$PROXY_PORT"; then
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
# crun: with krun the boundary is the guest kernel against a capless,
# seccomp-filtered VMM process, and a quiet fallback would drop it without
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
  local REBUILD=0 GIT_RW=0 NO_DEFAULT_ALLOWLIST=0 OVERLAY=0 OVL_DIR="" CA_FILES=() CA_PEM="" RESUME=0 RESUME_ID="" LIST_SESSIONS=0 T CONFIG_ENV=() MODEL_ENV=() PROXY_ENV=() MOUNTS=()
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
      --git-rw) GIT_RW=1; shift ;;
      --overlay) OVERLAY=1; shift ;;
      --resume) RESUME=1; shift ;;
      --resume=*) RESUME=1; RESUME_ID="${1#--resume=}"; shift ;;
      --sessions) LIST_SESSIONS=1; shift ;;
      --ca-cert) [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; sbx_usage 1; }
          CA_FILES+=("$2"); shift 2 ;;
      --no-default-allowlist) NO_DEFAULT_ALLOWLIST=1; shift ;;
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
  # Physical path (symlinks resolved): the guard, the agent-HOME key and the
  # mount must all see the directory that is actually mounted.
  local WORKDIR_ABS
  WORKDIR_ABS="$(cd "$WORKDIR" && pwd -P)"

  # -------------------------------------------------------- external proxy
  # -p host:port: an external forward proxy (e.g. Burp Suite) takes over
  # egress: harrbjorn's Smokescreen proxy is NOT started and its allowlist
  # is NOT enforced. The session net stays --internal all the same: proxy
  # env vars are only a hint a hostile agent ignores, so the "no raw egress"
  # layer must not depend on them. A per-session relay (sbx_start_relay) is
  # the sandbox's only way out — to the external proxy, the model server and
  # the -H ports, nothing else. Fail-closed: if nothing answers on the port
  # the session aborts before any resource exists — no fallback to the
  # per-session proxy or an open network. The check runs from the host,
  # with the address as given (host.containers.internal only exists inside
  # container nets).
  local ext_host ext_port ext_target
  if [[ -n "$EXT_PROXY" ]]; then
    ext_host="${EXT_PROXY%:*}"; ext_port="${EXT_PROXY##*:}"
    ext_host="${ext_host#[}"; ext_host="${ext_host%]}"
    if [[ -z "$ext_host" || "$EXT_PROXY" != *":"* || ! "$ext_port" =~ ^[0-9]+$ ]] \
       || ! (( ext_port >= 1 && ext_port <= 65535 )); then
      echo "error: -p: bad proxy '$EXT_PROXY' (need host:port, port 1-65535)" >&2
      sbx_usage 1
    fi
    if (( ${#EXTRA_HOSTS[@]} )) || [[ -n "$EXTRA_ALLOWLIST" ]]; then
      echo "warn: -a/-f have no effect with -p (harrbjorn's proxy is not started; the external proxy decides what is reachable)." >&2
    fi
    if ! sbx_tcp_probe "$ext_host" "$ext_port"; then
      echo "error: -p: no forward proxy answering at $EXT_PROXY (fail-closed: no fallback, session not started)." >&2
      exit 1
    fi
    # The relay reaches host loopback via host.containers.internal.
    ext_target="$ext_host"
    case "$ext_host" in
      localhost|127.0.0.1|::1) ext_target="host.containers.internal" ;;
      *:*) ext_target="[$ext_host]" ;;
    esac
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
  local SBX_NOFILE; SBX_NOFILE="$(sbx_nofile_limit "$(ulimit -Hn)")"
  # Terminal locale, injected as -e LANG so the host keyboard's multi-byte
  # UTF-8 (å/ø/æ) works in interactive mode (the image defaults to the same).
  # Must be a locale the image generated: nb_NO.UTF-8 (default) / en_US.UTF-8.
  # .env wins; the value is not re-derived from the host on purpose (a C host
  # would silently re-break it).
  local SBX_LOCALE="${SBX_LOCALE:-nb_NO.UTF-8}"
  # Egress: the allowlist is enforced in both usecases. Open egress is the
  # allowlist entry '*' (-a '*', a line in the -f file or the default
  # allowlist) — an explicit choice per session, never env: an exported
  # SBX_OPEN_NETWORK from one session must not silently open another.
  if [[ -n "${SBX_OPEN_NETWORK+x}" ]]; then
    echo "warn: SBX_OPEN_NETWORK is ignored; egress follows the allowlist (open egress: -a '*')." >&2
  fi
  local OPEN_EGRESS=0 h
  for h in ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do [[ "$h" == '*' ]] && OPEN_EGRESS=1; done
  if [[ -n "$EXTRA_ALLOWLIST" ]] && grep -qxE '[[:space:]]*\*[[:space:]]*' "$EXTRA_ALLOWLIST" 2>/dev/null; then
    OPEN_EGRESS=1
  fi
  if (( ! NO_DEFAULT_ALLOWLIST )) && grep -qxE '[[:space:]]*\*[[:space:]]*' "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" 2>/dev/null; then
    OPEN_EGRESS=1
  fi
  # OCI runtime: krun (microVM, default) / runsc / crun. Checked hard in
  # sbx_check_runtime (below, after the podman checks) — no silent fallback.
  local SBX_RUNTIME="${SBX_RUNTIME:-krun}"
  local MODE_TAG=""
  if (( OPEN_EGRESS )) && [[ -z "$EXT_PROXY" ]]; then
    MODE_TAG=", open network"
    echo "warn: open egress ('*' in the allowlist): every public destination is reachable (logged; private, loopback and link-local stay blocked)." >&2
  fi
  if (( NO_DEFAULT_ALLOWLIST )) && { (( OPEN_EGRESS )) || [[ -n "$EXT_PROXY" ]]; }; then
    echo "warn: --no-default-allowlist has no effect with open egress or -p (no allowlist is enforced)." >&2
  fi
  [[ -n "$EXT_PROXY" ]] && MODE_TAG=", external proxy"

  # ----------------------------------------------------------- extra CAs
  # --ca-cert FILE (repeatable) + SBX_CA_CERTS (colon-separated; env/.env):
  # CAs to trust on top of the image's store, e.g. a TLS-inspecting
  # middlebox's root. Validated here, before any resource exists. Used by
  # the image builds (build secret, never stored in a layer) and by the
  # sandbox (sbx-init.sh builds a combined bundle); not by the proxy, which
  # only tunnels TLS.
  if [[ -n "${SBX_CA_CERTS:-}" ]]; then
    local env_cas=()
    IFS=: read -r -a env_cas <<< "$SBX_CA_CERTS"
    CA_FILES=("${env_cas[@]}" ${CA_FILES[@]+"${CA_FILES[@]}"})
  fi
  if (( ${#CA_FILES[@]} )); then
    CA_PEM="$(sbx_ca_pem "${CA_FILES[@]}")" || exit 1
    echo ">> extra CA: $(grep -c -- '-----BEGIN CERTIFICATE-----' <<< "$CA_PEM") certificate(s) from ${CA_FILES[*]}"
  fi

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
  # Workdir guard before anything is evaluated or created: the workdir is
  # mounted rw, so it must not contain anything the host runs or trusts.
  sbx_check_workdir "$WORKDIR_ABS" "$HOME" "$SCRIPT_DIR" "$SBX_CLAUDE_CONFIG" || exit 1

  # ------------------------------------------------------------- session
  # One HOME per session (see sbx_session_touch): without --resume the
  # session gets a fresh HOME, so earlier sessions cannot affect it;
  # --resume[=ID] reuses one as it was. Resolved and locked here, before any
  # resource exists. --sessions lists them and exits.
  local SESSION_BASE SESSION_ID="" AGENT_HOME
  SESSION_BASE="$(sbx_agent_home "$STATE_DIR" "$SBX_USECASE" "$WORKDIR_ABS")"
  sbx_check_agent_home "$STATE_DIR" "$SESSION_BASE" || exit 1
  local SBX_KEEP_SESSIONS="${SBX_KEEP_SESSIONS:-10}"
  if [[ ! "$SBX_KEEP_SESSIONS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: SBX_KEEP_SESSIONS must be a positive integer (got '$SBX_KEEP_SESSIONS')." >&2
    exit 1
  fi
  if (( LIST_SESSIONS )); then
    local listing=""
    [[ -d "$SESSION_BASE" ]] && listing="$(sbx_session_list "$SESSION_BASE")"
    if [[ -n "$listing" ]]; then
      echo "sessions for $SBX_USECASE in $WORKDIR_ABS (most recent first; resume with --resume or --resume=ID):"
      printf '%s\n' "$listing"
    else
      echo "no sessions for $SBX_USECASE in $WORKDIR_ABS"
    fi
    exit 0
  fi
  if (( RESUME )); then
    if [[ -n "$RESUME_ID" ]]; then
      if [[ ! "$RESUME_ID" =~ $SBX_SESSION_ID_RE || ! -d "$SESSION_BASE/$RESUME_ID" || -L "$SESSION_BASE/$RESUME_ID" ]]; then
        echo "error: --resume: no session $RESUME_ID for $SBX_USECASE in $WORKDIR_ABS (see --sessions)." >&2
        exit 1
      fi
      SESSION_ID="$RESUME_ID"
    elif ! SESSION_ID="$( [[ -d "$SESSION_BASE" ]] && sbx_session_latest "$SESSION_BASE")"; then
      echo "error: --resume: no session to resume for $SBX_USECASE in $WORKDIR_ABS." >&2
      exit 1
    fi
    sbx_session_lock "$SESSION_BASE" "$SESSION_ID" || exit 1
  fi
  # Values never go on podman's command line (visible in ps): MODEL_ENV
  # holds NAME=VALUE and is exported only into the environment of the final
  # `podman run`, which gets bare `-e NAME` (podman copies the value from
  # its own environment).
  local rec cfg_url="" cfg_port
  if [[ -f "$SBX_CLAUDE_CONFIG" ]]; then
    while IFS= read -r -d '' rec; do
      MODEL_ENV+=("$rec")
      [[ "$rec" == ANTHROPIC_BASE_URL=* ]] && cfg_url="${rec#*=}"
    done < <(sbx_model_env "$SBX_CLAUDE_CONFIG")
    cfg_port="$(sbx_trusted_model_port "$cfg_url")"
    if [[ -n "$cfg_port" ]]; then
      PROXY_TRUSTED="host.containers.internal:$cfg_port"
    fi
    echo ">> model config: $SBX_CLAUDE_CONFIG (base_url=${cfg_url:-n/a})"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "warn: no model config at $SBX_CLAUDE_CONFIG; using ANTHROPIC_API_KEY from env/.env." >&2
    MODEL_ENV=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  else
    # No key is required: a sandbox for bash, pi against another provider or
    # a claude with its own login works without one.
    echo "warn: no model config at $SBX_CLAUDE_CONFIG and no ANTHROPIC_API_KEY; the agents get no model settings (log in inside the sandbox, or set SBX_CLAUDE_CONFIG)." >&2
  fi
  for rec in ${MODEL_ENV[@]+"${MODEL_ENV[@]}"}; do
    CONFIG_ENV+=(-e "${rec%%=*}")
  done

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

  # ------------------------------------------------------- relay specs (-p)
  # The external proxy plus every trusted host port (model server, -H).
  # In the sandbox host.containers.internal resolves to the relay, so each
  # host port is relayed on the same port number. A host port equal to the
  # external proxy's port only works when it IS the proxy.
  local RELAY_SPECS=() _trusted=() t tp
  if [[ -n "$EXT_PROXY" ]]; then
    RELAY_SPECS=("$ext_port:$ext_target:$ext_port")
    IFS=',' read -r -a _trusted <<< "$PROXY_TRUSTED"
    for t in ${_trusted[@]+"${_trusted[@]}"}; do
      tp="${t##*:}"
      if [[ "$tp" == "$ext_port" ]]; then
        if [[ "$ext_target" != host.containers.internal ]]; then
          echo "error: -p: host port $tp (model server or -H) collides with the external proxy's port $ext_port on another host." >&2
          exit 1
        fi
        continue
      fi
      RELAY_SPECS+=("$tp:host.containers.internal:$tp")
    done
    echo ">> external proxy: $EXT_PROXY via relay (${RELAY_SPECS[*]}; harrbjorn's proxy is not started)"
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
  # Extra CAs reach the builds as the build secret sbx_ca (RUN
  # --mount=type=secret in the Dockerfiles' HTTPS steps): trusted for the
  # fetches only, never written to a layer.
  if [[ -n "$CA_PEM" ]]; then
    mkdir -p "$STATE_DIR"
    BUILD_CA="$STATE_DIR/build-ca-$S.pem"
    (umask 077; printf '%s\n' "$CA_PEM" > "$BUILD_CA")
  fi
  build_image() {
    local img="$1" ctx="$2" secret=()
    [[ -n "$BUILD_CA" ]] && secret=(--secret "id=sbx_ca,src=$BUILD_CA")
    if [[ "$REBUILD" -eq 1 ]] || ! image_exists "$img"; then
      echo ">> building $img"
      $PODMAN build ${secret[@]+"${secret[@]}"} -t "$img" "$SCRIPT_DIR/$ctx"
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
  else
    build_image harrbjorn/sbx-relay:latest relay
  fi
  if [[ -n "$BUILD_CA" ]]; then rm -f "$BUILD_CA"; BUILD_CA=""; fi

  # ----------------------------------------------------------- network
  # Always --internal: the sandbox has no route anywhere; its only way out is
  # harrbjorn's proxy (allowlist → policy → proxy → readiness) or, with -p,
  # the relay to the external proxy.
  $PODMAN network create --internal "$NET_NAME" >/dev/null
  if [[ -n "$EXT_PROXY" ]]; then
    sbx_start_relay "$S" "${RELAY_SPECS[@]}"
  else
    PROXY_NAME="sbx-$S-proxy"
    sbx_start_proxy "$S" "$MODE_TAG"
  fi

  # ------------------------------------------------- agent HOME (per session)
  # Claude Code and pi keep their state in HOME (settings, transcripts,
  # caches). It lives on the host so a session can be resumed; the rest of
  # the container filesystem stays read-only. keep-id maps container uid
  # 1000 to this user's host uid, so no chown is needed.
  #
  # Keyed by usecase + absolute workdir: instances in different workdirs —
  # or in different usecases with the same workdir — share no filesystem
  # state. The key is flat (.sandbox/agent-home/<usecase>/<basename>-<hash>,
  # see sbx_agent_home): a path mirroring the workdir would nest a
  # subdirectory's HOME inside its parent's — rw for the parent's sessions.
  #
  # Each session has its own HOME below that key (resolved above): a new
  # session's HOME is created empty here, a resumed one is reused as is.
  # Sessions sit side by side; each mounts only its own.
  mkdir -p "$SESSION_BASE"
  sbx_check_agent_home "$STATE_DIR" "$SESSION_BASE" || exit 1
  chmod 0700 "$SESSION_BASE"
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$S"
    sbx_session_lock "$SESSION_BASE" "$SESSION_ID" || exit 1
  fi
  AGENT_HOME="$SESSION_BASE/$SESSION_ID"
  sbx_check_agent_home "$STATE_DIR" "$AGENT_HOME" || exit 1
  mkdir -p "$AGENT_HOME"
  sbx_check_agent_home "$STATE_DIR" "$AGENT_HOME" || exit 1
  chmod 0700 "$AGENT_HOME"
  sbx_session_touch "$SESSION_BASE" "$SESSION_ID"
  sbx_session_prune "$SESSION_BASE" "$SBX_KEEP_SESSIONS"
  if (( RESUME )); then echo ">> session: $SESSION_ID (resumed)"; else echo ">> session: $SESSION_ID (new)"; fi

  # Pre-seeding of Claude Code's interactive state (onboarding, /work trust
  # dialog, approved API key, permission mode) is done by the image's init
  # step (code/sbx-init.sh) INSIDE the container — never by a host process.
  # Between runs the agent owns this directory and can plant symlinks in it
  # (e.g. $HOME/.claude -> /work/...); a host-side seeder would follow them
  # and write wherever the link points. Inside the container the same writes
  # can only reach mounts the agent already fully controls.
  # The host-side touches above (mkdir/chmod, the session index and lock
  # files, removing pruned sessions) are safe: they happen in the key
  # directory, which is never mounted (only <key>/<session> is; the workdir
  # guard refuses workdirs at, above or inside the repo), rm does not follow
  # links inside a HOME, and sbx_check_agent_home refuses symlinks along
  # the path.

  # ------------------------------------------------------- proxy env (container)
  # Where the container's traffic goes: the per-session Smokescreen by
  # default, or with -p the relay to the external proxy. With -p,
  # SBX_EXTERNAL_PROXY lets sbx-init.sh detect Burp and install its CA from
  # http://<proxy>/cert (fetched past the proxy env — the listener itself
  # serves it). host.containers.internal resolves to the relay (--add-host)
  # and is in NO_PROXY: an external proxy on the host cannot resolve that
  # name, so host traffic (model server, -H ports) goes to the relay
  # directly. The default branch must NOT list it there: on the --internal
  # net the host is only reachable through Smokescreen (PROXY_TRUSTED).
  local EXTRA_RUN=()
  if [[ -n "$EXT_PROXY" ]]; then
    local rp="http://$RELAY_NAME:$ext_port"
    PROXY_ENV=(-e HTTP_PROXY="$rp" -e http_proxy="$rp"
               -e HTTPS_PROXY="$rp" -e https_proxy="$rp"
               -e NO_PROXY='localhost,127.0.0.1,::1,host.containers.internal' -e no_proxy='localhost,127.0.0.1,::1,host.containers.internal'
               -e SBX_EXTERNAL_PROXY="$rp")
    EXTRA_RUN=(--add-host "host.containers.internal:$RELAY_IP")
  else
    PROXY_ENV=(-e HTTP_PROXY="http://$PROXY_NAME:$PROXY_PORT" -e http_proxy="http://$PROXY_NAME:$PROXY_PORT"
               -e HTTPS_PROXY="http://$PROXY_NAME:$PROXY_PORT" -e https_proxy="http://$PROXY_NAME:$PROXY_PORT"
               -e NO_PROXY='localhost,127.0.0.1,::1' -e no_proxy='localhost,127.0.0.1,::1')
  fi

  # ------------------------------------------------------------- mounts
  # The workdir is rw, but its .git is mounted read-only on top unless
  # --git-rw: git config (core.fsmonitor, core.hooksPath, ...) and hooks
  # written by the agent would run on the HOST at the next git command
  # there — many shell prompts run `git status` on cd. Only an existing
  # top-level .git directory is covered: a .git the agent creates (also in
  # a subdirectory, or when the workdir is not a repo) and a .git file
  # (worktree/submodule, which the agent can repoint) stay writable. That
  # limit is documented; --overlay is the mode that covers them.
  #
  # --overlay instead: /work is an overlay over the workdir with a
  # per-session upperdir — the host's workdir (and .git) is never written
  # or relabeled during the session; the changes come out as a patch
  # afterwards (sbx_overlay_finish).
  if (( OVERLAY )); then
    OVL_DIR="$STATE_DIR/overlay/$S"
    mkdir -p "$OVL_DIR/up" "$OVL_DIR/wk" "$OVL_DIR/out"
    chmod 0700 "$OVL_DIR"
    OVL_PENDING="$OVL_DIR"
    MOUNTS=(-v "$WORKDIR_ABS:/work:O,upperdir=$OVL_DIR/up,workdir=$OVL_DIR/wk")
    if (( GIT_RW )); then
      echo "warn: --git-rw has no effect with --overlay (the host's .git is never written)." >&2
    fi
  else
    MOUNTS=(-v "$WORKDIR_ABS:/work:z")
  fi
  if (( ! OVERLAY )) && [[ -d "$WORKDIR_ABS/.git" && ! -L "$WORKDIR_ABS/.git" ]]; then
    if (( GIT_RW )); then
      echo "warn: --git-rw: the agent can write .git (hooks, config); git run on the host in $WORKDIR_ABS will execute what it plants." >&2
    else
      MOUNTS+=(-v "$WORKDIR_ABS/.git:/work/.git:ro")
    fi
  fi

  # ------------------------------------------------------------- sandbox
  # -i is always required so stdin reaches the container; -t only with a TTY.
  # tmpfs mounts need no uid=/gid=: keep-id makes container 1000 == host
  # 1000, and rootless podman rejects uid=/gid= options anyway.
  T="-i"
  [[ -t 0 && -t 1 ]] && T="-it"

  echo ">> sandbox [$SBX_USECASE]: image=$SBX_IMAGE workdir=$WORKDIR_ABS agent_home=$AGENT_HOME cmd=${CMD[*]}${MODE_TAG}"
  # Subshell: MODEL_ENV is exported for this podman process only (traps are
  # reset in the subshell, so the session cleanup still runs once, here).
  local rc=0
  (
    if (( ${#MODEL_ENV[@]} )); then export "${MODEL_ENV[@]}"; fi
    if [[ -n "$CA_PEM" ]]; then export SBX_EXTRA_CA_PEM="$CA_PEM"; fi
    $PODMAN run --rm $T --name "$SBX_NAME" \
      "${RUNTIME_ARGS[@]}" \
      --userns=keep-id:uid=1000,gid=1000 \
      --network "$NET_NAME" \
      ${EXTRA_RUN[@]+"${EXTRA_RUN[@]}"} \
      --user 1000:1000 \
      "${MOUNTS[@]}" -v "$AGENT_HOME:/home/agent:z" -w /work \
      "${CONFIG_ENV[@]}" \
      ${CA_PEM:+-e SBX_EXTRA_CA_PEM} \
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
      --ulimit "nofile=$SBX_NOFILE:$SBX_NOFILE" \
      "$SBX_IMAGE" "${CMD[@]}"
  ) || rc=$?
  # (PI_*: same intent for pi — no install telemetry, no pi.dev version check;
  #  model-catalog refreshes stay possible and go through the proxy.)

  echo ">> session $SESSION_ID kept: resume with --resume (most recent) or --resume=$SESSION_ID" >&2
  if (( OVERLAY )); then
    sbx_overlay_finish "$OVL_DIR" "$WORKDIR_ABS" "$STATE_DIR/overlay/$S.patch" \
      || { (( rc )) || rc=1; }
  fi
  return "$rc"
}
