# NetBird client for ArkKVM

Optional [NetBird](https://netbird.io) WireGuard mesh VPN client, offered next to
Tailscale. NetBird's control plane (management, signal, relay) is open source and
can be self-hosted, so remote access does not depend on a third-party
coordination service.

## Files

| Path | Purpose |
|------|---------|
| `sysdrv/tools/board/netbird/fetch-netbird.sh` | Downloads the pinned client release and verifies its SHA256 |
| `sysdrv/tools/board/rootfs/oem/usr/bin/netbird/netbird` | Client + daemon binary (fetched, not committed) |
| `sysdrv/tools/board/rootfs/etc/init.d/S41netbird` | Init script, driven by `arkkvm_app` (same contract as `S40tailscale`) |

Run `fetch-netbird.sh` once before building the rootfs.

## Runtime layout

| Path | Content |
|------|---------|
| `/userdata/arkkvm/netbird/enable` | Present = start daemon on boot |
| `/userdata/arkkvm/netbird/management_url` | Self-hosted management URL (absent = NetBird Cloud) |
| `/userdata/arkkvm/netbird/hostname` | Peer hostname used on registration |
| `/userdata/arkkvm/netbird/state/` | `NB_STATE_DIR`: profile config, WireGuard key, daemon state |
| `/var/run/netbird.sock` | Daemon gRPC socket |

The daemon logs to syslog. Setup keys are passed to `netbird up` via the
`NB_SETUP_KEY` environment variable and are never written to disk or argv.

## Manual use

```sh
/etc/init.d/S41netbird enable
/etc/init.d/S41netbird setManagementUrl https://netbird.example.com
NB_SETUP_KEY=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX /etc/init.d/S41netbird register
/etc/init.d/S41netbird getStatus
```

## Notes

- NetBird uses kernel WireGuard when available and otherwise falls back to
  userspace WireGuard on a TUN device (same requirement as Tailscale).
- Tailscale and NetBird both default to the `100.64.0.0/10` CGNAT range. Running
  both at once works only if the NetBird network range does not overlap with
  addresses used on the tailnet.
