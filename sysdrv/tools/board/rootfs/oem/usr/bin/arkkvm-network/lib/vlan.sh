# shellcheck shell=sh
# VLAN subinterface lifecycle, staging/committed route and DNS semantics

nwu_vlan_apply_mode() {
	if [ -n "${NWU_APPLY_MODE:-}" ]; then
		echo "$NWU_APPLY_MODE"
		return 0
	fi
	echo "${CONF_VLAN_APPLY_MODE:-committed}"
}

nwu_vlan_iface_name() {
	parent="${1:-$CONF_VLAN_PARENT}"
	id="$2"
	printf '%s.%s' "$parent" "$id"
}

nwu_vlan_is_enabled() {
	[ "$CONF_VLAN_ENABLED" = "true" ]
}

nwu_vlan_cleanup_pending() {
	pending="${NETWORK_CONF_PENDING:-/userdata/arkkvm/network.conf.pending}"
	rollback="${NETWORK_CONF_ROLLBACK:-/userdata/arkkvm/network.conf.rollback}"
	marker="${NETWORK_CONF_PENDING_MARKER:-/userdata/arkkvm/network.conf.pending-active}"
	if [ -f "$pending" ] || [ -f "$rollback" ] || [ -f "$marker" ]; then
		nwu_log "cleanup vlan pending files"
		rm -f "$pending" "$rollback" "$marker"
	fi
}

# True when kernel VLAN stack is present (loaded by board ko init, e.g. S20/RkLunch).
nwu_vlan_modules_ready() {
	[ -d /sys/module/8021q ] || grep -q '^8021q ' /proc/modules 2>/dev/null
}

# Wait for VLAN modules — do NOT load them here (insmod_ko.sh / platform owns that).
nwu_vlan_ensure_module() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] wait for VLAN modules (8021q)"
		return 0
	fi
	if nwu_vlan_modules_ready; then
		return 0
	fi

	wait_sec="${NWU_VLAN_MODULE_WAIT_SEC:-120}"
	msg_step "Waiting for VLAN modules (8021q); check every 1s, timeout=${wait_sec}s"
	nwu_log "waiting for VLAN modules (8021q), timeout=${wait_sec}s"
	elapsed=0
	while [ "$elapsed" -lt "$wait_sec" ]; do
		sleep 1
		elapsed=$((elapsed + 1))
		if nwu_vlan_modules_ready; then
			msg_ok "VLAN modules ready after ${elapsed}s"
			nwu_log "VLAN modules ready after ${elapsed}s"
			return 0
		fi
		# Progress every 5s to avoid log spam
		if [ $((elapsed % 5)) -eq 0 ]; then
			msg_info "still waiting for VLAN modules... ${elapsed}s"
		fi
	done
	die "VLAN modules (8021q) not ready after ${elapsed}s (network framework does not load them)"
}

nwu_vlan_list_ifaces() {
	parent="${1:-$CONF_VLAN_PARENT}"
	if nwu_skip_netlink; then
		return 0
	fi
	ip -o link show 2>/dev/null | awk -v p="$parent" '
		$2 ~ "^" p "\\." {
			name = $2
			sub(/:$/, "", name)
			sub(/@.*/, "", name)
			print name
		}'
}

nwu_vlan_link_exists() {
	iface="$1"
	if nwu_skip_netlink; then
		return 0
	fi
	ip link show "$iface" >/dev/null 2>&1
}

nwu_vlan_delete_iface() {
	iface="$1"
	if nwu_skip_netlink; then
		msg_info "[dry-run] ip link delete $iface"
		return 0
	fi
	nwu_with_iface "$iface" nwu_udhcpc_stop 2>/dev/null || true
	nwu_run ip link delete "$iface" 2>/dev/null || true
}

nwu_vlan_delete_all() {
	parent="${1:-$CONF_VLAN_PARENT}"
	for iface in $(nwu_vlan_list_ifaces "$parent"); do
		nwu_vlan_delete_iface "$iface"
	done
}

nwu_vlan_create_link() {
	parent="$1"
	id="$2"
	iface=$(nwu_vlan_iface_name "$parent" "$id")
	if nwu_skip_netlink; then
		msg_info "[dry-run] ip link add link $parent name $iface type vlan id $id"
		return 0
	fi
	if nwu_vlan_link_exists "$iface"; then
		return 0
	fi
	nwu_vlan_ensure_module
	if ! nwu_run ip link add link "$parent" name "$iface" type vlan id "$id"; then
		die "failed to create VLAN link $iface (id=$id) on $parent"
	fi
}

nwu_vlan_sync_interfaces() {
	parent="$CONF_VLAN_PARENT"
	keep=""
	if [ -n "$CONF_VLAN_PRIMARY_ID" ] && [ "$CONF_VLAN_PRIMARY_ID" != "0" ]; then
		keep="$keep $CONF_VLAN_PRIMARY_ID"
		nwu_vlan_create_link "$parent" "$CONF_VLAN_PRIMARY_ID"
	fi
	if [ -n "$CONF_VLAN_SECONDARY_ID" ] && [ "$CONF_VLAN_SECONDARY_ID" != "0" ]; then
		keep="$keep $CONF_VLAN_SECONDARY_ID"
		nwu_vlan_create_link "$parent" "$CONF_VLAN_SECONDARY_ID"
	fi
	for iface in $(nwu_vlan_list_ifaces "$parent"); do
		vid=${iface#"$parent."}
		case " $keep " in
		*" $vid "*) ;;
		*) nwu_vlan_delete_iface "$iface" ;;
		esac
	done
}

nwu_vlan_capture_parent() {
	parent="$CONF_VLAN_PARENT"
	VLAN_PARENT_SNAPSHOT_FILE="/tmp/nwu-vlan-parent.snap.$$"
	: >"$VLAN_PARENT_SNAPSHOT_FILE"
	if nwu_skip_netlink; then
		return 0
	fi
	ip -4 -o addr show dev "$parent" 2>/dev/null | awk '{print $4}' >>"$VLAN_PARENT_SNAPSHOT_FILE"
	ip route show default dev "$parent" 2>/dev/null | head -n1 >>"${VLAN_PARENT_SNAPSHOT_FILE}.route"
	if [ -f "$RESOLV_CONF" ]; then
		cp "$RESOLV_CONF" "${VLAN_PARENT_SNAPSHOT_FILE}.resolv" 2>/dev/null || true
	fi
}

nwu_vlan_restore_parent() {
	parent="$CONF_VLAN_PARENT"
	snap="${VLAN_PARENT_SNAPSHOT_FILE:-}"
	if [ -z "$snap" ] || nwu_skip_netlink; then
		return 0
	fi
	while read -r cidr; do
		[ -n "$cidr" ] || continue
		ip -4 -o addr show dev "$parent" 2>/dev/null | grep -q "$cidr" || \
			nwu_run ip addr add "$cidr" dev "$parent" 2>/dev/null || true
	done <"$snap" 2>/dev/null || true
	if [ -f "${snap}.route" ]; then
		route_line=$(head -n1 "${snap}.route")
		if [ -n "$route_line" ]; then
			set -- $route_line
			if [ "$1" = "default" ]; then
				nwu_run ip route replace default "$2" "$3" "$4" "$5" "$6" "$7" 2>/dev/null || true
			fi
		fi
	fi
	if [ -f "${snap}.resolv" ]; then
		cp "${snap}.resolv" "$RESOLV_CONF" 2>/dev/null || true
	fi
	rm -f "$snap" "${snap}.route" "${snap}.resolv" 2>/dev/null || true
}

nwu_vlan_strip_default_routes() {
	parent="$CONF_VLAN_PARENT"
	if nwu_skip_netlink; then
		msg_info "[dry-run] strip VLAN default routes on $parent.*"
		return 0
	fi
	for iface in $(nwu_vlan_list_ifaces "$parent"); do
		while ip route del default dev "$iface" 2>/dev/null; do
			:
		done
	done
}

# Strip every IPv4 default route (committed VLAN: reinstall only on primary).
nwu_vlan_strip_all_default_routes() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] strip all default routes"
		return 0
	fi
	while ip route del default 2>/dev/null; do
		:
	done
}

nwu_vlan_primary_gateway() {
	nwu_vlan_endpoint_vars primary
	gw=""
	case "$VLAN_EP_IPV4_MODE" in
	static) gw="$VLAN_EP_IPV4_GATEWAY" ;;
	dhcp)
		iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$VLAN_EP_ID")
		lease_path=$(printf "$LEASE_FILE" "$iface")
		if [ -f "$lease_path" ]; then
			gw=$(grep '^router=' "$lease_path" | cut -d= -f2- | awk '{print $1}')
			gw=$(nwu_ipv4_sanitize "$gw")
		fi
		;;
	esac
	echo "$gw"
}

# Committed: sole IPv4 default on primary VLAN (metric 0). No gateway → device-only.
# Do not install a long-lived blackhole; DHCP retry will keep trying for a real via.
nwu_vlan_install_primary_default_route() {
	[ -n "$CONF_VLAN_PRIMARY_ID" ] && [ "$CONF_VLAN_PRIMARY_ID" != "0" ] || return 0

	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
	gw=$(nwu_vlan_primary_gateway)
	metric="${CONF_VLAN_PRIMARY_ROUTE_METRIC:-0}"

	msg_step "primary default route dev=$iface gw=${gw:-<none>} metric=$metric"
	if [ -n "$gw" ]; then
		nwu_run ip route replace default via "$gw" dev "$iface" metric "$metric" && return 0
	fi
	nwu_run ip route replace default dev "$iface" metric "$metric" 2>/dev/null || true
}

nwu_vlan_enforce_primary_default_route() {
	nwu_vlan_strip_all_default_routes
	nwu_vlan_install_primary_default_route
}

nwu_vlan_endpoint_vars() {
	role="$1"
	case "$role" in
	primary)
		VLAN_EP_ID=$CONF_VLAN_PRIMARY_ID
		VLAN_EP_IPV4_MODE=$CONF_VLAN_PRIMARY_IPV4_MODE
		VLAN_EP_IPV4_ADDR=$CONF_VLAN_PRIMARY_IPV4_ADDR
		VLAN_EP_IPV4_NETMASK=$CONF_VLAN_PRIMARY_IPV4_NETMASK
		VLAN_EP_IPV4_GATEWAY=$CONF_VLAN_PRIMARY_IPV4_GATEWAY
		VLAN_EP_IPV4_DNS=$CONF_VLAN_PRIMARY_IPV4_DNS
		VLAN_EP_IPV6_MODE=$CONF_VLAN_PRIMARY_IPV6_MODE
		VLAN_EP_ROUTE_METRIC=$CONF_VLAN_PRIMARY_ROUTE_METRIC
		;;
	secondary)
		VLAN_EP_ID=$CONF_VLAN_SECONDARY_ID
		VLAN_EP_IPV4_MODE=$CONF_VLAN_SECONDARY_IPV4_MODE
		VLAN_EP_IPV4_ADDR=$CONF_VLAN_SECONDARY_IPV4_ADDR
		VLAN_EP_IPV4_NETMASK=$CONF_VLAN_SECONDARY_IPV4_NETMASK
		VLAN_EP_IPV4_GATEWAY=$CONF_VLAN_SECONDARY_IPV4_GATEWAY
		VLAN_EP_IPV4_DNS=$CONF_VLAN_SECONDARY_IPV4_DNS
		VLAN_EP_IPV6_MODE=$CONF_VLAN_SECONDARY_IPV6_MODE
		VLAN_EP_ROUTE_METRIC=$CONF_VLAN_SECONDARY_ROUTE_METRIC
		;;
	*) die "Unknown VLAN endpoint: $role" ;;
	esac
}

nwu_vlan_apply_endpoint_ipv4() {
	role="$1"
	is_primary="$2"
	mode="$3"
	nwu_vlan_endpoint_vars "$role"
	[ -n "$VLAN_EP_ID" ] && [ "$VLAN_EP_ID" != "0" ] || return 0

	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$VLAN_EP_ID")
	msg_step "VLAN $role ($iface) ipv4=$VLAN_EP_IPV4_MODE mode=$mode"

	nwu_with_iface "$iface" nwu_run ip link set "$iface" up 2>/dev/null || true
	# Ensure VLAN subiface is administratively up after create (some stacks need a bounce).
	if [ "$mode" = "committed" ] && [ "$VLAN_EP_IPV4_MODE" = "dhcp" ] && ! nwu_skip_netlink && ! nwu_is_dry_run; then
		if ! ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
			ip link set "$iface" down 2>/dev/null || true
			ip link set "$iface" up 2>/dev/null || true
		fi
	fi

	_save_mode=$CONF_IPV4_MODE
	_save_addr=$CONF_IPV4_ADDR
	_save_mask=$CONF_IPV4_NETMASK
	_save_gw=$CONF_IPV4_GATEWAY
	_save_dns=$CONF_IPV4_DNS

	CONF_IPV4_MODE=$VLAN_EP_IPV4_MODE
	CONF_IPV4_ADDR=$VLAN_EP_IPV4_ADDR
	CONF_IPV4_NETMASK=$VLAN_EP_IPV4_NETMASK
	CONF_IPV4_GATEWAY=$VLAN_EP_IPV4_GATEWAY
	CONF_IPV4_DNS=$VLAN_EP_IPV4_DNS

	case "$VLAN_EP_IPV4_MODE" in
	static)
		nwu_with_iface "$iface" nwu_ipv4_apply_static_no_route
		;;
	dhcp)
		if [ "$mode" = "staging" ]; then
			nwu_with_iface "$iface" nwu_udhcpc_start_staging
		else
			export NWU_DHCP_FORCE_RESTART=1
			nwu_with_iface "$iface" nwu_ipv4_apply_dhcp || true
			unset NWU_DHCP_FORCE_RESTART
			nwu_with_iface "$iface" nwu_udhcpc_wait_lease 2>/dev/null || true
		fi
		;;
	disabled)
		nwu_with_iface "$iface" nwu_ipv4_disable
		;;
	esac

	if [ "$mode" = "staging" ]; then
		nwu_vlan_strip_default_routes
	fi

	CONF_IPV4_MODE=$_save_mode
	CONF_IPV4_ADDR=$_save_addr
	CONF_IPV4_NETMASK=$_save_mask
	CONF_IPV4_GATEWAY=$_save_gw
	CONF_IPV4_DNS=$_save_dns
}

# Legacy helper — after primary DHCP lease change, re-apply exclusive default route.
nwu_vlan_apply_primary_routes_from_lease() {
	_iface="$1"
	_metric="${2:-0}"
	if [ "$(nwu_vlan_apply_mode)" = "committed" ] && nwu_vlan_is_enabled; then
		nwu_vlan_enforce_primary_default_route
	fi
}

nwu_vlan_disable_parent_l3() {
	# When VLAN is enabled, untagged parent must not communicate (no L3).
	# Keep link up so VLAN subinterfaces continue to work.
	parent="$CONF_VLAN_PARENT"
	old=$NET_IF
	NET_IF=$parent
	export NET_IF
	msg_step "Disable parent L3 on $parent (VLAN owns all traffic)"
	nwu_udhcpc_stop 2>/dev/null || true
	nwu_link_flush_ipv4
	nwu_link_flush_ipv6_global
	nwu_ipv4_strip_default_route
	nwu_ipv6_strip_default_route
	NET_IF=$old
	export NET_IF
}

nwu_vlan_apply_parent_management() {
	# Legacy: kept for callers; prefer nwu_vlan_disable_parent_l3 for committed VLAN.
	nwu_vlan_disable_parent_l3
}

nwu_vlan_sync_leases() {
	parent="$CONF_VLAN_PARENT"
	for iface in $(nwu_vlan_list_ifaces "$parent"); do
		nwu_with_iface "$iface" nwu_dhcp_sync_lease 2>/dev/null || true
	done
}

# Best-effort short wait for primary via before secondary (does NOT block forever).
# Long-lived recovery is nwu_dhcp_retry_* (no wall-clock timeout).
nwu_vlan_wait_primary_gateway_ready() {
	[ -n "$CONF_VLAN_PRIMARY_ID" ] && [ "$CONF_VLAN_PRIMARY_ID" != "0" ] || return 0
	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
	leasen=$(printf "$LEASE_FILE" "$iface")
	msg_step "wait primary gateway on $iface before secondary"
	i=0
	while [ "$i" -lt 5 ]; do
		gw=""
		if [ -f "$leasen" ]; then
			gw=$(grep '^router=' "$leasen" 2>/dev/null | cut -d= -f2- | awk '{print $1}')
			gw=$(nwu_ipv4_sanitize "$gw")
		fi
		if [ -n "$gw" ]; then
			nwu_vlan_enforce_primary_default_route 2>/dev/null || true
			if ip -4 route show default 2>/dev/null | grep "via $gw" | grep -q "dev $iface"; then
				msg_info "primary gateway ready: via $gw dev $iface"
				return 0
			fi
		fi
		nwu_with_iface "$iface" nwu_udhcpc_wait_lease 2>/dev/null || true
		sleep 1
		i=$((i + 1))
	done
	msg_warn "primary gateway not ready after wait — continuing (dhcp-retry will follow)"
	return 0
}


nwu_vlan_apply() {
	mode=$(nwu_vlan_apply_mode)
	msg_info "VLAN apply mode=$mode"

	nwu_vlan_ensure_module
	nwu_vlan_sync_interfaces

	if [ "$mode" = "staging" ]; then
		nwu_vlan_capture_parent
		nwu_vlan_strip_default_routes
	fi

	nwu_with_iface "$CONF_VLAN_PARENT" nwu_link_ensure_up

	nwu_vlan_apply_endpoint_ipv4 primary 1 "$mode"
	# Dual DHCP: finish primary lease+gateway first so secondary cannot race the
	# exclusive primary default route into a device-only blackhole.
	if [ "$mode" = "committed" ] && [ "$CONF_VLAN_PRIMARY_IPV4_MODE" = "dhcp" ]; then
		nwu_vlan_wait_primary_gateway_ready
	fi
	if [ -n "$CONF_VLAN_SECONDARY_ID" ] && [ "$CONF_VLAN_SECONDARY_ID" != "0" ]; then
		nwu_vlan_apply_endpoint_ipv4 secondary 0 "$mode"
	fi

	if [ "$mode" = "staging" ]; then
		nwu_vlan_strip_default_routes
	fi

	# Untagged parent: no L3 while VLAN is enabled (only link up for subinterfaces).
	nwu_vlan_disable_parent_l3

	if [ "$mode" = "staging" ]; then
		nwu_vlan_strip_default_routes
	fi

	if [ "$mode" = "committed" ]; then
		nwu_vlan_enforce_primary_default_route
		if [ -z "$CONF_DNS_SERVERS" ]; then
			case "$CONF_VLAN_PRIMARY_IPV4_MODE" in
			dhcp)
				iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
				nwu_with_iface "$iface" nwu_resolv_from_lease 2>/dev/null || \
					nwu_resolv_apply 2>/dev/null || true
				;;
			static)
				[ -n "$CONF_VLAN_PRIMARY_IPV4_DNS" ] && \
					nwu_resolv_write "$CONF_DOMAIN" $CONF_VLAN_PRIMARY_IPV4_DNS
				;;
			*)
				nwu_resolv_apply 2>/dev/null || true
				;;
			esac
		else
			nwu_resolv_apply
		fi
		nwu_vlan_sync_leases
		# sync_leases may rewrite from kernel; re-install exclusive primary via.
		nwu_vlan_enforce_primary_default_route
		# Keep trying DHCP/gateway until ready or conf/reset bumps generation.
		nwu_dhcp_retry_start_if_needed 2>/dev/null || true
	fi
}

nwu_vlan_apply_disabled() {
	nwu_dhcp_retry_stop 2>/dev/null || true
	nwu_vlan_delete_all "$CONF_VLAN_PARENT"
	# Remove any stray lease format-path artifact from older hooks.
	rm -f /run/udhcpc.%s.info 2>/dev/null || true
}

# Serial / rescue: set vlan.enabled=false in network.conf and refresh (restores eth0).
nwu_vlan_disable_in_conf() {
	conf="${1:-$NETWORK_CONF}"
	[ -f "$conf" ] || die "missing $conf"
	tmp="${conf}.tmp.$$"
	awk '
		BEGIN { in_vlan=0 }
		/^\[vlan\]/ { in_vlan=1; print; next }
		/^\[/ { in_vlan=0 }
		in_vlan && /^enabled=/ { print "enabled=false"; next }
		{ print }
	' "$conf" >"$tmp" || die "failed to rewrite $conf"
	mv "$tmp" "$conf"
	msg_ok "Set vlan.enabled=false in $conf"
}

nwu_vlan_status_endpoint() {
	role="$1"
	nwu_vlan_endpoint_vars "$role"
	[ -n "$VLAN_EP_ID" ] && [ "$VLAN_EP_ID" != "0" ] || return 0
	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$VLAN_EP_ID")
	ipv4=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1)
	lease=$(printf "$LEASE_FILE" "$iface")
	def_rt=$(ip route show default dev "$iface" 2>/dev/null | head -n1)
	link_state=$(ip link show "$iface" 2>/dev/null | head -n1)
	[ -n "$link_state" ] || link_state="<interface missing>"
	echo "  [$role] iface=$iface id=$VLAN_EP_ID mode=$VLAN_EP_IPV4_MODE ipv4=${ipv4:-<none>}"
	echo "         link=$link_state"
	echo "         lease=${lease}$( [ -f "$lease" ] && echo ' (present)' || echo ' (none)' )"
	echo "         default_route=${def_rt:-<none>}"
}

nwu_vlan_status() {
	mode=$(nwu_vlan_apply_mode)
	echo "======== VLAN status ========"
	echo "enabled:    ${CONF_VLAN_ENABLED:-false}"
	echo "parent:     ${CONF_VLAN_PARENT:-$CONF_IFACE}"
	echo "apply_mode: $mode"
	if [ "$CONF_VLAN_ENABLED" = "true" ]; then
		nwu_vlan_status_endpoint primary
		nwu_vlan_status_endpoint secondary
	else
		echo "  (VLAN disabled)"
	fi
	echo "=========================="
}
