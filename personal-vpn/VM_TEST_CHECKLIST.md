# Parallels macOS VM acceptance checklist

Create a clean macOS 14+ Apple Silicon VM, enable NAT networking, take a
snapshot, and perform all steps inside the VM.

1. Run `swift test`; all tests must pass, including installed sing-box config
   validation.
2. Build the release and verify every entry in `dist/SHA256SUMS`.
3. Install the disabled daemon and confirm `status` reports Direct with
   `networkEnabled=false`.
4. Import dedicated non-production VPS/ISP and subscription credentials.
5. Confirm connect requests are denied before canary arming.
6. Arm a 120-second canary and deliberately do not commit; verify automatic
   Direct recovery.
7. Arm again and validate stable mode: DNS, HTTPS, UDP, exit IP, SSH host-key
   rejection, ISP authentication rejection, and same-route reconnect.
8. Validate subscription mode with at least one VMess TCP and one WebSocket
   node, refresh failure cache retention, and certificate-pin mismatch.
9. Kill sing-box and daemon separately; verify no orphan TUN or stale route.
10. Sleep/wake, switch VM network connectivity, and renew DHCP.
11. Exercise Direct from App, CLI, and `personalvpn-rescue` during every phase.
12. Run the selected stable route for 24 hours and inspect state/log growth.
13. Revert the VM snapshot and repeat installation to prove reproducibility.

Do not copy production secrets into VM snapshots that will be retained.
