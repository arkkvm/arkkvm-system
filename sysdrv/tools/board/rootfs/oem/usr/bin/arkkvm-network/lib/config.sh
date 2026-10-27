# shellcheck shell=sh
# Load default.env / local.env

nwu_load_paths() {
	# shellcheck source=/dev/null
	[ -f "$NWU_ROOT/config/default.env" ] && . "$NWU_ROOT/config/default.env"
	# shellcheck source=/dev/null
	[ -f "$NWU_ROOT/config/local.env" ] && . "$NWU_ROOT/config/local.env"

	export NET_IF NETWORK_CONF NETWORK_CONF_PENDING NETWORK_CONF_ROLLBACK
	export NETWORK_CONF_PENDING_MARKER
	export RESOLV_CONF HOSTNAME_FILE HOSTS_FILE
	export NETWORK_LOG LEASE_FILE UDHCPC_SCRIPT DHCPCD_CONF DHCPCD_PIDFILE DHCPCD_DB LAST_DHCP_DIR
	export NWU_REFRESH_LOCK NWU_DHCP_RETRY_PID NWU_DHCP_RETRY_GEN NWU_DHCP_RETRY_INTERVAL
}
