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
import json, os, shutil, sys

# HOME is set by the wrapper (-e HOME=/home/agent); the model arrives as
# SBX_MODEL_* env vars (from the host's env/.env).
home = os.environ.get("HOME", "/home/agent")

cj = os.path.join(home, ".claude.json")
try:
    with open(cj) as f: d = json.load(f)
except (FileNotFoundError, ValueError):
    d = {}
d["hasCompletedOnboarding"] = True
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
# pi's model: an OpenAI-compatible endpoint (vLLM, llama.cpp, ...) declared
# in $HOME/.pi/agent/models.json from SBX_MODEL_*. pi sends the key as
# `Authorization: Bearer`, which is what vLLM's --api-key checks.
#
# The key is referenced by env interpolation ("${SBX_MODEL_API_KEY}") and is
# never written to disk as a literal. pi needs some key to offer the model,
# so a server without one gets a dummy.
base_url = os.environ.get("SBX_MODEL_BASE_URL", "")
model = os.environ.get("SBX_MODEL", "")
if base_url and not model:
    print(f"warn: SBX_MODEL_BASE_URL set but no SBX_MODEL; pi gets no "
          f"endpoint config (set SBX_MODEL in env/.env)", file=sys.stderr)
if base_url and model:
    provider_id = "harrbjorn"
    # Omit the limits and pi assumes 128k/16k on its own.
    entry = {
        "name": "harrbjorn model server",
        "baseUrl": base_url,
        "api": "openai-completions",
        "apiKey": "${SBX_MODEL_API_KEY}" if os.environ.get("SBX_MODEL_API_KEY") else "none",
        "models": [{"id": model}],
    }
    m = os.environ.get("SBX_MODEL_CONTEXT_WINDOW", "")
    if m.isdigit():
        entry["models"][0]["contextWindow"] = int(m)
    m = os.environ.get("SBX_MODEL_MAX_TOKENS", "")
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
    # Start every run on the host-configured model (SBX_MODEL); a /model
    # choice made mid-session may be overwritten on the next run by design. Other keys are merged, never replaced.
    psd["defaultProvider"] = provider_id
    psd["defaultModel"] = model
    with open(ps, "w") as f: json.dump(psd, f, indent=2)

# ------------------------------------------------------- pi extensions
# The image bakes operator-chosen extension packages (Dockerfile
# PI_EXTENSIONS) into a read-only store at /usr/local/share/pi/agent/npm.
# The container FS is read-only and /home/agent a bind mount, so that store
# never appears at runtime: seed it into $HOME/.pi/agent/npm here.
#
# The image is the source of truth for baked packages, and agent HOME is
# agent-controlled between runs: every run REPLACES each baked package
# wholesale (modified files restored, extra files gone, a symlink swapped in
# for the package replaced by the real directory) and forces the baked
# specifier into the store's package.json and the baked package-lock.json
# — otherwise pi's `npm install` against the store could resolve a baked
# package to something else. The agent's own packages are kept.
# SBX_PI_BAKED_STORE overrides the baked store's path (tests only).
def replace_tree(src, dst):
    if os.path.islink(dst) or os.path.isfile(dst):
        os.unlink(dst)
    elif os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(src, dst, symlinks=True)

ext = os.environ.get("SBX_PI_BAKED_STORE", "/usr/local/share/pi/agent/npm")
ext_nm = os.path.join(ext, "node_modules")
if os.path.isdir(ext_nm) and os.listdir(ext_nm):
    with open(os.path.join(ext, "package.json")) as f:
        ext_baked = json.load(f)
    store = os.path.join(home, ".pi", "agent", "npm")
    store_nm = os.path.join(store, "node_modules")
    os.makedirs(store_nm, exist_ok=True)
    spj = os.path.join(store, "package.json")
    try:
        with open(spj) as f: sp = json.load(f)
    except (FileNotFoundError, ValueError):
        sp = {"name": "pi-extensions", "private": True}
    if not isinstance(sp.get("dependencies"), dict):
        sp["dependencies"] = {}
    sp["dependencies"].update(ext_baked.get("dependencies", {}))
    tmp = spj + ".tmp"
    with open(tmp, "w") as f: json.dump(sp, f, indent=2)
    os.replace(tmp, spj)
    for entry in sorted(os.listdir(ext_nm)):
        if entry.startswith("."):
            continue
        src = os.path.join(ext_nm, entry)
        if not os.path.isdir(src):
            continue
        if entry.startswith("@"):
            # A scope dir holds several packages: replace each one, keep
            # the agent's own packages in the same scope.
            scope_dst = os.path.join(store_nm, entry)
            if os.path.islink(scope_dst) or os.path.isfile(scope_dst):
                os.unlink(scope_dst)
            for sub in sorted(os.listdir(src)):
                if os.path.isdir(os.path.join(src, sub)):
                    replace_tree(os.path.join(src, sub), os.path.join(scope_dst, sub))
        else:
            replace_tree(src, os.path.join(store_nm, entry))
    baked_lock = os.path.join(ext, "package-lock.json")
    if os.path.exists(baked_lock):
        lock = os.path.join(store, "package-lock.json")
        if os.path.islink(lock):
            os.unlink(lock)
        shutil.copy(baked_lock, lock)
    ps = os.path.join(home, ".pi", "agent", "settings.json")
    try:
        with open(ps) as f: psd = json.load(f)
    except (FileNotFoundError, ValueError):
        psd = {}
    pkgs = psd.setdefault("packages", [])
    for name in ext_baked.get("dependencies", {}):
        spec = "npm:" + name
        if spec not in pkgs:
            pkgs.append(spec)
    with open(ps, "w") as f: json.dump(psd, f, indent=2)
PYEOF

# ------------------------------------------------ CA bundle (--ca-cert, -p)
# Two sources of CAs to trust on top of the system store:
#  - SBX_EXTRA_CA_PEM: the host's --ca-cert / SBX_CA_CERTS (validated there),
#    e.g. the root of a TLS-inspecting middlebox
#  - with -p, the external proxy's CA: when it is Burp Suite, every CONNECT
#    through it fails TLS verification unless Burp's self-signed CA is
#    trusted. Burp serves it at http://<proxy>/cert (DER; PEM accepted too).
#    The fetch bypasses the proxy env (--noproxy): the endpoint is served by
#    the listener itself, and sending it through the proxy would loop. Any
#    failure (no answer, not a certificate) is a silent skip: a non-Burp
#    external proxy needs no CA, and the wrapper already proved the port
#    answers (fail-closed).
# The rootfs is read-only, so they are installed as a combined bundle
# (system store + CAs) in $HOME, fresh on every run — the file lives in
# agent-controlled storage and is never trusted stale — and every tool's CA
# variable points at it.
sys_bundle="${SBX_SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
bundle="$HOME/.sbx-ca-bundle.pem"
extra="$(mktemp /tmp/sbx-ca-extra.XXXXXX 2>/dev/null || true)"
ca_msgs=""
if [ -n "$extra" ] && [ -n "${SBX_EXTRA_CA_PEM:-}" ]; then
    printf '%s\n' "$SBX_EXTRA_CA_PEM" >> "$extra"
    ca_msgs=">> extra CA installed ($(grep -c -- '-----BEGIN CERTIFICATE-----' "$extra") certificate(s) from the host)"
fi
if [ -n "$extra" ] && [ -n "${SBX_EXTERNAL_PROXY:-}" ]; then
    derfile="$(mktemp /tmp/sbx-ca.XXXXXX 2>/dev/null || true)"
    pemfile="$(mktemp /tmp/sbx-cacert.XXXXXX 2>/dev/null || true)"
    if [ -n "$derfile" ] && [ -n "$pemfile" ] && curl -fsS --noproxy '*' --max-time 10 \
        -o "$derfile" "${SBX_EXTERNAL_PROXY%/}/cert" 2>/dev/null \
       && { openssl x509 -inform DER -in "$derfile" -out "$pemfile" 2>/dev/null \
            || openssl x509 -inform PEM -in "$derfile" -out "$pemfile" 2>/dev/null; } \
       && cat "$pemfile" >> "$extra"; then
        ca_msgs="${ca_msgs:+$ca_msgs
}>> Burp CA installed from ${SBX_EXTERNAL_PROXY%/}/cert"
    fi
    rm -f "${derfile:-}" "${pemfile:-}"
fi
if [ -n "$ca_msgs" ] && cat "$sys_bundle" "$extra" > "$bundle" 2>/dev/null; then
    chmod 0600 "$bundle"
    export SSL_CERT_FILE="$bundle" REQUESTS_CA_BUNDLE="$bundle" NODE_EXTRA_CA_CERTS="$bundle" \
           CURL_CA_BUNDLE="$bundle" GIT_SSL_CAINFO="$bundle"
    printf '%s (SSL_CERT_FILE=%s)\n' "$ca_msgs" "$bundle" >&2
fi
rm -f "${extra:-}"

if [ "$#" -gt 0 ]; then
    exec "$@"
fi
exec bash
