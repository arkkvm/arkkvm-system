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

# Active + .1 = 2 files. Default cap 10 MiB (NETWORK_LOG_MAX_BYTES).
nwu_log_file_size() {
	_f=$1
	[ -f "$_f" ] || {
		echo 0
		return 0
	}
	stat -c %s "$_f" 2>/dev/null || echo 0
}

nwu_log_rotate_if_needed() {
	_f="${NETWORK_LOG:-/userdata/arkkvm/logs/arkkvm_network.log}"
	_max="${NETWORK_LOG_MAX_BYTES:-10485760}"
	_sz=$(nwu_log_file_size "$_f")
	case "$_sz" in
	'' | *[!0-9]*) return 0 ;;
	esac
	if [ "$_sz" -ge "$_max" ]; then
		rm -f "${_f}.1"
		if ! mv "$_f" "${_f}.1" 2>/dev/null; then
			: >"$_f"
		fi
	fi
}

# Pre-logs path. Clear Logs does not see this file, so startup must retire it.
# Truncate first so a still-open writer releases the blocks, then unlink.
NWU_LEGACY_NETWORK_LOG=/userdata/arkkvm/network.log

nwu_log_retire_legacy() {
	_old="$NWU_LEGACY_NETWORK_LOG"
	[ -f "$_old" ] || return 0
	: >"$_old" 2>/dev/null || true
	rm -f "$_old" 2>/dev/null || true
}

nwu_log_file() {
	_line=$1
	NETWORK_LOG="${NETWORK_LOG:-/userdata/arkkvm/logs/arkkvm_network.log}"
	nwu_log_retire_legacy
	mkdir -p "$(dirname "$NETWORK_LOG")" 2>/dev/null || true
	nwu_log_rotate_if_needed
	if ! echo "$_line" >>"$NETWORK_LOG" 2>/dev/null; then
		echo "$_line" >>/tmp/network-unified.log 2>/dev/null || true
	fi
}

nwu_log() {
	TS=$(date '+%Y-%m-%d %H:%M:%S')
	LINE="$TS $*"
	if nwu_is_dry_run || nwu_skip_netlink; then
		msg_info "$LINE"
		return 0
	fi
	nwu_log_file "$LINE"
}

nwu_source_libs() {
	for f in parse link hostname resolv dhcp-udhcpc dhcp-dhcpcd dhcp ipv4 ipv4ll ipv6 vlan dhcp-retry state; do
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
