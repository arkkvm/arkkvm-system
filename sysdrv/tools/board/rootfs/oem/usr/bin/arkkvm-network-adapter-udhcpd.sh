#!/bin/sh
# USB network adapter DHCP server control for ArkKVM.
# Board L3 on the USB net iface is owned by usb_devices; this script only runs udhcpd.
# Does not touch eth*, does not ip addr/route, does not enable forwarding.
#
# Usage: arkkvm-network-adapter-udhcpd {start|stop|restart|status}
# Env (injected by usb_devices; defaults for local testing):
#   IFACE            USB net ifname (required for start; eth* rejected)
#   SERVER_IP        board address (conf/log only; default 172.16.0.1)
#   NETMASK          default 255.255.255.0
#   START / END      lease pool (default .100 / .200)
#   LEASE_TIME       default 86400
#   LEASE_FILE       default /var/lib/misc/arkkvm-network-adapter-udhcpd.leases
#   PIDFILE          udhcpd pidfile (default /run/arkkvm-network-adapter-udhcpd.pid)
#   LAUNCH_PIDFILE   launcher pid (default /run/arkkvm-network-adapter-udhcpd-launcher.pid)
#   RUNTIME_CONFIG   default /run/arkkvm-network-adapter-udhcpd.conf

SERVER_IP="${SERVER_IP:-172.16.0.1}"
NETMASK="${NETMASK:-255.255.255.0}"
START="${START:-172.16.0.100}"
END="${END:-172.16.0.200}"
LEASE_TIME="${LEASE_TIME:-86400}"
LEASE_FILE="${LEASE_FILE:-/var/lib/misc/arkkvm-network-adapter-udhcpd.leases}"
PIDFILE="${PIDFILE:-/run/arkkvm-network-adapter-udhcpd.pid}"
LAUNCH_PIDFILE="${LAUNCH_PIDFILE:-/run/arkkvm-network-adapter-udhcpd-launcher.pid}"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-/run/arkkvm-network-adapter-udhcpd.conf}"

is_eth_iface() {
	case "$1" in
	eth*) return 0 ;;
	*) return 1 ;;
	esac
}

read_pid() {
	file="$1"
	[ -f "$file" ] || return 1
	pid=$(cat "$file" 2>/dev/null)
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	echo "$pid"
}

# Kill udhcpc only on the NCM IFACE (never eth*).
stop_udhcpc_on_iface() {
	iface="$1"
	[ -n "$iface" ] || return 0
	is_eth_iface "$iface" && return 0
	for proc in /proc/[0-9]*; do
		[ -r "$proc/cmdline" ] || continue
		pid=${proc#/proc/}
		cmd=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null)
		case "$cmd" in
		*udhcpc*) ;;
		*) continue ;;
		esac
		case " $cmd " in
		*" -i $iface "*|*" -i$iface "*)
			kill "$pid" 2>/dev/null || true
			;;
		esac
	done
}

stop_server() {
	pid=$(read_pid "$LAUNCH_PIDFILE") || true
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		i=0
		while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
			sleep 1
			i=$((i + 1))
		done
		kill -9 "$pid" 2>/dev/null || true
	fi
	# Also stop by udhcpd pidfile if launcher pid is stale.
	upid=$(read_pid "$PIDFILE") || true
	if [ -n "$upid" ]; then
		kill "$upid" 2>/dev/null || true
		kill -9 "$upid" 2>/dev/null || true
	fi
	rm -f "$LAUNCH_PIDFILE" "$RUNTIME_CONFIG" "$PIDFILE"
}

start_server() {
	if [ -z "$IFACE" ]; then
		echo "arkkvm-network-adapter-udhcpd: IFACE is required" >&2
		return 1
	fi
	if is_eth_iface "$IFACE"; then
		echo "arkkvm-network-adapter-udhcpd: refusing eth interface: $IFACE" >&2
		return 1
	fi
	command -v udhcpd >/dev/null 2>&1 || {
		echo "arkkvm-network-adapter-udhcpd: udhcpd not found" >&2
		return 1
	}
	[ -d "/sys/class/net/$IFACE" ] || {
		echo "arkkvm-network-adapter-udhcpd: interface does not exist: $IFACE" >&2
		return 1
	}

	stop_server
	mkdir -p "$(dirname "$LEASE_FILE")" "$(dirname "$RUNTIME_CONFIG")" || return 1
	# BusyBox udhcpd expects an existing lease file path.
	touch "$LEASE_FILE" 2>/dev/null || true

	# Only on this USB net iface; never touch eth udhcpc.
	stop_udhcpc_on_iface "$IFACE"

	tmp_config="${RUNTIME_CONFIG}.tmp"
	{
		echo "start $START"
		echo "end $END"
		echo "interface $IFACE"
		echo "lease_file $LEASE_FILE"
		echo "pidfile $PIDFILE"
		echo "option subnet $NETMASK"
		echo "option lease $LEASE_TIME"
		# No router/dns: keep NCM isolated from eth / default route.
	} >"$tmp_config" || return 1
	mv "$tmp_config" "$RUNTIME_CONFIG" || return 1

	# -I is required on multi-homed boards (eth0 + usb0) so replies use the NCM address.
	udhcpd -f -I "$SERVER_IP" "$RUNTIME_CONFIG" >/dev/null 2>&1 &
	echo "$!" >"$LAUNCH_PIDFILE"
	sleep 1
	pid=$(read_pid "$LAUNCH_PIDFILE") || return 1
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "arkkvm-network-adapter-udhcpd: failed to start on $IFACE" >&2
		rm -f "$LAUNCH_PIDFILE"
		return 1
	fi
	echo "arkkvm-network-adapter-udhcpd: serving $START-$END on $IFACE (server_ip=$SERVER_IP conf-only)"
}

case "$1" in
start)
	start_server
	;;
stop)
	stop_server
	;;
restart)
	stop_server
	start_server
	;;
status)
	pid=$(read_pid "$LAUNCH_PIDFILE") || true
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		echo "arkkvm-network-adapter-udhcpd: running pid=$pid iface=${IFACE:-unknown}"
	else
		echo "arkkvm-network-adapter-udhcpd: stopped"
	fi
	;;
*)
	echo "Usage: $0 {start|stop|restart|status}"
	exit 1
	;;
esac

exit $?
