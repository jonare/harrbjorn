FROM python:3.13-slim

# Read-only rootfs container, runs as nobody(65534) (set by run-sandbox.sh).
# The allowlist is bind-mounted by the host at /allowlist/allowlist.txt.
COPY proxy.py /usr/local/lib/sbx-proxy/proxy.py
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "-u", "/usr/local/lib/sbx-proxy/proxy.py"]
