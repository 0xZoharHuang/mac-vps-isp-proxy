# mac-vps-isp-proxy

A macOS proxy stack that routes traffic through `local -> DMIT VPS (SSH relay) -> ISP proxy` with menu-bar mode switching (SwiftBar), system proxy support, and optional TUN mode.

## What This Solves

- Stable daily proxy path for browser/apps/CLI on macOS.
- One-click mode switching from menu bar:
  - `PROXY` (recommended stable)
  - `TUN` (full-traffic coverage, admin required)
  - `SURGE` (handoff back to Surge)
  - `OFF` (direct)
- Built-in diagnostics (`doctor`, `test`, TUN status/repair commands).

## Important Notes

- This repository contains **no production credentials**.
- `403` from services like Claude/ChatGPT is usually an **IP reputation / risk-control** issue, not a script bug.
- TUN mode needs privileged launchd daemon install and may prompt macOS admin authentication.

## Architecture

```text
Apps / Browser / CLI
      |
      | (PROXY mode: system HTTP/SOCKS + shell env)
      v
local sing-box (127.0.0.1:17890/17891)
      |
      v
SSH local forward (to DMIT VPS)
      |
      v
Upstream ISP proxy (SOCKS5/HTTP)
      |
      v
Internet
```

In `TUN` mode, root sing-box captures system traffic directly and routes final egress through the ISP upstream.

## Requirements

- macOS
- `bash`, `curl`, `ssh`, `networksetup`, `launchctl`
- `sing-box` (script can install via Homebrew)
- Optional: `SwiftBar` for menu UI
- Optional: `Surge` if you want Surge mode handoff

## Quick Start

1. Prepare runtime variables (example):

```bash
export DMIT_HOST="your.dmit.vps.ip"
export DMIT_PORT="443"
export DMIT_USER="root"

export IPROYAL_HOST="your.isp.proxy.host"
export IPROYAL_PORT="your.isp.proxy.port"
export IPROYAL_USER="your.isp.user"
export IPROYAL_PASS="your.isp.password"

# Either provide an existing SSH key, or a zip containing id_rsa.pem
export KEY_TARGET="$HOME/.ssh/dmit_relay_id_rsa"
# export KEY_ZIP="$HOME/path/to/relay-key.zip"
```

2. Install:

```bash
cd data-series/dmit-iproyal-stack
./scripts/install_all.sh
```

3. Use menu bar:

- `Use Proxy (Stable)` for daily use
- `Use TUN (Admin)` for full-coverage routing
- `Use Surge` to hand off back to Surge

## Modes

- `stack-proxy`: system proxy + local proxy core + shell env
- `stack-tun`: root TUN + optional proxy core retention for CLI compatibility
- `surge`: D-ISP proxy off, return control to Surge
- `direct`: no proxy

## Core Commands

```bash
dmit-iproyal-proxyctl info
dmit-iproyal-proxyctl doctor

dmit-iproyal-proxyctl use-stack-proxy-gui
dmit-iproyal-proxyctl use-stack-tun-gui
dmit-iproyal-proxyctl use-surge-gui
dmit-iproyal-proxyctl use-direct-gui

dmit-iproyal-proxyctl tun-status
dmit-iproyal-proxyctl tun-loaded
dmit-iproyal-proxyctl tun-running
dmit-iproyal-proxyctl tun-repair-gui
```

## TUN Reliability Defaults

- `TUN_MTU=1500`
- `TUN_KEEP_PROXY_CORE=1`
- `TUN_KEEP_SHELL_ENV=1`
- Fast health probes + post-cutover validation + rollback to proxy mode

## Troubleshooting

- `SOCKS proxy invalid response`: check upstream proxy protocol/account and relay path.
- `stream disconnected` in CLI after switching: use current codebase defaults (`TUN_KEEP_PROXY_CORE=1`, `TUN_KEEP_SHELL_ENV=1`).
- `403 forbidden`: replace egress IP/provider; this is typically reputation-based.

## Security

- Do not commit real credentials or private keys.
- Prefer environment variables or secure local secret storage.
- Keep `~/.config/dmit-iproyal/env` local-only.

## Project Layout

- `scripts/`: setup, control, launchd/TUN install scripts
- `swiftbar/`: menu bar plugin
