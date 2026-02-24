#!/usr/bin/env bash
set -euo pipefail

ROOT_ENV_FILE="${DMIT_IPROYAL_ROOT_ENV_FILE:-/usr/local/etc/dmit-iproyal/root.env}"
[ -f "$ROOT_ENV_FILE" ] || { echo "Missing root env file: $ROOT_ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ROOT_ENV_FILE"

SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || true)}"
SINGBOX_TUN_CONFIG_FILE="${SINGBOX_TUN_CONFIG_FILE:-/usr/local/etc/dmit-iproyal/sing-box-tun.json}"

[ -n "$SINGBOX_BIN" ] || {
  echo "sing-box binary not found" >&2
  exit 1
}

[ -f "$SINGBOX_TUN_CONFIG_FILE" ] || {
  echo "Missing TUN config: $SINGBOX_TUN_CONFIG_FILE" >&2
  exit 1
}

"$SINGBOX_BIN" check -c "$SINGBOX_TUN_CONFIG_FILE" >/dev/null
exec "$SINGBOX_BIN" run -c "$SINGBOX_TUN_CONFIG_FILE"
