# network-config-unified — ArkKVM simplified networking

Assumes **arkkvm_app has no built-in network configuration**. The device keeps a single **`network.conf`**; the app layer reads/writes that file and calls **`refresh-network.sh`** (or `./ctl refresh`) to apply it.

DHCP can switch between **`udhcpc`** and **`dhcpcd`**. After switching, **all DHCP operations** (start, stop, renew, release, lease) go **only through the selected backend**; the other backend is stopped explicitly.

**VLAN** is configured via `[vlan]` / `[vlan.primary]` / `[vlan.secondary]`. Supports **committed** and **staging** (90-second pending window writing `network.conf.pending` without changing the committed file).

---

## Design goals

| Principle | Description |
|-----------|-------------|
| Single config source | Only `network.conf` (committed); pending uses `network.conf.pending` |
| Single refresh entry | `scripts/refresh-network.sh` applies all capabilities |
| Mutually exclusive DHCP backends | `[dhcp] client=` selects one backend; `lib/dhcp.sh` dispatches, no mixing |
| Thin app layer | Rust only reads/writes conf + runs refresh; no netlink/DHCP stack |
| VLAN staging | During pending, do not change `network.conf`; after reboot, init cleans temp files |

---

## Layout

```
network-config-unified/
├── ctl                          # Command entry point
├── config/
│   ├── default.env              # Path defaults (including pending/rollback paths)
│   ├── network.conf.example     # Config template (flat + VLAN)
│   └── network.conf             # Local reference template (kept in sync with example)
├── lib/
│   ├── parse.sh                 # Parse network.conf (including VLAN sections)
│   ├── vlan.sh                  # VLAN subinterfaces, staging/committed semantics
│   ├── dhcp-udhcpc.sh           # udhcpc backend (per-interface, including staging DHCP)
│   ├── dhcp-dhcpcd.sh           # dhcpcd backend
│   ├── dhcp.sh                  # Dispatch backend from conf; supports per-iface ops
│   ├── ipv4.sh / ipv6.sh / resolv.sh / link.sh / state.sh / ...
│   └── common.sh                # Shared helpers, library loading, nwu_with_iface
├── init/
│   └── S16network               # Boot start; runs nwu_vlan_cleanup_pending() first
└── scripts/
    ├── refresh-network.sh       # ★ Sole refresh script (--staging / --committed)
    ├── udhcpc-hook.sh           # Production udhcpc hook (lease, routes, DNS)
    ├── udhcpc-staging.script    # Staging DHCP: address only, no default route/DNS
    ├── run-tests.sh             # Local dry-run tests (11 cases)
    ├── verify-device.sh         # On-device full verification (conf-only, VLAN matrix)
    ├── run-full-verify.sh       # Local tests + deploy + on-device verify + report
    ├── deploy-to-device.sh      # rsync deploy to device
    ├── install-init.sh          # Install init.d script
    └── lib/
        └── serial-probe.py      # Serial subnet probe (fallback when SSH unreachable)
```

---

## network.conf format

### Flat network

```ini
[interface]
name=eth0

[system]
hostname=arkkvm
domain=local

[dhcp]
client=udhcpc          # udhcpc | dhcpcd

[ipv4]
mode=dhcp              # dhcp | static | disabled
address=192.168.5.100
netmask=255.255.255.0
gateway=192.168.5.1
dns=192.168.5.1 8.8.8.8

[ipv6]
mode=slaac             # slaac | static | link_local | disabled

[dns]
servers=               # Optional forced DNS; empty derives from lease or ipv4.dns
```

### VLAN (when `vlan.enabled=true`)

- **`[ipv4]`** applies to the **parent eth0 management path** (address/DHCP only; **no default route under committed**)
- **`[vlan.primary]`** drives L3 on subinterface `eth0.{id}`; **sole IPv4 default route under committed** (metric defaults to 0)
- **`[vlan.secondary]`** extra tagged access, **no default route**
- **staging**: parent keeps/restores its existing default route; VLAN subinterfaces install no default route (90s pending window)

```ini
[vlan]
enabled=false
parent=eth0
apply_mode=committed   # committed | staging (also overridable via refresh --staging)

[vlan.primary]
id=10
ipv4_mode=dhcp         # dhcp | static | disabled
ipv4_address=
ipv4_netmask=
ipv4_gateway=
ipv4_dns=
route_metric=0

[vlan.secondary]
id=0                   # 0 = not configured
ipv4_mode=disabled
ipv4_address=
ipv4_netmask=
ipv4_gateway=
ipv4_dns=
route_metric=200
```

### Helper files (userdata)

| File | Purpose |
|------|---------|
| `network.conf` | **Committed** config; boot and normal refresh read only this file |
| `network.conf.pending` | Temp config during 90s window; **never overwrites** `network.conf` |
| `network.conf.rollback` | Optional audit snapshot |
| `network.conf.pending-active` | Optional pending marker |

**Single-writer, multi-reader**: only one process (recommended `vlan.rs`) writes conf; others read only. Use `tmp + rename` for atomic replace on write.

---

## Quick start

```bash
cd network-config-unified

./ctl help
./ctl test                    # 11 local dry-run tests, no root required
./ctl dry-run refresh ./config/network.conf.example

# On-device deploy (SSH)
DEVICE_IP=192.168.5.116 ./scripts/deploy-to-device.sh

# Full verification (local tests + deploy + on-device conf-only matrix + report)
./scripts/run-full-verify.sh 192.168.5.116

# On-device networking
sudo cp config/network.conf.example /userdata/arkkvm/network.conf
sudo ./ctl refresh

# VLAN staging (pending file; does not change committed)
sudo ./ctl refresh --staging /userdata/arkkvm/network.conf.pending

# Switch DHCP backend then refresh
sudo sed -i 's/client=udhcpc/client=dhcpcd/' /userdata/arkkvm/network.conf
sudo ./ctl refresh

# Renew lease (flat or VLAN subinterface)
sudo ./ctl dhcp renew
sudo ./ctl dhcp renew eth0.10
```

### Device access

| Method | Notes |
|--------|-------|
| **SSH deploy/verify** | `ssh -i ~/.ssh/procscope_ed25519 root@<DEVICE_IP>` |
| **Serial (preferred for verify)** | `/dev/cu.usbserial-120` 115200 8N1, `root` / `ArkKVM` |
| **Serial automation** | `python3 scripts/serial-device-verify.py` (use when SSH is unreachable; do not rely on local dry-run alone) |

---

## refresh flow

```
Parse network.conf (or pending file from --staging)
  → Stop non-selected DHCP backend
  → Hostname
  → If vlan.enabled:
        committed: create/sync subinterfaces → primary/secondary L3 → parent mgmt path (no default route) → primary default route only → DNS/lease
        staging:   apply VLAN L3 → keep/restore parent eth0 mgmt path → strip VLAN default routes
     Else:
        Delete VLAN subinterfaces → flat IPv4/IPv6/DNS/lease
  → Sync lease file /run/udhcpc.{iface}.info
```

Environment variables:

- `NWU_APPLY_MODE=staging|committed` (defaults from `vlan.apply_mode` in conf)
- `NWU_DRY_RUN=1` / `NWU_FORCE=1` / `NWU_TEST_MODE=1`

---

## Switching DHCP backends

| Operation | udhcpc backend | dhcpcd backend |
|-----------|----------------|----------------|
| Start | `udhcpc -i <iface> -s udhcpc-hook.sh` | `dhcpcd` + `dhcpcd -n <iface>` |
| Stop | Kill udhcpc per interface | `dhcpcd -k` / stop init |
| Renew | SIGUSR1 | `dhcpcd -n` |
| Release | SIGUSR2 | `dhcpcd -k` |
| Lease file | Hook writes `/run/udhcpc.<iface>.info` | Synthesized from `ip`/resolv |

On `refresh`, if `client` changes from `udhcpc` to `dhcpcd`, udhcpc is **stopped** first, then dhcpcd is **started**, and vice versa.

> **Why can the IP change after switching backends?** DHCP servers identify clients by **Client-ID/DUID**, not MAC alone. udhcpc uses `-x 0x3d:01<MAC>`; dhcpcd’s default DUID format differs, so the client may look new. For a stable IP: `release` before switching, unify Client-ID, or reserve by MAC on the router.

---

## Integration with arkkvm_app (suggested)

```rust
// Pseudocode — flat / VLAN committed
fn apply_network(settings: &NetworkSettings) {
    write_network_conf("/userdata/arkkvm/network.conf", settings)?;
    Command::new("/oem/usr/bin/arkkvm-network/scripts/refresh-network.sh")
        .status()?;
}

// VLAN pending (90s window)
fn set_vlan_settings(settings: &VlanSettings) {
    write_network_conf("/userdata/arkkvm/network.conf.pending", settings)?;
    Command::new(".../refresh-network.sh")
        .arg("--staging")
        .arg("/userdata/arkkvm/network.conf.pending")
        .env("NWU_APPLY_MODE", "staging")
        .status()?;
}

fn confirm_vlan_settings() {
    rename("network.conf.pending", "network.conf")?;  // atomic promote
    // Runtime already matches pending contents; refresh optional
}
```

- Web UI changes IP → update `network.conf` → `refresh`
- `renewDHCPLease` / `renewVlanDhcpLease` → `ctl dhcp renew [eth0.N]`
- `getVlanSettings` → read `network.conf` + pending; runtime enrichment → `ctl vlan status` + lease files
- Removable: `static_ip_config.rs` writing scattered conf, `S16network restart`, encrypted config network fields

---

## Command cheat sheet

| Command | Effect |
|---------|--------|
| `./ctl refresh [conf]` | Apply full network config |
| `./ctl refresh --staging <pending>` | Apply pending without changing committed |
| `./ctl refresh --committed [conf]` | Explicit committed mode |
| `./ctl conf [conf]` | Show parse result (including VLAN) |
| `./ctl status` | Runtime network info (IPv4/IPv6/VLAN fields aligned with Web UI) |
| `./ctl vlan status` | VLAN subinterface status/lease |
| `./ctl vlan cleanup-pending` | Remove `.pending` / `.rollback` etc. |
| `./ctl dhcp <op> [iface]` | start/stop/restart/renew/release/lease; iface e.g. `eth0.10` |
| `./ctl resolv show` | Show resolv.conf |
| `./ctl dry-run <cmd>` | Simulate |
| `./ctl test` | Local automated tests |

---

## Testing and deployment

| Script | Effect |
|--------|--------|
| `./ctl test` | Local 11 dry-run cases (parse, DHCP switch, VLAN staging, pending cleanup, etc.) |
| `./scripts/verify-device.sh` | On device: full flat + VLAN matrix, **conf + refresh only** |
| `./scripts/run-full-verify.sh [IP]` | Local test → deploy → on-device verify → `test-report-latest.md` |
| `./scripts/deploy-to-device.sh [IP]` | rsync to `/oem/usr/bin/arkkvm-network` |

---

## Boot autostart

Provides BusyBox **init.d** script [`init/S16network`](init/S16network):

1. Wait for userdata mount  
2. **`nwu_vlan_cleanup_pending()`** — remove unconfirmed `.pending` / `.rollback` (after reboot, only committed applies)  
3. Run `refresh-network.sh` (only `network.conf`)  
4. Background 12s lease catch-up (udhcpc cold start)

**Install on device:**

```bash
# Place the full network-config-unified tree on the device, e.g.:
#   /oem/usr/bin/arkkvm-network

sudo ./scripts/install-init.sh
# or manually:
sudo cp init/S16network /etc/init.d/S16network
sudo chmod +x /etc/init.d/S16network
```

**Suggested boot order:** `S11linkmount` → `S16network` → `S20appinit`

When using this scheme, **disable** legacy `S15dhcpcd` to avoid conflicting with the unified DHCP backend. `S16network` is provided by this project and replaces the old script.

Optional `/etc/default/network-unified`:

```sh
NWU_ROOT=/oem/usr/bin/arkkvm-network
NETWORK_CONF=/userdata/arkkvm/network.conf
WAIT_USERDATA_SEC=30
```

Path defaults are in [`config/default.env`](config/default.env) (including `NETWORK_CONF_PENDING`, etc.).

On first boot, if `network.conf` is missing, the init script copies from `config/network.conf.example` into userdata.
