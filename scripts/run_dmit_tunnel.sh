#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

UPSTREAM_PROXY_HOST="${UPSTREAM_PROXY_HOST:-${IPROYAL_HOST:-}}"
UPSTREAM_PROXY_PORT="${UPSTREAM_PROXY_PORT:-${IPROYAL_PORT:-}}"

exec /usr/bin/ssh -N \
  -L "127.0.0.1:${FORWARD_LOCAL_PORT}:${UPSTREAM_PROXY_HOST}:${UPSTREAM_PROXY_PORT}" \
  -o ExitOnForwardFailure=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=20 \
  -o ServerAliveCountMax=3 \
  -o TCPKeepAlive=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
  -i "$SSH_KEY_PATH" \
  -p "$DMIT_PORT" \
  "${DMIT_USER}@${DMIT_HOST}"
