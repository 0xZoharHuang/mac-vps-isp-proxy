#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
SHELL_ENV_FILE="${DMIT_IPROYAL_SHELL_ENV_FILE:-$HOME/.config/dmit-iproyal/shell_proxy.env}"
ZSHRC_FILE="${DMIT_IPROYAL_ZSHRC_FILE:-$HOME/.zshrc}"
ZSHENV_FILE="${DMIT_IPROYAL_ZSHENV_FILE:-$HOME/.zshenv}"

TUNNEL_LABEL="com.zohar.dmit.iproyal.tunnel"
SINGBOX_LABEL="com.zohar.dmit.iproyal.singbox"
ROOT_TUN_LABEL="com.zohar.dmit.iproyal.singbox.tun"

TUNNEL_PLIST="$HOME/Library/LaunchAgents/${TUNNEL_LABEL}.plist"
SINGBOX_PLIST="$HOME/Library/LaunchAgents/${SINGBOX_LABEL}.plist"
ROOT_TUN_PLIST="/Library/LaunchDaemons/${ROOT_TUN_LABEL}.plist"
ROOT_TUN_ETC_DIR="/usr/local/etc/dmit-iproyal"
ROOT_TUN_LIBEXEC_DIR="/usr/local/libexec/dmit-iproyal"
ROOT_TUN_ENV_FILE="$ROOT_TUN_ETC_DIR/root.env"
ROOT_TUN_CONFIG_FILE="$ROOT_TUN_ETC_DIR/sing-box-tun.json"
ROOT_TUN_CONFIG_FILE_LEGACY="$ROOT_TUN_ETC_DIR/singbox-tun.json"
ROOT_TUN_RUN_SCRIPT="$ROOT_TUN_LIBEXEC_DIR/run_singbox_tun_root.sh"

LOG_DIR="$HOME/Library/Logs/dmit-iproyal"
STATE_DIR="${DMIT_IPROYAL_STATE_DIR:-$HOME/.config/dmit-iproyal/state}"
CONTROL_DIR="${DMIT_IPROYAL_CONTROL_DIR:-$HOME/.config/dmit-iproyal/control}"
HEALTH_STATE_FILE="$STATE_DIR/health.env"
MONITOR_LOCK_DIR="$STATE_DIR/health-monitor.lock"
MODE_SWITCH_LOCK_FILE="$STATE_DIR/mode-switch.lock"
TUN_DISABLE_FILE="$CONTROL_DIR/tun.disabled"
TUN_STATUS_FILE="$CONTROL_DIR/tun.status"
TUN_PID_FILE="$CONTROL_DIR/tun.pid"
SURGE_CLI="/Applications/Surge.app/Contents/Applications/surge-cli"
SURGE_BIN_MATCH="/Applications/Surge.app/Contents/MacOS/Surge"
SURGE_HTTP_HOST="${SURGE_HTTP_HOST:-127.0.0.1}"
SURGE_HTTP_PORT="${SURGE_HTTP_PORT:-6152}"
SURGE_SOCKS_HOST="${SURGE_SOCKS_HOST:-127.0.0.1}"
SURGE_SOCKS_PORT="${SURGE_SOCKS_PORT:-6153}"
HEALTH_MONITOR_LABEL="com.zohar.dmit.iproyal.healthmonitor"
HEALTH_MONITOR_PLIST="$HOME/Library/LaunchAgents/${HEALTH_MONITOR_LABEL}.plist"

ADMIN_PROMPT="${DMIT_IPROYAL_ADMIN_PROMPT:-0}"

[ -f "$ENV_FILE" ] || {
  echo "Missing env file: $ENV_FILE"
  echo "Run: $REPO_ROOT/scripts/setup_dmit_iproyal_stack.sh"
  exit 1
}

# shellcheck disable=SC1090
source "$ENV_FILE"

UPSTREAM_PROXY_HOST="${UPSTREAM_PROXY_HOST:-${IPROYAL_HOST:-}}"

DEFAULT_BYPASS=(
  "localhost"
  "127.0.0.1"
  "::1"
  "*.local"
  "*.ts.net"
  "login.tailscale.com"
  "controlplane.tailscale.com"
  "100.64.0.0/10"
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
)

# Health probes (ordered): prefer neutral endpoints that work across more
# commercial proxy providers than provider-owned trace pages.
PUBLIC_IP_PROBE_URLS=(
  "https://ifconfig.me/ip"
  "https://ipv4.icanhazip.com"
  "https://api64.ipify.org"
)

HTTPS_CONNECT_PROBE_URLS=(
  "https://example.com/"
  "https://www.apple.com/"
  "https://api.github.com/"
)

cli_proxy_mode="${CLI_PROXY_MODE:-http}"
proxy_scope="${PROXY_SCOPE:-active}"
tun_keep_proxy_core="${TUN_KEEP_PROXY_CORE:-1}"
tun_keep_shell_env="${TUN_KEEP_SHELL_ENV:-1}"
probe_connect_timeout="${PROBE_CONNECT_TIMEOUT:-3}"
probe_max_time="${PROBE_MAX_TIME:-7}"
probe_fast_connect_timeout="${PROBE_FAST_CONNECT_TIMEOUT:-1}"
probe_fast_max_time="${PROBE_FAST_MAX_TIME:-3}"
tun_ready_attempts="${TUN_READY_ATTEMPTS:-20}"
tun_postcheck_attempts="${TUN_POSTCHECK_ATTEMPTS:-12}"
stack_proxy_precutover_attempts="${STACK_PROXY_PRECUTOVER_ATTEMPTS:-20}"
stack_proxy_precutover_consecutive="${STACK_PROXY_PRECUTOVER_CONSECUTIVE:-3}"
stack_proxy_postcheck_attempts="${STACK_PROXY_POSTCHECK_ATTEMPTS:-6}"
stack_proxy_postcheck_interval="${STACK_PROXY_POSTCHECK_INTERVAL:-2}"
proxy_core_upstream_mode="${PROXY_CORE_UPSTREAM_MODE:-relay}"
surge_proxy_wait_attempts="${SURGE_PROXY_WAIT_ATTEMPTS:-20}"
health_monitor_interval="${HEALTH_MONITOR_INTERVAL:-30}"
health_failure_threshold="${HEALTH_FAILURE_THRESHOLD:-3}"
auto_fallback_to_surge="${AUTO_FALLBACK_TO_SURGE:-1}"
launchd_soft_maxfiles="${LAUNCHD_SOFT_MAXFILES:-65536}"
launchd_hard_maxfiles="${LAUNCHD_HARD_MAXFILES:-131072}"
log_rotate_max_bytes="${LOG_ROTATE_MAX_BYTES:-10485760}"
log_rotate_keep="${LOG_ROTATE_KEEP:-5}"
mode_switch_context="${DMIT_IPROYAL_MODE_SWITCH_CONTEXT:-manual}"

run_admin_cmd() {
  local cmd="$1"

  if sudo -n true >/dev/null 2>&1; then
    sudo /bin/bash -lc "$cmd"
    return 0
  fi

  if [ "$ADMIN_PROMPT" = "1" ]; then
    local escaped
    escaped="${cmd//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    /usr/bin/osascript <<APPLESCRIPT
try
  do shell script "$escaped" with administrator privileges
  return "OK"
on error errMsg number errNum
  error errMsg number errNum
end try
APPLESCRIPT
    return 0
  fi

  echo "Admin privileges required. Retry with GUI prompt:" >&2
  echo "  DMIT_IPROYAL_ADMIN_PROMPT=1 $0 <command>" >&2
  return 1
}

with_gui_prompt() {
  local old="$ADMIN_PROMPT"
  ADMIN_PROMPT=1
  "$@"
  local code=$?
  ADMIN_PROMPT="$old"
  return "$code"
}

ensure_runtime_dirs() {
  mkdir -p "$(dirname "$SHELL_ENV_FILE")" "$LOG_DIR" "$STATE_DIR" "$CONTROL_DIR"
  chmod 700 "$STATE_DIR" "$CONTROL_DIR" >/dev/null 2>&1 || true
}

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

state_quote() {
  printf '%q' "$1"
}

health_state_reset_memory() {
  health_degraded="no"
  auto_fallback="no"
  health_failure_count="0"
  last_failure_mode=""
  last_failure_at=""
  last_failure_reason=""
  last_success_mode=""
  last_success_at=""
}

health_state_load() {
  health_state_reset_memory
  if [ -f "$HEALTH_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HEALTH_STATE_FILE"
  fi
}

health_state_save() {
  ensure_runtime_dirs
  cat >"$HEALTH_STATE_FILE" <<EOF_STATE
health_degraded=$(state_quote "${health_degraded:-no}")
auto_fallback=$(state_quote "${auto_fallback:-no}")
health_failure_count=$(state_quote "${health_failure_count:-0}")
last_failure_mode=$(state_quote "${last_failure_mode:-}")
last_failure_at=$(state_quote "${last_failure_at:-}")
last_failure_reason=$(state_quote "${last_failure_reason:-}")
last_success_mode=$(state_quote "${last_success_mode:-}")
last_success_at=$(state_quote "${last_success_at:-}")
EOF_STATE
  chmod 600 "$HEALTH_STATE_FILE"
}

normalize_reason() {
  local reason="${1:-}"
  reason="${reason//$'\n'/; }"
  reason="${reason//$'\r'/ }"
  printf '%s' "$reason"
}

health_state_record_failure() {
  local mode="${1:-unknown}" reason now
  reason="$(normalize_reason "${2:-unknown-failure}")"
  now="$(utc_now)"
  health_state_load
  health_degraded="yes"
  auto_fallback="${auto_fallback:-no}"
  health_failure_count="$(( ${health_failure_count:-0} + 1 ))"
  last_failure_mode="$mode"
  last_failure_at="$now"
  last_failure_reason="$reason"
  health_state_save
}

health_state_record_success() {
  local mode="${1:-unknown}" now
  now="$(utc_now)"
  health_state_load
  health_degraded="no"
  auto_fallback="no"
  health_failure_count="0"
  last_success_mode="$mode"
  last_success_at="$now"
  health_state_save
}

health_state_mark_fallback() {
  local mode="${1:-unknown}" reason now
  reason="$(normalize_reason "${2:-auto-fallback}")"
  now="$(utc_now)"
  health_state_load
  health_degraded="yes"
  auto_fallback="yes"
  last_failure_mode="$mode"
  last_failure_at="$now"
  last_failure_reason="$reason"
  health_state_save
}

log_file_size_bytes() {
  local file="$1"
  stat -f %z "$file" 2>/dev/null || echo 0
}

rotate_log_file_if_needed() {
  local file="$1" size i prev

  [ -f "$file" ] || return 0
  size="$(log_file_size_bytes "$file")"
  [ "$size" -ge "$log_rotate_max_bytes" ] || return 0

  for ((i=log_rotate_keep; i>=2; i--)); do
    prev=$((i - 1))
    [ -f "${file}.${prev}" ] && mv -f "${file}.${prev}" "${file}.${i}"
  done

  cp "$file" "${file}.1" 2>/dev/null || cat "$file" >"${file}.1"
  : >"$file"
}

rotate_user_logs_if_needed() {
  ensure_runtime_dirs
  rotate_log_file_if_needed "$LOG_DIR/tunnel.log"
  rotate_log_file_if_needed "$LOG_DIR/tunnel.err.log"
  rotate_log_file_if_needed "$LOG_DIR/singbox.log"
  rotate_log_file_if_needed "$LOG_DIR/singbox.err.log"
  rotate_log_file_if_needed "$LOG_DIR/health-monitor.log"
  rotate_log_file_if_needed "$LOG_DIR/health-monitor.err.log"
}

tun_control_protocol_ready() {
  [ -f "$TUN_STATUS_FILE" ] || [ -f "$TUN_PID_FILE" ]
}

tun_request_disable() {
  ensure_runtime_dirs
  : >"$TUN_DISABLE_FILE"
  chmod 600 "$TUN_DISABLE_FILE" >/dev/null 2>&1 || true
}

tun_request_enable() {
  ensure_runtime_dirs
  rm -f "$TUN_DISABLE_FILE"
}

tun_disabled_requested() {
  [ -f "$TUN_DISABLE_FILE" ]
}

tun_status_field() {
  local key="$1"
  [ -f "$TUN_STATUS_FILE" ] || return 1
  awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }' "$TUN_STATUS_FILE"
}

remove_managed_block() {
  local file="$1"
  [ -f "$file" ] || return 0

  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { skip=0 }
    /^# >>> dmit-iproyal proxy >>>$/ { skip=1; next }
    /^# <<< dmit-iproyal proxy <<<$/{ skip=0; next }
    skip == 0 { print }
  ' "$file" >"$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

ensure_shell_hook() {
  mkdir -p "$(dirname "$SHELL_ENV_FILE")"
  touch "$ZSHRC_FILE"

  remove_managed_block "$ZSHRC_FILE"
  cat >>"$ZSHRC_FILE" <<EOF_HOOK

# >>> dmit-iproyal proxy >>>
if [ -f "$SHELL_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$SHELL_ENV_FILE"
fi
# <<< dmit-iproyal proxy <<<
EOF_HOOK

  remove_managed_block "$ZSHENV_FILE"
}

shell_http_proxy_url() {
  echo "http://${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}"
}

shell_socks_proxy_url() {
  echo "socks5://${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}"
}

shell_export_block() {
  local http_url socks_url resolved_http_url resolved_all_url emit_all_proxy
  http_url="$(shell_http_proxy_url)"
  socks_url="$(shell_socks_proxy_url)"
  emit_all_proxy=1

  case "$cli_proxy_mode" in
    socks|socks5)
      resolved_http_url="$socks_url"
      resolved_all_url="$socks_url"
      ;;
    mixed)
      # Legacy mode: prefer SOCKS for clients that only honor ALL_PROXY.
      resolved_http_url="$http_url"
      resolved_all_url="$socks_url"
      ;;
    http-no-all|http_only)
      resolved_http_url="$http_url"
      resolved_all_url=""
      emit_all_proxy=0
      ;;
    http|https|*)
      # Stable default for CLI tools: keep all proxy vars on local HTTP inbound.
      resolved_http_url="$http_url"
      resolved_all_url="$http_url"
      ;;
  esac

  cat <<EOF_EXPORT
export HTTP_PROXY="$resolved_http_url"
export http_proxy="\${HTTP_PROXY}"
export HTTPS_PROXY="$resolved_http_url"
export https_proxy="\${HTTPS_PROXY}"
EOF_EXPORT

  if [ "$emit_all_proxy" = "1" ]; then
    cat <<EOF_EXPORT
export ALL_PROXY="$resolved_all_url"
export all_proxy="\${ALL_PROXY}"
EOF_EXPORT
  else
    cat <<'EOF_EXPORT'
unset ALL_PROXY all_proxy
EOF_EXPORT
  fi

  cat <<EOF_EXPORT
export NO_PROXY="localhost,127.0.0.1,::1,*.local,*.ts.net,100.64.0.0/10,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export no_proxy="\${NO_PROXY}"
EOF_EXPORT
}

shell_on() {

  ensure_shell_hook
  shell_export_block >"$SHELL_ENV_FILE"
  chmod 600 "$SHELL_ENV_FILE"
  echo "Shell proxy enabled: $SHELL_ENV_FILE"
  echo "New terminals proxy env generated for CLI_PROXY_MODE=$cli_proxy_mode"
  echo "HTTP entry: $(shell_http_proxy_url)"
  echo "SOCKS entry: $(shell_socks_proxy_url)"
}

shell_off() {
  rm -f "$SHELL_ENV_FILE"
  echo "Shell proxy disabled for new terminals."
  echo "Current terminal can run: unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy"
}

shell_status() {
  if [ -f "$SHELL_ENV_FILE" ]; then
    echo "shell_proxy=on ($SHELL_ENV_FILE)"
    sed -n '1,20p' "$SHELL_ENV_FILE"
  else
    echo "shell_proxy=off"
  fi
}

shell_print_exports() {
  shell_export_block
}

set_runtime_env_var() {
  local key="$1" value="$2" tmp

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { updated=0 }
    index($0, key "=") == 1 {
      print key "=" value
      updated=1
      next
    }
    { print }
    END {
      if (updated == 0) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
}

generate_proxy_core_config() {
  local generator

  generator="$SCRIPT_DIR/generate_singbox_config.sh"
  if [ ! -x "$generator" ]; then
    generator="$HOME/Library/Application Support/dmit-iproyal/bin/generate_singbox_config.sh"
  fi
  if [ ! -x "$generator" ]; then
    generator="$REPO_ROOT/scripts/generate_singbox_config.sh"
  fi

  if [ ! -x "$generator" ]; then
    echo "sing-box config generator missing." >&2
    return 1
  fi

  DMIT_IPROYAL_ENV_FILE="$ENV_FILE" "$generator"
  "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG_FILE" >/dev/null
}

set_proxy_core_upstream_mode() {
  local mode="${1:-relay}"

  case "$mode" in
    relay|surge|direct)
      ;;
    *)
      echo "Unsupported proxy core upstream mode: $mode" >&2
      return 1
      ;;
  esac

  set_runtime_env_var "PROXY_CORE_UPSTREAM_MODE" "$mode"
  PROXY_CORE_UPSTREAM_MODE="$mode"
  proxy_core_upstream_mode="$mode"
  generate_proxy_core_config

  if /bin/launchctl print "gui/$UID/$SINGBOX_LABEL" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "gui/$UID/$SINGBOX_LABEL" >/dev/null 2>&1 || true
  fi
}

is_excluded_service() {
  case "$1" in
    Tailscale|Thunderbolt\ Bridge|iPhone\ USB)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_all_services() {
  networksetup -listallnetworkservices | tail -n +2 | sed '/^\*/d'
}

active_global_service() {
  local sid svc
  sid="$(scutil <<<'show State:/Network/Global/IPv4' | awk '/PrimaryService :/{print $3; exit}')"
  [ -n "$sid" ] || return 1

  svc="$(scutil <<<"show Setup:/Network/Service/$sid" | awk -F' : ' '/UserDefinedName :/{print $2; exit}')"
  [ -n "$svc" ] || return 1

  echo "$svc"
}

active_primary_service() {
  local default_if svc
  default_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  [ -n "$default_if" ] || return 1

  svc="$({
    networksetup -listnetworkserviceorder | awk -v dev="$default_if" '
      /^\([0-9]+\)/ {
        svc=$0
        sub(/^\([0-9]+\)[[:space:]]*/, "", svc)
        sub(/^\*/, "", svc)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", svc)
      }
      /Device: / {
        if (index($0, "Device: " dev ")") > 0) {
          print svc
          exit
        }
      }
    '
  })"

  [ -n "$svc" ] || return 1
  echo "$svc"
}

default_services() {
  local global_svc primary

  if global_svc="$(active_global_service)"; then
    if ! is_excluded_service "$global_svc"; then
      echo "$global_svc"
      return 0
    fi
  fi

  if primary="$(active_primary_service)"; then
    if ! is_excluded_service "$primary"; then
      echo "$primary"
      return 0
    fi
  fi

  list_all_services | while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if ! is_excluded_service "$svc"; then
      echo "$svc"
      return 0
    fi
  done
}

all_eligible_services() {
  list_all_services | while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if ! is_excluded_service "$svc"; then
      echo "$svc"
    fi
  done
}

resolve_services() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi

  case "$proxy_scope" in
    all)
      all_eligible_services
      ;;
    active|primary|*)
      default_services
      ;;
  esac
}

ensure_launch_agent_loaded() {
  local label="$1"
  local plist="$2"

  if ! /bin/launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
    if [ -f "$plist" ]; then
      /bin/launchctl bootstrap "gui/$UID" "$plist" >/dev/null 2>&1 || true
    fi
  fi
}

start_tunnel_service() {
  rotate_user_logs_if_needed
  ensure_launch_agent_loaded "$TUNNEL_LABEL" "$TUNNEL_PLIST"
  if [ "$(tunnel_running_value)" = "yes" ]; then
    return 0
  fi
  /bin/launchctl kickstart -k "gui/$UID/$TUNNEL_LABEL"
}

start_proxy_core_service() {
  rotate_user_logs_if_needed
  ensure_launch_agent_loaded "$SINGBOX_LABEL" "$SINGBOX_PLIST"
  if [ "$(proxy_core_running_value)" = "yes" ]; then
    return 0
  fi
  /bin/launchctl kickstart -k "gui/$UID/$SINGBOX_LABEL"
}

start_health_monitor_service() {
  rotate_user_logs_if_needed
  ensure_launch_agent_loaded "$HEALTH_MONITOR_LABEL" "$HEALTH_MONITOR_PLIST"
  /bin/launchctl kickstart -k "gui/$UID/$HEALTH_MONITOR_LABEL" >/dev/null 2>&1 || true
}

stop_proxy_core_service() {
  /bin/launchctl bootout "gui/$UID/$SINGBOX_LABEL" >/dev/null 2>&1 || true
}

stop_tunnel_service() {
  /bin/launchctl bootout "gui/$UID/$TUNNEL_LABEL" >/dev/null 2>&1 || true
}

stop_health_monitor_service() {
  /bin/launchctl bootout "gui/$UID/$HEALTH_MONITOR_LABEL" >/dev/null 2>&1 || true
}

start_services() {
  start_tunnel_service
  start_proxy_core_service
  start_health_monitor_service
}

stop_services() {
  stop_health_monitor_service
  stop_proxy_core_service
  /bin/launchctl bootout "gui/$UID/$TUNNEL_LABEL" >/dev/null 2>&1 || true
}

restart_services() {
  stop_services
  local installer

  installer="$SCRIPT_DIR/setup_dmit_iproyal_stack.sh"
  if [ ! -x "$installer" ]; then
    installer="$HOME/Library/Application Support/dmit-iproyal/bin/setup_dmit_iproyal_stack.sh"
  fi
  if [ ! -x "$installer" ]; then
    installer="$REPO_ROOT/scripts/setup_dmit_iproyal_stack.sh"
  fi
  [ -x "$installer" ] || {
    echo "Setup installer script missing." >&2
    return 1
  }

  "$installer"
}

wait_proxy_core_ready() {
  local i
  for i in $(seq 1 12); do
    if [ "$(proxy_core_running_value)" = "yes" ]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

root_tun_is_installed() {
  [ -f "$ROOT_TUN_PLIST" ]
}

root_tun_is_loaded() {
  /bin/launchctl print "system/$ROOT_TUN_LABEL" >/dev/null 2>&1
}

root_tun_is_running() {
  local pid status tun_addr

  status="$(tun_status_field state || true)"
  pid="$(tun_status_field pid || true)"
  if [ "$status" = "running" ] && [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  tun_addr="${TUN_IPV4_ADDR%%/*}"
  [ -n "$tun_addr" ] || return 1
  ifconfig | grep -q "inet ${tun_addr}[[:space:]]"
}

root_tun_install_files_present() {
  [ -f "$ROOT_TUN_PLIST" ] &&
    [ -f "$ROOT_TUN_RUN_SCRIPT" ] &&
    [ -f "$ROOT_TUN_ENV_FILE" ] &&
    ( [ -f "$ROOT_TUN_CONFIG_FILE" ] || [ -f "$ROOT_TUN_CONFIG_FILE_LEGACY" ] )
}

tun_installed_value() {
  if root_tun_is_installed; then
    echo "yes"
  else
    echo "no"
  fi
}

tun_running_value() {
  if root_tun_is_running; then
    echo "yes"
  else
    echo "no"
  fi
}

tun_loaded_value() {
  if root_tun_is_loaded; then
    echo "yes"
  else
    echo "no"
  fi
}

tun_install() {
  local installer
  installer="$HOME/Library/Application Support/dmit-iproyal/bin/install_tun_privileged.sh"
  if [ ! -x "$installer" ]; then
    installer="$REPO_ROOT/scripts/install_tun_privileged.sh"
  fi

  if [ ! -x "$installer" ]; then
    echo "TUN installer script missing." >&2
    return 1
  fi

  if [ "$ADMIN_PROMPT" = "1" ]; then
    "$installer" --gui
  else
    "$installer"
  fi
}

tun_root_config_needs_refresh() {
  local user_cfg root_cfg user_mtime root_mtime

  user_cfg="${SINGBOX_TUN_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box-tun.json}"
  root_cfg="$ROOT_TUN_CONFIG_FILE"
  if [ ! -f "$root_cfg" ] && [ -f "$ROOT_TUN_CONFIG_FILE_LEGACY" ]; then
    root_cfg="$ROOT_TUN_CONFIG_FILE_LEGACY"
  fi

  [ -f "$user_cfg" ] || return 1
  [ -f "$root_cfg" ] || return 1

  user_mtime="$(stat -f %m "$user_cfg" 2>/dev/null || echo 0)"
  root_mtime="$(stat -f %m "$root_cfg" 2>/dev/null || echo 0)"
  [ "$user_mtime" -gt "$root_mtime" ]
}

tun_start() {
  local i

  if root_tun_is_running; then
    echo "tun_running=yes"
    return 0
  fi

  if ! root_tun_install_files_present; then
    echo "TUN privileged service missing or incomplete; attempting install..."
    tun_install || return 1
  fi

  if tun_root_config_needs_refresh; then
    echo "TUN root config is older than user config; reinstalling privileged TUN service..."
    tun_install || return 1
  fi

  tun_request_enable

  if tun_control_protocol_ready && root_tun_is_loaded; then
    for i in $(seq 1 15); do
      if root_tun_is_running; then
        echo "tun_running=yes"
        return 0
      fi
      sleep 1
    done
  fi

  run_admin_cmd "launchctl enable system/$ROOT_TUN_LABEL >/dev/null 2>&1 || true
if ! launchctl print system/$ROOT_TUN_LABEL >/dev/null 2>&1; then
  launchctl bootstrap system '$ROOT_TUN_PLIST'
fi
launchctl enable system/$ROOT_TUN_LABEL >/dev/null 2>&1 || true
launchctl kickstart -k system/$ROOT_TUN_LABEL" || return 1

  if ! root_tun_is_loaded; then
    echo "Failed to load root TUN service." >&2
    return 1
  fi

  for i in $(seq 1 15); do
    if root_tun_is_running; then
      echo "tun_running=yes"
      return 0
    fi
    sleep 1
  done

  echo "Failed to start root TUN service." >&2
  /bin/launchctl print "system/$ROOT_TUN_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
  return 1
}

tun_stop() {

  local i

  if ! root_tun_is_installed; then
    return 0
  fi

  if ! root_tun_is_loaded; then
    echo "tun_running=no"
    return 0
  fi

  if tun_control_protocol_ready; then
    tun_request_disable

    for i in $(seq 1 16); do
      if ! root_tun_is_running && ! tun_route_active; then
        echo "tun_running=no"
        return 0
      fi
      sleep 0.5
    done
  fi

  run_admin_cmd "launchctl bootout system/$ROOT_TUN_LABEL >/dev/null 2>&1 || true" || return 1

  for i in $(seq 1 16); do
    if ! root_tun_is_loaded && ! tun_route_active; then
      echo "tun_running=no"
      return 0
    fi
    sleep 0.5
  done

  if root_tun_is_loaded; then
    echo "Failed to unload root TUN service." >&2
    /bin/launchctl print "system/$ROOT_TUN_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
    return 1
  fi

  echo "tun_running=no"
}

tun_install_gui() {
  with_gui_prompt tun_install
}

tun_start_gui() {
  with_gui_prompt tun_start
}

tun_stop_gui() {
  with_gui_prompt tun_stop
}

tun_status() {
  local root_state root_pid
  root_state="$(tun_status_field state || true)"
  root_pid="$(tun_status_field pid || true)"

  echo "[root tun]"
  echo "installed=$(tun_installed_value)"
  echo "loaded=$(tun_loaded_value)"
  echo "running=$(tun_running_value)"
  echo "control_protocol=$(tun_control_protocol_ready && echo yes || echo no)"
  echo "disabled_requested=$(tun_disabled_requested && echo yes || echo no)"
  [ -n "$root_state" ] && echo "state=$root_state"
  [ -n "$root_pid" ] && echo "pid=$root_pid"
  if root_tun_is_loaded; then
    /bin/launchctl print "system/$ROOT_TUN_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
  elif root_tun_is_installed; then
    echo "state = unloaded"
  fi
}

build_bypass_array() {
  local bypass=("${DEFAULT_BYPASS[@]}")
  if [ -n "${EXTRA_BYPASS_DOMAINS:-}" ]; then
    local extra_raw extra_trimmed
    IFS=',' read -r -a extras <<<"$EXTRA_BYPASS_DOMAINS"
    for extra_raw in "${extras[@]}"; do
      extra_trimmed="$(echo "$extra_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -n "$extra_trimmed" ] && bypass+=("$extra_trimmed")
    done
  fi
  printf '%s\n' "${bypass[@]}"
}

proxy_on() {
  local svcs=() svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && svcs+=("$svc")
  done < <(resolve_services "$@")

  if [ "${#svcs[@]}" -eq 0 ]; then
    echo "No eligible network services found."
    return 1
  fi

  local bypass=()
  while IFS= read -r svc; do
    [ -n "$svc" ] && bypass+=("$svc")
  done < <(build_bypass_array)

  for svc in "${svcs[@]}"; do
    echo "Enable proxy on: $svc"
    networksetup -setautoproxystate "$svc" off || true
    networksetup -setwebproxy "$svc" "$LOCAL_HTTP_HOST" "$LOCAL_HTTP_PORT" off || true
    networksetup -setwebproxystate "$svc" on || true
    networksetup -setsecurewebproxy "$svc" "$LOCAL_HTTP_HOST" "$LOCAL_HTTP_PORT" off || true
    networksetup -setsecurewebproxystate "$svc" on || true
    networksetup -setsocksfirewallproxy "$svc" "$LOCAL_SOCKS_HOST" "$LOCAL_SOCKS_PORT" off || true
    networksetup -setsocksfirewallproxystate "$svc" on || true
    networksetup -setproxybypassdomains "$svc" "${bypass[@]}" || true
  done
}

proxy_off() {
  local svcs=() svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && svcs+=("$svc")
  done < <(resolve_services "$@")

  if [ "${#svcs[@]}" -eq 0 ]; then
    echo "No eligible network services found."
    return 1
  fi

  for svc in "${svcs[@]}"; do
    echo "Disable proxy on: $svc"
    networksetup -setwebproxystate "$svc" off || true
    networksetup -setsecurewebproxystate "$svc" off || true
    networksetup -setsocksfirewallproxystate "$svc" off || true
  done
}

proxy_off_all() {
  local svcs=() svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && svcs+=("$svc")
  done < <(all_eligible_services)

  if [ "${#svcs[@]}" -eq 0 ]; then
    echo "No eligible network services found."
    return 1
  fi

  for svc in "${svcs[@]}"; do
    echo "Disable proxy on: $svc"
    networksetup -setwebproxystate "$svc" off || true
    networksetup -setsecurewebproxystate "$svc" off || true
    networksetup -setsocksfirewallproxystate "$svc" off || true
  done
}

service_proxy_points_to_stack() {
  local svc="$1"
  local web_enabled web_server web_port https_enabled https_server https_port socks_enabled socks_server socks_port

  web_enabled="$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"
  web_server="$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/Server:/{print $2; exit}')"
  web_port="$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/Port:/{print $2; exit}')"

  https_enabled="$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"
  https_server="$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk -F': ' '/Server:/{print $2; exit}')"
  https_port="$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk -F': ' '/Port:/{print $2; exit}')"

  socks_enabled="$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"
  socks_server="$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk -F': ' '/Server:/{print $2; exit}')"
  socks_port="$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk -F': ' '/Port:/{print $2; exit}')"

  [ "$web_enabled" = "Yes" ] || return 1
  [ "$web_server" = "$LOCAL_HTTP_HOST" ] || return 1
  [ "$web_port" = "$LOCAL_HTTP_PORT" ] || return 1
  [ "$https_enabled" = "Yes" ] || return 1
  [ "$https_server" = "$LOCAL_HTTP_HOST" ] || return 1
  [ "$https_port" = "$LOCAL_HTTP_PORT" ] || return 1
  [ "$socks_enabled" = "Yes" ] || return 1
  [ "$socks_server" = "$LOCAL_SOCKS_HOST" ] || return 1
  [ "$socks_port" = "$LOCAL_SOCKS_PORT" ] || return 1
}

service_proxy_enabled_any() {
  local svc="$1"
  local web_enabled https_enabled socks_enabled

  web_enabled="$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"
  https_enabled="$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"
  socks_enabled="$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk -F': ' '/Enabled:/{print $2; exit}' | tr -d ' ')"

  [ "$web_enabled" = "Yes" ] || [ "$https_enabled" = "Yes" ] || [ "$socks_enabled" = "Yes" ]
}

scutil_proxy_get() {
  local key="$1"
  scutil --proxy 2>/dev/null | awk -F' : ' -v k="$key" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  '
}

global_proxy_enabled_any() {
  local h s x
  h="$(scutil_proxy_get HTTPEnable)"
  s="$(scutil_proxy_get HTTPSEnable)"
  x="$(scutil_proxy_get SOCKSEnable)"
  [ "$h" = "1" ] || [ "$s" = "1" ] || [ "$x" = "1" ]
}

global_proxy_points_to_stack() {
  local h hs hp s ss sp x xs xp
  h="$(scutil_proxy_get HTTPEnable)"
  hs="$(scutil_proxy_get HTTPProxy)"
  hp="$(scutil_proxy_get HTTPPort)"
  s="$(scutil_proxy_get HTTPSEnable)"
  ss="$(scutil_proxy_get HTTPSProxy)"
  sp="$(scutil_proxy_get HTTPSPort)"
  x="$(scutil_proxy_get SOCKSEnable)"
  xs="$(scutil_proxy_get SOCKSProxy)"
  xp="$(scutil_proxy_get SOCKSPort)"

  [ "$h" = "1" ] || return 1
  [ "$hs" = "$LOCAL_HTTP_HOST" ] || return 1
  [ "$hp" = "$LOCAL_HTTP_PORT" ] || return 1
  [ "$s" = "1" ] || return 1
  [ "$ss" = "$LOCAL_HTTP_HOST" ] || return 1
  [ "$sp" = "$LOCAL_HTTP_PORT" ] || return 1
  [ "$x" = "1" ] || return 1
  [ "$xs" = "$LOCAL_SOCKS_HOST" ] || return 1
  [ "$xp" = "$LOCAL_SOCKS_PORT" ] || return 1
}

global_proxy_points_to_surge() {
  local h hs hp s ss sp
  h="$(scutil_proxy_get HTTPEnable)"
  hs="$(scutil_proxy_get HTTPProxy)"
  hp="$(scutil_proxy_get HTTPPort)"
  s="$(scutil_proxy_get HTTPSEnable)"
  ss="$(scutil_proxy_get HTTPSProxy)"
  sp="$(scutil_proxy_get HTTPSPort)"

  [ "$h" = "1" ] || return 1
  [ "$hs" = "$SURGE_HTTP_HOST" ] || return 1
  [ "$hp" = "$SURGE_HTTP_PORT" ] || return 1
  [ "$s" = "1" ] || return 1
  [ "$ss" = "$SURGE_HTTP_HOST" ] || return 1
  [ "$sp" = "$SURGE_HTTP_PORT" ] || return 1
}

default_interface_value() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

health_monitor_loaded_value() {
  if /bin/launchctl print "gui/$UID/$HEALTH_MONITOR_LABEL" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

surge_running_value() {
  if pgrep -f "$SURGE_BIN_MATCH" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

proxy_core_running_value() {
  if lsof -nP -iTCP:"${LOCAL_HTTP_PORT}" -sTCP:LISTEN >/dev/null 2>&1 && \
     lsof -nP -iTCP:"${LOCAL_SOCKS_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

tunnel_running_value() {
  if lsof -nP -iTCP:"${FORWARD_LOCAL_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

current_mode() {
  local proxy_core_running
  proxy_core_running="$(proxy_core_running_value)"

  if root_tun_is_running; then
    echo "mode=stack-tun"
    return 0
  fi

  if global_proxy_points_to_stack && [ "$proxy_core_running" = "yes" ]; then
    echo "mode=stack-proxy"
    return 0
  fi

  if global_proxy_enabled_any; then
    if global_proxy_points_to_surge && [ "$(surge_running_value)" = "yes" ]; then
      echo "mode=surge"
    else
      echo "mode=other-proxy"
    fi
    return 0
  fi

  if [ "$(surge_running_value)" = "yes" ]; then
    echo "mode=surge"
  else
    echo "mode=direct"
  fi
}

info_status() {
  local mode_line mode svc iface
  health_state_load
  mode_line="$(current_mode)"
  mode="${mode_line#mode=}"
  svc="$(active_global_service || true)"
  if [ -z "$svc" ]; then
    svc="$(active_primary_service || true)"
  fi
  iface="$(default_interface_value || true)"

  echo "mode=$mode"
  if [ -n "$svc" ]; then
    echo "service=$svc"
  else
    echo "service=${iface:-unknown}"
  fi
  echo "shell_proxy=$( [ -f "$SHELL_ENV_FILE" ] && echo on || echo off )"
  echo "tun_installed=$(tun_installed_value)"
  echo "tun_loaded=$(tun_loaded_value)"
  echo "tun_running=$(tun_running_value)"
  echo "surge_running=$(surge_running_value)"
  echo "proxy_core_running=$(proxy_core_running_value)"
  echo "proxy_core_upstream=${proxy_core_upstream_mode}"
  echo "tunnel_running=$(tunnel_running_value)"
  echo "health_monitor_loaded=$(health_monitor_loaded_value)"
  echo "health_degraded=${health_degraded:-no}"
  echo "auto_fallback=${auto_fallback:-no}"
  echo "health_failure_count=${health_failure_count:-0}"
  echo "last_failure_mode=${last_failure_mode:-}"
  echo "last_failure_at=${last_failure_at:-}"
  echo "last_failure_reason=${last_failure_reason:-}"
  echo "last_success_mode=${last_success_mode:-}"
  echo "last_success_at=${last_success_at:-}"
}

stop_surge() {
  local i

  if [ -x "$SURGE_CLI" ]; then
    "$SURGE_CLI" stop >/dev/null 2>&1 || true
  fi

  /usr/bin/osascript -e 'tell application "Surge" to quit' >/dev/null 2>&1 || true
  pkill -f "$SURGE_BIN_MATCH" >/dev/null 2>&1 || true

  for i in $(seq 1 12); do
    if ! pgrep -f "$SURGE_BIN_MATCH" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
}

start_surge() {
  open -a Surge >/dev/null 2>&1 || true
  if [ -x "$SURGE_CLI" ]; then
    "$SURGE_CLI" reload >/dev/null 2>&1 || true
  fi
}

wait_surge_proxy_ready() {
  local i
  for i in $(seq 1 "$surge_proxy_wait_attempts"); do
    if lsof -nP -iTCP:"${SURGE_SOCKS_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

ensure_tun_stopped_if_running() {
  if root_tun_is_loaded || root_tun_is_running; then
    tun_stop
  fi
}

extract_ipv4_from_payload() {
  local payload="$1" ip

  ip="$(printf '%s\n' "$payload" | tr -d '\r' | awk -F= '/^ip=/{print $2; exit}')"
  if [ -z "$ip" ]; then
    ip="$(printf '%s\n' "$payload" | tr -d '\r' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
  fi

  if [ -n "$ip" ]; then
    echo "$ip"
    return 0
  fi

  return 1
}

probe_public_ip_via_http_proxy() {
  local url payload ip
  for url in "${PUBLIC_IP_PROBE_URLS[@]}"; do
    payload="$(curl -4 -s --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" --proxy "http://${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}" "$url" || true)"
    ip="$(extract_ipv4_from_payload "$payload" || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

probe_public_ip_via_socks_proxy() {
  local url payload ip
  for url in "${PUBLIC_IP_PROBE_URLS[@]}"; do
    payload="$(curl -4 -s --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" --proxy "socks5h://${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}" "$url" || true)"
    ip="$(extract_ipv4_from_payload "$payload" || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

probe_public_ip_direct() {
  local url payload ip
  for url in "${PUBLIC_IP_PROBE_URLS[@]}"; do
    payload="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -4 -s --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" "$url" || true)"
    ip="$(extract_ipv4_from_payload "$payload" || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

probe_https_via_http_proxy() {
  local url code
  for url in "${HTTPS_CONNECT_PROBE_URLS[@]}"; do
    code="$(curl -4 -s -o /dev/null -w '%{http_code}' --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" --proxy "http://${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}" "$url" || true)"
    [ -n "$code" ] || code="000"
    if [ "$code" != "000" ]; then
      return 0
    fi
  done
  return 1
}

probe_https_via_socks_proxy() {
  local url code
  for url in "${HTTPS_CONNECT_PROBE_URLS[@]}"; do
    code="$(curl -4 -s -o /dev/null -w '%{http_code}' --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" --proxy "socks5h://${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}" "$url" || true)"
    [ -n "$code" ] || code="000"
    if [ "$code" != "000" ]; then
      return 0
    fi
  done
  return 1
}

probe_https_direct() {
  local url code
  for url in "${HTTPS_CONNECT_PROBE_URLS[@]}"; do
    code="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -4 -s -o /dev/null -w '%{http_code}' --connect-timeout "$probe_connect_timeout" --max-time "$probe_max_time" "$url" || true)"
    [ -n "$code" ] || code="000"
    if [ "$code" != "000" ]; then
      return 0
    fi
  done
  return 1
}

probe_public_ip_direct_fast() {
  local payload ip
  payload="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -4 -s --connect-timeout "$probe_fast_connect_timeout" --max-time "$probe_fast_max_time" https://api.ipify.org || true)"
  ip="$(extract_ipv4_from_payload "$payload" || true)"
  if [ -n "$ip" ]; then
    echo "$ip"
    return 0
  fi
  return 1
}

probe_https_direct_fast() {
  local code
  code="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -4 -s -o /dev/null -w '%{http_code}' --connect-timeout "$probe_fast_connect_timeout" --max-time "$probe_fast_max_time" https://www.cloudflare.com/cdn-cgi/trace || true)"
  [ -n "$code" ] || code="000"
  [ "$code" != "000" ]
}

tun_route_active() {
  local iface
  iface="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')"
  case "$iface" in
    utun*) return 0 ;;
    *) return 1 ;;
  esac
}

stack_proxy_health_snapshot() {
  local http_ip socks_ip

  echo "mode=stack-proxy"
  if [ "$(tunnel_running_value)" != "yes" ]; then
    echo "healthy=no"
    echo "reason=relay-listener-down"
    return 1
  fi

  if [ "$(proxy_core_running_value)" != "yes" ]; then
    echo "healthy=no"
    echo "reason=proxy-core-down"
    return 1
  fi

  http_ip="$(probe_public_ip_via_http_proxy || true)"
  if [ -n "$http_ip" ]; then
    echo "http_ip=$http_ip"
  elif probe_https_via_http_proxy; then
    echo "http_ip=unknown"
  else
    echo "healthy=no"
    echo "reason=http-probe-failed"
    return 1
  fi

  socks_ip="$(probe_public_ip_via_socks_proxy || true)"
  if [ -n "$socks_ip" ]; then
    echo "socks_ip=$socks_ip"
  elif probe_https_via_socks_proxy; then
    echo "socks_ip=unknown"
  else
    echo "healthy=no"
    echo "reason=socks-probe-failed"
    return 1
  fi

  echo "healthy=yes"
}

stack_tun_health_snapshot() {
  local direct_ip

  echo "mode=stack-tun"
  if ! root_tun_is_running; then
    echo "healthy=no"
    echo "reason=tun-process-down"
    return 1
  fi

  if [ "$(tunnel_running_value)" != "yes" ]; then
    echo "healthy=no"
    echo "reason=relay-listener-down"
    return 1
  fi

  if ! tun_route_active; then
    echo "healthy=no"
    echo "reason=tun-route-inactive"
    return 1
  fi

  direct_ip="$(probe_public_ip_direct_fast || true)"
  if [ -n "$direct_ip" ]; then
    echo "direct_ip=$direct_ip"
    if [ -n "${UPSTREAM_PROXY_HOST:-}" ] && [ "$direct_ip" != "$UPSTREAM_PROXY_HOST" ]; then
      echo "healthy=no"
      echo "reason=tun-egress-mismatch:$direct_ip"
      return 1
    fi
    echo "healthy=yes"
    return 0
  fi

  if probe_https_direct_fast; then
    echo "direct_ip=unknown"
    echo "healthy=yes"
    return 0
  fi

  echo "healthy=no"
  echo "reason=tun-egress-probe-failed"
  return 1
}

health_check_current_mode() {
  local mode_line mode
  mode_line="$(current_mode)"
  mode="${mode_line#mode=}"

  case "$mode" in
    stack-proxy)
      stack_proxy_health_snapshot
      ;;
    stack-tun)
      stack_tun_health_snapshot
      ;;
    *)
      echo "$mode_line"
      echo "healthy=skip"
      ;;
  esac
}

trigger_auto_fallback_to_surge() {
  local mode="${1:-unknown}" reason fallback_reason
  reason="$(normalize_reason "${2:-health-check-failed}")"
  fallback_reason="health-threshold-reached:${reason}"

  if [ "$auto_fallback_to_surge" != "1" ]; then
    return 1
  fi

  mode_switch_context="auto-fallback"
  if use_surge >/dev/null 2>&1; then
    health_state_mark_fallback "$mode" "$fallback_reason"
    return 0
  fi

  health_state_mark_fallback "$mode" "fallback-failed:${fallback_reason}"
  return 1
}

handle_stack_failure() {
  local mode="${1:-unknown}" reason="${2:-stack-health-failed}"

  health_state_record_failure "$mode" "$reason"
  echo "health_failure_mode=$mode"
  echo "health_failure_reason=$reason"

  if [ "$auto_fallback_to_surge" = "1" ]; then
    if trigger_auto_fallback_to_surge "$mode" "$reason"; then
      echo "auto_fallback=surge"
    else
      echo "auto_fallback=failed"
    fi
  fi

  return 1
}

health_monitor_once() (
  local snapshot mode_line mode reason

  ensure_runtime_dirs
  rotate_user_logs_if_needed

  if ! mkdir "$MONITOR_LOCK_DIR" >/dev/null 2>&1; then
    echo "health_monitor=locked"
    exit 0
  fi
  trap 'rmdir "$MONITOR_LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  snapshot="$(health_check_current_mode)"
  printf '%s\n' "$snapshot"
  mode_line="$(printf '%s\n' "$snapshot" | awk -F= '/^mode=/{print $0; exit}')"
  mode="${mode_line#mode=}"

  case "$mode" in
    stack-proxy|stack-tun)
      if printf '%s\n' "$snapshot" | grep -q '^healthy=yes$'; then
        health_state_record_success "$mode"
        echo "health_failure_count=0"
        exit 0
      fi

      reason="$(printf '%s\n' "$snapshot" | awk -F= '/^reason=/{print substr($0, 8); exit}')"
      health_state_record_failure "$mode" "$reason"
      health_state_load
      echo "health_failure_count=${health_failure_count:-0}"
      if [ "${health_failure_count:-0}" -ge "$health_failure_threshold" ]; then
        if trigger_auto_fallback_to_surge "$mode" "$reason"; then
          echo "auto_fallback=surge"
        else
          echo "auto_fallback=failed"
        fi
      else
        echo "auto_fallback=pending"
      fi
      exit 1
      ;;
    *)
      exit 0
      ;;
  esac
)

wait_stack_proxy_relay_ready_before_cutover() {
  local direct_before="${1:-}" i consecutive=0 snapshot http_ip socks_ip

  for i in $(seq 1 "$stack_proxy_precutover_attempts"); do
    snapshot="$(stack_proxy_health_snapshot || true)"
    if ! printf '%s\n' "$snapshot" | grep -q '^healthy=yes$'; then
      consecutive=0
      sleep 1
      continue
    fi

    http_ip="$(printf '%s\n' "$snapshot" | awk -F= '/^http_ip=/{print $2; exit}')"
    socks_ip="$(printf '%s\n' "$snapshot" | awk -F= '/^socks_ip=/{print $2; exit}')"

    if [ -n "$http_ip" ] && [ "$http_ip" != "unknown" ]; then
      if [ -n "${UPSTREAM_PROXY_HOST:-}" ] && [ "$http_ip" = "$UPSTREAM_PROXY_HOST" ]; then
        consecutive=$((consecutive + 1))
      elif [ -n "$direct_before" ] && [ "$http_ip" != "$direct_before" ]; then
        consecutive=$((consecutive + 1))
      else
        consecutive=0
      fi
    elif [ -n "$socks_ip" ] && [ "$socks_ip" != "unknown" ]; then
      if [ -n "${UPSTREAM_PROXY_HOST:-}" ] && [ "$socks_ip" = "$UPSTREAM_PROXY_HOST" ]; then
        consecutive=$((consecutive + 1))
      elif [ -n "$direct_before" ] && [ "$socks_ip" != "$direct_before" ]; then
        consecutive=$((consecutive + 1))
      else
        consecutive=0
      fi
    else
      consecutive=0
    fi

    if [ "$consecutive" -ge "$stack_proxy_precutover_consecutive" ]; then
      if [ -n "$http_ip" ] && [ "$http_ip" != "unknown" ]; then
        echo "precutover_http_ip=$http_ip"
      fi
      if [ -n "$socks_ip" ] && [ "$socks_ip" != "unknown" ]; then
        echo "precutover_socks_ip=$socks_ip"
      fi
      echo "precutover_consecutive=$consecutive"
      return 0
    fi

    sleep 1
  done

  return 1
}

wait_stack_proxy_ready() {
  local i http_ip socks_ip

  for i in $(seq 1 15); do
    if [ "$(tunnel_running_value)" != "yes" ] || [ "$(proxy_core_running_value)" != "yes" ]; then
      sleep 1
      continue
    fi

    http_ip="$(probe_public_ip_via_http_proxy || true)"
    if [ -z "$http_ip" ] && ! probe_https_via_http_proxy; then
      sleep 1
      continue
    fi

    socks_ip="$(probe_public_ip_via_socks_proxy || true)"
    if [ -z "$socks_ip" ] && ! probe_https_via_socks_proxy; then
      socks_ip="unknown"
    fi

    if [ -n "$http_ip" ]; then
      echo "stack_ready_http_ip=$http_ip"
    else
      echo "stack_ready_http_ip=unknown"
    fi

    if [ -n "$socks_ip" ]; then
      echo "stack_ready_socks_ip=$socks_ip"
    else
      echo "stack_ready_socks_ip=unknown"
    fi

    return 0
  done

  return 1
}

wait_stack_proxy_post_cutover_ready() {
  local i snapshot http_ip socks_ip

  for i in $(seq 1 "$stack_proxy_postcheck_attempts"); do
    snapshot="$(stack_proxy_health_snapshot || true)"
    if ! printf '%s\n' "$snapshot" | grep -q '^healthy=yes$'; then
      return 1
    fi

    http_ip="$(printf '%s\n' "$snapshot" | awk -F= '/^http_ip=/{print $2; exit}')"
    socks_ip="$(printf '%s\n' "$snapshot" | awk -F= '/^socks_ip=/{print $2; exit}')"
    [ -n "$http_ip" ] && echo "stack_postcheck_http_ip=$http_ip"
    [ -n "$socks_ip" ] && echo "stack_postcheck_socks_ip=$socks_ip"

    if [ "$i" -lt "$stack_proxy_postcheck_attempts" ]; then
      sleep "$stack_proxy_postcheck_interval"
    fi
  done

  return 0
}

wait_stack_tun_ready() {
  local i ip mismatch_count=0
  local ready_probe_start=8

  for i in $(seq 1 "$tun_ready_attempts"); do
    if ! root_tun_is_running || [ "$(tunnel_running_value)" != "yes" ]; then
      sleep 1
      continue
    fi

    if ! tun_route_active; then
      sleep 1
      continue
    fi

    ip="$(probe_public_ip_direct_fast || true)"
    if [ -n "$ip" ]; then
      if [ -n "${UPSTREAM_PROXY_HOST:-}" ] && [ "$ip" != "$UPSTREAM_PROXY_HOST" ]; then
        mismatch_count=$((mismatch_count + 1))
        echo "stack_tun_ip_mismatch=$ip"
        echo "stack_tun_expected_ip=$UPSTREAM_PROXY_HOST"
        if [ "$mismatch_count" -ge 3 ]; then
          return 1
        fi
        sleep 1
        continue
      fi
      echo "stack_tun_ready_ip=$ip"
      return 0
    fi

    if [ "$i" -ge "$ready_probe_start" ] && probe_https_direct_fast; then
      echo "stack_tun_ready_ip=unknown"
      return 0
    fi

    sleep 1
  done

  return 1
}

wait_stack_tun_post_cutover_ready() {
  local i ip mismatch_count=0
  local ready_probe_start=6

  for i in $(seq 1 "$tun_postcheck_attempts"); do
    if ! root_tun_is_running || ! tun_route_active; then
      sleep 1
      continue
    fi

    ip="$(probe_public_ip_direct_fast || true)"
    if [ -n "$ip" ]; then
      if [ -n "${UPSTREAM_PROXY_HOST:-}" ] && [ "$ip" != "$UPSTREAM_PROXY_HOST" ]; then
        mismatch_count=$((mismatch_count + 1))
        echo "stack_tun_postcheck_mismatch=$ip"
        echo "stack_tun_expected_ip=$UPSTREAM_PROXY_HOST"
        if [ "$mismatch_count" -ge 2 ]; then
          return 1
        fi
        sleep 1
        continue
      fi
      echo "stack_tun_postcheck_ip=$ip"
      return 0
    fi

    if [ "$i" -ge "$ready_probe_start" ] && probe_https_direct_fast; then
      echo "stack_tun_postcheck_ip=unknown"
      return 0
    fi

    sleep 1
  done

  return 1
}

rollback_to_stack_proxy() {
  tun_stop >/dev/null 2>&1 || true
  start_tunnel_service >/dev/null 2>&1 || true
  set_proxy_core_upstream_mode relay >/dev/null 2>&1 || true
  start_proxy_core_service >/dev/null 2>&1 || true
  wait_proxy_core_ready || true
  proxy_off_all >/dev/null 2>&1 || true
  proxy_on >/dev/null 2>&1 || true
  if [ "${AUTO_SHELL_ENABLE_ON_STACK:-1}" = "1" ]; then
    shell_on >/dev/null 2>&1 || true
  fi
}

use_stack_proxy() {
  local direct_before=""

  rotate_user_logs_if_needed
  start_health_monitor_service >/dev/null 2>&1 || true
  direct_before="$(probe_public_ip_direct_fast || true)"

  ensure_tun_stopped_if_running
  start_tunnel_service
  set_proxy_core_upstream_mode relay
  start_proxy_core_service >/dev/null 2>&1 || true
  wait_proxy_core_ready || true

  if ! wait_stack_proxy_relay_ready_before_cutover "$direct_before"; then
    echo "stack_precutover=failed"
    handle_stack_failure "stack-proxy" "stack_proxy_precutover_failed" || true
    return 1
  fi

  proxy_off_all >/dev/null 2>&1 || true
  proxy_on "$@"

  if [ "${AUTO_SHELL_ENABLE_ON_STACK:-1}" = "1" ]; then
    shell_on
  fi

  if ! wait_stack_proxy_ready; then
    echo "stack_ready=failed"
    handle_stack_failure "stack-proxy" "stack_proxy_ready_failed" || true
    return 1
  fi

  if ! wait_stack_proxy_post_cutover_ready; then
    echo "stack_postcheck=failed"
    handle_stack_failure "stack-proxy" "stack_proxy_postcheck_failed" || true
    return 1
  fi

  if [ "${STOP_SURGE_WHEN_STACK:-1}" = "1" ]; then
    stop_surge
  fi

  health_state_record_success "stack-proxy"
  echo "mode=stack-proxy"
}

use_stack_proxy_gui() {
  with_gui_prompt use_stack_proxy "$@"
}

use_stack_tun() {
  local restore_proxy_core="no"
  local attempted_without_proxy_core="no"

  rotate_user_logs_if_needed
  start_health_monitor_service >/dev/null 2>&1 || true
  start_tunnel_service
  set_proxy_core_upstream_mode relay >/dev/null 2>&1 || true

  if [ "$(proxy_core_running_value)" = "yes" ]; then
    restore_proxy_core="yes"
  elif [ "$tun_keep_proxy_core" = "1" ]; then
    start_proxy_core_service >/dev/null 2>&1 || true
    wait_proxy_core_ready || true
    restore_proxy_core="yes"
  fi

  # First try starting TUN with proxy core still running to minimize switchover downtime.
  # If privileged TUN fails (e.g. stale config with local port conflicts), retry once
  # after stopping proxy core.
  if ! tun_start; then
    if [ "$restore_proxy_core" = "yes" ]; then
      stop_proxy_core_service
      attempted_without_proxy_core="yes"
      if ! tun_start; then
        echo "stack_tun_start=failed"
        if [ "$tun_keep_proxy_core" = "1" ]; then
          start_proxy_core_service >/dev/null 2>&1 || true
          wait_proxy_core_ready || true
        fi
        handle_stack_failure "stack-tun" "stack_tun_start_failed" || true
        return 1
      fi
    else
      echo "stack_tun_start=failed"
      handle_stack_failure "stack-tun" "stack_tun_start_failed" || true
      return 1
    fi
  fi

  if ! wait_stack_tun_ready; then
    echo "stack_tun_ready=failed"
    tun_stop >/dev/null 2>&1 || true
    if [ "$restore_proxy_core" = "yes" ] || [ "$attempted_without_proxy_core" = "yes" ] || [ "$tun_keep_proxy_core" = "1" ]; then
      start_proxy_core_service >/dev/null 2>&1 || true
      wait_proxy_core_ready || true
    fi
    handle_stack_failure "stack-tun" "stack_tun_ready_failed" || true
    return 1
  fi

  if [ "${STOP_SURGE_WHEN_STACK:-1}" = "1" ]; then
    stop_surge
  fi

  proxy_off_all >/dev/null 2>&1 || true

  if [ "$tun_keep_shell_env" = "0" ]; then
    shell_off
  fi

  if [ "$tun_keep_proxy_core" = "1" ]; then
    start_proxy_core_service >/dev/null 2>&1 || true
    wait_proxy_core_ready || true
    if [ "$tun_keep_shell_env" = "1" ] && [ "${AUTO_SHELL_ENABLE_ON_STACK:-1}" = "1" ]; then
      shell_on >/dev/null 2>&1 || true
    fi
  else
    stop_proxy_core_service >/dev/null 2>&1 || true
  fi

  if ! wait_stack_tun_post_cutover_ready; then
    echo "stack_tun_postcheck=failed"
    handle_stack_failure "stack-tun" "stack_tun_postcheck_failed" || true
    return 1
  fi

  health_state_record_success "stack-tun"
  echo "mode=stack-tun"
}

use_stack_tun_gui() {

  with_gui_prompt use_stack_tun
}

use_stack_auto() {
  if root_tun_is_installed; then
    use_stack_tun
  else
    use_stack_proxy "$@"
  fi
}

use_stack_auto_gui() {
  if root_tun_is_installed; then
    use_stack_tun_gui
  else
    use_stack_proxy_gui "$@"
  fi
}

use_surge() {
  rotate_user_logs_if_needed
  start_health_monitor_service >/dev/null 2>&1 || true
  proxy_off_all
  shell_off
  ensure_tun_stopped_if_running

  if [ "${START_SURGE_WHEN_OFF:-1}" = "1" ]; then
    start_surge
    wait_surge_proxy_ready || true
  fi

  stop_tunnel_service
  set_proxy_core_upstream_mode surge
  start_proxy_core_service >/dev/null 2>&1 || true
  wait_proxy_core_ready || true

  echo "mode=surge"
}

use_surge_gui() {
  with_gui_prompt use_surge
}

use_direct() {
  rotate_user_logs_if_needed
  start_health_monitor_service >/dev/null 2>&1 || true
  proxy_off_all
  shell_off
  ensure_tun_stopped_if_running

  if [ "${STOP_SURGE_WHEN_DIRECT:-1}" = "1" ]; then
    stop_surge
  fi

  stop_tunnel_service
  set_proxy_core_upstream_mode direct
  start_proxy_core_service >/dev/null 2>&1 || true
  wait_proxy_core_ready || true

  echo "mode=direct"
}

use_direct_gui() {
  with_gui_prompt use_direct
}

test_stack() {
  local i out_http out_socks ok_http=0 ok_socks=0 fail_http=0 fail_socks=0

  echo "[HTTP proxy test] http://${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}"
  for i in 1 2 3 4 5; do
    out_http="$(curl -4 -s --connect-timeout 8 --max-time 20 --proxy "http://${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}" https://api.ipify.org || true)"
    if [ -n "$out_http" ]; then
      ok_http=$((ok_http + 1))
      echo "#${i} $out_http"
    else
      fail_http=$((fail_http + 1))
      echo "#${i} fail"
    fi
    sleep 1
  done
  echo "summary http ok=$ok_http fail=$fail_http"
  echo

  echo "[SOCKS proxy test] socks5h://${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}"
  for i in 1 2 3 4 5; do
    out_socks="$(curl -4 -s --connect-timeout 8 --max-time 20 --proxy "socks5h://${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}" https://api.ipify.org || true)"
    if [ -n "$out_socks" ]; then
      ok_socks=$((ok_socks + 1))
      echo "#${i} $out_socks"
    else
      fail_socks=$((fail_socks + 1))
      echo "#${i} fail"
    fi
    sleep 1
  done
  echo "summary socks ok=$ok_socks fail=$fail_socks"

  if root_tun_is_running; then
    echo
    echo "[TUN direct test]"
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -4 -s --connect-timeout 8 --max-time 20 https://api.ipify.org || true
    echo
  fi
}

listener_pid_for_port() {
  local port="$1"
  lsof -nP -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -n 1
}

fd_count_for_pid() {
  local pid="${1:-}"
  if [ -z "$pid" ]; then
    echo "0"
    return 0
  fi
  lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' '
}

print_resource_limits() {
  local tunnel_pid proxy_pid

  echo "[resource limits]"
  echo "configured_launchd_soft_maxfiles=$launchd_soft_maxfiles"
  echo "configured_launchd_hard_maxfiles=$launchd_hard_maxfiles"
  /bin/launchctl limit maxfiles 2>/dev/null | awk '{print "session_soft_maxfiles=" $2 "\nsession_hard_maxfiles=" $3}'

  tunnel_pid="$(listener_pid_for_port "$FORWARD_LOCAL_PORT" || true)"
  proxy_pid="$(listener_pid_for_port "$LOCAL_HTTP_PORT" || true)"
  echo "tunnel_pid=${tunnel_pid:-}"
  echo "tunnel_fd_count=$(fd_count_for_pid "$tunnel_pid")"
  echo "proxy_core_pid=${proxy_pid:-}"
  echo "proxy_core_fd_count=$(fd_count_for_pid "$proxy_pid")"
}

print_recent_error_summary() {
  local file label

  echo "[recent errors]"
  for label in tunnel.err.log singbox.err.log health-monitor.err.log; do
    file="$LOG_DIR/$label"
    echo "--$label"
    if [ -f "$file" ]; then
      rg -n 'Too many open files|Connection reset by peer|Broken pipe|timed out|timeout|refused|failed|error|disconnect' "$file" | tail -n 5 || echo "clean"
    else
      echo "missing"
    fi
  done
}

status_services() {
  echo "[launchd status]"
  /bin/launchctl print "gui/$UID/$TUNNEL_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
  /bin/launchctl print "gui/$UID/$SINGBOX_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
  /bin/launchctl print "gui/$UID/$HEALTH_MONITOR_LABEL" 2>/dev/null | grep -E "state =|pid =|last exit code|path =" || true
  echo
  tun_status
  echo
  echo "[ports]"
  lsof -nP -iTCP:"${FORWARD_LOCAL_PORT}" -sTCP:LISTEN || true
  lsof -nP -iTCP:"${LOCAL_HTTP_PORT}" -sTCP:LISTEN || true
  lsof -nP -iTCP:"${LOCAL_SOCKS_PORT}" -sTCP:LISTEN || true
}

doctor() {
  local direct_ip http_ip socks_ip

  echo "[info]"
  info_status
  echo
  echo "[health snapshot]"
  health_check_current_mode || true
  echo
  print_resource_limits
  echo
  echo "[shell]"
  shell_status | head -n 8
  echo
  echo "[services]"
  status_services
  echo

  echo "[egress direct]"
  direct_ip="$(probe_public_ip_direct || true)"
  if [ -n "$direct_ip" ]; then
    echo "$direct_ip"
  elif probe_https_direct; then
    echo "reachable (ip unknown)"
  else
    echo "fail"
  fi
  echo

  echo "[egress via local http]"
  http_ip="$(probe_public_ip_via_http_proxy || true)"
  if [ -n "$http_ip" ]; then
    echo "$http_ip"
  elif probe_https_via_http_proxy; then
    echo "reachable (ip unknown)"
  else
    echo "fail"
  fi
  echo

  echo "[egress via local socks]"
  socks_ip="$(probe_public_ip_via_socks_proxy || true)"
  if [ -n "$socks_ip" ]; then
    echo "$socks_ip"
  elif probe_https_via_socks_proxy; then
    echo "reachable (ip unknown)"
  else
    echo "fail"
  fi
  echo

  print_recent_error_summary
  echo
}

tail_logs() {
  mkdir -p "$LOG_DIR"
  tail -n "${1:-80}" \
    "$LOG_DIR/tunnel.log" \
    "$LOG_DIR/tunnel.err.log" \
    "$LOG_DIR/singbox.log" \
    "$LOG_DIR/singbox.err.log" \
    "$LOG_DIR/health-monitor.log" \
    "$LOG_DIR/health-monitor.err.log" 2>/dev/null || true
}

usage() {
  cat <<EOF_USAGE
Usage:
  $0 start
  $0 stop
  $0 restart
  $0 status
  $0 info
  $0 doctor
  $0 test
  $0 health-check
  $0 health-monitor-once
  $0 proxy-on [service ...]
  $0 proxy-off [service ...]
  $0 proxy-off-all
  $0 use-stack [service ...]        # alias of use-stack-proxy
  $0 use-stack-proxy [service ...]
  $0 use-stack-proxy-gui [service ...]
  $0 use-stack-tun
  $0 use-stack-tun-gui
  $0 use-stack-auto [service ...]
  $0 use-stack-auto-gui [service ...]
  $0 use-surge
  $0 use-surge-gui
  $0 use-direct
  $0 use-direct-gui
  $0 tun-install
  $0 tun-install-gui
  $0 tun-start
  $0 tun-start-gui
  $0 tun-stop
  $0 tun-stop-gui
  $0 tun-status
  $0 tun-installed
  $0 tun-loaded
  $0 tun-running
  $0 tun-repair
  $0 tun-repair-gui
  $0 mode
  $0 shell-on
  $0 shell-off
  $0 shell-status
  $0 shell-print-exports
  $0 tail [lines]
  $0 services

Examples:
  $0 use-stack-auto-gui
  $0 use-stack-proxy
  $0 use-stack-tun-gui
  $0 use-surge-gui
EOF_USAGE
}

cmd="${1:-}"
case "$cmd" in
  start)
    start_services
    ;;
  stop)
    stop_services
    ;;
  restart)
    restart_services
    ;;
  status)
    status_services
    ;;
  info)
    info_status
    ;;
  doctor)
    doctor
    ;;
  test)
    test_stack
    ;;
  health-check)
    health_check_current_mode
    ;;
  health-monitor-once)
    health_monitor_once
    ;;
  proxy-on)
    shift
    proxy_on "$@"
    ;;
  proxy-off)
    shift
    proxy_off "$@"
    ;;
  proxy-off-all)
    proxy_off_all
    ;;
  use-stack)
    shift
    use_stack_proxy "$@"
    ;;
  use-stack-proxy)
    shift
    use_stack_proxy "$@"
    ;;
  use-stack-proxy-gui)
    shift
    use_stack_proxy_gui "$@"
    ;;
  use-stack-tun)
    use_stack_tun
    ;;
  use-stack-tun-gui)
    use_stack_tun_gui
    ;;
  use-stack-auto)
    shift
    use_stack_auto "$@"
    ;;
  use-stack-auto-gui)
    shift
    use_stack_auto_gui "$@"
    ;;
  use-surge)
    use_surge
    ;;
  use-surge-gui)
    use_surge_gui
    ;;
  use-direct)
    use_direct
    ;;
  use-direct-gui)
    use_direct_gui
    ;;
  tun-install)
    tun_install
    ;;
  tun-install-gui)
    tun_install_gui
    ;;
  tun-start)
    tun_start
    ;;
  tun-start-gui)
    tun_start_gui
    ;;
  tun-stop)
    tun_stop
    ;;
  tun-stop-gui)
    tun_stop_gui
    ;;
  tun-status)
    tun_status
    ;;
  tun-installed)
    tun_installed_value
    ;;
  tun-loaded)
    tun_loaded_value
    ;;
  tun-running)
    tun_running_value
    ;;
  tun-repair)
    tun_install
    tun_start
    ;;
  tun-repair-gui)
    with_gui_prompt tun_install
    with_gui_prompt tun_start
    ;;
  mode)
    current_mode
    ;;
  shell-on)
    shell_on
    ;;
  shell-off)
    shell_off
    ;;
  shell-status)
    shell_status
    ;;
  shell-print-exports)
    shell_print_exports
    ;;
  tail)
    shift
    tail_logs "${1:-80}"
    ;;
  services)
    default_services
    ;;
  *)
    usage
    exit 1
    ;;
esac
