#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box.json}"
SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || true)}"
LAUNCHD_SOFT_MAXFILES="${LAUNCHD_SOFT_MAXFILES:-65536}"
LAUNCHD_HARD_MAXFILES="${LAUNCHD_HARD_MAXFILES:-131072}"

[ -n "$SINGBOX_BIN" ] || {
  echo "sing-box binary not found in PATH" >&2
  exit 1
}

if [ ! -f "$SINGBOX_CONFIG_FILE" ]; then
  "$SCRIPT_DIR/generate_singbox_config.sh"
fi

ulimit -H -n "$LAUNCHD_HARD_MAXFILES" >/dev/null 2>&1 || true
ulimit -S -n "$LAUNCHD_SOFT_MAXFILES" >/dev/null 2>&1 || true
echo "run_singbox: fd_soft=$(ulimit -Sn 2>/dev/null || echo unknown) fd_hard=$(ulimit -Hn 2>/dev/null || echo unknown)" >&2

"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG_FILE" >/dev/null
exec "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG_FILE"
