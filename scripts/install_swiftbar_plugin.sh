#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLUGIN_SRC="$REPO_ROOT/swiftbar/dmit-iproyal.30s.sh"
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
PLUGIN_DST="$PLUGIN_DIR/dmit-iproyal.30s.sh"

[ -f "$PLUGIN_SRC" ] || { echo "Plugin source not found: $PLUGIN_SRC" >&2; exit 1; }

if [ ! -d /Applications/SwiftBar.app ]; then
  if command -v brew >/dev/null 2>&1; then
    brew list --cask swiftbar >/dev/null 2>&1 || brew install --cask swiftbar
  else
    echo "SwiftBar not found and Homebrew unavailable. Install SwiftBar first." >&2
    exit 1
  fi
fi

mkdir -p "$PLUGIN_DIR"
install -m 755 "$PLUGIN_SRC" "$PLUGIN_DST"

defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR" >/dev/null 2>&1 || true

open -a SwiftBar >/dev/null 2>&1 || true

# Best effort: add SwiftBar as a login item so menu control is always present.
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "System Events"
  if not (exists login item "SwiftBar") then
    make login item at end with properties {name:"SwiftBar", path:"/Applications/SwiftBar.app", hidden:false}
  end if
end tell
APPLESCRIPT

echo "Installed SwiftBar plugin: $PLUGIN_DST"
echo "SwiftBar plugin directory: $PLUGIN_DIR"
