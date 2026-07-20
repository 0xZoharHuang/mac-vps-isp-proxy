#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "--i-understand-this-only-installs-a-disabled-daemon" ]; then
  echo "Refusing to install without the explicit safety acknowledgement." >&2
  echo "Usage: sudo $0 --i-understand-this-only-installs-a-disabled-daemon [dist-dir]" >&2
  exit 2
fi

[ "$(id -u)" -eq 0 ] || { echo "Run this installer with sudo." >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${2:-$SCRIPT_DIR/../dist}"
CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
CONSOLE_GROUP="$(id -gn "$CONSOLE_USER")"
CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')"
PLIST="/Library/LaunchDaemons/local.personalvpn.daemon.plist"
APP_PLIST="$CONSOLE_HOME/Library/LaunchAgents/local.personalvpn.app.plist"

[ -f "$DIST/SHA256SUMS" ] || { echo "Missing release manifest in $DIST" >&2; exit 1; }
(cd "$DIST" && shasum -a 256 -c SHA256SUMS)

install -d -m 755 /usr/local/libexec/personalvpn /usr/local/bin /usr/local/sbin
install -d -m 700 "/Library/Application Support/PersonalVPN"
install -m 755 "$DIST/libexec/personalvpnd" /usr/local/libexec/personalvpn/personalvpnd
install -m 755 "$DIST/libexec/sing-box" /usr/local/libexec/personalvpn/sing-box
install -m 755 "$DIST/personalvpnctl" /usr/local/bin/personalvpnctl
install -m 755 "$DIST/personalvpn-rescue" /usr/local/sbin/personalvpn-rescue
install -m 755 "$DIST/personalvpn-canary" /usr/local/sbin/personalvpn-canary
rm -rf "/Applications/PersonalVPN.app"
cp -R "$DIST/PersonalVPN.app" "/Applications/PersonalVPN.app"

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.personalvpn.daemon</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/libexec/personalvpn/personalvpnd</string>
    <string>--owner-uid</string><string>$CONSOLE_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootout system/local.personalvpn.daemon >/dev/null 2>&1 || true
sleep 1
if ! launchctl bootstrap system "$PLIST"; then
  sleep 2
  launchctl bootstrap system "$PLIST"
fi
READY=0
for _ in $(seq 1 50); do
  if /usr/local/bin/personalvpnctl status >/dev/null 2>&1; then READY=1; break; fi
  sleep 0.1
done
[ "$READY" -eq 1 ] || { echo "PersonalVPN daemon did not become ready." >&2; exit 1; }

install -d -o "$CONSOLE_USER" -g "$CONSOLE_GROUP" -m 700 "$CONSOLE_HOME/Library/LaunchAgents"
cat >"$APP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.personalvpn.app</string>
  <key>ProgramArguments</key><array>
    <string>/Applications/PersonalVPN.app/Contents/MacOS/PersonalVPNApp</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
chown "$CONSOLE_USER:$CONSOLE_GROUP" "$APP_PLIST"
chmod 600 "$APP_PLIST"
launchctl bootout "gui/$CONSOLE_UID/local.personalvpn.app" >/dev/null 2>&1 || true
sleep 1
if ! launchctl bootstrap "gui/$CONSOLE_UID" "$APP_PLIST" >/dev/null 2>&1; then
  sleep 2
  launchctl bootstrap "gui/$CONSOLE_UID" "$APP_PLIST" >/dev/null 2>&1 || true
fi

echo "Installed Personal VPN for $CONSOLE_USER."
echo "Safety state: daemon installed WITHOUT --network-enabled; it cannot start TUN."
echo "The menu-bar app is configured to start when $CONSOLE_USER logs in."
echo "The existing proxy stack and system network settings were not changed."
