#!/usr/bin/env bash
# tests/probe.sh — HTTP-probe mot egress-proxyen.
#
# Kjøres I KLIENTCONTAINEREN (fedora-basert, ingen curl): rå /dev/tcp +
# håndskrevet HTTP. Test-driveren (test-proxy-integration.sh) pakker hvert
# påkall i en throwaway-klient på nettverket.
#
# Bruk:
#   ready   <proxy_ip>                 én TCP-tilkobling til :3128 (exit 0/1)
#   get     <proxy_ip> <url> [host]    GET absolutt-URI via proxy
#   post    <proxy_ip> <url> <body>    POST med X-Test-Header: keepme-value
#   connect <proxy_ip> <host:port>     CONNECT; deretter GET / over tunnelen
#
# Output (stdout):
#   STATUS: <statuslinje>
#   HDR:   <responsheader slik den ble sendt>
#   BODY_BEGIN / BODY_END  (body-bytt som base64, ett linje —
#                           byte-eksakt; base64 -d gir kroppen)
set -u
IP="$1"; MODE="$2"; shift 2
P=3128

exec 3<>/dev/tcp/"$IP"/"$P" 2>/dev/null || { echo "TCP_CONNECT_FAILED"; exit 1; }

SC="" CL=""
# Les statuslinje + header til tom linje; husk statuskode og Content-Length.
read_headers() {
  local line
  while IFS= read -r -t 5 line <&3; do
    line="${line%$'\r'}"   # svar bruker CRLF; read beholders \r ellers
    [[ -z "$line" ]] && break
    if [[ "$line" == HTTP/* ]]; then
      echo "STATUS: $line"
      SC="${line#* }"; SC="${SC%% *}"
    else
      echo "HDR: $line"
      case "${line,,}" in
        content-length:*) CL="${line#*: }" ;;
      esac
    fi
  done
}

# Les body til fil: nøyaktig CL-bytt om kjent, ellers til EOF (256KiB-cap).
# timeout på begge vegar: ei halåpen tilkobling må aldri henge testen.
read_body() {
  local f="$1" n=262144
  [[ -n "$CL" ]] && n="$CL"
  timeout 8 head -c "$n" <&3 > "$f" 2>/dev/null || true
}

# Bare les body på suksess-svar (2xx/3xx): 4xx-avvisninger krever aldri
# body, og å vente på de ville koste timeout-tid per tilfelle.
read_body_if_ok() {
  [[ "$SC" == 2* || "$SC" == 3* ]] || return 0
  read_body "$1"
}

body_out() {
  echo "BODY_BEGIN"
  base64 -w0 "$1"
  echo
  echo "BODY_END"
}

host_of() { local hp="${1#http://}"; echo "${hp%%/*}"; }

case "$MODE" in
  ready)
    exit 0
    ;;
  get)
    url="$1"
    host="${3:-$(host_of "$url")}"
    printf 'GET %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: close\r\n\r\n' \
      "$url" "$host" >&3
    read_headers
    read_body_if_ok /tmp/body.bin
    body_out /tmp/body.bin
    exec 3<&- 3>&-
    ;;
  post)
    url="$1"; body="$2"
    host="$(host_of "$url")"
    {
      printf 'POST %s HTTP/1.1\r\n' "$url"
      printf 'Host: %s\r\n' "$host"
      printf 'X-Test-Header: keepme-value\r\n'
      printf 'Content-Length: %s\r\n' "${#body}"
      printf 'Proxy-Connection: close\r\n\r\n'
      printf '%s' "$body"
    } >&3
    read_headers
    read_body_if_ok /tmp/body.bin
    body_out /tmp/body.bin
    exec 3<&- 3>&-
    ;;
  connect)
    hp="$1"
    printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' "$hp" "$hp" >&3
    line=""
    IFS= read -r -t 5 line <&3
    line="${line%$'\r'}"
    echo "STATUS: $line"
    case "$line" in
      HTTP/*[23]*)
        # Tunnelen er åpen; drain resten av headerblokken (skal være tom).
        while IFS= read -r -t 5 line <&3; do
          line="${line%$'\r'}"
          [[ -z "$line" ]] && break
        done
        printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' \
          "$hp" >&3
        read_headers
        read_body /tmp/tunnel.bin
        body_out /tmp/tunnel.bin
        ;;
    esac
    exec 3<&- 3>&-
    ;;
esac
