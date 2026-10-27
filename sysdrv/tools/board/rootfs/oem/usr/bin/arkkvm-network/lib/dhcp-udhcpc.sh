# shellcheck shell=sh
# udhcpc backend — all udhcpc operations live only in this file

nwu_udhcpc_hook() {
	echo "$NWU_ROOT/scripts/udhcpc-hook.sh"
}

nwu_udhcpc_find_pid() {
	for p in $(pidof udhcpc 2>/dev/null); do
		[ -n "$p" ] || continue
		cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
		case " $cmd " in
		*" -i $NET_IF "*) echo "$p"; return 0 ;;
		*" -i $NET_IF"*) echo "$p"; return 0 ;;
		*" -i$NET_IF "*) echo "$p"; return 0 ;;
		*" -i$NET_IF"*) echo "$p"; return 0 ;;
		esac
	done
	return 1
}

nwu_udhcpc_stop() {
	msg_step "Stop udhcpc ($NET_IF)"
	if nwu_skip_netlink; then
		msg_info "[dry-run] kill udhcpc ($NET_IF)"
		return 0
	fi
	pid=$(nwu_udhcpc_find_pid) || true
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		sleep 1
		kill -9 "$pid" 2>/dev/null || true
	fi
	nwu_log "udhcpc stopped on $NET_IF"
}

nwu_udhcpc_stop_all() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] killall udhcpc"
		return 0
	fi
	killall udhcpc 2>/dev/null || true
	nwu_log "udhcpc stopped (all)"
}

nwu_udhcpc_has_ipv4() {
	[ -n "$(nwu_ipv4_nonll_cidr "$NET_IF")" ]
}

nwu_udhcpc_start() {
	msg_step "Start udhcpc ($NET_IF)"
	if nwu_skip_netlink; then
		msg_info "[dry-run] udhcpc -i $NET_IF -s $(nwu_udhcpc_hook)"
		return 0
	fi

	if nwu_udhcpc_find_pid >/dev/null 2>&1; then
		if nwu_udhcpc_has_ipv4; then
			msg_warn "udhcpc already running"
			return 0
		fi
		msg_warn "udhcpc running but no IPv4, restarting"
		nwu_udhcpc_stop
	fi

	hook=$(nwu_udhcpc_hook)
	chmod +x "$hook" 2>/dev/null || true
	# Hook must receive a concrete lease path — never the printf format with %s.
	lease_path=$(nwu_lease_path)
	export NWU_ROOT NET_IF RESOLV_CONF
	export LEASE_FILE="$lease_path"

	MAC_HEX=$(cat "/sys/class/net/$NET_IF/address" 2>/dev/null | tr -d ':')
	req_ip_args=""
	if [ -n "${NWU_DHCP_REQUEST_IP:-}" ]; then
		req_ip_args="-r $NWU_DHCP_REQUEST_IP"
		msg_info "udhcpc request previous IP $NWU_DHCP_REQUEST_IP"
	fi
	# OTA from dhcpcd: replay dhcpcd RFC4361 ClientID (DUID+IAID). Plain omit of
	# -x is NOT enough — busybox still sends MAC as option 61 unless -C is set.
	clientid_args=""
	if [ "${NWU_DHCP_OMIT_CLIENTID:-0}" = "1" ]; then
		cid=$(nwu_dhcpcd_rfc4361_clientid_hex "$NET_IF" 2>/dev/null || true)
		if [ -n "$cid" ]; then
			clientid_args="-C -x 0x3d:$cid"
			msg_info "udhcpc migrate with dhcpcd client-id"
			nwu_log "DHCP migrate client-id=$cid"
		else
			clientid_args="-C"
			msg_info "udhcpc migrate with -C (no option 61; chaddr only)"
			nwu_log "DHCP migrate omit client-id (-C); no dhcpcd DUID/IAID"
		fi
	elif [ -n "$MAC_HEX" ]; then
		clientid_args="-x 0x3d:01$MAC_HEX"
	fi
	# shellcheck disable=SC2086
	udhcpc -i "$NET_IF" -s "$hook" -b $clientid_args $req_ip_args 2>/dev/null || true
	nwu_log "udhcpc started on $NET_IF lease=$lease_path"
}

nwu_udhcpc_start_staging() {
	msg_step "staging udhcpc ($NET_IF)"
	if nwu_skip_netlink; then
		msg_info "[dry-run] udhcpc staging -i $NET_IF"
		return 0
	fi
	nwu_udhcpc_stop
	nwu_link_flush_ipv4
	script="$NWU_ROOT/scripts/udhcpc-staging.script"
	chmod +x "$script" 2>/dev/null || true
	udhcpc -i "$NET_IF" -n -q -t 10 -T 3 -s "$script" 2>/dev/null || true
	nwu_udhcpc_write_lease_from_system 2>/dev/null || true
	nwu_log "udhcpc staging finished on $NET_IF"
}

nwu_udhcpc_renew() {
	msg_step "udhcpc renew (SIGUSR1)"
	if nwu_skip_netlink; then
		msg_info "[dry-run] udhcpc renew"
		return 0
	fi
	pid=$(nwu_udhcpc_find_pid) || true
	if [ -z "$pid" ]; then
		msg_warn "udhcpc not running on $NET_IF; starting then renewing"
		nwu_udhcpc_start
		pid=$(nwu_udhcpc_find_pid) || die "udhcpc failed to start"
	fi
	kill -USR1 "$pid"
	nwu_log "udhcpc renew signal sent"
}

nwu_udhcpc_release() {
	msg_step "udhcpc release (SIGUSR2)"
	if nwu_skip_netlink; then
		msg_info "[dry-run] udhcpc release"
		return 0
	fi
	pid=$(nwu_udhcpc_find_pid) || die "udhcpc not running"
	kill -USR2 "$pid"
	nwu_log "udhcpc release signal sent"
}

nwu_udhcpc_restart() {
	nwu_udhcpc_stop
	sleep 1
	nwu_udhcpc_start
}

nwu_udhcpc_show_lease() {
	lease=$(nwu_lease_path)
	if [ -f "$lease" ]; then
		cat "$lease"
	else
		msg_warn "Lease file not found: $lease"
		return 1
	fi
}

nwu_udhcpc_lease_valid() {
	lease=$(nwu_lease_path)
	[ -f "$lease" ] || return 1
	grep -q '^backend=udhcpc' "$lease" 2>/dev/null || return 1
	ip=$(grep '^ip=' "$lease" | cut -d= -f2-)
	[ -n "$ip" ]
}

nwu_udhcpc_write_lease_from_system() {
	if nwu_skip_netlink; then
		return 0
	fi
	ip=$(nwu_ipv4_nonll_cidr "$NET_IF")
	[ -n "$ip" ] || return 1
	addr=${ip%/*}
	mask=${ip#*/}
	router=$(nwu_ipv4_default_gateway "$NET_IF")
	router=$(nwu_ipv4_sanitize "$router")
	dns=$(grep '^nameserver ' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
	domain=$(grep '^search ' "$RESOLV_CONF" 2>/dev/null | awk '{print $2; exit}')
	[ -n "$domain" ] || domain=$(grep '^domain ' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}')
	[ -n "$domain" ] || domain="$CONF_DOMAIN"
	hostname="${CONF_HOSTNAME:-$(cat /etc/hostname 2>/dev/null | tr -d '\n')}"
	lease=$(nwu_lease_path)
	# Preserve DHCP-provided router/serverid/siaddr from an existing hook lease when
	# the kernel only has a device-only default (no via) — do not blank UI fields.
	if [ -f "$lease" ]; then
		old_router=$(grep '^router=' "$lease" 2>/dev/null | cut -d= -f2- | awk '{print $1}')
		old_router=$(nwu_ipv4_sanitize "$old_router")
		old_serverid=$(nwu_ipv4_sanitize "$(grep '^serverid=' "$lease" 2>/dev/null | cut -d= -f2- | awk '{print $1}')")
		old_siaddr=$(nwu_ipv4_sanitize "$(grep '^siaddr=' "$lease" 2>/dev/null | cut -d= -f2- | awk '{print $1}')")
		old_dns=$(grep '^dns=' "$lease" 2>/dev/null | cut -d= -f2-)
		old_domain=$(grep '^domain=' "$lease" 2>/dev/null | cut -d= -f2-)
		old_hostname=$(grep '^hostname=' "$lease" 2>/dev/null | cut -d= -f2-)
		[ -n "$router" ] || router=$old_router
		[ -n "$dns" ] || dns=$old_dns
		[ -n "$domain" ] || domain=$old_domain
		[ -n "$hostname" ] || hostname=$old_hostname
		serverid=$old_serverid
		siaddr=$old_siaddr
	fi
	[ -n "$serverid" ] || serverid=$router
	[ -n "$siaddr" ] || siaddr=$router
	mkdir -p "$(dirname "$lease")"
	cat >"$lease" <<EOF
# generated by network-config-unified (lease sync)
ip=$addr
subnet=$mask
router=$router
dns=$dns
domain=$domain
hostname=$hostname
serverid=$serverid
siaddr=$siaddr
backend=udhcpc
EOF
}

nwu_udhcpc_wait_lease() {
	if nwu_skip_netlink || nwu_is_dry_run; then
		return 0
	fi
	# A link-local fallback is already usable; do not block on DHCP.
	[ -n "$(nwu_ipv4_linklocal_cidr "$NET_IF")" ] && return 0
	i=0
	while [ "$i" -lt 15 ]; do
		nwu_udhcpc_lease_valid && return 0
		if nwu_udhcpc_has_ipv4; then
			nwu_udhcpc_write_lease_from_system && nwu_udhcpc_lease_valid && return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	nwu_udhcpc_write_lease_from_system || true
}
