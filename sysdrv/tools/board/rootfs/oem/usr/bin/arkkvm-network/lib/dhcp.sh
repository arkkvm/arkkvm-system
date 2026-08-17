# shellcheck shell=sh
# DHCP dispatch layer — call only the backend selected by network.conf [dhcp] client

nwu_dhcp_stop_udhcpc() {
	nwu_udhcpc_stop_all
}

nwu_dhcp_stop_dhcpcd() {
	nwu_dhcpcd_stop
}

nwu_dhcp_stop_all() {
	nwu_udhcpc_stop
	nwu_dhcpcd_stop
}

nwu_dhcp_stop_other_backend() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_dhcpcd_stop ;;
	dhcpcd) nwu_udhcpc_stop ;;
	esac
}

nwu_dhcp_start() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_start ;;
	dhcpcd) nwu_dhcpcd_start ;;
	*) die "Unknown DHCP backend: $CONF_DHCP_CLIENT" ;;
	esac
}

nwu_dhcp_stop() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_stop ;;
	dhcpcd) nwu_dhcpcd_stop ;;
	esac
}

nwu_dhcp_restart() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_restart ;;
	dhcpcd) nwu_dhcpcd_restart ;;
	esac
}

nwu_dhcp_renew() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_renew ;;
	dhcpcd) nwu_dhcpcd_renew ;;
	esac
}

nwu_dhcp_release() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_release ;;
	dhcpcd) nwu_dhcpcd_release ;;
	esac
}

nwu_dhcp_sync_lease() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc)
		nwu_udhcpc_wait_lease
		nwu_udhcpc_lease_valid || nwu_udhcpc_write_lease_from_system || true
		;;
	dhcpcd) nwu_dhcpcd_write_lease_from_system ;;
	esac
}

nwu_dhcp_show_lease() {
	case "$CONF_DHCP_CLIENT" in
	udhcpc) nwu_udhcpc_show_lease ;;
	dhcpcd) nwu_dhcpcd_show_lease ;;
	esac
}

nwu_dhcp_op() {
	# For standalone calls outside refresh: parse conf then operate
	op="$1"
	iface="${2:-}"
	nwu_conf_parse
	if [ -n "$iface" ]; then
		nwu_dhcp_op_iface "$iface" "$op"
		return
	fi
	case "$op" in
	start) nwu_dhcp_start ;;
	stop) nwu_dhcp_stop ;;
	restart) nwu_dhcp_restart ;;
	renew) nwu_dhcp_renew ;;
	release) nwu_dhcp_release ;;
	lease) nwu_dhcp_show_lease ;;
	*) die "Unknown dhcp operation: $op" ;;
	esac
}

nwu_dhcp_op_iface() {
	iface="$1"
	op="$2"
	_nwu_saved_iface=$NET_IF
	NET_IF=$iface
	export NET_IF
	case "$op" in
	start) nwu_dhcp_start ;;
	stop) nwu_dhcp_stop ;;
	restart) nwu_dhcp_restart ;;
	renew) nwu_dhcp_renew ;;
	release) nwu_dhcp_release ;;
	lease) nwu_dhcp_show_lease ;;
	*) die "Unknown dhcp operation: $op" ;;
	esac
	NET_IF=$_nwu_saved_iface
	export NET_IF
}
