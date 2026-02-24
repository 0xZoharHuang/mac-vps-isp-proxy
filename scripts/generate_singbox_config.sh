#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box.json}"
mkdir -p "$(dirname "$SINGBOX_CONFIG_FILE")"

cat >"$SINGBOX_CONFIG_FILE" <<JSON
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL:-info}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "http",
      "tag": "in-http",
      "listen": "${LOCAL_HTTP_HOST}",
      "listen_port": ${LOCAL_HTTP_PORT}
    },
    {
      "type": "socks",
      "tag": "in-socks",
      "listen": "${LOCAL_SOCKS_HOST}",
      "listen_port": ${LOCAL_SOCKS_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "upstream-iproyal",
      "server": "127.0.0.1",
      "server_port": ${FORWARD_LOCAL_PORT},
      "username": "${IPROYAL_USER}",
      "password": "${IPROYAL_PASS}",
      "version": "5"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_cidr": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "100.64.0.0/10"
        ],
        "outbound": "direct"
      }
    ],
    "final": "upstream-iproyal",
    "auto_detect_interface": true
  }
}
JSON

chmod 600 "$SINGBOX_CONFIG_FILE"
echo "Generated sing-box config: $SINGBOX_CONFIG_FILE"
