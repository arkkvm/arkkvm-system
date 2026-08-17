# shellcheck shell=sh

nwu_link_operstate() {
	if nwu_skip_netlink; then
		echo "UP"
		return 0
	fi
	state=$(cat "/sys/class/net/$NET_IF/operstate" 2>/dev/null)
	[ -n "$state" ] && echo "$state" || echo "UNKNOWN"
}

nwu_link_ensure_up() {
	msg_step "Bring up link $NET_IF"
	nwu_run ip link set "$NET_IF" up 2>/dev/null || nwu_run ifconfig "$NET_IF" up 2>/dev/null || true
}

nwu_link_flush_ipv4() {
	nwu_run ip -4 addr flush dev "$NET_IF" 2>/dev/null || true
	nwu_run ip -4 route del default dev "$NET_IF" 2>/dev/null || true
}

nwu_link_flush_ipv6_global() {
	nwu_run ip -6 addr flush dev "$NET_IF" scope global 2>/dev/null || true
}
