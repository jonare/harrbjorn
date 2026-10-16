# harrbjorn/sbx-proxy — Smokescreen egress proxy (stripe/smokescreen).
#
# Pinned to release v0.1.0 (the only published release, 2026-09-21) and
# verified against the SHA256SUMS published with that release. The binary is
# statically linked, so the final image is scratch: no libraries, no distro,
# nothing to patch. Config (YAML main + egress ACL) is generated per session
# by lib/sandbox.sh and bind-mounted read-only at /config; the proxy starts
# with --config-file /config/proxy.yaml (the ACL path is inside it).

FROM debian:bookworm-slim AS fetch
ARG SMOKESCREEN_VERSION=v0.1.0
# sha256 of smokescreen_v0.1.0_linux_amd64.tar.gz per the release's SHA256SUMS
ARG SMOKESCREEN_SHA256=4e1e447449e3cc653dae956208588722b5c8fe8ce894f633adc756a851d1ec46
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget \
    && wget -qO /tmp/smokescreen.tar.gz \
       "https://github.com/stripe/smokescreen/releases/download/${SMOKESCREEN_VERSION}/smokescreen_${SMOKESCREEN_VERSION}_linux_amd64.tar.gz" \
    && echo "${SMOKESCREEN_SHA256}  /tmp/smokescreen.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/smokescreen.tar.gz -C /tmp \
    && cp "/tmp/smokescreen_${SMOKESCREEN_VERSION}_linux_amd64/smokescreen" /tmp/smokescreen

FROM scratch
COPY --from=fetch /tmp/smokescreen /smokescreen
USER 65534:65534
ENTRYPOINT ["/smokescreen"]
