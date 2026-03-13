#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box.json}"
proxy_core_upstream_mode="${PROXY_CORE_UPSTREAM_MODE:-relay}"
SURGE_SOCKS_HOST="${SURGE_SOCKS_HOST:-127.0.0.1}"
SURGE_SOCKS_PORT="${SURGE_SOCKS_PORT:-6153}"
UPSTREAM_PROXY_TYPE="${UPSTREAM_PROXY_TYPE:-socks}"
UPSTREAM_PROXY_USER="${UPSTREAM_PROXY_USER-${IPROYAL_USER:-}}"
UPSTREAM_PROXY_PASS="${UPSTREAM_PROXY_PASS-${IPROYAL_PASS:-}}"
mkdir -p "$(dirname "$SINGBOX_CONFIG_FILE")"

username_line=""
password_line=""
[ -n "$UPSTREAM_PROXY_USER" ] && username_line="      \"username\": \"${UPSTREAM_PROXY_USER}\","
[ -n "$UPSTREAM_PROXY_PASS" ] && password_line="      \"password\": \"${UPSTREAM_PROXY_PASS}\","

case "$proxy_core_upstream_mode" in
  relay)
    case "$UPSTREAM_PROXY_TYPE" in
      socks|socks5)
        primary_outbound_json="$(cat <<JSON
    {
      "type": "socks",
      "tag": "primary",
      "server": "127.0.0.1",
      "server_port": ${FORWARD_LOCAL_PORT},
${username_line}
${password_line}
      "version": "5"
    }
JSON
)"
        ;;
      http|https)
        primary_outbound_json="$(cat <<JSON
    {
      "type": "http",
      "tag": "primary",
      "server": "127.0.0.1",
      "server_port": ${FORWARD_LOCAL_PORT},
${username_line}
${password_line}
      "path": ""
    }
JSON
)"
        ;;
      *)
        echo "Unsupported UPSTREAM_PROXY_TYPE for relay mode: $UPSTREAM_PROXY_TYPE" >&2
        exit 1
        ;;
    esac
    ;;
  surge)
    primary_outbound_json="$(cat <<JSON
    {
      "type": "socks",
      "tag": "primary",
      "server": "${SURGE_SOCKS_HOST}",
      "server_port": ${SURGE_SOCKS_PORT},
      "version": "5"
    }
JSON
)"
    ;;
  direct)
    primary_outbound_json="$(cat <<'JSON'
    {
      "type": "direct",
      "tag": "primary"
    }
JSON
)"
    ;;
  *)
    echo "Unsupported PROXY_CORE_UPSTREAM_MODE: $proxy_core_upstream_mode" >&2
    exit 1
    ;;
esac

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
${primary_outbound_json},
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
    "final": "primary",
    "auto_detect_interface": true
  }
}
JSON

chmod 600 "$SINGBOX_CONFIG_FILE"
echo "Generated sing-box config: $SINGBOX_CONFIG_FILE"
