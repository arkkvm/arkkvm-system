# shellcheck shell=sh
# Load default.env / local.env; redirect paths in test mode

nwu_load_paths() {
	# shellcheck source=/dev/null
	[ -f "$NWU_ROOT/config/default.env" ] && . "$NWU_ROOT/config/default.env"
	# shellcheck source=/dev/null
	[ -f "$NWU_ROOT/config/local.env" ] && . "$NWU_ROOT/config/local.env"

	if [ -n "${NWU_TEST_MODE:-}" ]; then
		TEST_ROOT="${TEST_ROOT:-$NWU_ROOT/.test-run}"
		mkdir -p "$TEST_ROOT"
		NETWORK_CONF="$TEST_ROOT/network.conf"
		RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
		HOSTNAME_FILE="$TEST_ROOT/etc/hostname"
		HOSTS_FILE="$TEST_ROOT/etc/hosts"
		NETWORK_LOG="$TEST_ROOT/network.log"
		LEASE_FILE="$TEST_ROOT/run/udhcpc.%s.info"
		DHCPCD_PIDFILE="$TEST_ROOT/run/dhcpcd/pid"
		DHCPCD_DB="$TEST_ROOT/userdata/arkkvm/dhcpcd"
		LAST_DHCP_DIR="$TEST_ROOT/userdata/arkkvm/last_dhcp"
		NWU_REFRESH_LOCK="$TEST_ROOT/run/arkkvm-network.refresh.lock"
		NWU_DHCP_RETRY_PID="$TEST_ROOT/run/arkkvm-network.dhcp-retry.pid"
		NWU_DHCP_RETRY_GEN="$TEST_ROOT/run/arkkvm-network.dhcp-retry.gen"
	fi

	export NET_IF NETWORK_CONF NETWORK_CONF_PENDING NETWORK_CONF_ROLLBACK
	export NETWORK_CONF_PENDING_MARKER
	export RESOLV_CONF HOSTNAME_FILE HOSTS_FILE
	export NETWORK_LOG LEASE_FILE UDHCPC_SCRIPT DHCPCD_CONF DHCPCD_PIDFILE DHCPCD_DB LAST_DHCP_DIR
	export NWU_REFRESH_LOCK NWU_DHCP_RETRY_PID NWU_DHCP_RETRY_GEN NWU_DHCP_RETRY_INTERVAL
}
