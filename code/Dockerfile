# harrbjorn code-agent sandbox: dev environment + agent CLIs (Claude Code,
# pi) for autonomous code agents. Intended to run with:
# --read-only --cap-drop ALL --security-opt no-new-privileges,
# non-privileged user 1000, tmpfs /tmp /var/tmp /home/agent (see lib/sandbox.sh).
# Base image pinned by digest; re-pin when the node line moves.
FROM node:22-bookworm-slim@sha256:efd0ab5780c2d9ab1f0f869571a00d5edb17793bff4cce4a2792e3eb0ffc7562

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-client \
        build-essential \
        make \
        g++ \
        gcc \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        ripgrep \
        file \
        vim \
        less \
        tar \
        unzip \
        zip \
        locales \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code@2.1.296 \
 && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.3.0

# Pi extensions baked into the image: a space-separated list of pi package
# sources (npm:..., git:github.com/..., or plain npm package names). They are
# installed at build time straight into /usr/local/share/pi/agent/npm via
# PI_CODING_AGENT_DIR (no throwaway HOME + relocate: a cross-directory
# rename on this stack intermittently fails with ENOENT). The container
# filesystem is read-only at runtime, so that store stays pristine;
# /home/agent is a bind mount and the baked store never reaches the agent
# home directly — sbx-init.sh copies it into $HOME/.pi/agent/npm on each run,
# merging into any store the agent already has (the image is the source of
# truth: extensions the agent removed are re-seeded on the next run, like the
# model config). To add an extension, append it here, rebuild, and commit the
# new image digest.
ARG PI_EXTENSIONS=npm:pi-subagents
RUN for src in $PI_EXTENSIONS; do PI_CODING_AGENT_DIR=/usr/local/share/pi/agent pi install "$src"; done \
 && rm -rf /root/.npm /root/.pi

# The base image ships only the POSIX/C locale (LC_CTYPE=POSIX, single-byte),
# which mis-handles the multi-byte UTF-8 a Norwegian keyboard emits for
# å/ø/æ in interactive mode. Generate a Norwegian UTF-8 locale plus a neutral
# en_US.UTF-8 fallback, and default to Norwegian. The wrapper can override via
# SBX_LOCALE (see lib/sandbox.sh); it must be one of the locales generated here.
RUN printf 'nb_NO.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\n' >> /etc/locale.gen \
 && locale-gen

ENV LANG=nb_NO.UTF-8

# node:slim already provides uid 1000 (the 'node' user); rename it so the
# sandbox user has a stable name regardless of the base image's choice.
RUN usermod -l agent -d /home/agent -m node

# Init step: pre-seeds $HOME with Claude Code and pi state before exec'ing
# the command (see sbx-init.sh). Seeding happens inside the container, never
# the host: between runs the agent owns the agent-HOME bind mount and can
# plant symlinks in it, which a host-side seeder would follow.
COPY sbx-init.sh /usr/local/bin/sbx-init.sh
RUN chmod 755 /usr/local/bin/sbx-init.sh

WORKDIR /work
USER agent
ENTRYPOINT ["/usr/local/bin/sbx-init.sh"]
CMD ["bash"]
