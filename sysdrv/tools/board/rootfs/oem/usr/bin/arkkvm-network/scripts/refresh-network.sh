#!/bin/sh
# Sole network refresh entry — read network.conf and apply full network config
# ArkKVM simplified scheme: app layer only maintains network.conf and calls this script
set -e

NWU_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
export NWU_ROOT

# shellcheck source=/dev/null
. "$NWU_ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$NWU_ROOT/lib/config.sh"
nwu_load_paths
nwu_source_libs

# Serialize refresh / link-up / app apply (single flight).
# BusyBox flock: `flock FD` (no PROG) never returns — it stays as a child while the
# parent shell waits forever (util-linux returns after locking the shared OFD).
# Use FILE + re-exec instead (BusyBox and util-linux both support this form).
LOCK="${NWU_REFRESH_LOCK:-/run/arkkvm-network.refresh.lock}"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
if [ -z "${NWU_REFRESH_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
	export NWU_REFRESH_LOCKED=1
	exec flock "$LOCK" "$0" "$@"
fi

# Invalidate any in-flight VLAN DHCP retry before re-applying.
nwu_dhcp_retry_bump_gen 2>/dev/null || true
nwu_dhcp_retry_stop 2>/dev/null || true

conf=""
while [ $# -gt 0 ]; do
	case "$1" in
	--staging)
		export NWU_APPLY_MODE=staging
		shift
		;;
	--committed)
		export NWU_APPLY_MODE=committed
		shift
		;;
	-*)
		die "Unknown argument: $1"
		;;
	*)
		conf="$1"
		shift
		;;
	esac
done
conf="${conf:-$NETWORK_CONF}"

msg_info "======== refresh-network ========"
msg_info "Config file: $conf"
[ -n "${NWU_APPLY_MODE:-}" ] && msg_info "Apply mode: $NWU_APPLY_MODE"

nwu_require_root
nwu_require_cmd ip

nwu_conf_parse "$conf"

nwu_log "======== refresh start ========"
nwu_log "dhcp=$CONF_DHCP_CLIENT ipv4=$CONF_IPV4_MODE vlan=${CONF_VLAN_ENABLED:-false} mode=${NWU_APPLY_MODE:-$CONF_VLAN_APPLY_MODE}"

# 1. loopback
nwu_run ip link set lo up 2>/dev/null || true

# 2. Before switching DHCP backend: stop non-selected backend (mutual exclusion)
msg_step "Ensure only DHCP backend: $CONF_DHCP_CLIENT"
nwu_dhcp_stop_other_backend

# 3. Hostname
nwu_hostname_set "$CONF_HOSTNAME" "$CONF_DOMAIN"

# 4. Link + L3
if nwu_vlan_is_enabled; then
	NET_IF="$CONF_VLAN_PARENT"
	export NET_IF
	nwu_ipv4ll_remove 2>/dev/null || true
	nwu_link_ensure_up
	# Leaving flat eth0 DHCP behind: stop all clients before VLAN L3 owns traffic.
	nwu_udhcpc_stop_all 2>/dev/null || true
	export NWU_DHCP_FORCE_RESTART=1
	nwu_vlan_apply
	unset NWU_DHCP_FORCE_RESTART
else
	# Snapshot VLAN ifaces before disable — only that teardown changes L2 domain.
	_vlan_before=$(nwu_vlan_list_ifaces "$CONF_VLAN_PARENT" 2>/dev/null || true)
	nwu_vlan_apply_disabled
	nwu_link_ensure_up
	if [ -n "$_vlan_before" ]; then
		# Leaving eth0.N: force rediscover on untagged eth0 + carrier bounce.
		nwu_udhcpc_stop_all 2>/dev/null || true
		if ! nwu_skip_netlink && ! nwu_is_dry_run; then
			ip link set "$NET_IF" down 2>/dev/null || true
			sleep 1
			ip link set "$NET_IF" up 2>/dev/null || true
			sleep 1
		fi
		export NWU_DHCP_FORCE_RESTART=1
		nwu_ipv4_apply
		unset NWU_DHCP_FORCE_RESTART
	else
		# Flat eth0 refresh (incl. OTA migrate / link-up): do not kill negotiating udhcpc.
		nwu_ipv4_apply
	fi

	# udhcpc backend: wait for lease ready (for DNS / lease file)
	if [ "$CONF_IPV4_MODE" = "dhcp" ] && [ "$CONF_DHCP_CLIENT" = "udhcpc" ]; then
		nwu_udhcpc_wait_lease 2>/dev/null || true
	fi

	nwu_ipv6_apply
	nwu_resolv_apply

	if [ "$CONF_IPV4_MODE" = "dhcp" ]; then
		nwu_dhcp_sync_lease
		if [ "$CONF_DHCP_CLIENT" = "udhcpc" ] && ! nwu_udhcpc_lease_valid 2>/dev/null; then
			if ! nwu_skip_netlink && ! nwu_is_dry_run; then
				i=0
				while [ "$i" -lt 8 ]; do
					[ -n "$(nwu_ipv4_linklocal_cidr "$NET_IF")" ] && break
					nwu_udhcpc_lease_valid 2>/dev/null && break
					if nwu_udhcpc_has_ipv4 2>/dev/null; then
						nwu_udhcpc_write_lease_from_system 2>/dev/null && break
					fi
					sleep 1
					i=$((i + 1))
				done
			fi
		fi
	fi
	# If DHCP bound during the wait, drop the fallback; otherwise keep it.
	nwu_ipv4ll_apply
fi

NET_IF="$CONF_IFACE"
export NET_IF

nwu_log "======== refresh end ========"
msg_ok "Network refreshed from network.conf"
nwu_state_print
if [ "$CONF_VLAN_ENABLED" = "true" ]; then
	nwu_vlan_status
fi
