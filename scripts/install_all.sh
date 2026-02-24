#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$HOME/.local/bin/dmit-iproyal-proxyctl"

"$SCRIPT_DIR/setup_dmit_iproyal_stack.sh"
"$SCRIPT_DIR/install_swiftbar_plugin.sh"

if [ -x "$CTL" ]; then
  "$CTL" status
  "$CTL" test || true
fi

echo "Install complete."
echo "Menu bar usage (current version):"
echo "- Top label is read-only (click opens dropdown only)"
echo "- Stable daily mode: choose Use Proxy (Stable) in dropdown"
echo "- Enhanced mode: Use TUN Mode (Admin) after one-time TUN install"
