# shellcheck shell=sh

if [ -t 1 ]; then
	_C_RESET='\033[0m'
	_C_INFO='\033[36m'
	_C_OK='\033[32m'
	_C_WARN='\033[33m'
	_C_ERR='\033[31m'
	_C_STEP='\033[35m'
else
	_C_RESET='' _C_INFO='' _C_OK='' _C_WARN='' _C_ERR='' _C_STEP=''
fi

msg_info()  { printf '%b[INFO]%b %s\n' "$_C_INFO" "$_C_RESET" "$*" >&2; }
msg_ok()    { printf '%b[OK]%b %s\n' "$_C_OK" "$_C_RESET" "$*" >&2; }
msg_warn()  { printf '%b[WARN]%b %s\n' "$_C_WARN" "$_C_RESET" "$*" >&2; }
msg_err()   { printf '%b[ERR]%b %s\n' "$_C_ERR" "$_C_RESET" "$*" >&2; }
msg_step()  { printf '%b[STEP]%b %s\n' "$_C_STEP" "$_C_RESET" "$*" >&2; }

die() {
	msg_err "$1"
	exit "${2:-1}"
}

nwu_is_dry_run() {
	[ "${NWU_DRY_RUN:-0}" = "1" ]
}

nwu_skip_netlink() {
	if [ "${NWU_FORCE:-0}" = "1" ]; then
		return 1
	fi
	if [ -n "${NWU_TEST_MODE:-}" ]; then
		return 0
	fi
	if ! ip link show "$NET_IF" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

nwu_run() {
	if nwu_skip_netlink; then
		msg_info "[dry-run] $*"
		return 0
	fi
	"$@"
}

nwu_require_cmd() {
	if nwu_is_dry_run || nwu_skip_netlink; then
		return 0
	fi
	for c in "$@"; do
		if ! command -v "$c" >/dev/null 2>&1; then
			die "Missing command: $c"
		fi
	done
}

nwu_require_root() {
	if nwu_skip_netlink && [ "${NWU_DRY_RUN:-0}" != "1" ]; then
		return 0
	fi
	if nwu_is_dry_run; then
		msg_warn "dry-run mode, skipping root check"
		return 0
	fi
	if [ "$(id -u)" -ne 0 ]; then
		die "Need root: sudo $0 ..."
	fi
}

nwu_lease_path() {
	printf '%s' "$(printf "$LEASE_FILE" "$NET_IF")"
}

nwu_log() {
	TS=$(date '+%Y-%m-%d %H:%M:%S')
	LINE="$TS $*"
	if nwu_is_dry_run || nwu_skip_netlink; then
		msg_info "$LINE"
		return 0
	fi
	mkdir -p "$(dirname "$NETWORK_LOG")" 2>/dev/null || true
	if ! echo "$LINE" >>"$NETWORK_LOG" 2>/dev/null; then
		echo "$LINE" >>/tmp/network-unified.log 2>/dev/null || true
	fi
}

nwu_source_libs() {
	for f in parse link hostname resolv dhcp-udhcpc dhcp-dhcpcd dhcp ipv4 ipv6 vlan dhcp-retry state; do
		# shellcheck source=/dev/null
		. "$NWU_ROOT/lib/${f}.sh"
	done
}

nwu_with_iface() {
	iface="$1"
	shift
	_nwu_saved_iface=$NET_IF
	NET_IF=$iface
	export NET_IF
	"$@"
	_rc=$?
	NET_IF=$_nwu_saved_iface
	export NET_IF
	return $_rc
}
