# shellcheck shell=sh

nwu_hostname_set() {
	name="${1:-$CONF_HOSTNAME}"
	domain="${2:-$CONF_DOMAIN}"

	msg_step "Set hostname: $name"
	mkdir -p "$(dirname "$HOSTNAME_FILE")"
	if nwu_is_dry_run || nwu_skip_netlink; then
		msg_info "[dry-run] echo $name > $HOSTNAME_FILE"
	else
		echo "$name" >"$HOSTNAME_FILE"
		hostname "$name" 2>/dev/null || true
	fi

	mkdir -p "$(dirname "$HOSTS_FILE")"
	if [ -f "$HOSTS_FILE" ]; then
		grep -v '127.0.1.1' "$HOSTS_FILE" >"${HOSTS_FILE}.tmp" 2>/dev/null || true
	else
		: >"${HOSTS_FILE}.tmp"
	fi
	{
		cat "${HOSTS_FILE}.tmp"
		echo "127.0.1.1	$name.$domain	$name"
	} >"$HOSTS_FILE"
	rm -f "${HOSTS_FILE}.tmp"
}
