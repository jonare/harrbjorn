#!/bin/bash
# relay.sh LISTEN:HOST:PORT... — harrbjorn/sbx-relay entrypoint.
#
# Forwards each LISTEN port to one fixed HOST:PORT (socat, one listener per
# spec). Used with -p: the session net stays --internal and this relay is
# the sandbox's only way out — to the external proxy, the model server and
# the -H host ports, nothing else. Exits as soon as any listener dies, so a
# half-working relay never looks healthy.
set -euo pipefail
(( $# )) || { echo "usage: relay.sh LISTEN:HOST:PORT..." >&2; exit 2; }
for spec in "$@"; do
  lport="${spec%%:*}"; rest="${spec#*:}"
  thost="${rest%:*}"; tport="${rest##*:}"
  if [[ ! "$lport" =~ ^[0-9]+$ || ! "$tport" =~ ^[0-9]+$ || -z "$thost" ]]; then
    echo "relay: bad spec '$spec' (need LISTEN:HOST:PORT)" >&2; exit 2
  fi
  echo "relay: :$lport -> $thost:$tport" >&2
  socat "TCP-LISTEN:$lport,fork,reuseaddr" "TCP:$thost:$tport" &
done
wait -n
echo "relay: a listener exited; stopping" >&2
exit 1
