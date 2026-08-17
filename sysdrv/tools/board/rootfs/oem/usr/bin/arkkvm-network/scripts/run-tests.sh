#!/bin/sh
# network-config-unified tests
set -e

NWU_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
export NWU_ROOT
export NWU_TEST_MODE=1

# shellcheck source=/dev/null
. "$NWU_ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$NWU_ROOT/lib/config.sh"
nwu_load_paths
nwu_source_libs

TESTS_RUN=0 TESTS_OK=0 TESTS_FAIL=0

test_case() {
	name="$1"
	shift
	TESTS_RUN=$((TESTS_RUN + 1))
	msg_step "Test #$TESTS_RUN: $name"
	if "$@"; then
		TESTS_OK=$((TESTS_OK + 1))
		msg_ok "PASS: $name"
	else
		TESTS_FAIL=$((TESTS_FAIL + 1))
		msg_err "FAIL: $name"
	fi
}

setup_conf() {
	cp "$NWU_ROOT/config/network.conf.example" "$NETWORK_CONF"
}

test_parse_conf() {
	setup_conf
	nwu_conf_parse
	[ "$CONF_DHCP_CLIENT" = "udhcpc" ] && [ "$CONF_IPV4_MODE" = "dhcp" ]
}

test_dhcp_switch_udhcpc() {
	setup_conf
	sed -i 's/^client=.*/client=udhcpc/' "$NETWORK_CONF"
	nwu_conf_parse
	nwu_dhcp_stop_all
	NWU_DRY_RUN=1 nwu_ipv4_apply_dhcp
	grep -q '^client=udhcpc' "$NETWORK_CONF" || grep -q 'client=udhcpc' "$NETWORK_CONF"
}

test_dhcp_switch_dhcpcd() {
	setup_conf
	awk '/^\[dhcp\]/{print; getline; print "client=dhcpcd"; next}1' "$NETWORK_CONF" >"$NETWORK_CONF.tmp" || true
	if ! grep -q 'client=dhcpcd' "$NETWORK_CONF.tmp" 2>/dev/null; then
		sed 's/client=udhcpc/client=dhcpcd/' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	fi
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	nwu_conf_parse
	[ "$CONF_DHCP_CLIENT" = "dhcpcd" ]
}

test_refresh_dry() {
	setup_conf
	NWU_DRY_RUN=1 sh "$NWU_ROOT/scripts/refresh-network.sh" "$NETWORK_CONF"
}

test_static_mode() {
	setup_conf
	sed -i '/^\[ipv4\]/,/^\[ipv6\]/s/^mode=.*/mode=static/' "$NETWORK_CONF"
	nwu_conf_parse
	[ "$CONF_IPV4_MODE" = "static" ]
	NWU_DRY_RUN=1 nwu_ipv4_apply_static
}

test_resolv_static() {
	setup_conf
	nwu_conf_parse
	nwu_resolv_write "$CONF_DOMAIN" 192.168.5.1 8.8.8.8
	grep -q '192.168.5.1' "$RESOLV_CONF"
}

test_udhcpc_hook() {
	lease="$TEST_ROOT/run/udhcpc.eth0.info"
	mkdir -p "$(dirname "$lease")"
	export NWU_ROOT NET_IF=eth0 LEASE_FILE="$lease" RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
	mkdir -p "$(dirname "$RESOLV_CONF")"
	interface=eth0 ip=10.0.0.5 subnet=24 router=10.0.0.1 dns=10.0.0.1 domain=lan \
		sh "$NWU_ROOT/scripts/udhcpc-hook.sh" bound
	grep -q 'backend=udhcpc' "$lease"
}

test_dhcpcd_lease_sync() {
	setup_conf
	echo 'client=dhcpcd' >>"$NETWORK_CONF"
	sed -i '/^\[dhcp\]/,/^\[/{s/^client=.*/client=dhcpcd/}' "$NETWORK_CONF" 2>/dev/null || \
		sed -i 's/client=udhcpc/client=dhcpcd/' "$NETWORK_CONF"
	nwu_conf_parse
	CONF_DHCP_CLIENT=dhcpcd
	nwu_dhcpcd_write_lease_from_system
	grep -q 'backend=dhcpcd' "$(nwu_lease_path)"
}

test_vlan_parse() {
	setup_conf
	awk '/^\[vlan\]/{print; print "enabled=true"; next}1' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	nwu_conf_parse
	[ "$CONF_VLAN_ENABLED" = "true" ] && [ "$CONF_VLAN_PRIMARY_ID" = "10" ]
}

test_vlan_refresh_staging_dry() {
	setup_conf
	sed 's/^enabled=false/enabled=true/; s/^apply_mode=committed/apply_mode=staging/' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	NWU_DRY_RUN=1 NWU_APPLY_MODE=staging sh "$NWU_ROOT/scripts/refresh-network.sh" "$NETWORK_CONF"
}

test_vlan_refresh_committed_dry() {
	setup_conf
	sed 's/^enabled=false/enabled=true/' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	NWU_DRY_RUN=1 NWU_APPLY_MODE=committed sh "$NWU_ROOT/scripts/refresh-network.sh" "$NETWORK_CONF" 2>&1 | grep -q 'primary default route'
}

test_vlan_cleanup_pending() {
	touch "$TEST_ROOT/network.conf.pending" "$TEST_ROOT/network.conf.rollback"
	NETWORK_CONF_PENDING="$TEST_ROOT/network.conf.pending"
	NETWORK_CONF_ROLLBACK="$TEST_ROOT/network.conf.rollback"
	export NETWORK_CONF_PENDING NETWORK_CONF_ROLLBACK
	nwu_vlan_cleanup_pending
	[ ! -f "$TEST_ROOT/network.conf.pending" ] && [ ! -f "$TEST_ROOT/network.conf.rollback" ]
}

test_status_print_flat() {
	setup_conf
	nwu_conf_parse
	lease=$(nwu_lease_path)
	mkdir -p "$(dirname "$lease")"
	cat >"$lease" <<EOF
ip=10.0.0.5
subnet=255.255.255.0
broadcast=10.0.0.255
router=10.0.0.1
dns=10.0.0.1 8.8.8.8
hostname=arkkvm
serverid=10.0.0.1
siaddr=10.0.0.1
backend=udhcpc
EOF
	out=$(nwu_state_print)
	echo "$out" | grep -q 'IPv4 Mode: dhcp' || return 1
	echo "$out" | grep -q 'IP Address' || return 1
	echo "$out" | grep -q 'Boot Next Server' || return 1
	echo "$out" | grep -q 'IPv6 Mode: slaac' || return 1
	echo "$out" | grep -q 'Linklocal' || return 1
	echo "$out" | grep -q 'Global' || return 1
}

test_status_print_vlan() {
	setup_conf
	sed 's/^enabled=false/enabled=true/' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	nwu_conf_parse
	out=$(nwu_state_print)
	echo "$out" | grep -q 'Primary VLAN' || return 1
	echo "$out" | grep -q 'VLAN ID' || return 1
	echo "$out" | grep -q 'IPv4 Mode:' || return 1
	echo "$out" | grep -q 'IPv6 Mode:' || return 1
}

test_gateway_parse_rejects_iface_name() {
	# Mimic device-only default route: awk '{print $3}' wrongly yields eth0.6
	gw=$(printf '%s\n' 'default dev eth0.6 scope link' | awk '
	{
		for (i = 1; i < NF; i++) {
			if ($i == "via") {
				g = $(i + 1)
				if (g ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print g; exit }
			}
		}
	}')
	[ -z "$gw" ] || return 1
	gw=$(printf '%s\n' 'default via 192.168.6.1 dev eth0.6' | awk '
	{
		for (i = 1; i < NF; i++) {
			if ($i == "via") {
				g = $(i + 1)
				if (g ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print g; exit }
			}
		}
	}')
	[ "$gw" = "192.168.6.1" ] || return 1
	nwu_ipv4_is_dotted "192.168.6.1" || return 1
	nwu_ipv4_is_dotted "eth0.6" && return 1
	[ "$(nwu_ipv4_sanitize eth0.6)" = "" ] || return 1
	[ "$(nwu_ipv4_sanitize 192.168.6.1)" = "192.168.6.1" ] || return 1
}

test_status_print_sanitizes_iface_gateway() {
	setup_conf
	sed 's/^enabled=false/enabled=true/' "$NETWORK_CONF" >"$NETWORK_CONF.tmp"
	mv "$NETWORK_CONF.tmp" "$NETWORK_CONF"
	nwu_conf_parse
	iface=$(nwu_vlan_iface_name "$CONF_VLAN_PARENT" "$CONF_VLAN_PRIMARY_ID")
	lease=$(printf "$LEASE_FILE" "$iface")
	mkdir -p "$(dirname "$lease")" "$(dirname "$RESOLV_CONF")"
	cat >"$lease" <<EOF
ip=192.168.6.116
subnet=255.255.255.0
broadcast=192.168.6.255
router=eth0.6
dns=192.168.6.1
hostname=arkkvm3
serverid=eth0.6
siaddr=eth0.6
backend=udhcpc
EOF
	echo 'nameserver 192.168.6.1' >"$RESOLV_CONF"
	out=$(nwu_state_print)
	# Must not surface iface names as gateway/server fields.
	! echo "$out" | grep -q 'Gateway:.*eth0\.6' || return 1
	! echo "$out" | grep -q 'DHCP Server:.*eth0\.6' || return 1
	! echo "$out" | grep -q 'Boot Next Server:.*eth0\.6' || return 1
	echo "$out" | grep -q 'DNS Servers:.*192.168.6.1' || return 1
}

test_dhcpcd_lease_yiaddr_parse() {
	# Minimal RFC2131-shaped lease: yiaddr 192.168.5.117 at offset 16
	mkdir -p "${DHCPCD_DB:?DHCPCD_DB unset}"
	lease="$DHCPCD_DB/eth0.lease"
	# Avoid printf \x / dd portability issues under set -e
	awk 'BEGIN{
		for (i = 0; i < 16; i++) printf "%c", 0
		printf "%c%c%c%c", 192, 168, 5, 117
	}' >"$lease" || return 1
	ip=$(nwu_dhcpcd_lease_yiaddr "$lease") || return 1
	[ "$ip" = "192.168.5.117" ] || return 1
	# 0.0.0.0 rejected
	awk 'BEGIN{for (i = 0; i < 20; i++) printf "%c", 0}' >"$lease" || return 1
	out=$(nwu_dhcpcd_lease_yiaddr "$lease" 2>/dev/null || true)
	[ -z "$out" ] || return 1
}

test_dhcp_preferred_ip_from_dhcpcd() {
	setup_conf
	nwu_conf_parse
	NET_IF=eth0
	export NET_IF
	mkdir -p "${DHCPCD_DB:?DHCPCD_DB unset}" "$(dirname "$(printf "$LEASE_FILE" eth0)")"
	rm -f "$(printf "$LEASE_FILE" eth0)"
	lease="$DHCPCD_DB/eth0.lease"
	awk 'BEGIN{
		for (i = 0; i < 16; i++) printf "%c", 0
		printf "%c%c%c%c", 192, 168, 5, 117
	}' >"$lease" || return 1
	# No live iface in test mode — should fall through to dhcpcd DB
	pref=$(nwu_dhcp_preferred_ip eth0) || return 1
	[ "$pref" = "dhcpcd|192.168.5.117" ] || return 1
	# Consume removes the legacy file after read (OTA one-shot)
	nwu_dhcpcd_consume_legacy_lease eth0
	[ ! -f "$lease" ] || return 1
}

test_dhcp_preferred_ip_prefers_udhcpc_lease() {
	setup_conf
	nwu_conf_parse
	NET_IF=eth0
	export NET_IF
	mkdir -p "${DHCPCD_DB:?DHCPCD_DB unset}" "$(dirname "$(printf "$LEASE_FILE" eth0)")"
	ulease=$(printf "$LEASE_FILE" eth0)
	cat >"$ulease" <<EOF
ip=192.168.5.200
backend=udhcpc
EOF
	lease="$DHCPCD_DB/eth0.lease"
	awk 'BEGIN{
		for (i = 0; i < 16; i++) printf "%c", 0
		printf "%c%c%c%c", 192, 168, 5, 117
	}' >"$lease" || return 1
	pref=$(nwu_dhcp_preferred_ip eth0) || return 1
	[ "$pref" = "udhcpc|192.168.5.200" ] || return 1
}

run_all() {
	msg_info "======== network-config-unified tests ========"
	test_case "parse network.conf" test_parse_conf
	test_case "parse VLAN sections" test_vlan_parse
	test_case "DHCP backend udhcpc" test_dhcp_switch_udhcpc
	test_case "DHCP backend dhcpcd" test_dhcp_switch_dhcpcd
	test_case "refresh dry-run" test_refresh_dry
	test_case "VLAN staging dry-run" test_vlan_refresh_staging_dry
	test_case "VLAN committed default route dry-run" test_vlan_refresh_committed_dry
	test_case "VLAN pending cleanup" test_vlan_cleanup_pending
	test_case "static IPv4 mode" test_static_mode
	test_case "resolv write" test_resolv_static
	test_case "udhcpc hook lease" test_udhcpc_hook
	test_case "dhcpcd lease sync" test_dhcpcd_lease_sync
	test_case "status print flat UI fields" test_status_print_flat
	test_case "status print VLAN UI fields" test_status_print_vlan
	test_case "gateway parse rejects iface name" test_gateway_parse_rejects_iface_name
	test_case "status sanitizes iface gateway" test_status_print_sanitizes_iface_gateway
	test_case "dhcpcd lease yiaddr parse" test_dhcpcd_lease_yiaddr_parse
	test_case "preferred IP from dhcpcd DB" test_dhcp_preferred_ip_from_dhcpcd
	test_case "preferred IP prefers udhcpc lease" test_dhcp_preferred_ip_prefers_udhcpc_lease
	echo ""
	echo "======== Test results ========"
	echo "Total: $TESTS_RUN  PASS: $TESTS_OK  FAIL: $TESTS_FAIL"
	[ "$TESTS_FAIL" -eq 0 ]
}

case "${1:-all}" in
	all) run_all ;;
	parse) test_case "parse" test_parse_conf ;;
	dhcp) test_case "udhcpc" test_dhcp_switch_udhcpc; test_case "dhcpcd" test_dhcp_switch_dhcpcd ;;
	refresh) test_case "refresh" test_refresh_dry ;;
	*) die "Unknown test: $1" ;;
esac
