> Publication status (2026-10-21): historical/research architecture. See the
> [current cross-client guide](../docs/stable-isp/architecture-and-clients.md).
> This document is not proof of a production-accepted native VPN release.

# Architecture

The macOS data plane uses sing-box's gVisor TUN stack. The command-line system
stack can install routes without delivering packets on some macOS 15.6 hosts;
gVisor is therefore an explicit compatibility invariant. The compiler also
emits `/32` or `/128` exclusions for fixed tunnel entry points to prevent
recursive capture of the SSH and ISP transports.

## Authority and data flow

`personalvpnd` is the only component allowed to own desired mode, connection
phase, sing-box configuration, child process, health history, and route
selection. The App and CLI are clients; neither infers state from ports or
system proxy settings.

```text
PersonalVPN.app ─┐
                 ├─ versioned JSON Lines over owner-only Unix socket
personalvpnctl ──┘
                         │
                    personalvpnd
                         │ validated JSON + pinned binary
                      sing-box TUN
                         │
              stable SSH detour or VMess node
```

The socket is mode `0600`, owned by the configured console UID, and every
accepted connection is checked with `getpeereid`. Root is also accepted for
offline rescue and administration.

## State semantics

- Direct stops the TUN child; it is not a synthetic direct outbound.
- An active route is immutable during automatic recovery.
- Three failed health rounds trigger same-route reconnects after
  1/2/5/10/30 seconds.
- Exhaustion stops TUN and records `error-direct`.
- An expected-exit mismatch records `degraded` but does not reconnect or switch.
- Configuration is compiled and checked before replacing an active engine.

## Security and maintenance

- All JSON is produced with `JSONSerialization`/`Codable`, never shell string
  interpolation.
- SSH requires an explicit host-key pin.
- Subscription responses are limited to 10 MB and must use HTTPS.
- Sensitive values are redacted at the daemon API boundary and in errors.
- The sing-box executable is copied into a release bundle and covered by the
  release SHA-256 manifest.
- The physical-host safety gate requires two independent acknowledgements.
- No PF firewall or kill switch is installed; failure is deliberately fail-open
  to a clearly reported Direct state.

## Versioning

The persisted configuration starts at schema version 1. Unknown schema
versions are rejected rather than guessed. Additional subscription protocols
must be implemented as parsers that produce typed nodes; raw subscription
configuration is never passed directly to sing-box.
