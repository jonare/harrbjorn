#!/usr/bin/env bash
# lib/overlay-diff.sh LOWER MERGED OUT — write a binary-safe git patch of
# MERGED relative to LOWER to OUT (empty when nothing changed).
#
# Run by harrbjorn after an overlay session (--work overlay), in a networkless helper
# container: LOWER is the untouched workdir, MERGED the workdir as the
# agent left it. MERGED is agent-controlled, so nothing in it configures
# git: a private GIT_DIR (the workdir's .git is never read), no system or
# global config, no template hooks, no external diff or textconv.
#
# What the patch holds — as in a repository whose index is LOWER:
#  - .git directories never (git skips them); nested repositories are
#    skipped (--ignore-submodules)
#  - new files ignored by MERGED's .gitignore are left out, but a file
#    LOWER already had stays tracked even if MERGED ignores it (no silent
#    deletion through .gitignore)
#  - plain paths (no rename detection), so the host can list them
set -euo pipefail
lower="$1" merged="$2" out="$3"

GIT_DIR="$(mktemp -d)"
trap 'rm -rf "$GIT_DIR"' EXIT
export GIT_DIR GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=/nonexistent GIT_TERMINAL_PROMPT=0
unset XDG_CONFIG_HOME GIT_WORK_TREE GIT_INDEX_FILE
git init -q --template=

g() { git -c advice.addEmbeddedRepo=false "$@"; }

# LOWER's tree.
GIT_INDEX_FILE="$GIT_DIR/index-lower" GIT_WORK_TREE="$lower" g -C "$lower" add -A
a="$(GIT_INDEX_FILE="$GIT_DIR/index-lower" g write-tree)"

# MERGED's tree, starting from LOWER's entries without stat data (read-tree),
# so every file is re-hashed and LOWER's files stay tracked.
GIT_INDEX_FILE="$GIT_DIR/index-merged" g read-tree "$a"
GIT_INDEX_FILE="$GIT_DIR/index-merged" GIT_WORK_TREE="$merged" g -C "$merged" add -A
b="$(GIT_INDEX_FILE="$GIT_DIR/index-merged" g write-tree)"

g diff --binary --full-index --no-renames --no-ext-diff --no-textconv \
  --ignore-submodules=all "$a" "$b" > "$out"
