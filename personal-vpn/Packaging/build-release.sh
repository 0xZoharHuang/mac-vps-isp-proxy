#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/.build/release"
SING_BOX_BIN="${SING_BOX_BIN:-$(command -v sing-box || true)}"

[ -n "$SING_BOX_BIN" ] && [ -x "$SING_BOX_BIN" ] || {
  echo "sing-box is required to produce a pinned release bundle" >&2
  exit 1
}

swift build --package-path "$ROOT" -c release
rm -rf "$DIST"
mkdir -p "$DIST/PersonalVPN.app/Contents/MacOS" "$DIST/PersonalVPN.app/Contents/Resources" "$DIST/libexec"
install -m 755 "$BUILD/PersonalVPNApp" "$DIST/PersonalVPN.app/Contents/MacOS/PersonalVPNApp"
install -m 755 "$BUILD/personalvpnd" "$DIST/libexec/personalvpnd"
install -m 755 "$BUILD/personalvpnctl" "$DIST/personalvpnctl"
install -m 755 "$SING_BOX_BIN" "$DIST/libexec/sing-box"
install -m 755 "$ROOT/Packaging/personalvpn-rescue" "$DIST/personalvpn-rescue"
install -m 755 "$ROOT/Packaging/personalvpn-canary" "$DIST/personalvpn-canary"

cat >"$DIST/PersonalVPN.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PersonalVPNApp</string>
  <key>CFBundleIdentifier</key><string>local.personalvpn.app</string>
  <key>CFBundleName</key><string>Personal VPN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$DIST/PersonalVPN.app"
(
  cd "$DIST"
  shasum -a 256 PersonalVPN.app/Contents/MacOS/PersonalVPNApp personalvpnctl personalvpn-rescue personalvpn-canary libexec/personalvpnd libexec/sing-box >SHA256SUMS
)
echo "Release bundle created at $DIST"
echo "This command did not install or start anything."
