#!/bin/sh
# Migrate legacy network config to network.conf, refresh, then archive and remove legacy files.
#
# Currently supported legacy sources:
#   /userdata/arkkvm/static_ip.conf   (flat IPv4 key=value)
#
# Usage:
#   ./scripts/migrate-legacy-network.sh
#   NWU_ROOT=/oem/usr/bin/arkkvm-network ./scripts/migrate-legacy-network.sh
#
# Exit codes: 0=nothing to migrate or success; 1=migrate/refresh failed (legacy files kept)

set -e

NWU_ROOT="${NWU_ROOT:-/oem/usr/bin/arkkvm-network}"
NETWORK_CONF="${NETWORK_CONF:-/userdata/arkkvm/network.conf}"
STATIC_IP_CONF="${STATIC_IP_CONF:-/userdata/arkkvm/static_ip.conf}"
LEGACY_ARCHIVE_DIR="${LEGACY_ARCHIVE_DIR:-/userdata/arkkvm/legacy-network}"
REFRESH_SCRIPT="${REFRESH_SCRIPT:-$NWU_ROOT/scripts/refresh-network.sh}"
USERDATA_DIR="${USERDATA_DIR:-/userdata/arkkvm}"

log() {
	echo "[migrate-legacy] $*"
}

timestamp() {
	date +%Y%m%d%H%M%S 2>/dev/null || date +%s
}

get_static_kv() {
	key="$1"
	grep -i "^${key}=" "$STATIC_IP_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

read_existing_section() {
	# read_existing_section <section> <key>
	sec="$1"
	key="$2"
	awk -F= -v sec="$sec" -v key="$key" '
		/^\[/ {
			in_sec = ($0 == "[" sec "]")
			next
		}
		in_sec && $1 == key { print substr($0, index($0, "=") + 1); exit }
	' "$NETWORK_CONF" 2>/dev/null
}

write_network_conf_from_static_ip() {
	ip_addr="$1"
	netmask="$2"
	gateway="$3"
	dns="$4"

	hostname="$(read_existing_section system hostname 2>/dev/null)"
	domain="$(read_existing_section system domain 2>/dev/null)"
	dhcp_client="$(read_existing_section dhcp client 2>/dev/null)"
	vlan_enabled="$(read_existing_section vlan enabled 2>/dev/null)"

	[ -n "$hostname" ] || hostname="arkkvm"
	[ -n "$domain" ] || domain="local"
	[ -n "$dhcp_client" ] || dhcp_client="udhcpc"
	[ -n "$vlan_enabled" ] || vlan_enabled="false"

	mkdir -p "$(dirname "$NETWORK_CONF")"

	# If network.conf already exists, back it up first
	if [ -f "$NETWORK_CONF" ]; then
		_bak_ts="$(timestamp)"
		cp "$NETWORK_CONF" "${NETWORK_CONF}.pre-migrate.${_bak_ts}"
	fi

	cat >"$NETWORK_CONF" <<EOF
# Migrated from static_ip.conf on $(date -Iseconds 2>/dev/null || date)
# Apply: $REFRESH_SCRIPT

[interface]
name=eth0

[system]
hostname=$hostname
domain=$domain

[dhcp]
client=$dhcp_client

[ipv4]
mode=static
address=$ip_addr
netmask=${netmask:-255.255.255.0}
gateway=${gateway:-}
dns=${dns:-}

[ipv6]
mode=slaac
prefix=
gateway=
dns=

[dns]
servers=

[vlan]
enabled=$vlan_enabled
parent=eth0
apply_mode=committed

[vlan.primary]
id=10
ipv4_mode=dhcp
ipv4_address=
ipv4_netmask=
ipv4_gateway=
ipv4_dns=
ipv6_mode=slaac
ipv6_prefix=
ipv6_gateway=
ipv6_dns=
route_metric=100

[vlan.secondary]
id=0
ipv4_mode=disabled
ipv4_address=
ipv4_netmask=
ipv4_gateway=
ipv4_dns=
ipv6_mode=disabled
ipv6_prefix=
ipv6_gateway=
ipv6_dns=
route_metric=200
EOF

	# If original conf had VLAN enabled, prompt for manual confirmation
	if [ "$vlan_enabled" = "true" ] && [ -f "${NETWORK_CONF}.pre-migrate.${_bak_ts:-}" ]; then
		log "Warning: VLAN enabled detected; confirm vlan section via Web UI"
	fi
}

archive_legacy_file() {
	src="$1"
	label="$2"
	mkdir -p "$LEGACY_ARCHIVE_DIR"
	dest="$LEGACY_ARCHIVE_DIR/${label}.migrated.$(timestamp)"
	mv "$src" "$dest"
	log "Archived legacy: $src -> $dest"
}

apply_and_cleanup() {
	if [ ! -x "$REFRESH_SCRIPT" ]; then
		log "Error: refresh script not executable: $REFRESH_SCRIPT"
		return 1
	fi

	log "Refreshing network: $REFRESH_SCRIPT $NETWORK_CONF"
	if ! "$REFRESH_SCRIPT" "$NETWORK_CONF"; then
		log "Error: refresh failed, keeping $STATIC_IP_CONF"
		return 1
	fi

	archive_legacy_file "$STATIC_IP_CONF" "static_ip.conf"
	log "Migration complete and applied"
	return 0
}

main() {
	if [ ! -f "$STATIC_IP_CONF" ]; then
		log "No legacy file $STATIC_IP_CONF, skipping"
		exit 0
	fi

	ip_addr="$(get_static_kv ip)"
	netmask="$(get_static_kv netmask)"
	gateway="$(get_static_kv gateway)"
	dns="$(get_static_kv dns)"

	if [ -z "$ip_addr" ]; then
		log "Error: no ip= in $STATIC_IP_CONF, skipping migration"
		exit 1
	fi

	log "Found legacy static_ip.conf: ip=$ip_addr"
	write_network_conf_from_static_ip "$ip_addr" "$netmask" "$gateway" "$dns"
	apply_and_cleanup
}

main "$@"
