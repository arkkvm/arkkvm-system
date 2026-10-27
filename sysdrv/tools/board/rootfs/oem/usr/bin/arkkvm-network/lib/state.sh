# shellcheck shell=sh
# Runtime network info printer — fields align with frontend SettingNetwork
# (IPv4 Mode / DHCP Lease / Static IPv4 / IPv6 Mode / VLAN Primary|Secondary)

nwu_state_dash() {
	val="$1"
	if [ -n "$val" ]; then
		printf '%s' "$val"
	else
		printf '-'
	fi
}

nwu_state_kv() {
	printf '  %-20s %s\n' "$1:" "$(nwu_state_dash "$2")"
}

nwu_state_lease_get() {
	key="$1"
	lease="$2"
	[ -f "$lease" ] || return 0
	grep "^${key}=" "$lease" 2>/dev/null | head -n1 | cut -d= -f2-
}

# Convert CIDR prefix length (e.g. 24) to dotted netmask; pass through dotted masks.
nwu_ipv4_netmask_from_cidr() {
	prefix="$1"
	case "$prefix" in
	''|*[!0-9]*)
		# Already dotted or empty
		printf '%s' "$prefix"
		return 0
		;;
	esac
	case "$prefix" in
	8) echo 255.0.0.0 ;;
	16) echo 255.255.0.0 ;;
	24) echo 255.255.255.0 ;;
	25) echo 255.255.255.128 ;;
	26) echo 255.255.255.192 ;;
	27) echo 255.255.255.224 ;;
	28) echo 255.255.255.240 ;;
	29) echo 255.255.255.248 ;;
	30) echo 255.255.255.252 ;;
	32) echo 255.255.255.255 ;;
	*)
		# Generic conversion for other prefix lengths
		bits=$prefix
		out=""
		i=0
		while [ "$i" -lt 4 ]; do
			if [ "$bits" -ge 8 ]; then
				octet=255
				bits=$((bits - 8))
			elif [ "$bits" -le 0 ]; then
				octet=0
			else
				octet=$((256 - (1 << (8 - bits))))
				bits=0
			fi
			if [ -z "$out" ]; then
				out="$octet"
			else
				out="$out.$octet"
			fi
			i=$((i + 1))
		done
		echo "$out"
		;;
	esac
}

nwu_state_runtime_ipv4() {
	iface="$1"
	cidr=$(nwu_ipv4_nonll_cidr "$iface")
	[ -n "$cidr" ] || cidr=$(nwu_ipv4_linklocal_cidr "$iface")
	[ -n "$cidr" ] && echo "$cidr"
}

nwu_state_runtime_gateway() {
	iface="$1"
	nwu_ipv4_default_gateway "$iface"
}

nwu_state_runtime_dns() {
	grep '^nameserver ' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

nwu_state_ipv6_linklocal() {
	iface="$1"
	ip -6 -o addr show dev "$iface" scope link 2>/dev/null | awk '{print $4}' | head -n1
}

nwu_state_ipv6_global() {
	iface="$1"
	ip -6 -o addr show dev "$iface" 2>/dev/null | awk '!/fe80:/ {print $4; exit}'
}

# Print IPv4 block matching frontend DHCP Lease Information / Static IPv4 Configuration.
# Args: iface mode [static_addr static_netmask static_gateway static_dns]
nwu_state_print_ipv4() {
	iface="$1"
	mode="$2"
	static_addr="${3:-}"
	static_netmask="${4:-}"
	static_gateway="${5:-}"
	static_dns="${6:-}"

	echo "---- IPv4 Mode: ${mode:-?} ----"
	case "$mode" in
	dhcp)
		lease=$(printf "$LEASE_FILE" "$iface")
		ip_addr=$(nwu_state_lease_get ip "$lease")
		[ -n "$ip_addr" ] || {
			cidr=$(nwu_state_runtime_ipv4 "$iface")
			ip_addr=${cidr%/*}
		}
		gateway=$(nwu_state_lease_get router "$lease")
		gateway=$(echo "$gateway" | awk '{print $1}')
		gateway=$(nwu_ipv4_sanitize "$gateway")
		[ -n "$gateway" ] || gateway=$(nwu_state_runtime_gateway "$iface")

		subnet=$(nwu_state_lease_get subnet "$lease")
		if [ -z "$subnet" ]; then
			cidr=$(nwu_state_runtime_ipv4 "$iface")
			[ -n "$cidr" ] && subnet=${cidr#*/}
		fi
		case "$subnet" in
		*[!0-9]*) ;; # dotted
		*) [ -n "$subnet" ] && subnet=$(nwu_ipv4_netmask_from_cidr "$subnet") ;;
		esac

		dns=$(nwu_state_lease_get dns "$lease")
		[ -n "$dns" ] || dns=$(nwu_state_runtime_dns)
		# Frontend joins DNS with ", "
		dns=$(echo "$dns" | awk '{for (i=1;i<=NF;i++) {printf "%s%s", (i>1?", ":""), $i}}')

		# Never invent gateway from DNS; leave empty when lease/route have no via.
		serverid=$(nwu_ipv4_sanitize "$(nwu_state_lease_get serverid "$lease")")
		[ -n "$serverid" ] || serverid="$gateway"
		broadcast=$(nwu_state_lease_get broadcast "$lease")
		hostname=$(nwu_state_lease_get hostname "$lease")
		siaddr=$(nwu_ipv4_sanitize "$(nwu_state_lease_get siaddr "$lease")")
		[ -n "$siaddr" ] || siaddr="$gateway"

		echo "  [DHCP Lease Information]"
		nwu_state_kv "IP Address" "$ip_addr"
		nwu_state_kv "Gateway" "$gateway"
		nwu_state_kv "Subnet Mask" "$subnet"
		nwu_state_kv "DHCP Server" "$serverid"
		nwu_state_kv "DNS Servers" "$dns"
		nwu_state_kv "Broadcast" "$broadcast"
		nwu_state_kv "Hostname" "$hostname"
		nwu_state_kv "Boot Next Server" "$siaddr"
		;;
	static)
		addr="$static_addr"
		mask="$static_netmask"
		gw="$static_gateway"
		dns="$static_dns"
		if [ -z "$addr" ] || [ -z "$mask" ]; then
			cidr=$(nwu_state_runtime_ipv4 "$iface")
			[ -z "$addr" ] && [ -n "$cidr" ] && addr=${cidr%/*}
			if [ -z "$mask" ] && [ -n "$cidr" ]; then
				mask=$(nwu_ipv4_netmask_from_cidr "${cidr#*/}")
			fi
		fi
		gw=$(nwu_ipv4_sanitize "$gw")
		[ -n "$gw" ] || gw=$(nwu_state_runtime_gateway "$iface")
		if [ -z "$dns" ]; then
			dns=$(nwu_state_runtime_dns)
		fi
		dns=$(echo "$dns" | awk '{for (i=1;i<=NF;i++) {printf "%s%s", (i>1?", ":""), $i}}')

		echo "  [Static IPv4 Configuration]"
		nwu_state_kv "IPv4 Address" "$addr"
		nwu_state_kv "IPv4 Netmask" "$mask"
		nwu_state_kv "IPv4 Gateway" "$gw"
		nwu_state_kv "IPv4 DNS" "$dns"
		;;
	disabled)
		echo "  (IPv4 disabled)"
		;;
	*)
		echo "  (unknown IPv4 mode: ${mode:-empty})"
		;;
	esac
}

# Print IPv6 block matching frontend IPv6 Information (Linklocal / Global).
nwu_state_print_ipv6() {
	iface="$1"
	mode="$2"

	echo "---- IPv6 Mode: ${mode:-?} ----"
	case "$mode" in
	disabled)
		echo "  (IPv6 disabled)"
		return 0
		;;
	esac

	linklocal=$(nwu_state_ipv6_linklocal "$iface")
	global=$(nwu_state_ipv6_global "$iface")
	# Strip /prefix for display parity with frontend address strings when present as CIDR
	linklocal_disp=${linklocal%%/*}
	global_disp=${global%%/*}

	echo "  [IPv6 Information]"
	# Frontend hardcodes labels "Linklocal" / "Global"
	nwu_state_kv "Linklocal" "$linklocal_disp"
	nwu_state_kv "Global" "$global_disp"
}

nwu_state_print_flat() {
	echo "==== Flat Network ===="
	nwu_state_print_ipv4 "$NET_IF" "$CONF_IPV4_MODE" \
		"$CONF_IPV4_ADDR" "$CONF_IPV4_NETMASK" "$CONF_IPV4_GATEWAY" "$CONF_IPV4_DNS"
	echo ""
	nwu_state_print_ipv6 "$NET_IF" "$CONF_IPV6_MODE"
}

nwu_state_print_vlan_endpoint() {
	role="$1"
	nwu_vlan_endpoint_vars "$role"
	[ -n "$VLAN_EP_ID" ] && [ "$VLAN_EP_ID" != "0" ] || return 0

	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$VLAN_EP_ID")
	case "$role" in
	primary) title="Primary" ;;
	secondary) title="Secondary" ;;
	*) title="$role" ;;
	esac

	echo "==== ${title} VLAN ===="
	nwu_state_kv "VLAN ID" "$VLAN_EP_ID"
	nwu_state_kv "Interface" "$iface"
	if ! ip link show "$iface" >/dev/null 2>&1; then
		echo "  (interface missing)"
	fi
	echo ""
	nwu_state_print_ipv4 "$iface" "$VLAN_EP_IPV4_MODE" \
		"$VLAN_EP_IPV4_ADDR" "$VLAN_EP_IPV4_NETMASK" "$VLAN_EP_IPV4_GATEWAY" "$VLAN_EP_IPV4_DNS"
	echo ""
	nwu_state_print_ipv6 "$iface" "$VLAN_EP_IPV6_MODE"
}

nwu_state_print() {
	mac=$(cat "/sys/class/net/$NET_IF/address" 2>/dev/null || echo "N/A")
	link=$(nwu_link_operstate 2>/dev/null || echo "?")

	echo "======== Network Information ========"
	echo "Config:     $NETWORK_CONF"
	echo "Interface:  $NET_IF"
	echo "Link:       $link"
	echo "MAC:        $mac"
	echo "Hostname:   ${CONF_HOSTNAME:-$(cat /etc/hostname 2>/dev/null | tr -d '\n')}"
	echo "DHCP backend: ${CONF_DHCP_CLIENT:-?}"
	echo "VLAN:       ${CONF_VLAN_ENABLED:-false}"

	if [ "${CONF_VLAN_ENABLED:-false}" = "true" ]; then
		echo "Parent:     ${CONF_VLAN_PARENT:-$CONF_IFACE}"
		echo "Apply mode: $(nwu_vlan_apply_mode)"
		echo ""
		nwu_state_print_vlan_endpoint primary
		echo ""
		if [ -n "$CONF_VLAN_SECONDARY_ID" ] && [ "$CONF_VLAN_SECONDARY_ID" != "0" ]; then
			nwu_state_print_vlan_endpoint secondary
			echo ""
		fi
	else
		echo ""
		nwu_state_print_flat
		echo ""
	fi
	echo "====================================="
}
