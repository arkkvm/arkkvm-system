# shellcheck shell=sh

nwu_ipv6_sysctl() {
	key="$1"
	val="$2"
	path="/proc/sys/net/ipv6/conf/${NET_IF}/$(echo "$key" | tr '.' '/')"
	if nwu_skip_netlink; then
		msg_info "[dry-run] echo $val > $path"
		return 0
	fi
	[ -f "$path" ] && echo "$val" >"$path" 2>/dev/null || true
}

nwu_ipv6_apply_slaac() {
	msg_step "IPv6 SLAAC"
	nwu_ipv6_sysctl disable_ipv6 0
	nwu_ipv6_sysctl accept_ra 2
	nwu_link_flush_ipv6_global
}

nwu_ipv6_apply_link_local() {
	msg_step "IPv6 link-local only"
	nwu_ipv6_sysctl disable_ipv6 0
	nwu_ipv6_sysctl accept_ra 0
	nwu_link_flush_ipv6_global
}

nwu_ipv6_disable() {
	msg_step "Disable IPv6"
	nwu_ipv6_sysctl disable_ipv6 1
	nwu_link_flush_ipv6_global
}

nwu_ipv6_apply_static() {
	prefix="${CONF_IPV6_PREFIX:?missing ipv6.prefix}"
	msg_step "Static IPv6 $prefix"
	nwu_ipv6_sysctl disable_ipv6 0
	nwu_ipv6_sysctl accept_ra 0
	nwu_link_flush_ipv6_global
	nwu_run ip -6 addr add "$prefix" dev "$NET_IF"
	if [ -n "$CONF_IPV6_GATEWAY" ]; then
		nwu_run ip -6 route replace default via "$CONF_IPV6_GATEWAY" dev "$NET_IF" 2>/dev/null || true
	fi
}

nwu_ipv6_strip_default_route() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] ip -6 route del default dev $NET_IF"
		return 0
	fi
	while ip -6 route del default dev "$NET_IF" 2>/dev/null; do
		:
	done
}

# Parent management path IPv6: no default route (committed VLAN egress via primary).
nwu_ipv6_apply_management() {
	nwu_ipv6_apply
	nwu_ipv6_strip_default_route
}

nwu_ipv6_apply() {
	case "$CONF_IPV6_MODE" in
	slaac) nwu_ipv6_apply_slaac ;;
	link_local) nwu_ipv6_apply_link_local ;;
	disabled) nwu_ipv6_disable ;;
	static) nwu_ipv6_apply_static ;;
	esac
}
