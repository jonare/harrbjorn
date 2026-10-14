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
# --internal) med per-sesjon proxy som eneste utgang. Ingen sudo: hosten
# berøres aldri (nattverks-isolasjon kjører i nettverket, ikke i iptables).

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

# Per-sesjon ressurser (globale slik at EXIT-trappen kan rømme dem).
PROXY_NAME=""
NET_NAME=""
RESOLV_CONF=""

sbx_cleanup() {
  $PODMAN rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  $PODMAN network rm "$NET_NAME" >/dev/null 2>&1 || true
  rm -f "$RESOLV_CONF"
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

sbx_main() {
  local WORKDIR="" EXTRA_HOSTS=() EXTRA_ALLOWLIST=""
  local HOST_PORTS=()
  local REBUILD=0 T CONFIG_ENV=() MERGED
  local S SBX_NAME PROXY_TRUSTED=""

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
  local MODE_TAG=""
  [[ "$SBX_OPEN_NETWORK" == "1" ]] && MODE_TAG=", open network"

  # ----------------------------------------------- model config (injection)
  # The sandbox reuses the host's Claude Code model setup (SBX_CLAUDE_CONFIG,
  # default ~/claude.sh) — same model, effort, context window and key — with
  # one rewrite: a loopback ANTHROPIC_BASE_URL is pointed at the host through
  # host.containers.internal (pasta host address) instead of localhost. The
  # host address is a *trusted* proxy upstream (SBX_PROXY_TRUSTED below) —
  # it is a runtime exception, never a user allowlist entry. Only `export ...`
  # lines are evaluated, so the file's comments and trailing `claude ...`
  # invocation are ignored. The result is injected as env vars, standalone;
  # no file is mounted into the container.
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

  # ------------------------------------------------------------- session id
  # $S is namespaced per usecase+second+PID; concurrent sessions can't
  # collide, and sbx_reap_orphans only ever touches what it created.
  S="${SBX_USECASE}-$(date +%s)-$$"
  NET_NAME="sbx-$S-int"
  PROXY_NAME="sbx-$S-proxy"
  SBX_NAME="sbx-$S"
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
  build_image harrbjorn/sbx-proxy:latest proxy

  # ----------------------------------------------------------- network
  $PODMAN network create --internal "$NET_NAME" >/dev/null

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
    --userns=keep-id:uid=1000,gid=1000 \
    --network podman --network "$NET_NAME" \
    -v "$RESOLV_CONF:/etc/resolv.conf:ro,z" \
    -e SBX_PROXY_OPEN="$SBX_OPEN_NETWORK" \
    ${PROXY_TRUSTED:+-e SBX_PROXY_TRUSTED="$PROXY_TRUSTED"} \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --user 65534:65534 \
    --memory 256m --pids-limit 128 --ulimit nofile=65536:65536 \
    -v "$MERGED:/allowlist/allowlist.txt:ro,z" \
    harrbjorn/sbx-proxy:latest >/dev/null
  # Wait until the proxy accepts connections (its own loopback).
  local i
  for i in $(seq 1 20); do
    if $PODMAN exec "$PROXY_NAME" python3 -c \
      "import socket; socket.create_connection(('127.0.0.1', 3128), 0.5).close()" \
      >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if $PODMAN exec "$PROXY_NAME" python3 -c \
    "import socket; socket.create_connection(('127.0.0.1', 3128), 0.5).close()" \
    >/dev/null 2>&1; then
    echo ">> proxy is up"
  else
    echo "error: proxy failed to start; check: podman logs $PROXY_NAME" >&2
    exit 1
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

  # ------------------------------------------------------------- sandbox
  # -i is always required so stdin reaches the container; -t only with a TTY.
  # tmpfs mounts need no uid=/gid=: keep-id makes container 1000 == host
  # 1000, and rootless podman rejects uid=/gid= options anyway.
  T="-i"
  [[ -t 0 && -t 1 ]] && T="-it"

  echo ">> sandbox [$SBX_USECASE]: image=$SBX_IMAGE workdir=$WORKDIR_ABS agent_home=$AGENT_HOME cmd=${CMD[*]}${MODE_TAG}"
  $PODMAN run --rm $T --name "$SBX_NAME" \
    --userns=keep-id:uid=1000,gid=1000 \
    --network "$NET_NAME" \
    --user 1000:1000 \
    -v "$WORKDIR_ABS:/work:z" -v "$AGENT_HOME:/home/agent:z" -w /work \
    "${CONFIG_ENV[@]}" \
    -e HOME=/home/agent \
    -e LANG="$SBX_LOCALE" \
    -e HTTP_PROXY="http://$PROXY_NAME:3128" -e http_proxy="http://$PROXY_NAME:3128" \
    -e HTTPS_PROXY="http://$PROXY_NAME:3128" -e https_proxy="http://$PROXY_NAME:3128" \
    -e NO_PROXY='localhost,127.0.0.1,::1' -e no_proxy='localhost,127.0.0.1,::1' \
    -e DISABLE_TELEMETRY=1 -e DO_NOT_TRACK=1 -e DISABLE_AUTOUPDATER=1 \
    --read-only \
    --tmpfs /tmp:size=1g,mode=1777 \
    --tmpfs /var/tmp:size=256m,mode=1777 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --pids-limit "$SBX_PIDS" --memory "$SBX_MEMORY" --cpus "$SBX_CPUS" \
    --ulimit nofile=65536:65536 \
    "$SBX_IMAGE" "${CMD[@]}"
}
