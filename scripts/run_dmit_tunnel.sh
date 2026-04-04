#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

UPSTREAM_PROXY_HOST="${UPSTREAM_PROXY_HOST:-${IPROYAL_HOST:-}}"
UPSTREAM_PROXY_PORT="${UPSTREAM_PROXY_PORT:-${IPROYAL_PORT:-}}"
LAUNCHD_SOFT_MAXFILES="${LAUNCHD_SOFT_MAXFILES:-65536}"
LAUNCHD_HARD_MAXFILES="${LAUNCHD_HARD_MAXFILES:-131072}"

apply_fd_limits() {
  ulimit -H -n "$LAUNCHD_HARD_MAXFILES" >/dev/null 2>&1 || true
  ulimit -S -n "$LAUNCHD_SOFT_MAXFILES" >/dev/null 2>&1 || true
}

apply_fd_limits
echo "run_dmit_tunnel: fd_soft=$(ulimit -Sn 2>/dev/null || echo unknown) fd_hard=$(ulimit -Hn 2>/dev/null || echo unknown)" >&2

exec /usr/bin/ssh -N \
  -L "127.0.0.1:${FORWARD_LOCAL_PORT}:${UPSTREAM_PROXY_HOST}:${UPSTREAM_PROXY_PORT}" \
  -o ExitOnForwardFailure=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -o TCPKeepAlive=yes \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
  -i "$SSH_KEY_PATH" \
  -p "$DMIT_PORT" \
  "${DMIT_USER}@${DMIT_HOST}"
