# shellcheck shell=sh
# Background retry for committed primary VLAN DHCP until lease+router exist,
# or until generation changes (refresh / reset / vlan disable).
#
# Lab note: first enabling VLAN usually breaks L2 until the switch port is
# moved from untagged → tagged. Keep retrying (restart udhcpc when still
# address-less) so DHCP completes after that retag without a device reboot.

nwu_dhcp_retry_pidfile() {
	echo "${NWU_DHCP_RETRY_PID:-/run/arkkvm-network.dhcp-retry.pid}"
}

nwu_dhcp_retry_genfile() {
	echo "${NWU_DHCP_RETRY_GEN:-/run/arkkvm-network.dhcp-retry.gen}"
}

nwu_dhcp_retry_interval() {
	# Faster than 8s: wait for switch operator to flip port to tagged.
	echo "${NWU_DHCP_RETRY_INTERVAL:-5}"
}

nwu_dhcp_retry_bump_gen() {
	genf=$(nwu_dhcp_retry_genfile)
	mkdir -p "$(dirname "$genf")" 2>/dev/null || true
	old=0
	[ -f "$genf" ] && old=$(cat "$genf" 2>/dev/null || echo 0)
	case "$old" in
	''|*[!0-9]*) old=0 ;;
	esac
	echo $((old + 1)) >"$genf"
}

nwu_dhcp_retry_read_gen() {
	genf=$(nwu_dhcp_retry_genfile)
	[ -f "$genf" ] || { echo 0; return 0; }
	cat "$genf" 2>/dev/null || echo 0
}

nwu_dhcp_retry_stop() {
	pidf=$(nwu_dhcp_retry_pidfile)
	[ -f "$pidf" ] || return 0
	pid=$(cat "$pidf" 2>/dev/null || true)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		msg_info "Stopping VLAN DHCP retry pid=$pid"
		kill "$pid" 2>/dev/null || true
		sleep 0.2 2>/dev/null || sleep 1
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$pidf" 2>/dev/null || true
}

# True when primary lease has IPv4 and a dotted router (usable L3 gateway).
nwu_dhcp_retry_primary_ready() {
	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
	lease=$(printf "$LEASE_FILE" "$iface")
	[ -f "$lease" ] || return 1
	ip=$(grep '^ip=' "$lease" 2>/dev/null | cut -d= -f2- | awk '{print $1}')
	[ -n "$ip" ] || return 1
	gw=$(grep '^router=' "$lease" 2>/dev/null | cut -d= -f2- | awk '{print $1}')
	gw=$(nwu_ipv4_sanitize "$gw")
	[ -n "$gw" ] || return 1
	# Must have exclusive default via <gw> on primary — device-only is NOT WAN-ready.
	ip -4 route show default 2>/dev/null | grep "via $gw" | grep -q "dev $iface" && return 0
	return 1
}

nwu_dhcp_retry_should_run() {
	[ "${CONF_VLAN_ENABLED:-false}" = "true" ] || return 1
	[ "$(nwu_vlan_apply_mode)" = "committed" ] || return 1
	[ "${CONF_VLAN_PRIMARY_IPV4_MODE:-}" = "dhcp" ] || return 1
	[ -n "${CONF_VLAN_PRIMARY_ID:-}" ] && [ "$CONF_VLAN_PRIMARY_ID" != "0" ] || return 1
	nwu_dhcp_retry_primary_ready && return 1
	return 0
}

nwu_dhcp_retry_attempt_once() {
	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
	nwu_with_iface "$iface" nwu_link_ensure_up 2>/dev/null || true

	# No address yet (typical while switch port is still untagged): bounce udhcpc
	# so DISCOVER resumes cleanly after the port becomes tagged.
	if ! nwu_with_iface "$iface" nwu_udhcpc_has_ipv4 >/dev/null 2>&1; then
		msg_info "VLAN DHCP retry: no IPv4 on $iface — restart udhcpc (await switch tagged)"
		nwu_with_iface "$iface" nwu_udhcpc_stop 2>/dev/null || true
		export NWU_DHCP_FORCE_RESTART=1
		nwu_with_iface "$iface" nwu_udhcpc_start 2>/dev/null || true
		unset NWU_DHCP_FORCE_RESTART
	elif ! nwu_with_iface "$iface" nwu_udhcpc_find_pid >/dev/null 2>&1; then
		nwu_with_iface "$iface" nwu_udhcpc_start 2>/dev/null || true
	else
		# Have IP but missing router / via — renew to fill lease options.
		nwu_with_iface "$iface" nwu_udhcpc_renew 2>/dev/null || true
	fi

	nwu_with_iface "$iface" nwu_udhcpc_wait_lease 2>/dev/null || true
	nwu_vlan_enforce_primary_default_route 2>/dev/null || true
	if [ -z "${CONF_DNS_SERVERS:-}" ]; then
		nwu_with_iface "$iface" nwu_resolv_from_lease 2>/dev/null || true
	fi
}

# Start background retry if primary DHCP is not yet ready. Safe to call often.
nwu_dhcp_retry_start_if_needed() {
	if nwu_skip_netlink || nwu_is_dry_run; then
		return 0
	fi
	nwu_dhcp_retry_stop
	nwu_dhcp_retry_should_run || return 0

	gen=$(nwu_dhcp_retry_read_gen)
	interval=$(nwu_dhcp_retry_interval)
	pidf=$(nwu_dhcp_retry_pidfile)
	mkdir -p "$(dirname "$pidf")" 2>/dev/null || true

	msg_info "Starting VLAN DHCP retry (interval=${interval}s gen=$gen) — waits across switch untagged→tagged"
	(
		export NWU_ROOT NETWORK_CONF
		# shellcheck source=/dev/null
		. "$NWU_ROOT/lib/common.sh"
		# shellcheck source=/dev/null
		. "$NWU_ROOT/lib/config.sh"
		nwu_load_paths
		nwu_source_libs
		mygen=$gen
		while true; do
			cur=$(nwu_dhcp_retry_read_gen)
			[ "$cur" = "$mygen" ] || exit 0
			nwu_conf_parse "$NETWORK_CONF" 2>/dev/null || exit 0
			nwu_dhcp_retry_should_run || {
				nwu_log "VLAN DHCP retry done (ready or no longer needed)"
				rm -f "$(nwu_dhcp_retry_pidfile)" 2>/dev/null || true
				exit 0
			}
			nwu_dhcp_retry_attempt_once
			if nwu_dhcp_retry_primary_ready; then
				nwu_log "VLAN DHCP retry succeeded with gateway"
				rm -f "$(nwu_dhcp_retry_pidfile)" 2>/dev/null || true
				exit 0
			fi
			sleep "$interval"
		done
	) &
	echo $! >"$pidf"
}
