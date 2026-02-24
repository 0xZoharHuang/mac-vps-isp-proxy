#!/usr/bin/env bash
set -euo pipefail

CTL="${DMIT_IPROYAL_CTL:-$HOME/.local/bin/dmit-iproyal-proxyctl}"
if [ ! -x "$CTL" ]; then
  CTL="$HOME/Library/Application Support/dmit-iproyal/bin/dmit_iproyal_proxyctl.sh"
fi

if [ ! -x "$CTL" ]; then
  echo "D-ISP ! | color=red"
  echo "---"
  echo "Control script missing: $CTL"
  exit 0
fi

mode=""
service=""
shell_proxy=""
tun_installed=""
tun_loaded=""
tun_running=""
surge_running=""
proxy_core_running=""
tunnel_running=""

while IFS='=' read -r k v; do
  case "$k" in
    mode) mode="$v" ;;
    service) service="$v" ;;
    shell_proxy) shell_proxy="$v" ;;
    tun_installed) tun_installed="$v" ;;
    tun_loaded) tun_loaded="$v" ;;
    tun_running) tun_running="$v" ;;
    surge_running) surge_running="$v" ;;
    proxy_core_running) proxy_core_running="$v" ;;
    tunnel_running) tunnel_running="$v" ;;
  esac
done < <("$CTL" info 2>/dev/null || true)

[ -n "$mode" ] || mode="unknown"
[ -n "$service" ] || service="unknown"
[ -n "$shell_proxy" ] || shell_proxy="unknown"
[ -n "$tun_installed" ] || tun_installed="unknown"
[ -n "$tun_loaded" ] || tun_loaded="unknown"
[ -n "$tun_running" ] || tun_running="unknown"
[ -n "$surge_running" ] || surge_running="unknown"
[ -n "$proxy_core_running" ] || proxy_core_running="unknown"
[ -n "$tunnel_running" ] || tunnel_running="unknown"

label="D-ISP ?"
color="#E53E3E"

case "$mode" in
  stack-tun)
    label="D-ISP TUN"
    color="#15803D"
    ;;
  stack-proxy)
    label="D-ISP PROXY"
    color="#2BA84A"
    ;;
  surge)
    label="D-ISP SURGE"
    color="#CC7A00"
    ;;
  direct)
    label="D-ISP OFF"
    color="#777777"
    ;;
  other-proxy)
    label="D-ISP MIX"
    color="#DD6B20"
    ;;
  *)
    label="D-ISP ?"
    color="#E53E3E"
    ;;
esac

# No top-bar click action: click only opens dropdown menu.
echo "$label | color=$color"

echo "---"
echo "Current: $label"
echo "Network Service: $service"

echo "---"
echo "Use Proxy (Stable) | bash=$CTL param1=use-stack-proxy-gui terminal=false refresh=true"
echo "Use Surge | bash=$CTL param1=use-surge-gui terminal=false refresh=true"
echo "Use TUN (Admin) | bash=$CTL param1=use-stack-tun-gui terminal=false refresh=true"
echo "Use Direct (No Proxy) | bash=$CTL param1=use-direct-gui terminal=false refresh=true"

echo "---"
echo "Advanced"
echo "--Mode: $mode"
echo "--Shell Proxy: $shell_proxy"
echo "--TUN Installed: $tun_installed"
echo "--TUN Loaded: $tun_loaded"
echo "--TUN Running: $tun_running"
echo "--Surge Running: $surge_running"
echo "--Proxy Core Running: $proxy_core_running"
echo "--Tunnel Running: $tunnel_running"
echo "--Refresh Status | refresh=true"
echo "--Quick Test Exit IP | bash=$CTL param1=test terminal=false refresh=true"
echo "--Doctor | bash=$CTL param1=doctor terminal=false refresh=true"

echo "---"
echo "TUN Tools"
echo "--Install (One-Time Admin) | bash=$CTL param1=tun-install-gui terminal=false refresh=true"
echo "--Start | bash=$CTL param1=tun-start-gui terminal=false refresh=true"
echo "--Stop | bash=$CTL param1=tun-stop-gui terminal=false refresh=true"
echo "--Status | bash=$CTL param1=tun-status terminal=false refresh=true"
echo "--Repair (Reinstall + Start) | bash=$CTL param1=tun-repair-gui terminal=false refresh=true"

echo "---"
echo "Open Logs | bash=/bin/bash param1=-lc param2='open "$HOME/Library/Logs/dmit-iproyal"' terminal=false refresh=false"
echo "Open Config | bash=/bin/bash param1=-lc param2='open "$HOME/.config/dmit-iproyal"' terminal=false refresh=false"
