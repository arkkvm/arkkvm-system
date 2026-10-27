#!/bin/sh
# Cap a single redirect log under /userdata/arkkvm/log via truncate.
# Default 50 MiB (arkkvm_app / arkkvm_usb). Callers may set ARKKVM_LOG_MAX_BYTES
# first (arkkvm_ui uses 20 MiB). BusyBox-friendly; safe while a writer still
# holds the FD (unlike rm).
#
# Install path on image:
#   /oem/usr/bin/arkkvm_log_cap.sh
# Sourced from board rootfs:
#   /arkkvm-sys/jack-build-system/sysdrv/tools/board/rootfs/oem/usr/bin/arkkvm_log_cap.sh
# Backup in arkkvm-app/shell/arkkvm_log_cap.sh (keep in sync with rootfs).

ARKKVM_LOG_DIR="${ARKKVM_LOG_DIR:-/userdata/arkkvm/log}"
ARKKVM_LOG_MAX_BYTES="${ARKKVM_LOG_MAX_BYTES:-52428800}" # 50 MiB
ARKKVM_LOG_GUARD_INTERVAL_SEC="${ARKKVM_LOG_GUARD_INTERVAL_SEC:-300}"

arkkvm_log_file_size() {
	_f=$1
	[ -f "$_f" ] || {
		echo 0
		return 0
	}
	# GNU stat first, BSD/macOS fallback (dev hosts)
	stat -c %s "$_f" 2>/dev/null || stat -f %z "$_f" 2>/dev/null || echo 0
}

# Truncate if at or over the cap. Keeps the same inode for open writers.
cap_log_file() {
	_f=$1
	[ -n "$_f" ] || return 0
	mkdir -p "$(dirname "$_f")" 2>/dev/null || true
	[ -f "$_f" ] || return 0
	_sz=$(arkkvm_log_file_size "$_f")
	case "$_sz" in
	'' | *[!0-9]*) return 0 ;;
	esac
	if [ "$_sz" -ge "$ARKKVM_LOG_MAX_BYTES" ]; then
		: >"$_f"
	fi
}

start_log_guard() {
	_f=$1
	_pidfile=$2
	[ -n "$_f" ] && [ -n "$_pidfile" ] || return 1

	stop_log_guard "$_pidfile"

	# Ignore SIGHUP: BusyBox ash may signal background jobs when the init
	# script exits, which previously left stale guard pidfiles and no cap.
	(
		trap '' HUP
		while true; do
			sleep "$ARKKVM_LOG_GUARD_INTERVAL_SEC"
			cap_log_file "$_f"
		done
	) >/dev/null 2>&1 &
	echo $! >"$_pidfile"
}

stop_log_guard() {
	_pidfile=$1
	[ -n "$_pidfile" ] || return 0
	if [ -f "$_pidfile" ]; then
		_pid=$(cat "$_pidfile" 2>/dev/null)
		if [ -n "$_pid" ]; then
			kill "$_pid" 2>/dev/null || true
		fi
		rm -f "$_pidfile"
	fi
}
