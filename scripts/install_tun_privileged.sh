#!/usr/bin/env bash
set -euo pipefail

GUI_PROMPT=0
if [ "${1:-}" = "--gui" ]; then
  GUI_PROMPT=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${DMIT_IPROYAL_ENV_FILE:-$HOME/.config/dmit-iproyal/env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

ROOT_ETC_DIR="/usr/local/etc/dmit-iproyal"
ROOT_LIBEXEC_DIR="/usr/local/libexec/dmit-iproyal"
ROOT_LOG_DIR="/var/log/dmit-iproyal"
ROOT_ENV_FILE="$ROOT_ETC_DIR/root.env"
ROOT_TUN_CONFIG_FILE="$ROOT_ETC_DIR/sing-box-tun.json"
ROOT_TUN_CONFIG_LEGACY="$ROOT_ETC_DIR/singbox-tun.json"
ROOT_RUN_SCRIPT="$ROOT_LIBEXEC_DIR/run_singbox_tun_root.sh"
ROOT_PLIST="/Library/LaunchDaemons/com.zohar.dmit.iproyal.singbox.tun.plist"
ROOT_LABEL="com.zohar.dmit.iproyal.singbox.tun"

USER_TUN_CONFIG_FILE="${SINGBOX_TUN_CONFIG_FILE:-$HOME/.config/dmit-iproyal/sing-box-tun.json}"
SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || true)}"

[ -n "$SINGBOX_BIN" ] || {
  echo "sing-box not found in PATH. Run setup first." >&2
  exit 1
}

if [ ! -f "$USER_TUN_CONFIG_FILE" ]; then
  DMIT_IPROYAL_ENV_FILE="$ENV_FILE" SINGBOX_TUN_CONFIG_FILE="$USER_TUN_CONFIG_FILE" "$SCRIPT_DIR/generate_singbox_tun_config.sh"
fi

[ -f "$USER_TUN_CONFIG_FILE" ] || {
  echo "Missing user TUN config: $USER_TUN_CONFIG_FILE" >&2
  exit 1
}

ROOT_RUN_SRC="$SCRIPT_DIR/run_singbox_tun_root.sh"
if [ ! -f "$ROOT_RUN_SRC" ]; then
  ROOT_RUN_SRC="$REPO_ROOT/scripts/run_singbox_tun_root.sh"
fi

[ -f "$ROOT_RUN_SRC" ] || {
  echo "Missing run_singbox_tun_root.sh source file." >&2
  exit 1
}

TMP_ROOT_ENV="$(mktemp)"
TMP_ROOT_SCRIPT="$(mktemp)"

cleanup() {
  rm -f "$TMP_ROOT_ENV" "$TMP_ROOT_SCRIPT"
}
trap cleanup EXIT

cat >"$TMP_ROOT_ENV" <<EOF_ENV
SINGBOX_BIN=$SINGBOX_BIN
SINGBOX_TUN_CONFIG_FILE=$ROOT_TUN_CONFIG_FILE
EOF_ENV
chmod 600 "$TMP_ROOT_ENV"

cat >"$TMP_ROOT_SCRIPT" <<EOF_ROOT
#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 "$ROOT_ETC_DIR" "$ROOT_LIBEXEC_DIR" "$ROOT_LOG_DIR"
install -m 700 "$ROOT_RUN_SRC" "$ROOT_RUN_SCRIPT"
install -m 600 "$TMP_ROOT_ENV" "$ROOT_ENV_FILE"
install -m 600 "$USER_TUN_CONFIG_FILE" "$ROOT_TUN_CONFIG_FILE"
ln -sfn "$ROOT_TUN_CONFIG_FILE" "$ROOT_TUN_CONFIG_LEGACY"

cat >"$ROOT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ROOT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOT_RUN_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$ROOT_LOG_DIR/singbox-tun.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT_LOG_DIR/singbox-tun.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DMIT_IPROYAL_ROOT_ENV_FILE</key>
    <string>$ROOT_ENV_FILE</string>
  </dict>
</dict>
</plist>
PLIST

chown root:wheel "$ROOT_PLIST" "$ROOT_RUN_SCRIPT" "$ROOT_ENV_FILE" "$ROOT_TUN_CONFIG_FILE"
chmod 644 "$ROOT_PLIST"
chown -h root:wheel "$ROOT_TUN_CONFIG_LEGACY" >/dev/null 2>&1 || true

launchctl bootout system/$ROOT_LABEL >/dev/null 2>&1 || true
launchctl enable system/$ROOT_LABEL >/dev/null 2>&1 || true
launchctl bootstrap system "$ROOT_PLIST"
launchctl enable system/$ROOT_LABEL >/dev/null 2>&1 || true
launchctl kickstart -k system/$ROOT_LABEL
launchctl print system/$ROOT_LABEL >/dev/null
EOF_ROOT
chmod 700 "$TMP_ROOT_SCRIPT"

run_as_admin() {
  local cmd_path="$1"

  if sudo -n true >/dev/null 2>&1; then
    sudo "$cmd_path"
    return 0
  fi

  if [ "$GUI_PROMPT" = "1" ]; then
    local escaped
    escaped="${cmd_path//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    /usr/bin/osascript <<APPLESCRIPT
try
  do shell script "bash \"$escaped\"" with administrator privileges
  return "OK"
on error errMsg number errNum
  error errMsg number errNum
end try
APPLESCRIPT
    return 0
  fi

  return 1
}

if run_as_admin "$TMP_ROOT_SCRIPT"; then
  echo "TUN privileged service installed and started."
  exit 0
fi

echo "Admin privileges required to install TUN service." >&2
echo "Options:" >&2
echo "1) CLI: sudo $SCRIPT_DIR/install_tun_privileged.sh" >&2
echo "2) GUI prompt: $SCRIPT_DIR/install_tun_privileged.sh --gui" >&2
exit 1
