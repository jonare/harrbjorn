#!/usr/bin/env bash
# lib/sandbox.sh — harrbjorn-sandboxens felles kjerne.
#
# Kjent av wrappers (run-code.sh, run-pentest.sh) som setter usecase-kontrakt
# før de kjører `source lib/sandbox.sh; sbx_main "$@"`:
#   SBX_USECASE            code|pentest (logglinjer + container-navn)
#   SBX_IMAGE              bildet som bygges ved behov og kjøres
#   SBX_CONTEXT            build-kontekst (direktori med Dockerfile)
#   SBX_ALLOWLIST_DEFAULT  default-allowlisten (fil i repo-rotten)
# Wrapperen definerer i tillegg sbx_usage() som skriver sin egen hjelpetekst
# og avslutter med gitt exit-kode.

set -euo pipefail

# Repo-rotten = forelderen til lib/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$SCRIPT_DIR/.sandbox"

# Kontrakten — wrappers setter disse; fallbackene er code-usecasen.
SBX_USECASE="${SBX_USECASE:-code}"
SBX_IMAGE="${SBX_IMAGE:-harrbjorn/code:latest}"
SBX_CONTEXT="${SBX_CONTEXT:-code}"
SBX_ALLOWLIST_DEFAULT="${SBX_ALLOWLIST_DEFAULT:-allowlist.code.default}"

image_exists() { $DOCKER image inspect "$1" >/dev/null 2>&1; }

proxy_running() {
  $DOCKER inspect -f '{{.State.Running}}' sbx-proxy 2>/dev/null | grep -q true
}
proxy_hash() {
  $DOCKER inspect -f '{{ index .Config.Labels "sbx.allowlist.hash" }}' sbx-proxy 2>/dev/null
}
proxy_image_id() {
  $DOCKER inspect -f '{{.Image}}' sbx-proxy 2>/dev/null
}
image_id() { $DOCKER image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

sbx_main() {
  local WORKDIR="" EXTRA_HOSTS=() EXTRA_ALLOWLIST=""
  local HOST_ISOLATION=1 HOST_ISOLATION_SET=0 REBUILD=0
  local T CONFIG_ENV=() CFG_GATEWAY_ENTRY="" MERGED HASH BRIDGE NET_ID
  local AGENT_HOME

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -w) WORKDIR="$2"; shift 2 ;;
      -a) EXTRA_HOSTS+=("$2"); shift 2 ;;
      -f) EXTRA_ALLOWLIST="$2"; shift 2 ;;
      --no-host-isolation) HOST_ISOLATION=0; HOST_ISOLATION_SET=1; shift ;;
      --rebuild) REBUILD=1; shift ;;
      -h|--help) sbx_usage 0 ;;
      --) shift; break ;;
      *) echo "error: unknown option: $1" >&2; sbx_usage 1 ;;
    esac
  done
  [[ $# -gt 0 ]] || { echo "error: no command after --" >&2; sbx_usage 1; }
  local CMD=("$@")
  [[ -n "$WORKDIR" ]] || { echo "error: -w <workdir> is required" >&2; sbx_usage 1; }
  [[ -d "$WORKDIR" ]] || { echo "error: workdir $WORKDIR does not exist" >&2; exit 1; }
  local WORKDIR_ABS="$(cd "$WORKDIR" && pwd)"

  # ---------------------------------------------------------------- .env
  # Wrapper-preset (f.eks. SBX_PIDS fra run-pentest.sh) er satt før source;
  # .env vinner alltid over preset, core-fallback vinner over ingenting.
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
  fi
  # .env is sourced above and may set HOST_ISOLATION=1; an explicit
  # --no-host-isolation flag always wins.
  if [[ "$HOST_ISOLATION_SET" -eq 1 ]]; then
    HOST_ISOLATION=0
  else
    HOST_ISOLATION="${HOST_ISOLATION:-1}"
  fi
  local SBX_MEMORY="${SBX_MEMORY:-4g}"
  local SBX_CPUS="${SBX_CPUS:-2}"
  local SBX_PIDS="${SBX_PIDS:-1024}"
  # ----------------------------------------------- model config (injection)
  # The sandbox reuses the host's Claude Code model setup (SBX_CLAUDE_CONFIG,
  # default ~/claude.sh) — same model, effort, context window and key — with
  # one rewrite: a loopback ANTHROPIC_BASE_URL is pointed at the host through
  # the bridge gateway (172.28.0.1) instead of localhost. Only `export ...`
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
          http://localhost:*)   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL/localhost/172.28.0.1} ;;
          http://127.0.0.1:*)   ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL/127.0.0.1/172.28.0.1} ;;
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
      SBX_HOST_PORTS="${SBX_HOST_PORTS:-$cfg_port}"
      CFG_GATEWAY_ENTRY="172.28.0.1:$cfg_port"
    fi
    echo ">> model config: $SBX_CLAUDE_CONFIG (base_url=${cfg_url:-n/a})"
  else
    echo "warn: no model config at $SBX_CLAUDE_CONFIG; falling back to ANTHROPIC_API_KEY in .env." >&2
    CONFIG_ENV=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY in .env, or provide a model config via SBX_CLAUDE_CONFIG}")
  fi
  # Comma-separated tcp ports on the host gateway (172.28.0.1) the sandbox may
  # reach. Defaults to the port parsed from the model config's base URL above.
  SBX_HOST_PORTS="${SBX_HOST_PORTS:-}"

  # ------------------------------------------------------------- docker
  local DOCKER=docker
  if ! $DOCKER info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
      DOCKER="sudo docker"
    else
      echo "error: docker daemon unreachable (or permission denied)." >&2
      echo "  start it with:  sudo systemctl enable --now docker" >&2
      exit 1
    fi
  fi

  # ------------------------------------------------------------ build
  if [[ "$REBUILD" -eq 1 ]] || ! image_exists "$SBX_IMAGE"; then
    echo ">> building $SBX_IMAGE"
    $DOCKER build -t "$SBX_IMAGE" "$SCRIPT_DIR/$SBX_CONTEXT"
  fi
  if [[ "$REBUILD" -eq 1 ]] || ! image_exists "harrbjorn/sbx-proxy:latest"; then
    echo ">> building harrbjorn/sbx-proxy:latest"
    $DOCKER build -t harrbjorn/sbx-proxy:latest "$SCRIPT_DIR/proxy"
  fi

  # ----------------------------------------------------------- networks
  $DOCKER network create --driver bridge --internal --subnet 172.28.0.0/24 sbx-internal \
    || true
  $DOCKER network create --driver bridge --subnet 172.29.0.0/24 sbx-egress \
    || true

  # --------------------------------------------------------- allowlist
  mkdir -p "$STATE_DIR"
  [[ -f "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" ]] \
    || { echo "error: allowlist default '$SBX_ALLOWLIST_DEFAULT' not found" >&2; exit 1; }
  MERGED="$STATE_DIR/allowlist.txt"
  {
    echo "# merged at $(date -u +%Y-%m-%dT%H:%M:%SZ) by harrbjorn $SBX_USECASE"
    grep -vE '^\s*(#|$)' "$SCRIPT_DIR/$SBX_ALLOWLIST_DEFAULT" || true
    for h in ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do echo "$h"; done
    if [[ -n "$EXTRA_ALLOWLIST" ]]; then
      grep -vE '^\s*(#|$)' "$EXTRA_ALLOWLIST" || true
    fi
    # Host model server, derived from the model config's base URL.
    if [[ -n "$CFG_GATEWAY_ENTRY" ]]; then echo "$CFG_GATEWAY_ENTRY"; fi
  } | sort -u > "$MERGED"
  # Hash only the content lines — the header comment carries a run timestamp.
  HASH="$(grep -vE '^\s*#' "$MERGED" | sha256sum | awk '{print $1}')"

  # ------------------------------------------------------- proxy (re)start
  # A rebuilt proxy image (new code) must replace the running container,
  # not just an allowlist change.
  if proxy_running && [[ "$(proxy_hash)" == "$HASH" ]] \
    && [[ "$(proxy_image_id)" == "$(image_id harrbjorn/sbx-proxy:latest)" ]]; then
    echo ">> proxy sbx-proxy: reusing (allowlist unchanged)"
  else
    $DOCKER rm -f sbx-proxy >/dev/null 2>&1 || true
    echo ">> proxy sbx-proxy: starting (allowlist hash ${HASH:0:12})"
    $DOCKER run -d --name sbx-proxy \
      --label sbx.allowlist.hash="$HASH" \
      --label sbx.image.id="$(image_id harrbjorn/sbx-proxy:latest)" \
      --network sbx-internal --network sbx-egress \
      --read-only --tmpfs /tmp:size=32m \
      --cap-drop ALL --security-opt no-new-privileges \
      --user 65534:65534 \
      --memory 256m --pids-limit 128 --ulimit nofile=65536:65536 \
      -v "$MERGED:/allowlist/allowlist.txt:ro,z" \
      harrbjorn/sbx-proxy:latest >/dev/null
    # Wait until the proxy accepts connections on the internal net.
    local i
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
      echo "      install the sudoers drop-in once (etc/harrbjorn-sbx.sudoers; README 'Host-isolasjon')," >&2
      echo "      or install manually, ports from SBX_HOST_PORTS:" >&2
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
      local p
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

  # --------------------------------------------- persistent agent HOME
  # Claude Code keeps its onboarding/settings state in HOME (~/.claude.json and
  # ~/.claude/). Persist it on the host so state survives between runs; the
  # rest of the container filesystem stays read-only.
  AGENT_HOME="$STATE_DIR/agent-home"
  mkdir -p "$AGENT_HOME"
  chown 1000:1000 "$AGENT_HOME"
  chmod 0700 "$AGENT_HOME"

  # Pre-seed Claude Code's interactive state so the first-run wizard (theme ->
  # login/API-key) and the /work trust dialog are skipped entirely. The custom
  # API key from the model config is added to the approved list (the wizard
  # would otherwise validate it against the real Anthropic API and reject it).
  # Existing state is merged, never replaced.
  local CFG_API_KEY="" kv
  for kv in "${CONFIG_ENV[@]}"; do
    case "$kv" in ANTHROPIC_API_KEY=*) CFG_API_KEY="${kv#ANTHROPIC_API_KEY=}" ;; esac
  done
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$AGENT_HOME" "$CFG_API_KEY" <<'PYEOF' \
      || { echo "warn: failed to pre-seed agent HOME; first-run wizard will appear." >&2; }
import json, os, sys
home, key = sys.argv[1], sys.argv[2]
cj = os.path.join(home, ".claude.json")
try:
    with open(cj) as f: d = json.load(f)
except (FileNotFoundError, ValueError):
    d = {}
d["hasCompletedOnboarding"] = True
apk = d.setdefault("customApiKeyResponses", {"approved": [], "rejected": []})
approved = apk.setdefault("approved", [])
if key and key not in approved:
    approved.append(key)
d.setdefault("projects", {}).setdefault("/work", {})["hasTrustDialogAccepted"] = True
tmp = cj + ".tmp"
with open(tmp, "w") as f: json.dump(d, f, indent=2)
os.replace(tmp, cj)
os.chmod(cj, 0o600)
ss = os.path.join(home, ".claude", "settings.json")
if not os.path.exists(ss):
    os.makedirs(os.path.dirname(ss), exist_ok=True)
    with open(ss, "w") as f: json.dump({"theme": "dark"}, f)
PYEOF
  else
    echo "warn: python3 not found; agent HOME not pre-seeded, first-run wizard will appear." >&2
  fi

  # ------------------------------------------------------------- sandbox
  # -i is always required so stdin reaches the container; -t only with a TTY.
  T="-i"
  [[ -t 0 && -t 1 ]] && T="-it"

  echo ">> sandbox [$SBX_USECASE]: image=$SBX_IMAGE workdir=$WORKDIR_ABS cmd=${CMD[*]}"
  $DOCKER run --rm $T --name "sbx-$SBX_USECASE-$(date +%s)" \
    --network sbx-internal \
    --user 1000:1000 \
    -v "$WORKDIR_ABS:/work:z" -v "$AGENT_HOME:/home/agent:z" -w /work \
    "${CONFIG_ENV[@]}" \
    -e HOME=/home/agent \
    -e HTTP_PROXY=http://sbx-proxy:3128 -e http_proxy=http://sbx-proxy:3128 \
    -e HTTPS_PROXY=http://sbx-proxy:3128 -e https_proxy=http://sbx-proxy:3128 \
    -e NO_PROXY='localhost,127.0.0.1,::1' -e no_proxy='localhost,127.0.0.1,::1' \
    -e DISABLE_TELEMETRY=1 -e DO_NOT_TRACK=1 -e DISABLE_AUTOUPDATER=1 \
    --read-only \
    --tmpfs /tmp:uid=1000,gid=1000,size=1g,mode=1777 \
    --tmpfs /var/tmp:uid=1000,gid=1000,size=256m,mode=1777 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --pids-limit "$SBX_PIDS" --memory "$SBX_MEMORY" --cpus "$SBX_CPUS" \
    --ulimit nofile=65536:65536 \
    "$SBX_IMAGE" "${CMD[@]}"
}
