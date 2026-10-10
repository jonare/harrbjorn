# harrbjorn code-agent sandbox: dev environment + Claude Code CLI for
# autonomous code agents. Intended to run with:
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
 && npm install -g @anthropic-ai/claude-code@2.1.296

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

WORKDIR /work
USER agent
CMD ["bash"]
