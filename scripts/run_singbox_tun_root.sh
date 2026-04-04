#!/usr/bin/env bash
set -euo pipefail

ROOT_ENV_FILE="${DMIT_IPROYAL_ROOT_ENV_FILE:-/usr/local/etc/dmit-iproyal/root.env}"
[ -f "$ROOT_ENV_FILE" ] || { echo "Missing root env file: $ROOT_ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ROOT_ENV_FILE"

SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || true)}"
SINGBOX_TUN_CONFIG_FILE="${SINGBOX_TUN_CONFIG_FILE:-/usr/local/etc/dmit-iproyal/sing-box-tun.json}"
TUN_CONTROL_DIR="${TUN_CONTROL_DIR:-/tmp/dmit-iproyal-control}"
TUN_DISABLE_FILE="${TUN_DISABLE_FILE:-$TUN_CONTROL_DIR/tun.disabled}"
TUN_PID_FILE="${TUN_PID_FILE:-$TUN_CONTROL_DIR/tun.pid}"
TUN_STATUS_FILE="${TUN_STATUS_FILE:-$TUN_CONTROL_DIR/tun.status}"
LAUNCHD_SOFT_MAXFILES="${LAUNCHD_SOFT_MAXFILES:-65536}"
LAUNCHD_HARD_MAXFILES="${LAUNCHD_HARD_MAXFILES:-131072}"

[ -n "$SINGBOX_BIN" ] || {
  echo "sing-box binary not found" >&2
  exit 1
}

[ -f "$SINGBOX_TUN_CONFIG_FILE" ] || {
  echo "Missing TUN config: $SINGBOX_TUN_CONFIG_FILE" >&2
  exit 1
}

ulimit -H -n "$LAUNCHD_HARD_MAXFILES" >/dev/null 2>&1 || true
ulimit -S -n "$LAUNCHD_SOFT_MAXFILES" >/dev/null 2>&1 || true

mkdir -p "$TUN_CONTROL_DIR"

write_status() {
  local state="$1" pid="${2:-}" reason="${3:-}"
  cat >"$TUN_STATUS_FILE" <<EOF_STATUS
state=$state
pid=$pid
reason=$reason
updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF_STATUS
  chmod 644 "$TUN_STATUS_FILE" >/dev/null 2>&1 || true
}

clear_pid_file() {
  rm -f "$TUN_PID_FILE"
}

reap_child() {
  local pid="$1" exit_code
  if wait "$pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  echo "$exit_code"
}

child_pid=""

child_running() {
  [ -n "$child_pid" ] && kill -0 "$child_pid" >/dev/null 2>&1
}

start_child() {
  "$SINGBOX_BIN" check -c "$SINGBOX_TUN_CONFIG_FILE" >/dev/null
  "$SINGBOX_BIN" run -c "$SINGBOX_TUN_CONFIG_FILE" &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$TUN_PID_FILE"
  chmod 644 "$TUN_PID_FILE" >/dev/null 2>&1 || true
  write_status "running" "$child_pid" "sing-box-active"
}

stop_child() {
  local reason="${1:-disabled}"
  if child_running; then
    kill "$child_pid" >/dev/null 2>&1 || true
    reap_child "$child_pid" >/dev/null 2>&1 || true
  fi
  child_pid=""
  clear_pid_file
  write_status "disabled" "" "$reason"
}

cleanup() {
  if child_running; then
    kill "$child_pid" >/dev/null 2>&1 || true
    reap_child "$child_pid" >/dev/null 2>&1 || true
  fi
  clear_pid_file
  write_status "stopped" "" "supervisor-exit"
}

trap cleanup EXIT INT TERM

write_status "starting" "" "supervisor-online"

while true; do
  if [ -f "$TUN_DISABLE_FILE" ]; then
    if child_running; then
      stop_child "disabled-by-control-file"
    else
      clear_pid_file
      write_status "disabled" "" "disabled-by-control-file"
    fi
    sleep 1
    continue
  fi

  if [ -n "$child_pid" ] && ! child_running; then
    exit_code="$(reap_child "$child_pid")"
    child_pid=""
    clear_pid_file
    write_status "crashed" "" "exit_code=$exit_code"
    sleep 1
    continue
  fi

  if ! child_running; then
    write_status "starting" "" "launching-child"
    start_child
  fi

  sleep 1
done
