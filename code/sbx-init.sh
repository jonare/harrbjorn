#!/bin/sh
# harrbjorn sandbox init step: pre-seed $HOME with Claude Code's and pi's
# interactive state, then exec the requested command.
#
# This runs INSIDE the container, not on the host. The agent-HOME bind
# mount is agent-controlled between runs: a previous agent run can plant
# symlinks in it (e.g. $HOME/.claude -> /work/...). A host-side seeder would
# follow them and write wherever the link points. Inside the container the
# same writes can only reach mounts the agent already fully controls
# (/work, $HOME), so no host file is ever touched through a planted link.
set -u

python3 - <<'PYEOF' || echo "warn: failed to pre-seed agent HOME; first-run wizard will appear." >&2
import json, os, sys

# HOME is set by the wrapper (-e HOME=/home/agent); the model config arrives
# via the same env the container's claude uses.
home = os.environ.get("HOME", "/home/agent")
key = os.environ.get("ANTHROPIC_API_KEY", "")

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
os.makedirs(os.path.dirname(ss), exist_ok=True)
try:
    with open(ss) as f: s = json.load(f)
except (FileNotFoundError, ValueError):
    s = {"theme": "dark"}
# The sandbox IS the permission boundary: the container's claude runs with
# bypassPermissions by default (user-level settings — the only place that
# mode is honored), so no --dangerously-skip-permissions flag is needed.
# Existing keys are merged, never replaced.
s.setdefault("skipDangerousModePermissionPrompt", True)
s.setdefault("permissions", {}).setdefault("defaultMode", "bypassPermissions")
with open(ss, "w") as f: json.dump(s, f, indent=2)

# ------------------------------------------------------------- pi (harness)
# pi has no ANTHROPIC_BASE_URL env var: an Anthropic-compatible endpoint must
# be declared in $HOME/.pi/agent/models.json. Seed it from the same env the
# container's claude uses, so both harnesses point at the same model.
#
# The key is referenced by env interpolation ("${ANTHROPIC_API_KEY}") and is
# never written to disk as a literal.
base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
model = os.environ.get("ANTHROPIC_MODEL", "")
if base_url and not model:
    print(f"warn: ANTHROPIC_BASE_URL set but no ANTHROPIC_MODEL; pi gets no "
          f"endpoint config (set ANTHROPIC_MODEL in the model config file)", file=sys.stderr)
if base_url and model:
    provider_id = "harrbjorn"
    # Same limits claude is told about (CLAUDE_CODE_MAX_*_TOKENS from the
    # model config); omit them and pi assumes 128k/16k on its own.
    entry = {
        "name": "harrbjorn model server",
        "baseUrl": base_url,
        "api": "anthropic-messages",
        "apiKey": "${ANTHROPIC_API_KEY}",
        "models": [{"id": model}],
    }
    m = os.environ.get("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "")
    if m.isdigit():
        entry["models"][0]["contextWindow"] = int(m)
    m = os.environ.get("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "")
    if m.isdigit():
        entry["models"][0]["maxTokens"] = int(m)

    pj = os.path.join(home, ".pi", "agent", "models.json")
    os.makedirs(os.path.dirname(pj), exist_ok=True)
    try:
        with open(pj) as f: p = json.load(f)
    except (FileNotFoundError, ValueError):
        p = {}
    # Re-derive the harrbjorn entry from env on every run (the host config is
    # the source of truth and may change between runs); keep any other
    # providers the agent or user added.
    p.setdefault("providers", {})[provider_id] = entry
    tmp = pj + ".tmp"
    with open(tmp, "w") as f: json.dump(p, f, indent=2)
    os.replace(tmp, pj)

    ps = os.path.join(home, ".pi", "agent", "settings.json")
    try:
        with open(ps) as f: psd = json.load(f)
    except (FileNotFoundError, ValueError):
        psd = {}
    # Start every run on the host-configured model, like claude does from
    # ANTHROPIC_MODEL; a /model choice made mid-session may be overwritten
    # on the next run by design. Other keys are merged, never replaced.
    psd["defaultProvider"] = provider_id
    psd["defaultModel"] = model
    with open(ps, "w") as f: json.dump(psd, f, indent=2)
PYEOF

if [ "$#" -gt 0 ]; then
    exec "$@"
fi
exec bash
