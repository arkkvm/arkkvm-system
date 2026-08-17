# shellcheck shell=sh

nwu_ipv4_cidr_from_netmask() {
	mask="$1"
	case "$mask" in
		255.255.255.0) echo 24 ;;
		255.255.255.128) echo 25 ;;
		255.255.255.192) echo 26 ;;
		255.255.255.224) echo 27 ;;
		255.255.255.240) echo 28 ;;
		255.255.255.248) echo 29 ;;
		255.255.255.252) echo 30 ;;
		255.255.0.0) echo 16 ;;
		255.0.0.0) echo 8 ;;
		*/*) echo "${mask#*/}" ;;
		*) echo 24 ;;
	esac
}

# True if $1 looks like a dotted IPv4 address (not an iface name like eth0.6).
nwu_ipv4_is_dotted() {
	case "$1" in
	''|*[!0-9.]*) return 1 ;;
	esac
	echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# Echo $1 only when it is dotted IPv4; otherwise echo nothing.
nwu_ipv4_sanitize() {
	nwu_ipv4_is_dotted "$1" || return 0
	echo "$1"
}

# Parse default gateway for iface from `via <ipv4>` only.
# Device-only routes (`default dev eth0.6`) must not yield the iface name.
nwu_ipv4_default_gateway() {
	iface="$1"
	[ -n "$iface" ] || return 0
	ip -4 route show default dev "$iface" 2>/dev/null | awk '
	{
		for (i = 1; i < NF; i++) {
			if ($i == "via") {
				gw = $(i + 1)
				if (gw ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
					print gw
					exit
				}
			}
		}
	}'
}

nwu_ipv4_apply_static() {
	addr="${CONF_IPV4_ADDR:?missing ipv4.address}"
	mask="${CONF_IPV4_NETMASK:?missing ipv4.netmask}"
	gw="${CONF_IPV4_GATEWAY:-}"
	prefix=$(nwu_ipv4_cidr_from_netmask "$mask")

	msg_step "Static IPv4 ${addr}/${prefix}"
	nwu_dhcp_stop_all
	nwu_link_flush_ipv4
	nwu_run ip addr add "${addr}/${prefix}" dev "$NET_IF"
	if [ -n "$gw" ]; then
		nwu_run ip route replace default via "$gw" dev "$NET_IF" metric 100
	fi
	nwu_log "static ipv4 applied $addr/$prefix"
}

nwu_ipv4_apply_static_no_route() {
	addr="${CONF_IPV4_ADDR:?missing ipv4.address}"
	mask="${CONF_IPV4_NETMASK:?missing ipv4.netmask}"
	prefix=$(nwu_ipv4_cidr_from_netmask "$mask")

	msg_step "Static IPv4 ${addr}/${prefix} (no default route)"
	nwu_udhcpc_stop 2>/dev/null || true
	nwu_link_flush_ipv4
	nwu_run ip addr add "${addr}/${prefix}" dev "$NET_IF"
	nwu_log "static ipv4 (no route) applied $addr/$prefix on $NET_IF"
}

nwu_ipv4_disable() {
	msg_step "Disable IPv4"
	nwu_dhcp_stop_all
	nwu_link_flush_ipv4
	nwu_ipv4_strip_default_route
}

# Remove all IPv4 default routes bound to NET_IF.
nwu_ipv4_strip_default_route() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] ip route del default dev $NET_IF"
		return 0
	fi
	while ip route del default dev "$NET_IF" 2>/dev/null; do
		:
	done
}

# Parent management path: address/DHCP only, no default route (committed VLAN egress via primary).
nwu_ipv4_apply_management() {
	case "$CONF_IPV4_MODE" in
	static)
		if [ -z "$CONF_IPV4_ADDR" ] || [ -z "$CONF_IPV4_NETMASK" ]; then
			die "ipv4.mode=static requires address and netmask"
		fi
		nwu_ipv4_apply_static_no_route
		;;
	dhcp)
		# Keep a running DHCP client for long-term lease renewal on parent management path.
		nwu_ipv4_apply_dhcp
		;;
	disabled) nwu_ipv4_disable ;;
	esac
	nwu_ipv4_strip_default_route
}

# Persist last successfully bound IPv4 for OTA/reboot -r.
nwu_dhcp_last_path() {
	iface="${1:-$NET_IF}"
	dir="${LAST_DHCP_DIR:-/userdata/arkkvm/last_dhcp}"
	echo "$dir/${iface}.prefer"
}

nwu_dhcp_write_last() {
	iface="${1:-$NET_IF}"
	ip="$2"
	src="${3:-udhcpc}"
	ip=$(nwu_ipv4_sanitize "$ip")
	[ -n "$ip" ] || return 1
	path=$(nwu_dhcp_last_path "$iface")
	mkdir -p "$(dirname "$path")" 2>/dev/null || true
	{
		echo "ip=$ip"
		echo "when=$(date +%s 2>/dev/null || echo 0)"
		echo "source=$src"
	} >"$path"
	nwu_log "last_dhcp wrote $path ip=$ip source=$src"
}

nwu_dhcp_read_last() {
	iface="${1:-$NET_IF}"
	path=$(nwu_dhcp_last_path "$iface")
	[ -f "$path" ] || return 1
	prev=$(grep '^ip=' "$path" 2>/dev/null | head -n1 | cut -d= -f2- | awk '{print $1}')
	prev=$(nwu_ipv4_sanitize "$prev")
	[ -n "$prev" ] || return 1
	echo "$prev"
}

# Preferred IPv4 for udhcpc -r (reboot/OTA stability).
# Prints: <source>|<ipv4>  where source is live|last|udhcpc|dhcpcd
# Order: live → last_dhcp sidecar → /run udhcpc info → legacy dhcpcd lease.
nwu_dhcp_preferred_ip() {
	iface="${1:-$NET_IF}"

	# In test/dry-run, skip live iface (host eth0 would poison preferred-IP tests).
	if [ -n "$iface" ] && ! nwu_skip_netlink; then
		prev=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1)
		prev=$(nwu_ipv4_sanitize "$prev")
		if [ -n "$prev" ]; then
			echo "live|$prev"
			return 0
		fi
	fi

	prev=$(nwu_dhcp_read_last "$iface" 2>/dev/null || true)
	if [ -n "$prev" ]; then
		# Keep dhcpcd DHCP identity across cold reboots after OTA migrate.
		path=$(nwu_dhcp_last_path "$iface")
		lsrc=$(grep '^source=' "$path" 2>/dev/null | head -n1 | cut -d= -f2- | awk '{print $1}')
		if [ "$lsrc" = "dhcpcd" ]; then
			echo "dhcpcd|$prev"
		else
			echo "last|$prev"
		fi
		return 0
	fi

	lease=$(printf "$LEASE_FILE" "$iface")
	if [ -f "$lease" ]; then
		prev=$(grep '^ip=' "$lease" 2>/dev/null | head -n1 | cut -d= -f2- | awk '{print $1}')
		prev=$(nwu_ipv4_sanitize "$prev")
		if [ -n "$prev" ]; then
			echo "udhcpc|$prev"
			return 0
		fi
	fi

	db="${DHCPCD_DB:-/userdata/arkkvm/dhcpcd}"
	dlease="$db/${iface}.lease"
	if [ -f "$dlease" ]; then
		prev=$(nwu_dhcpcd_lease_yiaddr "$dlease" 2>/dev/null || true)
		prev=$(nwu_ipv4_sanitize "$prev")
		if [ -n "$prev" ]; then
			echo "dhcpcd|$prev"
			return 0
		fi
	fi
	return 1
}

nwu_ipv4_apply_dhcp() {
	msg_step "IPv4 DHCP (backend: $CONF_DHCP_CLIENT)"
	# Concurrent refresh (OTA migrate + link-up) must not kill a negotiating
	# udhcpc unless caller forces rediscover (VLAN domain change).
	if [ "${NWU_DHCP_FORCE_RESTART:-0}" != "1" ] \
		&& nwu_udhcpc_find_pid >/dev/null 2>&1; then
		if nwu_udhcpc_has_ipv4; then
			msg_warn "udhcpc already running with IPv4; skip restart"
			nwu_log "DHCP skip restart: udhcpc already has IPv4 on $NET_IF"
			return 0
		fi
		msg_warn "udhcpc already negotiating on $NET_IF; skip restart"
		nwu_log "DHCP skip restart: udhcpc negotiating on $NET_IF"
		return 0
	fi
	# Capture preferred IP before flush.
	pref=$(nwu_dhcp_preferred_ip "$NET_IF" || true)
	prev_ip=""
	pref_src=""
	case "$pref" in
	*\|*)
		pref_src="${pref%%|*}"
		prev_ip="${pref#*|}"
		;;
	esac
	nwu_link_flush_ipv4
	nwu_link_ensure_up
	nwu_dhcp_stop_other_backend
	if [ "${NWU_DHCP_FORCE_RESTART:-0}" = "1" ]; then
		nwu_udhcpc_stop 2>/dev/null || true
	fi
	unset NWU_DHCP_OMIT_CLIENTID
	if [ -n "$prev_ip" ] && [ "$CONF_DHCP_CLIENT" = "udhcpc" ]; then
		export NWU_DHCP_REQUEST_IP="$prev_ip"
		nwu_log "DHCP prefer previous IP $prev_ip (source=$pref_src)"
		msg_info "DHCP prefer previous IP $prev_ip (source=$pref_src)"
		if [ "$pref_src" = "dhcpcd" ]; then
			export NWU_DHCP_OMIT_CLIENTID=1
			nwu_log "DHCP migrate from legacy dhcpcd (replay client-id / -C)"
			# Seed last_dhcp so a concurrent refresh can still -r after lease consume delay.
			nwu_dhcp_write_last "$NET_IF" "$prev_ip" "dhcpcd" 2>/dev/null || true
		fi
	fi
	nwu_dhcp_start
	if [ "$CONF_DHCP_CLIENT" = "udhcpc" ]; then
		nwu_udhcpc_wait_lease 2>/dev/null || true
		got=$(ip -4 -o addr show dev "$NET_IF" 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1)
		got=$(nwu_ipv4_sanitize "$got")
		if [ -n "$got" ]; then
			if [ -z "$prev_ip" ] || [ "$got" = "$prev_ip" ]; then
				nwu_dhcp_write_last "$NET_IF" "$got" "${pref_src:-udhcpc}" 2>/dev/null || true
			else
				nwu_log "DHCP got $got != wanted $prev_ip — not updating last_dhcp"
			fi
		fi
		if [ "$pref_src" = "dhcpcd" ]; then
			if [ -n "$got" ] && [ "$got" = "$prev_ip" ]; then
				nwu_log "DHCP got wanted $got — consuming legacy dhcpcd lease"
				nwu_dhcpcd_consume_legacy_lease "$NET_IF"
			elif [ -n "$got" ]; then
				nwu_log "DHCP got $got (wanted $prev_ip) — keeping legacy dhcpcd lease for retry"
			else
				nwu_log "DHCP no IPv4 yet after prefer $prev_ip — keeping legacy dhcpcd lease for retry"
			fi
		fi
	fi
	unset NWU_DHCP_REQUEST_IP
	unset NWU_DHCP_OMIT_CLIENTID
}

nwu_ipv4_apply() {
	case "$CONF_IPV4_MODE" in
	static)
		if [ -z "$CONF_IPV4_ADDR" ] || [ -z "$CONF_IPV4_NETMASK" ]; then
			die "ipv4.mode=static requires address and netmask"
		fi
		nwu_ipv4_apply_static
		;;
	dhcp) nwu_ipv4_apply_dhcp ;;
	disabled) nwu_ipv4_disable ;;
	esac
}
