#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$(mktemp -d /tmp/personalvpn-safe-api.XXXXXX)"
SOCKET="$RUN_DIR/daemon.sock"
STATE="$RUN_DIR/state"
DAEMON="$ROOT/.build/debug/personalvpnd"
CTL="$ROOT/.build/debug/personalvpnctl"

swift build --package-path "$ROOT" >/dev/null
"$DAEMON" --socket "$SOCKET" --state-dir "$STATE" >"$RUN_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" >/dev/null 2>&1 || true' EXIT INT TERM

for _ in $(seq 1 50); do
  [ -S "$SOCKET" ] && break
  sleep 0.05
done
[ -S "$SOCKET" ] || { echo "daemon did not create its development socket" >&2; exit 1; }

STATUS="$("$CTL" --socket "$SOCKET" status)"
printf '%s\n' "$STATUS" | grep -q '"networkEnabled" : false'
printf '%s\n' "$STATUS" | grep -q '"mode" : "direct"'

"$CTL" --socket "$SOCKET" config-import "$ROOT/config.example.json" >/dev/null
if "$CTL" --socket "$SOCKET" stable primary-vps stable-isp >"$RUN_DIR/connect.out" 2>&1; then
  echo "disabled daemon unexpectedly accepted a network connection request" >&2
  exit 1
fi
grep -q 'Safety gate denied' "$RUN_DIR/connect.out"
"$CTL" --socket "$SOCKET" direct >/dev/null

# A malformed client must be isolated to that connection and must not crash the
# authoritative daemon.
ruby -rsocket -e 'socket = UNIXSocket.new(ARGV[0]); socket.puts("{"); socket.close' "$SOCKET"
sleep 0.1
"$CTL" --socket "$SOCKET" status >/dev/null

echo "safe API smoke test passed; no network mutation was enabled"
echo "artifacts retained at $RUN_DIR"
