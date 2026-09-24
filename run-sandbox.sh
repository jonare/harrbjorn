#!/usr/bin/env bash
# run-sandbox.sh — run an agent container isolated from the host.
#
# Usage:
#   ./run-sandbox.sh -w <workdir> [-a host[:port]]... [-f extra-allowlist] \
#                    [--no-host-isolation] [--rebuild] -- <cmd> [args...]
#
# Examples:
#   ./run-sandbox.sh -w ~/proj -- claude --dangerously-skip-permissions
#   ./run-sandbox.sh -w ~/proj -a 192.168.50.10:22 -- claude -p "..."
#
# Isolation layers (each holds on its own):
#   1. sandbox joins the --internal network only (no direct egress)
#   2. the forward proxy is the sole egress path; enforces the allowlist
#   3. host iptables rules (sudo) block the internal-bridge gateway IP hole
#   4. container hardening: read-only, cap-drop ALL, no-new-privileges, limits

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.sandbox"

WORKDIR=""
EXTRA_HOSTS=()
EXTRA_ALLOWLIST=""
HOST_ISOLATION=1
REBUILD=0

usage() { sed -n '2,16p' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w) WORKDIR="$2"; shift 2 ;;
    -a) EXTRA_HOSTS+=("$2"); shift 2 ;;
    -f) EXTRA_ALLOWLIST="$2"; shift 2 ;;
    --no-host-isolation) HOST_ISOLATION=0; shift ;;
    --rebuild) REBUILD=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    *) usage 1 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "error: no command after --" >&2; usage 1; }
CMD=("$@")
[[ -n "$WORKDIR" ]] || { echo "error: -w <workdir> is required" >&2; usage 1; }
[[ -d "$WORKDIR" ]] || { echo "error: workdir $WORKDIR does not exist" >&2; exit 1; }
WORKDIR_ABS="$(cd "$WORKDIR" && pwd)"

# ---------------------------------------------------------------- .env
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi
HOST_ISOLATION="${HOST_ISOLATION:-1}"
SBX_MEMORY="${SBX_MEMORY:-4g}"
SBX_CPUS="${SBX_CPUS:-2}"
SBX_PIDS="${SBX_PIDS:-1024}"
# Comma-separated tcp ports on the host gateway (172.28.0.1) the sandbox may
# reach, e.g. a local OpenAI-compatible model server. Pair each with an
# allowlist entry (172.28.0.1:<port>) via -a/-f or allowlist.default.
SBX_HOST_PORTS="${SBX_HOST_PORTS:-8000}"

# ------------------------------------------------------------- docker
DOCKER=docker
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    echo "error: docker daemon unreachable (or permission denied)." >&2
    echo "  start it with:  sudo systemctl enable --now docker" >&2
    exit 1
  fi
fi

image_exists() { $DOCKER image inspect "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ build
build() {
  if [[ "$REBUILD" -eq 1 ]] || ! image_exists "harrbjorn/sandbox:latest"; then
    echo ">> building harrbjorn/sandbox:latest"
    $DOCKER build -t harrbjorn/sandbox:latest "$SCRIPT_DIR"
  fi
  if [[ "$REBUILD" -eq 1 ]] || ! image_exists "harrbjorn/sbx-proxy:latest"; then
    echo ">> building harrbjorn/sbx-proxy:latest"
    $DOCKER build -t harrbjorn/sbx-proxy:latest "$SCRIPT_DIR/proxy"
  fi
}
build

# ----------------------------------------------------------- networks
$DOCKER network create --driver bridge --internal --subnet 172.28.0.0/24 sbx-internal \
  || true
$DOCKER network create --driver bridge --subnet 172.29.0.0/24 sbx-egress \
  || true

# --------------------------------------------------------- allowlist
mkdir -p "$STATE_DIR"
MERGED="$STATE_DIR/allowlist.txt"
{
  echo "# merged at $(date -u +%Y-%m-%dT%H:%M:%SZ) by run-sandbox.sh"
  grep -vE '^\s*(#|$)' "$SCRIPT_DIR/allowlist.default" || true
  for h in ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do echo "$h"; done
  if [[ -n "$EXTRA_ALLOWLIST" ]]; then
    grep -vE '^\s*(#|$)' "$EXTRA_ALLOWLIST" || true
  fi
} | sort -u > "$MERGED"
# Hash only the content lines — the header comment carries a run timestamp.
HASH="$(grep -vE '^\s*#' "$MERGED" | sha256sum | awk '{print $1}')"

# ------------------------------------------------------- proxy (re)start
proxy_running() {
  $DOCKER inspect -f '{{.State.Running}}' sbx-proxy 2>/dev/null | grep -q true
}
proxy_hash() {
  $DOCKER inspect -f '{{ index .Config.Labels "sbx.allowlist.hash" }}' sbx-proxy 2>/dev/null
}

if proxy_running && [[ "$(proxy_hash)" == "$HASH" ]]; then
  echo ">> proxy sbx-proxy: reusing (allowlist unchanged)"
else
  $DOCKER rm -f sbx-proxy >/dev/null 2>&1 || true
  echo ">> proxy sbx-proxy: starting (allowlist hash ${HASH:0:12})"
  $DOCKER run -d --name sbx-proxy \
    --label sbx.allowlist.hash="$HASH" \
    --network sbx-internal --network sbx-egress \
    --read-only --tmpfs /tmp:size=32m \
    --cap-drop ALL --security-opt no-new-privileges \
    --user 65534:65534 \
    --memory 256m --pids-limit 128 --ulimit nofile=65536:65536 \
    -v "$MERGED:/allowlist/allowlist.txt:ro,z" \
    harrbjorn/sbx-proxy:latest >/dev/null
  # Wait until the proxy accepts connections on the internal net.
  for i in $(seq 1 20); do
    if $DOCKER exec sbx-proxy python3 -c \
      "import socket; socket.create_connection(('127.0.0.1', 3128), 0.5).close()" \
      >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if $DOCKER exec sbx-proxy python3 -c \
    "import socket; socket.create_connection(('127.0.0.1', 3128), 0.5).close()" \
    >/dev/null 2>&1; then
    echo ">> proxy is up"
  else
    echo "error: proxy failed to start; check: docker logs sbx-proxy" >&2
    exit 1
  fi
fi

# ------------------------------------------------- host isolation (sudo)
if [[ "$HOST_ISOLATION" == "1" ]]; then
  BRIDGE=""
  NET_ID="$($DOCKER network inspect -f '{{.Id}}' sbx-internal 2>/dev/null || true)"
  if [[ -n "$NET_ID" ]]; then
    BRIDGE="br-${NET_ID:0:12}"
  fi
  if [[ -z "$BRIDGE" || ! -e "/sys/class/net/$BRIDGE" ]]; then
    echo "warn: could not find bridge for sbx-internal; skipping host-isolation iptables." >&2
  elif ! sudo -n iptables --version >/dev/null 2>&1; then
    echo "warn: sudo (passwordless) unavailable; host-isolation iptables NOT installed." >&2
    echo "      install with (see README 'Fjerne iptables' for removal), ports from SBX_HOST_PORTS:" >&2
    echo "      sudo iptables -N SBX-ISOLATE 2>/dev/null || true" >&2
    echo "      sudo iptables -A SBX-ISOLATE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" >&2
    echo "      sudo iptables -A SBX-ISOLATE -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT" >&2
    echo "      sudo iptables -A SBX-ISOLATE -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT" >&2
    echo "      # for each port P in $SBX_HOST_PORTS:" >&2
    echo "      # sudo iptables -A SBX-ISOLATE -p tcp --dport P -m conntrack --ctstate NEW -j ACCEPT" >&2
    echo "      sudo iptables -A SBX-ISOLATE -j DROP" >&2
    echo "      sudo iptables -I INPUT 1 -i $BRIDGE -j SBX-ISOLATE" >&2
  else
    # Rebuild the chain so the port set always matches SBX_HOST_PORTS.
    sudo -n iptables -D INPUT -i "$BRIDGE" -j SBX-ISOLATE 2>/dev/null || true
    sudo -n iptables -F SBX-ISOLATE 2>/dev/null || true
    sudo -n iptables -X SBX-ISOLATE 2>/dev/null || true
    sudo -n iptables -N SBX-ISOLATE
    sudo -n iptables -A SBX-ISOLATE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    sudo -n iptables -A SBX-ISOLATE -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
    sudo -n iptables -A SBX-ISOLATE -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
    for p in $(echo "$SBX_HOST_PORTS" | tr ',' ' '); do
      [[ "$p" =~ ^[0-9]+$ ]] || { echo "error: SBX_HOST_PORTS contains non-numeric port: $p" >&2; exit 1; }
      sudo -n iptables -A SBX-ISOLATE -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
    done
    sudo -n iptables -A SBX-ISOLATE -j DROP
    sudo -n iptables -I INPUT 1 -i "$BRIDGE" -j SBX-ISOLATE
    echo ">> host isolation: iptables rules in place on $BRIDGE (host tcp ports: ${SBX_HOST_PORTS:-none})"
  fi
fi

# -------------------------------------------------------- model backend
# Two backends, chosen via .env (see .env.example):
#   vllm (default here): ANTHROPIC_BASE_URL -> the host model server via the
#     bridge gateway; needs SBX_HOST_PORTS + allowlist entry 172.28.0.1:<port>.
#   anthropic: a real ANTHROPIC_API_KEY, traffic via the allowlisted API hosts.
MODEL_ENV=()
if [[ -n "${SBX_MODEL_BASE_URL:-}" ]]; then
  M="${SBX_MODEL_NAME:-qwen}"
  MODEL_ENV=(
    -e "CLAUDE_CODE_EFFORT_LEVEL=${SBX_EFFORT_LEVEL:-medium}"
    -e "ANTHROPIC_BASE_URL=${SBX_MODEL_BASE_URL}"
    -e "ANTHROPIC_API_KEY=${SBX_MODEL_API_KEY:-vllm}"
    -e "ANTHROPIC_MODEL=${M}"
    -e "CLAUDE_CODE_SUBAGENT_MODEL=${M}"
    -e "ANTHROPIC_SMALL_FAST_MODEL=${M}"
    -e "ANTHROPIC_DEFAULT_MODEL=${M}"
    -e "ANTHROPIC_DEFAULT_SONNET_MODEL=${M}"
    -e "ANTHROPIC_DEFAULT_HAIKU_MODEL=${M}"
    -e "CLAUDE_CODE_MAX_CONTEXT_TOKENS=${SBX_MAX_CONTEXT_TOKENS:-100000}"
    -e "CLAUDE_CODE_MAX_OUTPUT_TOKENS=${SBX_MAX_OUTPUT_TOKENS:-8192}"
    -e "CLAUDE_CODE_AUTO_COMPACT_WINDOW=${SBX_AUTO_COMPACT_WINDOW:-95000}"
  )
else
  MODEL_ENV=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY in .env, or use the vllm backend (SBX_MODEL_BASE_URL)}")
fi

# ------------------------------------------------------------- sandbox
# -i is always required so stdin reaches the container; -t only with a TTY.
T="-i"
[[ -t 0 && -t 1 ]] && T="-it"

echo ">> sandbox: workdir=$WORKDIR_ABS cmd=${CMD[*]}"
$DOCKER run --rm $T --name "sbx-$(date +%s)" \
  --network sbx-internal \
  --user 1000:1000 \
  -v "$WORKDIR_ABS:/work:z" -w /work \
  "${MODEL_ENV[@]}" \
  -e HOME=/home/agent \
  -e HTTP_PROXY=http://sbx-proxy:3128 -e http_proxy=http://sbx-proxy:3128 \
  -e HTTPS_PROXY=http://sbx-proxy:3128 -e https_proxy=http://sbx-proxy:3128 \
  -e NO_PROXY='localhost,127.0.0.1,::1' -e no_proxy='localhost,127.0.0.1,::1' \
  -e DISABLE_TELEMETRY=1 -e DO_NOT_TRACK=1 -e DISABLE_AUTOUPDATER=1 \
  --read-only \
  --tmpfs /tmp:uid=1000,gid=1000,size=1g,mode=1777 \
  --tmpfs /var/tmp:uid=1000,gid=1000,size=256m,mode=1777 \
  --tmpfs /home/agent:uid=1000,gid=1000,size=2g,mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --pids-limit "$SBX_PIDS" --memory "$SBX_MEMORY" --cpus "$SBX_CPUS" \
  --ulimit nofile=65536:65536 \
  harrbjorn/sandbox:latest "${CMD[@]}"
