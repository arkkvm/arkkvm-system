# shellcheck shell=sh
# Parse network.conf (INI: [section] + key=value)

nwu_conf_reset() {
	CONF_IFACE=
	CONF_HOSTNAME=
	CONF_DOMAIN=
	CONF_DHCP_CLIENT=
	CONF_IPV4_MODE=
	CONF_IPV4_ADDR=
	CONF_IPV4_NETMASK=
	CONF_IPV4_GATEWAY=
	CONF_IPV4_DNS=
	CONF_IPV6_MODE=
	CONF_IPV6_PREFIX=
	CONF_IPV6_GATEWAY=
	CONF_IPV6_DNS=
	CONF_DNS_SERVERS=
	CONF_VLAN_ENABLED=
	CONF_VLAN_PARENT=
	CONF_VLAN_APPLY_MODE=
	CONF_VLAN_PRIMARY_ID=
	CONF_VLAN_PRIMARY_IPV4_MODE=
	CONF_VLAN_PRIMARY_IPV4_ADDR=
	CONF_VLAN_PRIMARY_IPV4_NETMASK=
	CONF_VLAN_PRIMARY_IPV4_GATEWAY=
	CONF_VLAN_PRIMARY_IPV4_DNS=
	CONF_VLAN_PRIMARY_IPV6_MODE=
	CONF_VLAN_PRIMARY_IPV6_PREFIX=
	CONF_VLAN_PRIMARY_IPV6_GATEWAY=
	CONF_VLAN_PRIMARY_IPV6_DNS=
	CONF_VLAN_PRIMARY_ROUTE_METRIC=
	CONF_VLAN_SECONDARY_ID=
	CONF_VLAN_SECONDARY_IPV4_MODE=
	CONF_VLAN_SECONDARY_IPV4_ADDR=
	CONF_VLAN_SECONDARY_IPV4_NETMASK=
	CONF_VLAN_SECONDARY_IPV4_GATEWAY=
	CONF_VLAN_SECONDARY_IPV4_DNS=
	CONF_VLAN_SECONDARY_IPV6_MODE=
	CONF_VLAN_SECONDARY_IPV6_PREFIX=
	CONF_VLAN_SECONDARY_IPV6_GATEWAY=
	CONF_VLAN_SECONDARY_IPV6_DNS=
	CONF_VLAN_SECONDARY_ROUTE_METRIC=
}

nwu_conf_get() {
	section="$1"
	key="$2"
	file="$3"
	awk -F= -v sec="$section" -v k="$key" '
		/^\[/ { cur = substr($0, 2, length($0)-2); next }
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		cur == sec {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
			if ($1 == k) {
				# BusyBox awk: -F= rebuilds $0 with space-joined fields; cannot use index($0,"=")
				val = $2
				for (i = 3; i <= NF; i++) val = val "=" $i
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
				print val
				exit
			}
		}
	' "$file"
}

nwu_conf_parse_vlan_endpoint() {
	role="$1"
	conf="$2"
	tag=$(echo "$role" | tr '[:lower:]' '[:upper:]')
	prefix="vlan.$role"

	eval "CONF_VLAN_${tag}_ID=\$(nwu_conf_get \"$prefix\" id \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV4_MODE=\$(nwu_conf_get \"$prefix\" ipv4_mode \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV4_ADDR=\$(nwu_conf_get \"$prefix\" ipv4_address \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV4_NETMASK=\$(nwu_conf_get \"$prefix\" ipv4_netmask \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV4_GATEWAY=\$(nwu_conf_get \"$prefix\" ipv4_gateway \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV4_DNS=\$(nwu_conf_get \"$prefix\" ipv4_dns \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV6_MODE=\$(nwu_conf_get \"$prefix\" ipv6_mode \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV6_PREFIX=\$(nwu_conf_get \"$prefix\" ipv6_prefix \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV6_GATEWAY=\$(nwu_conf_get \"$prefix\" ipv6_gateway \"$conf\")"
	eval "CONF_VLAN_${tag}_IPV6_DNS=\$(nwu_conf_get \"$prefix\" ipv6_dns \"$conf\")"
	eval "CONF_VLAN_${tag}_ROUTE_METRIC=\$(nwu_conf_get \"$prefix\" route_metric \"$conf\")"
}

nwu_vlan_normalize() {
	if [ "$CONF_VLAN_ENABLED" != "true" ]; then
		return 0
	fi
	if [ -z "$CONF_VLAN_PRIMARY_ID" ] || [ "$CONF_VLAN_PRIMARY_ID" = "0" ]; then
		CONF_VLAN_PRIMARY_ID=10
	fi
	[ -n "$CONF_VLAN_PRIMARY_IPV4_MODE" ] || CONF_VLAN_PRIMARY_IPV4_MODE=dhcp
	[ -n "$CONF_VLAN_PRIMARY_IPV6_MODE" ] || CONF_VLAN_PRIMARY_IPV6_MODE=slaac
	[ -n "$CONF_VLAN_PRIMARY_ROUTE_METRIC" ] || CONF_VLAN_PRIMARY_ROUTE_METRIC=0
	[ -n "$CONF_VLAN_SECONDARY_ID" ] || CONF_VLAN_SECONDARY_ID=0
	[ -n "$CONF_VLAN_SECONDARY_IPV4_MODE" ] || CONF_VLAN_SECONDARY_IPV4_MODE=disabled
	[ -n "$CONF_VLAN_SECONDARY_IPV6_MODE" ] || CONF_VLAN_SECONDARY_IPV6_MODE=disabled
	[ -n "$CONF_VLAN_SECONDARY_ROUTE_METRIC" ] || CONF_VLAN_SECONDARY_ROUTE_METRIC=200
}

nwu_vlan_validate() {
	if [ "$CONF_VLAN_ENABLED" != "true" ]; then
		return 0
	fi
	if [ -z "$CONF_VLAN_PRIMARY_ID" ] || [ "$CONF_VLAN_PRIMARY_ID" = "0" ]; then
		die "vlan.enabled=true requires a valid vlan.primary.id"
	fi
	nwu_vlan_validate_endpoint primary "$CONF_VLAN_PRIMARY_ID" "$CONF_VLAN_PRIMARY_IPV4_MODE" \
		"$CONF_VLAN_PRIMARY_IPV4_ADDR" "$CONF_VLAN_PRIMARY_IPV4_NETMASK" "$CONF_VLAN_PRIMARY_IPV4_GATEWAY"
	if [ -n "$CONF_VLAN_SECONDARY_ID" ] && [ "$CONF_VLAN_SECONDARY_ID" != "0" ]; then
		if [ "$CONF_VLAN_SECONDARY_ID" = "$CONF_VLAN_PRIMARY_ID" ]; then
			die "vlan.primary.id and vlan.secondary.id must differ"
		fi
		nwu_vlan_validate_endpoint secondary "$CONF_VLAN_SECONDARY_ID" "$CONF_VLAN_SECONDARY_IPV4_MODE" \
			"$CONF_VLAN_SECONDARY_IPV4_ADDR" "$CONF_VLAN_SECONDARY_IPV4_NETMASK" "$CONF_VLAN_SECONDARY_IPV4_GATEWAY"
	fi
}

nwu_vlan_validate_endpoint() {
	role="$1"
	id="$2"
	mode="$3"
	addr="$4"
	mask="$5"
	gw="$6"
	if [ -z "$id" ] || [ "$id" = "0" ]; then
		return 0
	fi
	case "$id" in
	*[!0-9]*) die "vlan.$role.id invalid: $id" ;;
	esac
	if [ "$id" -lt 1 ] || [ "$id" -gt 4094 ]; then
		die "vlan.$role.id must be 1-4094: $id"
	fi
	case "$mode" in
	dhcp|static|disabled) ;;
	*) die "vlan.$role.ipv4_mode invalid: $mode" ;;
	esac
	if [ "$mode" = "static" ]; then
		[ -n "$addr" ] && [ -n "$mask" ] || die "vlan.$role ipv4_mode=static requires ipv4_address and ipv4_netmask"
		[ -n "$gw" ] || die "vlan.$role ipv4_mode=static requires ipv4_gateway"
	fi
}

nwu_conf_parse() {
	conf="${1:-$NETWORK_CONF}"
	nwu_conf_reset

	[ -f "$conf" ] || die "Config file not found: $conf"

	CONF_IFACE=$(nwu_conf_get interface name "$conf")
	CONF_HOSTNAME=$(nwu_conf_get system hostname "$conf")
	CONF_DOMAIN=$(nwu_conf_get system domain "$conf")
	CONF_DHCP_CLIENT=$(nwu_conf_get dhcp client "$conf")
	CONF_IPV4_MODE=$(nwu_conf_get ipv4 mode "$conf")
	CONF_IPV4_ADDR=$(nwu_conf_get ipv4 address "$conf")
	CONF_IPV4_NETMASK=$(nwu_conf_get ipv4 netmask "$conf")
	CONF_IPV4_GATEWAY=$(nwu_conf_get ipv4 gateway "$conf")
	CONF_IPV4_DNS=$(nwu_conf_get ipv4 dns "$conf")
	CONF_IPV6_MODE=$(nwu_conf_get ipv6 mode "$conf")
	CONF_IPV6_PREFIX=$(nwu_conf_get ipv6 prefix "$conf")
	CONF_IPV6_GATEWAY=$(nwu_conf_get ipv6 gateway "$conf")
	CONF_IPV6_DNS=$(nwu_conf_get ipv6 dns "$conf")
	CONF_DNS_SERVERS=$(nwu_conf_get dns servers "$conf")

	CONF_VLAN_ENABLED=$(nwu_conf_get vlan enabled "$conf")
	CONF_VLAN_PARENT=$(nwu_conf_get vlan parent "$conf")
	CONF_VLAN_APPLY_MODE=$(nwu_conf_get vlan apply_mode "$conf")
	nwu_conf_parse_vlan_endpoint primary "$conf"
	nwu_conf_parse_vlan_endpoint secondary "$conf"

	# Defaults
	[ -n "$CONF_IFACE" ] || CONF_IFACE=eth0
	[ -n "$CONF_HOSTNAME" ] || CONF_HOSTNAME=arkkvm
	[ -n "$CONF_DOMAIN" ] || CONF_DOMAIN=local
	[ -n "$CONF_DHCP_CLIENT" ] || CONF_DHCP_CLIENT=udhcpc
	[ -n "$CONF_IPV4_MODE" ] || CONF_IPV4_MODE=dhcp
	[ -n "$CONF_IPV6_MODE" ] || CONF_IPV6_MODE=slaac
	[ -n "$CONF_VLAN_PARENT" ] || CONF_VLAN_PARENT="$CONF_IFACE"
	[ -n "$CONF_VLAN_APPLY_MODE" ] || CONF_VLAN_APPLY_MODE=committed

	case "$CONF_DHCP_CLIENT" in
	udhcpc|dhcpcd) ;;
	*) die "dhcp.client invalid: $CONF_DHCP_CLIENT (only udhcpc | dhcpcd)" ;;
	esac

	case "$CONF_IPV4_MODE" in
	dhcp|static|disabled) ;;
	*) die "ipv4.mode invalid: $CONF_IPV4_MODE" ;;
	esac

	case "$CONF_IPV6_MODE" in
	slaac|static|link_local|disabled) ;;
	*) die "ipv6.mode invalid: $CONF_IPV6_MODE" ;;
	esac

	nwu_vlan_normalize
	nwu_vlan_validate

	# Export for modules
	export CONF_IFACE CONF_HOSTNAME CONF_DOMAIN CONF_DHCP_CLIENT
	export CONF_IPV4_MODE CONF_IPV4_ADDR CONF_IPV4_NETMASK CONF_IPV4_GATEWAY CONF_IPV4_DNS
	export CONF_IPV6_MODE CONF_IPV6_PREFIX CONF_IPV6_GATEWAY CONF_IPV6_DNS CONF_DNS_SERVERS
	export CONF_VLAN_ENABLED CONF_VLAN_PARENT CONF_VLAN_APPLY_MODE
	export CONF_VLAN_PRIMARY_ID CONF_VLAN_PRIMARY_IPV4_MODE CONF_VLAN_PRIMARY_IPV4_ADDR
	export CONF_VLAN_PRIMARY_IPV4_NETMASK CONF_VLAN_PRIMARY_IPV4_GATEWAY CONF_VLAN_PRIMARY_IPV4_DNS
	export CONF_VLAN_PRIMARY_IPV6_MODE CONF_VLAN_PRIMARY_IPV6_PREFIX CONF_VLAN_PRIMARY_IPV6_GATEWAY
	export CONF_VLAN_PRIMARY_IPV6_DNS CONF_VLAN_PRIMARY_ROUTE_METRIC
	export CONF_VLAN_SECONDARY_ID CONF_VLAN_SECONDARY_IPV4_MODE CONF_VLAN_SECONDARY_IPV4_ADDR
	export CONF_VLAN_SECONDARY_IPV4_NETMASK CONF_VLAN_SECONDARY_IPV4_GATEWAY CONF_VLAN_SECONDARY_IPV4_DNS
	export CONF_VLAN_SECONDARY_IPV6_MODE CONF_VLAN_SECONDARY_IPV6_PREFIX CONF_VLAN_SECONDARY_IPV6_GATEWAY
	export CONF_VLAN_SECONDARY_IPV6_DNS CONF_VLAN_SECONDARY_ROUTE_METRIC

	NET_IF="$CONF_IFACE"
	export NET_IF

	nwu_log "parsed network.conf: dhcp=$CONF_DHCP_CLIENT ipv4=$CONF_IPV4_MODE vlan=${CONF_VLAN_ENABLED:-false}"
}

nwu_conf_show() {
	nwu_conf_parse "$1"
	echo "======== network.conf ========"
	echo "File:       ${1:-$NETWORK_CONF}"
	echo "Interface:  $CONF_IFACE"
	echo "Hostname:   $CONF_HOSTNAME"
	echo "Domain:     $CONF_DOMAIN"
	echo "DHCP backend: $CONF_DHCP_CLIENT"
	echo "IPv4 mode:  $CONF_IPV4_MODE"
	echo "IPv4 static: ${CONF_IPV4_ADDR:-<none>}/${CONF_IPV4_NETMASK:-<none>} gw=${CONF_IPV4_GATEWAY:-<none>}"
	echo "IPv4 DNS:   ${CONF_IPV4_DNS:-<none>}"
	echo "IPv6 mode:  $CONF_IPV6_MODE"
	echo "Forced DNS: ${CONF_DNS_SERVERS:-<none>}"
	echo "VLAN:       enabled=${CONF_VLAN_ENABLED:-false} parent=$CONF_VLAN_PARENT apply=${CONF_VLAN_APPLY_MODE:-committed}"
	if [ "$CONF_VLAN_ENABLED" = "true" ]; then
		echo "  primary:  id=$CONF_VLAN_PRIMARY_ID ipv4=$CONF_VLAN_PRIMARY_IPV4_MODE"
		if [ -n "$CONF_VLAN_SECONDARY_ID" ] && [ "$CONF_VLAN_SECONDARY_ID" != "0" ]; then
			echo "  secondary: id=$CONF_VLAN_SECONDARY_ID ipv4=$CONF_VLAN_SECONDARY_IPV4_MODE"
		fi
	fi
	echo "=============================="
}
