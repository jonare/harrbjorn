#!/bin/sh
# harrbjorn sandbox init step: pre-seed $HOME with Claude Code's interactive
# state, then exec the requested command.
#
# This runs INSIDE the container, not on the host. The agent-HOME bind
# mount is agent-controlled between runs: a previous agent run can plant
# symlinks in it (e.g. $HOME/.claude -> /work/...). A host-side seeder would
# follow them and write wherever the link points. Inside the container the
# same writes can only reach mounts the agent already fully controls
# (/work, $HOME), so no host file is ever touched through a planted link.
set -u

python3 - <<'PYEOF' || echo "warn: failed to pre-seed agent HOME; first-run wizard will appear." >&2
import json, os

# HOME is set by the wrapper (-e HOME=/home/agent); the API key arrives via
# the same env the container's claude uses.
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
PYEOF

if [ "$#" -gt 0 ]; then
    exec "$@"
fi
exec bash
