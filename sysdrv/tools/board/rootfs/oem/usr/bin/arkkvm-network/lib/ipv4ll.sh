# shellcheck shell=sh
# RFC 3927 IPv4 link-local fallback for flat and VLAN DHCP without a server.

NWU_IPV4LL_PREFIX=16

nwu_ipv4ll_is_addr() {
	case "$1" in
	169.254.*) return 0 ;;
	esac
	return 1
}

# Deterministic seed from the interface MAC; falls back to the interface name.
nwu_ipv4ll_seed() {
	iface="${1:-$NET_IF}"
	mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr -d ':' | tr 'A-F' 'a-f')
	[ -n "$mac" ] || mac="$iface"
	seed_src="$mac"
	# VLAN subinterfaces share the parent MAC; include the VLAN iface so each
	# broadcast domain gets its own deterministic candidate.
	case "$iface" in
	*.*) seed_src="${mac}:${iface}" ;;
	esac
	printf '%s' "$seed_src" | cksum | awk '{print $1}'
}

# Map the seed into 169.254.1.1 - 169.254.254.254 (RFC 3927 usable range).
nwu_ipv4ll_candidate() {
	seed="$1"
	n=$((seed % 64516))
	o3=$((n / 254 + 1))
	o4=$((n % 254 + 1))
	echo "169.254.${o3}.${o4}"
}

nwu_ipv4ll_next() {
	ip="$1"
	o3=$(echo "$ip" | cut -d. -f3)
	o4=$(echo "$ip" | cut -d. -f4)
	o4=$((o4 + 1))
	if [ "$o4" -gt 254 ]; then
		o4=1
		o3=$((o3 + 1))
		[ "$o3" -gt 254 ] && o3=1
	fi
	echo "169.254.${o3}.${o4}"
}

# arping -D exits 0 when no duplicate responds, 1 when the address is in use.
# If arping is unavailable, accept the deterministic candidate.
nwu_ipv4ll_probe() {
	ip="$1"
	iface="${2:-$NET_IF}"
	command -v arping >/dev/null 2>&1 || return 0
	arping -D -q -c 2 -w 2 -I "$iface" "$ip" >/dev/null 2>&1
}

nwu_ipv4ll_pick() {
	iface="${1:-$NET_IF}"
	seed=$(nwu_ipv4ll_seed "$iface")
	ip=$(nwu_ipv4ll_candidate "$seed")
	i=0
	while [ "$i" -lt 8 ]; do
		if nwu_ipv4ll_probe "$ip" "$iface"; then
			echo "$ip"
			return 0
		fi
		nwu_log "ipv4ll candidate $ip is in use on $iface"
		ip=$(nwu_ipv4ll_next "$ip")
		i=$((i + 1))
	done
	nwu_log "ipv4ll probes conflicted on $iface; using $ip"
	echo "$ip"
}

nwu_ipv4ll_remove() {
	iface="${1:-$NET_IF}"
	[ -n "$iface" ] || return 0
	if nwu_skip_netlink; then
		msg_info "[dry-run] remove 169.254/16 from $iface"
		return 0
	fi
	for cidr in $(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '$4 ~ /^169\.254\./ {print $4}'); do
		nwu_run ip addr del "$cidr" dev "$iface" 2>/dev/null || true
		nwu_log "ipv4ll removed $cidr from $iface"
	done
}

nwu_ipv4ll_apply() {
	if [ "${CONF_IPV4_MODE:-}" != "dhcp" ]; then
		nwu_ipv4ll_remove
		return 0
	fi
	iface="${NET_IF:-${CONF_IFACE:-}}"
	[ -n "$iface" ] || return 0

	nonll=$(nwu_ipv4_nonll_cidr "$iface")
	if [ -n "$nonll" ]; then
		nwu_ipv4ll_remove "$iface"
		return 0
	fi

	ll=$(nwu_ipv4_linklocal_cidr "$iface")
	[ -n "$ll" ] && return 0

	if nwu_skip_netlink; then
		msg_info "[dry-run] add 169.254/16 link-local on $iface"
		return 0
	fi

	carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)
	if [ "$carrier" != "1" ]; then
		nwu_log "ipv4ll skipped: $iface carrier=${carrier:-unknown}"
		return 0
	fi

	ip=$(nwu_ipv4ll_pick "$iface")
	nwu_run ip addr add "${ip}/${NWU_IPV4LL_PREFIX}" dev "$iface" 2>/dev/null || true
	if [ -n "$(nwu_ipv4_linklocal_cidr "$iface")" ]; then
		nwu_log "ipv4ll applied $ip/$NWU_IPV4LL_PREFIX on $iface (DHCP unavailable)"
		msg_info "IPv4 link-local $ip/16 on $iface (DHCP unavailable)"
	else
		nwu_log "ipv4ll failed to add $ip/$NWU_IPV4LL_PREFIX on $iface"
	fi
}
