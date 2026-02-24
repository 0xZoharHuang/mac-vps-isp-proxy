#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEY_ZIP_DEFAULT=""
KEY_ZIP="${KEY_ZIP:-$KEY_ZIP_DEFAULT}"
KEY_TARGET="${KEY_TARGET:-$HOME/.ssh/dmit_relay_id_rsa}"

ENV_FILE="${ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box.json}"
SINGBOX_TUN_CONFIG_FILE="${SINGBOX_TUN_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box-tun.json}"

LOG_DIR="$HOME/Library/Logs/dmit-iproyal"
RUNTIME_DIR="$HOME/Library/Application Support/dmit-iproyal"
RUNTIME_BIN="$RUNTIME_DIR/bin"
LOCAL_BIN_DIR="$HOME/.local/bin"
LOCAL_CTL_LINK="$LOCAL_BIN_DIR/dmit-iproyal-proxyctl"

LAUNCH_DIR="$HOME/Library/LaunchAgents"
TUNNEL_LABEL="com.zohar.dmit.iproyal.tunnel"
SINGBOX_LABEL="com.zohar.dmit.iproyal.singbox"
LEGACY_BRIDGE_LABEL="com.zohar.dmit.iproyal.bridge"

TUNNEL_PLIST="$LAUNCH_DIR/${TUNNEL_LABEL}.plist"
SINGBOX_PLIST="$LAUNCH_DIR/${SINGBOX_LABEL}.plist"

DMIT_HOST="${DMIT_HOST:-}"
DMIT_PORT="${DMIT_PORT:-443}"
DMIT_USER="${DMIT_USER:-root}"

IPROYAL_HOST="${IPROYAL_HOST:-}"
IPROYAL_PORT="${IPROYAL_PORT:-}"
IPROYAL_USER="${IPROYAL_USER:-}"
IPROYAL_PASS="${IPROYAL_PASS:-}"

FORWARD_LOCAL_PORT="${FORWARD_LOCAL_PORT:-31080}"
LOCAL_HTTP_HOST="${LOCAL_HTTP_HOST:-127.0.0.1}"
LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-17890}"
LOCAL_SOCKS_HOST="${LOCAL_SOCKS_HOST:-127.0.0.1}"
LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-17891}"

SINGBOX_LOG_LEVEL="${SINGBOX_LOG_LEVEL:-info}"
CLI_PROXY_MODE="${CLI_PROXY_MODE:-http}"
PROXY_SCOPE="${PROXY_SCOPE:-active}"
EXTRA_BYPASS_DOMAINS="${EXTRA_BYPASS_DOMAINS:-}"

TUN_IPV4_ADDR="${TUN_IPV4_ADDR:-172.31.250.1/30}"
TUN_AUTO_ROUTE="${TUN_AUTO_ROUTE:-1}"
TUN_STRICT_ROUTE="${TUN_STRICT_ROUTE:-1}"
TUN_MTU="${TUN_MTU:-1500}"

AUTO_SHELL_ENABLE_ON_STACK="${AUTO_SHELL_ENABLE_ON_STACK:-1}"
STOP_SURGE_WHEN_STACK="${STOP_SURGE_WHEN_STACK:-1}"
START_SURGE_WHEN_OFF="${START_SURGE_WHEN_OFF:-1}"
STOP_SURGE_WHEN_DIRECT="${STOP_SURGE_WHEN_DIRECT:-1}"
TUN_KEEP_PROXY_CORE="${TUN_KEEP_PROXY_CORE:-1}"
TUN_KEEP_SHELL_ENV="${TUN_KEEP_SHELL_ENV:-1}"
PROBE_CONNECT_TIMEOUT="${PROBE_CONNECT_TIMEOUT:-3}"
PROBE_MAX_TIME="${PROBE_MAX_TIME:-7}"
PROBE_FAST_CONNECT_TIMEOUT="${PROBE_FAST_CONNECT_TIMEOUT:-1}"
PROBE_FAST_MAX_TIME="${PROBE_FAST_MAX_TIME:-3}"
TUN_READY_ATTEMPTS="${TUN_READY_ATTEMPTS:-20}"
TUN_POSTCHECK_ATTEMPTS="${TUN_POSTCHECK_ATTEMPTS:-12}"

AUTO_ENABLE_PROXY="${AUTO_ENABLE_PROXY:-0}"

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    echo "Missing required variable: $name" >&2
    return 1
  fi
  return 0
}

require_env DMIT_HOST
require_env IPROYAL_HOST
require_env IPROYAL_PORT
require_env IPROYAL_USER
require_env IPROYAL_PASS

mkdir -p "$HOME/.ssh" "$(dirname "$ENV_FILE")" "$LOG_DIR" "$RUNTIME_BIN" "$LAUNCH_DIR" "$LOCAL_BIN_DIR"

ensure_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "sing-box not found. Installing via Homebrew..." >&2
    brew install sing-box
    command -v sing-box >/dev/null 2>&1 || {
      echo "sing-box install finished but binary is still missing in PATH." >&2
      exit 1
    }
    return 0
  fi

  echo "sing-box not found and Homebrew unavailable." >&2
  echo "Install Homebrew or place sing-box in PATH, then rerun." >&2
  exit 1
}

ensure_singbox
SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box)}"

if [ ! -f "$KEY_TARGET" ]; then
  [ -f "$KEY_ZIP" ] || {
    echo "SSH key not found at $KEY_TARGET and zip missing: $KEY_ZIP" >&2
    exit 1
  }

  tmpdir="$(mktemp -d)"
  unzip -q "$KEY_ZIP" -d "$tmpdir"
  [ -f "$tmpdir/id_rsa.pem" ] || {
    echo "id_rsa.pem not found in $KEY_ZIP" >&2
    rm -rf "$tmpdir"
    exit 1
  }

  install -m 600 "$tmpdir/id_rsa.pem" "$KEY_TARGET"
  rm -rf "$tmpdir"
  echo "Installed SSH key to $KEY_TARGET"
else
  chmod 600 "$KEY_TARGET"
  echo "Using existing SSH key: $KEY_TARGET"
fi

cat >"$ENV_FILE" <<EOF_ENV
DMIT_HOST="${DMIT_HOST:-}"
DMIT_PORT="${DMIT_PORT:-443}"
DMIT_USER=$DMIT_USER
SSH_KEY_PATH=$KEY_TARGET
IPROYAL_HOST="${IPROYAL_HOST:-}"
IPROYAL_PORT="${IPROYAL_PORT:-}"
IPROYAL_USER="${IPROYAL_USER:-}"
IPROYAL_PASS="${IPROYAL_PASS:-}"
FORWARD_LOCAL_PORT=$FORWARD_LOCAL_PORT
LOCAL_HTTP_HOST=$LOCAL_HTTP_HOST
LOCAL_HTTP_PORT=$LOCAL_HTTP_PORT
LOCAL_SOCKS_HOST=$LOCAL_SOCKS_HOST
LOCAL_SOCKS_PORT=$LOCAL_SOCKS_PORT
SINGBOX_BIN=$SINGBOX_BIN
SINGBOX_CONFIG_FILE=$SINGBOX_CONFIG_FILE
SINGBOX_TUN_CONFIG_FILE=$SINGBOX_TUN_CONFIG_FILE
SINGBOX_LOG_LEVEL=$SINGBOX_LOG_LEVEL
CLI_PROXY_MODE=$CLI_PROXY_MODE
PROXY_SCOPE=$PROXY_SCOPE
EXTRA_BYPASS_DOMAINS=$EXTRA_BYPASS_DOMAINS
TUN_IPV4_ADDR=$TUN_IPV4_ADDR
TUN_AUTO_ROUTE=$TUN_AUTO_ROUTE
TUN_STRICT_ROUTE=$TUN_STRICT_ROUTE
TUN_MTU=$TUN_MTU
AUTO_SHELL_ENABLE_ON_STACK=$AUTO_SHELL_ENABLE_ON_STACK
STOP_SURGE_WHEN_STACK=$STOP_SURGE_WHEN_STACK
START_SURGE_WHEN_OFF=$START_SURGE_WHEN_OFF
STOP_SURGE_WHEN_DIRECT=$STOP_SURGE_WHEN_DIRECT
TUN_KEEP_PROXY_CORE=$TUN_KEEP_PROXY_CORE
TUN_KEEP_SHELL_ENV=$TUN_KEEP_SHELL_ENV
PROBE_CONNECT_TIMEOUT=$PROBE_CONNECT_TIMEOUT
PROBE_MAX_TIME=$PROBE_MAX_TIME
PROBE_FAST_CONNECT_TIMEOUT=$PROBE_FAST_CONNECT_TIMEOUT
PROBE_FAST_MAX_TIME=$PROBE_FAST_MAX_TIME
TUN_READY_ATTEMPTS=$TUN_READY_ATTEMPTS
TUN_POSTCHECK_ATTEMPTS=$TUN_POSTCHECK_ATTEMPTS
EOF_ENV
chmod 600 "$ENV_FILE"
echo "Wrote runtime env: $ENV_FILE"

install -m 755 "$REPO_ROOT/scripts/run_dmit_tunnel.sh" "$RUNTIME_BIN/run_dmit_tunnel.sh"
install -m 755 "$REPO_ROOT/scripts/run_singbox.sh" "$RUNTIME_BIN/run_singbox.sh"
install -m 755 "$REPO_ROOT/scripts/generate_singbox_config.sh" "$RUNTIME_BIN/generate_singbox_config.sh"
install -m 755 "$REPO_ROOT/scripts/generate_singbox_tun_config.sh" "$RUNTIME_BIN/generate_singbox_tun_config.sh"
install -m 755 "$REPO_ROOT/scripts/install_tun_privileged.sh" "$RUNTIME_BIN/install_tun_privileged.sh"
install -m 755 "$REPO_ROOT/scripts/run_singbox_tun_root.sh" "$RUNTIME_BIN/run_singbox_tun_root.sh"
install -m 755 "$REPO_ROOT/scripts/dmit_iproyal_proxyctl.sh" "$RUNTIME_BIN/dmit_iproyal_proxyctl.sh"
echo "Installed runtime scripts in: $RUNTIME_BIN"

ln -sf "$RUNTIME_BIN/dmit_iproyal_proxyctl.sh" "$LOCAL_CTL_LINK"
echo "Linked control command: $LOCAL_CTL_LINK"

DMIT_IPROYAL_ENV_FILE="$ENV_FILE" "$RUNTIME_BIN/generate_singbox_config.sh"
DMIT_IPROYAL_ENV_FILE="$ENV_FILE" "$RUNTIME_BIN/generate_singbox_tun_config.sh"
"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG_FILE" >/dev/null
"$SINGBOX_BIN" check -c "$SINGBOX_TUN_CONFIG_FILE" >/dev/null

cat >"$TUNNEL_PLIST" <<EOF_TUNNEL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TUNNEL_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME_BIN/run_dmit_tunnel.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/tunnel.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/tunnel.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DMIT_IPROYAL_ENV_FILE</key>
    <string>$ENV_FILE</string>
  </dict>
</dict>
</plist>
EOF_TUNNEL

cat >"$SINGBOX_PLIST" <<EOF_SINGBOX
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SINGBOX_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME_BIN/run_singbox.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/singbox.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/singbox.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DMIT_IPROYAL_ENV_FILE</key>
    <string>$ENV_FILE</string>
  </dict>
</dict>
</plist>
EOF_SINGBOX

chmod 644 "$TUNNEL_PLIST" "$SINGBOX_PLIST"
echo "Wrote launchd agents in $LAUNCH_DIR"

/bin/launchctl bootout "gui/$UID/$LEGACY_BRIDGE_LABEL" >/dev/null 2>&1 || true

for plist in "$TUNNEL_PLIST" "$SINGBOX_PLIST"; do
  /bin/launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/$UID" "$plist"
done

/bin/launchctl kickstart -k "gui/$UID/$TUNNEL_LABEL"
/bin/launchctl kickstart -k "gui/$UID/$SINGBOX_LABEL"

echo "Services started."
echo "Local HTTP proxy: ${LOCAL_HTTP_HOST}:${LOCAL_HTTP_PORT}"
echo "Local SOCKS proxy: ${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}"
echo "TUN config prepared: ${SINGBOX_TUN_CONFIG_FILE}"

if [ "$AUTO_ENABLE_PROXY" = "1" ]; then
  "$RUNTIME_BIN/dmit_iproyal_proxyctl.sh" use-stack-proxy
  echo "System + shell proxy enabled by default."
else
  echo "AUTO_ENABLE_PROXY=0, proxy not enabled automatically."
  echo "Use menu bar D-ISP dropdown to switch modes."
fi
