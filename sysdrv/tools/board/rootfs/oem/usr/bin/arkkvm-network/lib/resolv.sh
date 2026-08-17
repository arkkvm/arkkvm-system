# shellcheck shell=sh

nwu_resolv_write() {
	domain="${1:-$CONF_DOMAIN}"
	shift || true
	ns_list="$*"

	msg_step "Write $RESOLV_CONF"
	mkdir -p "$(dirname "$RESOLV_CONF")"

	{
		echo "# managed by network-config-unified / refresh-network.sh"
		[ -n "$domain" ] && echo "domain $domain"
		for ns in $ns_list; do
			[ -n "$ns" ] && echo "nameserver $ns"
		done
	} >"${RESOLV_CONF}.tmp"

	if nwu_is_dry_run; then
		cat "${RESOLV_CONF}.tmp"
		rm -f "${RESOLV_CONF}.tmp"
		return 0
	fi
	mv "${RESOLV_CONF}.tmp" "$RESOLV_CONF"
}

nwu_resolv_from_lease() {
	lease=$(nwu_lease_path)
	[ -f "$lease" ] || return 1
	dns=$(grep '^dns=' "$lease" | cut -d= -f2-)
	domain=$(grep '^domain=' "$lease" | cut -d= -f2-)
	[ -n "$domain" ] || domain="$CONF_DOMAIN"
	if [ -z "$dns" ]; then
		dns=$(grep '^nameserver ' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
	fi
	[ -n "$dns" ] || return 1
	nwu_resolv_write "$domain" $dns
}

nwu_resolv_apply() {
	if [ -n "$CONF_DNS_SERVERS" ]; then
		nwu_resolv_write "$CONF_DOMAIN" $CONF_DNS_SERVERS
		return 0
	fi
	case "$CONF_IPV4_MODE" in
	static)
		[ -n "$CONF_IPV4_DNS" ] && nwu_resolv_write "$CONF_DOMAIN" $CONF_IPV4_DNS
		;;
	dhcp)
		nwu_resolv_from_lease || true
		;;
	esac
}

nwu_resolv_show() {
	[ -f "$RESOLV_CONF" ] && cat "$RESOLV_CONF" || msg_warn "No $RESOLV_CONF"
}
