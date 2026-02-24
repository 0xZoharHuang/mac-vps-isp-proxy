#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box.json}"
SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || true)}"

[ -n "$SINGBOX_BIN" ] || {
  echo "sing-box binary not found in PATH" >&2
  exit 1
}

if [ ! -f "$SINGBOX_CONFIG_FILE" ]; then
  "$SCRIPT_DIR/generate_singbox_config.sh"
fi

"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG_FILE" >/dev/null
exec "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG_FILE"
