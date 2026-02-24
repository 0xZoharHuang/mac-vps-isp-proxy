#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

SINGBOX_TUN_CONFIG_FILE="${SINGBOX_TUN_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box-tun.json}"
mkdir -p "$(dirname "$SINGBOX_TUN_CONFIG_FILE")"

TUN_IPV4_ADDR="${TUN_IPV4_ADDR:-172.31.250.1/30}"
TUN_AUTO_ROUTE="${TUN_AUTO_ROUTE:-1}"
TUN_STRICT_ROUTE="${TUN_STRICT_ROUTE:-1}"
TUN_MTU="${TUN_MTU:-1500}"

if [ "$TUN_AUTO_ROUTE" = "1" ]; then
  TUN_AUTO_ROUTE_JSON=true
else
  TUN_AUTO_ROUTE_JSON=false
fi

if [ "$TUN_STRICT_ROUTE" = "1" ]; then
  TUN_STRICT_ROUTE_JSON=true
else
  TUN_STRICT_ROUTE_JSON=false
fi

# TUN root daemon runs independently from user sing-box proxy core.
# Keep this config TUN-only to avoid local port conflicts on 17890/17891.
cat >"$SINGBOX_TUN_CONFIG_FILE" <<JSON
{
  "log": {
    "level": "${SINGBOX_LOG_LEVEL:-info}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "in-tun",
      "address": [
        "${TUN_IPV4_ADDR}"
      ],
      "mtu": ${TUN_MTU},
      "auto_route": ${TUN_AUTO_ROUTE_JSON},
      "strict_route": ${TUN_STRICT_ROUTE_JSON},
      "sniff": true,
      "route_exclude_address": [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
        "${DMIT_HOST}/32",
        "${IPROYAL_HOST}/32"
      ]
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
          "100.64.0.0/10",
          "${DMIT_HOST}/32",
          "${IPROYAL_HOST}/32"
        ],
        "outbound": "direct"
      }
    ],
    "final": "upstream-iproyal",
    "auto_detect_interface": true
  }
}
JSON

chmod 600 "$SINGBOX_TUN_CONFIG_FILE"
echo "Generated sing-box TUN config: $SINGBOX_TUN_CONFIG_FILE"
