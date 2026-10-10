# Base image pinned by digest; re-pin when the python line moves.
FROM python:3.13-slim@sha256:8fb4cfa1a2616d7b8e0c2175cc6ad68f5729c34ea8488c0b360d2934b7be9024

# Read-only rootfs container, runs as nobody(65534) (set by run-sandbox.sh).
# The allowlist is bind-mounted by the host at /allowlist/allowlist.txt.
COPY proxy.py /usr/local/lib/sbx-proxy/proxy.py
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "-u", "/usr/local/lib/sbx-proxy/proxy.py"]
