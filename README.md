# harrbjorn — an isolated sandbox for autonomous agents

harrbjorn runs an autonomous agent, or any other command, with full
permissions inside a rootless Podman microVM. The agent can only reach
what you give it: a copy of the workdir and the network targets you open
for the session. No sudo, no daemon.

## Use cases

- **Coding agent** (`harrbjorn code`): let an agent work in a repository
  without permission prompts, and without letting it touch the host or the
  rest of the network. Its changes come out as a patch you read before
  applying.
- **Security testing** (`harrbjorn security`): agent-driven testing of a
  scoped set of targets, with pentest tools in the image.

| Use case | Image | Tools |
|---|---|---|
| `code` | `harrbjorn/code` | node, python3, git, build-essential, claude, pi |
| `security` | `harrbjorn/pentest` | same as `code`, plus nmap, sqlmap, hydra, ffuf, whatweb |

## Setup

Requires rootless Podman and KVM with krun (`dnf install crun-krun`).
Without KVM, set `SBX_RUNTIME=crun` in `.env`; this drops the VM layer.

```bash
cp .env.example .env                            # model, resource limits, optional CA
ln -s "$PWD/harrbjorn" ~/.local/bin/harrbjorn   # or run ./harrbjorn
echo 'eval "$(harrbjorn completion)"' >> ~/.bashrc
```

The images are built on first run.

### Agent and model

You choose the agent: harrbjorn runs whatever command you give it. The
image comes with pi and Claude Code installed, and pi is preconfigured for
the model in `.env`. Add other agents to `code/Dockerfile` or install them
during a session.

The model is an OpenAI-compatible endpoint (vLLM, llama.cpp, etc.), set in
`.env` or the environment:

| Variable | Value |
|---|---|
| `SBX_MODEL_BASE_URL` | The endpoint including `/v1`, e.g. `http://localhost:8000/v1` |
| `SBX_MODEL` | The model ID (vLLM: `--served-model-name`) |
| `SBX_MODEL_API_KEY` | Optional (vLLM: `--api-key`) |
| `SBX_MODEL_CONTEXT_WINDOW`, `SBX_MODEL_MAX_TOKENS` | Optional; pi otherwise assumes 128k/16k |

The proxy always lets traffic through to the endpoint. The variables are
set as environment variables inside the sandbox, so other agents can use
them too, which also means the key is readable there. A `localhost` URL is
rewritten to reach the model server on the host, which must then listen
beyond loopback (see [Host services](#host-services)). vLLM needs
`--enable-auto-tool-choice --tool-call-parser <parser>` for pi to get tool
calls.

Claude Code has no model configured: log in during the session and open
`--net @anthropic`.

## Usage

```
harrbjorn code|security [flags] [command [args...]]
```

The workdir is the current directory (or `-w`) and appears as `/work`.
Without a command you get bash.

```bash
harrbjorn code claude                              # interactive Claude Code
harrbjorn code pi -p "Fix the failing tests"       # one-shot run
harrbjorn code --net @dev --work rw claude         # package registries + GitHub, write straight to the workdir
harrbjorn security -w ~/pentest --net 192.168.50.10:8080 pi -p "Test the target"
```

| Flag | Effect |
|---|---|
| `-w DIR` | Workdir. Default: the current directory. |
| `--net LIST` | Network targets for the session, see [Network](#network---net). Default: only the model. |
| `--work MODE` | How the session gets the workdir, see [Workdir](#workdir---work). Default: `overlay`. |
| `-p HOST:PORT` | Route traffic through an external proxy (Burp), see [External proxy](#external-proxy--p). |
| `--ca-cert FILE` | Extra CA to trust, see [Extra CA](#extra-ca---ca-cert). |
| `--resume[=ID]` | Reuse the HOME of the last (or a given) session, see [Sessions](#sessions---resume). |
| `--sessions` | List the sessions for the workdir and exit. |
| `--rebuild` | Rebuild the images. |

Other settings in `.env` (documented in `.env.example`):

| Variable | Default | |
|---|---|---|
| `SBX_MEMORY`, `SBX_CPUS`, `SBX_PIDS` | `4g`, `2`, `1024` | Resource limits |
| `SBX_RUNTIME` | `krun` | `krun`, `runsc` or `crun`. Startup fails if it is missing. |
| `SBX_LOCALE` | `nb_NO.UTF-8` | Or `en_US.UTF-8` |
| `SBX_CA_CERTS` | | Colon-separated CA files, like `--ca-cert` |
| `SBX_UPSTREAM_PORT` | `3129` | Upstream port for `-p` |
| `SBX_KEEP_SESSIONS` | `10` | Sessions kept per workdir |

## Network (`--net`)

Without `--net`, the session can only reach the model endpoint. Everything
else is opened on the command line for each session, never in `.env`.
Entries can be repeated or comma-separated:

| Entry | Opens |
|---|---|
| `example.com` | the host, all ports |
| `*.example.com` | its subdomains, not `example.com` itself |
| `10.1.2.3`, `10.1.2.3:8080`, `[fd00::1]:443` | the IP; the port is enforced only for private addresses |
| `host:PORT` | a service on the host, see [Host services](#host-services) |
| `@name` | a named set, see below |
| `@path/to/file` | a set read from a file (the entry contains `/`) |
| `@all` | everything, including LAN, VPN and the host; can only be combined with `host:PORT` |

The port in `name:port` and on public IPs is not enforced; the wrapper
warns about it.

The sets in `net/` are `@anthropic`, `@github`, `@npm`, `@pypi`, `@maven`,
`@debian` and `@dev` (all except `@anthropic`). Your own sets in
`~/.config/harrbjorn/net/` take precedence over the repository's. A set
file has entries per line, `#` comments, and can include other `@name`
sets. Set files inside the workdir are rejected, since the agent could
widen the next session. Put a pentest scope next to the workdir instead:
`--net @../scope`.

All traffic goes through a forward proxy
([Smokescreen](https://github.com/stripe/smokescreen)). It resolves names
itself, rejects private, loopback, link-local and CGNAT addresses unless
they are listed as IPs, tunnels HTTPS without decrypting it, and logs
every decision:

```bash
podman logs -f sbx-<session>-proxy       # during the session; the name is printed at startup
jq . .sandbox/logs/<session>.jsonl       # afterwards
```

## Workdir (`--work`)

| Mode | `/work` | Output ends up |
|---|---|---|
| `overlay` (default) | overlay; the workdir is untouched | as a patch in `.sandbox/overlay/<session>.patch` |
| `ro` | read-only | in `/out` → `.sandbox/out/<session>/` |
| `none` | empty | in `/out` → `.sandbox/out/<session>/` |
| `rw` | writable; an existing top-level `.git` is read-only | directly in the workdir |
| `rw+git` | writable, including `.git` | directly in the workdir |

With `overlay`, a git patch is built after the session. harrbjorn prints
the diffstat, the command to apply the patch, and the files in it that the
host may end up running (`.envrc`, `Makefile`, `package.json`, IDE, CI and
agent config, executables, symlinks). The list is an aid, not a
guarantee. Read the patch before applying it:

```bash
git -C <workdir> apply .sandbox/overlay/<session>.patch
```

The host does not see the changes while the session runs. Files excluded
by `.gitignore`, nested repositories and the agent's commits are not part
of the patch. If the session is interrupted before the patch is built, the
changes remain in `.sandbox/overlay/<session>/`.

The workdir cannot be `/`, `$HOME` or a directory above it, nor the
harrbjorn repository. Anything else is accepted, including `~/.ssh`.

## Sessions (`--resume`)

Every run gets a new, empty HOME. `--resume` reuses the HOME of the most
recent session for the same workdir and use case, and `--resume=ID` picks
a specific one (`--sessions` lists them). Continue the conversation with
the agent's own flag:

```bash
harrbjorn code --resume claude -c
harrbjorn code --resume=<ID> pi -r
```

A resumed HOME carries everything the agent left there, including
anything a target may have planted. `--net` and `--work` are not
inherited. If a resumed session gets more access than it has had before,
the wrapper warns before starting.

## Host services

The host is closed to the sandbox, except for the model port (from a local
`SBX_MODEL_BASE_URL`) and the ports you open with `--net host:PORT`. They
are reachable at `http://host.containers.internal:PORT`. The agent then
reaches the whole service on that port, not just its API.

The service must listen beyond loopback (e.g. `0.0.0.0`) and **is then
also reachable from the LAN** unless a firewall stops it. Fedora
Workstation's default zone allows ports 1025–65535. This also applies to
the Burp listener with `-p`.

## External proxy (`-p`)

`-p HOST:PORT` routes traffic through e.g. Burp Suite. Burp uses
harrbjorn's proxy as its upstream, so the allowlist and the log still
apply:

```
sandbox → relay → Burp → 127.0.0.1:3129 → harrbjorn proxy → target
```

One-time setup in Burp: *Settings → Network → Connections → Upstream
proxy servers*, destination host `*`, proxy `127.0.0.1:3129`. The rule
applies to all traffic through Burp, so consider a separate Burp project.

- The session does not start if the proxy does not answer, or does not
  forward to harrbjorn (checked with a canary at startup).
- Burp's CA is fetched from `http://<proxy>/cert` and installed in the
  sandbox. It is fetched over plain HTTP, so only use `-p` with a proxy you
  control.
- Traffic to the model and to `host:PORT` bypasses Burp and is not logged.

```bash
harrbjorn security --net target.example.com -p 127.0.0.1:4321 pi -p "Test the target via Burp"
```

## Extra CA (`--ca-cert`)

Behind a TLS-inspecting middlebox, both image builds and HTTPS from the
sandbox fail. `--ca-cert FILE` (repeatable, PEM or DER) or `SBX_CA_CERTS`
adds the CA to the image builds (as a build secret, never in a layer) and
to the sandbox's CA bundle. Rebuild the first time:

```bash
harrbjorn code --rebuild --ca-cert /path/to/root-ca.crt true
```

## Security model

The attacker is the agent itself: prompt-injected by something it reads,
or a model that does destructive things. The host, `.env`, the model
server, the build inputs and any external proxy are trusted.

The isolation has four layers:

1. **Network:** the sandbox sits on its own `--internal` network per
   session with no route out. The only way out is the proxy (with `-p`, a
   relay that only forwards to fixed ports).
2. **Proxy:** the allowlist from `--net`, an IP filter, DNS-rebinding
   protection and a log of every decision.
3. **Container:** read-only root filesystem, `--cap-drop ALL`,
   `no-new-privileges`, resource limits and a separate HOME per session.
4. **MicroVM:** krun gives the sandbox and the proxy their own kernels.
   Layer 3 does not apply inside the guest (root there has all
   capabilities), but all I/O goes through a rootless VMM process without
   capabilities.

harrbjorn does **not** protect against:

- **What the agent writes to the workdir.** The host later runs
  `Makefile`, scripts, `.envrc`, IDE tasks and git hooks. With `overlay`
  you read the patch first; with `rw` it lands directly in the workdir.
  There, only an existing top-level `.git` is protected, not a `.git` the
  agent creates elsewhere.
- **Project config.** Claude Code runs with `bypassPermissions`, so hooks
  and MCP servers in the project's `.claude/settings.json` run without
  asking.
- **Exfiltration to allowed targets.** Anything you open with `--net` can
  receive data, including the model endpoint. CONNECT allows arbitrary TCP
  to an allowed host, e.g. SSH to github.com:22.
- **The host via its own addresses.** If the host's LAN or public IP is in
  the allowlist, the host is reachable on it.
- **Incomplete upstream rules in Burp (`-p`).** Hosts the rule does not
  cover are reached by Burp directly, including the host's loopback and
  LAN.
- **The terminal.** In interactive sessions, output goes straight to your
  terminal, and escape sequences (e.g. OSC 52 to the clipboard) are a way
  out. Read patches and logs with `less`, not `cat`.
- **The proxy and the relay.** If they are compromised, the agent has a
  way out. They are also attached to Podman's default network, where other
  containers can reach them.
- **The supply chain.** Base images and agent versions are pinned;
  transitive npm and apt packages are not. Builds run with full network
  access.
- **Disk usage.** The workdir, the overlay and the sessions have no quota.

## Limitations

- Only proxy-aware tools reach the targets. curl, git and python use
  `HTTP(S)_PROXY`, sqlmap needs `--proxy "$HTTP_PROXY"`, and nmap and hydra
  (raw sockets) cannot reach them.
- An image is only built when it is missing. If you change `code/`,
  `pentest/`, `proxy/` or `relay/`, or want newer versions of Claude Code
  and pi, use `--rebuild`. `harrbjorn security --rebuild` rebuilds both
  code and pentest. pi extensions are baked in from `PI_EXTENSIONS` in
  `code/Dockerfile`.
- On SELinux hosts, the workdir (except with `overlay` and `none`) and the
  session HOME are permanently relabeled to a shared container label.
- Each krun VM uses about 90 MB of memory and takes a few seconds to start.
  `--cpus` does not limit the number of vCPUs. runsc is untested.

## Tests

```bash
bash tests/run-unit.sh                     # no podman, no network
bash tests/test-proxy-integration.sh       # integration, requires podman + KVM
```

## Removal

Each session cleans up after itself, and leftovers from interrupted
sessions are removed at the next startup (not after `kill -9`). To remove
everything:

```bash
podman rm -f $(podman ps -a --filter name=sbx- --format '{{.Names}}' 2>/dev/null)
podman network ls --format '{{.Name}}' | grep -E '^sbx-.*-int$' | xargs -r -n1 podman network rm
podman rmi harrbjorn/code:latest harrbjorn/pentest:latest harrbjorn/sbx-proxy:latest harrbjorn/sbx-relay:latest
rm -rf .sandbox
```
