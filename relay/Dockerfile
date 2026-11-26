# harrbjorn/sbx-relay — fixed-target TCP relay (socat) for -p sessions.
#
# With an external proxy (-p) the session net stays --internal; this relay
# sits on the internal net + pasta's default net and forwards only the
# ports it is started with (see relay.sh and sbx_start_relay in
# lib/sandbox.sh). Run read-only, cap-drop ALL, no-new-privileges, uid 65534
# (root inside the guest under krun, where --sysctl does not reach the guest).
# Base pinned by digest; re-pin when bookworm moves.
FROM docker.io/library/debian:bookworm-slim@sha256:311f7a192fd9a92b165a86b32fa3aae9005b11849bfb1db2d4fd784559ee464f
RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/*
COPY relay.sh /usr/local/bin/relay.sh
RUN chmod 755 /usr/local/bin/relay.sh
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/relay.sh"]
