# Personal VPN for macOS

`personal-vpn/` is the parallel, product-oriented replacement for the legacy
DMIT/IPRoyal Shell stack. It is intentionally not installed by a normal build.

## Safety contract

- `swift build` and `swift test` never change routes, proxies, DNS, launchd, or
  the running legacy stack.
- `personalvpnd` starts with network operations disabled unless it receives
  `--network-enabled`.
- On a physical Mac, `--network-enabled` is still denied unless both the
  `PERSONALVPN_ALLOW_HOST_NETWORK=I_UNDERSTAND_THIS_CHANGES_ROUTES` environment
  value and `/Library/Application Support/PersonalVPN/host-canary-approved`
  marker exist.
- The local installer installs a disabled daemon. Network enablement is a
  separate canary operation with an independent rollback timer.
- Root/TUN testing belongs in a snapshotted Parallels macOS VM. Do not use the
  host Mac as the first integration environment.

## Components

- `PersonalVPNCore`: typed configuration, VMess subscription parser, state
  machine, safe JSON generation, TLS pinning, redaction, and socket protocol.
- `personalvpnd`: the single source of truth and sing-box supervisor.
- `personalvpnctl`: CLI and offline-friendly control surface.
- `PersonalVPNApp`: SwiftUI menu-bar UI and configuration window.
- `Packaging/`: release builder, disabled-by-default installer, rescue command,
  and canary dead-man switch.

The stable route is generated as:

```text
TUN → ISP SOCKS/HTTP outbound → sing-box SSH detour → VPS → ISP → Internet
```

The subscription route supports Base64 lists of `vmess://` entries. VMess TCP
and WebSocket transports are supported in this first implementation.

## Safe development

```bash
cd personal-vpn
swift test
swift build
```

To exercise the API without allowing any network mutation:

```bash
SOCKET=/tmp/personalvpn-dev.sock
STATE=/tmp/personalvpn-dev-state
.build/debug/personalvpnd --socket "$SOCKET" --state-dir "$STATE"
PERSONALVPN_SOCKET="$SOCKET" .build/debug/personalvpnctl status
```

Any `stable` or `subscription` connect request sent to this development daemon
is rejected by `SafetyGate`. `direct`, status, configuration import, and local
socket tests remain available.

## Configuration

The settings window can add VPS, ISP, and standard-HTTPS subscription sources.
The CLI can import the full versioned JSON format:

```bash
personalvpnctl config-import ./config.json
```

Start from `config.example.json`. Never commit a populated configuration.

Important distinctions:

- `host` is an entry address and may be a domain.
- `expectedEgressIP` is optional and represents the public exit identity.
- SSH host keys are mandatory and pinned.
- Subscription TLS uses system trust or an explicitly configured SHA-256 pin.
- Client-facing API responses redact passwords, private-key paths, UUIDs, and
  subscription tokens.

A pinned subscription source uses this stable JSON shape:

```json
{
  "id": "private-subscription",
  "name": "Private Subscription",
  "url": "https://subscription.example/path?token=replace-me",
  "tlsPolicy": {
    "mode": "pinned-sha256",
    "fingerprint": "REPLACE_WITH_64_HEX_CHARACTERS"
  },
  "refreshIntervalSeconds": 21600
}
```

## VM-only release validation

Inside a snapshotted Parallels macOS VM:

```bash
./Packaging/build-release.sh
sudo ./Packaging/install-local.sh \
  --i-understand-this-only-installs-a-disabled-daemon ./dist
personalvpnctl status
```

Installation alone cannot start TUN. After importing VM test credentials, arm
the separately guarded network test:

```bash
sudo personalvpn-canary arm --i-understand-network-will-change 120
# Connect from PersonalVPN.app, verify IP/DNS, then either:
sudo personalvpn-canary commit
# or immediately:
sudo personalvpn-canary rollback
```

If no commit arrives before the deadline, `personalvpn-rescue` kills only the
new pinned sing-box process and restores the captured legacy mode when present.

## Current acceptance boundary

Completed and host-safe:

- typed config and atomic persistence;
- stable and VMess config compilation;
- actual `sing-box check` validation;
- authenticated local socket API;
- explicit Direct rescue;
- health monitoring, fixed-route reconnect, exit-IP mismatch detection;
- subscription refresh with TLS pinning;
- latency probe and manual throughput test;
- menu UI, settings UI, CLI, packaging and canary tooling.

Still requires VM execution before host installation:

- root LaunchDaemon lifecycle;
- real TUN/DNS routing and sleep/wake behavior;
- real DMIT → ISP SSH-detour interoperability;
- 24-hour soak and canary rollback drill.
