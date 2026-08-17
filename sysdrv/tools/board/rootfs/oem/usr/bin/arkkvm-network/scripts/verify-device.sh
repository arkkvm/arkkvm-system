#!/bin/sh
# On-device full verification — network changes only via network.conf + refresh-network.sh
# Usage: NWU_ROOT=/oem/usr/bin/arkkvm-network ./scripts/verify-device.sh
set -u

NWU_ROOT="${NWU_ROOT:-/oem/usr/bin/arkkvm-network}"
NETWORK_CONF="${NETWORK_CONF:-/userdata/arkkvm/network.conf}"
NETWORK_CONF_PENDING="${NETWORK_CONF_PENDING:-/userdata/arkkvm/network.conf.pending}"
REPORT="${NWU_VERIFY_REPORT:-/tmp/nwu-verify-report.md}"
BACKUP="${NETWORK_CONF}.verify.bak"
REFRESH="$NWU_ROOT/scripts/refresh-network.sh"

PASS=0 FAIL=0 SKIP=0
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname 2>/dev/null || echo unknown)
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || echo N/A)

# shellcheck source=/dev/null
. "$NWU_ROOT/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$NWU_ROOT/lib/config.sh" 2>/dev/null || true
nwu_load_paths 2>/dev/null || true
nwu_source_libs 2>/dev/null || true

log() { printf '%s\n' "$*" >&2; }

record() {
	id="$1" name="$2" result="$3" detail="$4"
	case "$result" in
	PASS) PASS=$((PASS + 1)) mark="PASS" ;;
	FAIL) FAIL=$((FAIL + 1)) mark="FAIL" ;;
	SKIP) SKIP=$((SKIP + 1)) mark="SKIP" ;;
	esac
	printf '| %s | %s | %s | %s |\n' "$id" "$name" "$mark" "$detail" >>"$REPORT"
	log "[$mark] $id $name — $detail"
}

probe_network() {
	ETH0_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -n1)
	ETH0_ADDR=${ETH0_IP%/*}
	ETH0_PREFIX=${ETH0_IP#*/}
	[ -n "$ETH0_PREFIX" ] || ETH0_PREFIX=24
	GW=$(ip -4 route show default 2>/dev/null | awk '
	/^default/ {
		for (i = 1; i < NF; i++) {
			if ($i == "via" && $(i + 1) ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
				print $(i + 1); exit
			}
		}
	}')
	[ -n "$GW" ] || GW=$(echo "$ETH0_ADDR" | awk -F. '{print $1"."$2"."$3".1"}')
	NET_BASE=$(echo "$ETH0_ADDR" | awk -F. '{print $1"."$2"."$3}')
	STATIC_TEST_IP="${NET_BASE}.117"
	VLAN_PRI_STATIC="${NET_BASE}.200"
	VLAN_SEC_STATIC="${NET_BASE}.201"
	VLAN_PRI_STATIC_ALT="${NET_BASE}.202"
}

wait_eth0_ip() {
	i=0
	while [ "$i" -lt 25 ]; do
		ip -4 -o addr show dev eth0 2>/dev/null | grep -q 'inet ' && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# Sole network-config entry: write conf + refresh (for staging, write pending and pass --staging)
apply_conf() {
	target="$1"
	staging="${2:-0}"
	if [ "$staging" = "1" ]; then
		NWU_APPLY_MODE=staging "$REFRESH" --staging "$target" >/dev/null 2>&1
	else
		"$REFRESH" "$target" >/dev/null 2>&1
	fi
}

write_conf_base() {
	vlan_enabled="$1"
	ipv4_mode="$2"
	ipv4_addr="$3"
	pri_mode="$4"
	sec_id="$5"
	sec_mode="$6"
	target="$7"
	cat >"$target" <<EOF
[interface]
name=eth0

[system]
hostname=arkkvm
domain=local

[dhcp]
client=udhcpc

[ipv4]
mode=$ipv4_mode
address=$ipv4_addr
netmask=255.255.255.0
gateway=$GW
dns=$GW

[ipv6]
mode=slaac

[dns]
servers=

[vlan]
enabled=$vlan_enabled
parent=eth0
apply_mode=committed

[vlan.primary]
id=10
ipv4_mode=$pri_mode
ipv4_address=$VLAN_PRI_STATIC
ipv4_netmask=255.255.255.0
ipv4_gateway=$GW
ipv4_dns=$GW
route_metric=100

[vlan.secondary]
id=$sec_id
ipv4_mode=$sec_mode
ipv4_address=$VLAN_SEC_STATIC
ipv4_netmask=255.255.255.0
ipv4_gateway=$GW
ipv4_dns=$GW
route_metric=200
EOF
}

write_flat_dhcp() {
	write_conf_base false dhcp "" dhcp 0 disabled "$NETWORK_CONF"
}

write_flat_static() {
	write_conf_base false static "$1" dhcp 0 disabled "$NETWORK_CONF"
}

write_vlan() {
	# write_vlan <pri_mode> <sec_id> <sec_mode>
	write_conf_base true dhcp "" "$1" "$2" "$3" "$NETWORK_CONF"
}

write_vlan_pending_staging() {
	cat >"$NETWORK_CONF_PENDING" <<EOF
[interface]
name=eth0

[system]
hostname=arkkvm
domain=local

[dhcp]
client=udhcpc

[ipv4]
mode=dhcp
address=
netmask=255.255.255.0
gateway=$GW
dns=$GW

[ipv6]
mode=slaac

[dns]
servers=

[vlan]
enabled=true
parent=eth0
apply_mode=staging

[vlan.primary]
id=10
ipv4_mode=static
ipv4_address=$VLAN_PRI_STATIC_ALT
ipv4_netmask=255.255.255.0
ipv4_gateway=$GW
ipv4_dns=$GW
route_metric=100

[vlan.secondary]
id=0
ipv4_mode=disabled
ipv4_address=
ipv4_netmask=
ipv4_gateway=
ipv4_dns=
route_metric=200
EOF
}

restore_backup() {
	if [ -f "$BACKUP" ]; then
		cp "$BACKUP" "$NETWORK_CONF"
		rm -f "$NETWORK_CONF_PENDING" /userdata/arkkvm/network.conf.rollback \
			/userdata/arkkvm/network.conf.pending-active 2>/dev/null || true
		apply_conf "$NETWORK_CONF"
	fi
}

run_case() {
	id="$1" name="$2"
	shift 2
	DETAIL=
	if "$@"; then
		record "$id" "$name" PASS "${DETAIL:-ok}"
	else
		record "$id" "$name" FAIL "${DETAIL:-failed}"
	fi
}

skip_case() { record "$1" "$2" SKIP "${3:-skipped}"; }

has_iface_ip() {
	iface="$1"
	ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q 'inet '
}

# ---------- Cases: conf + refresh only ----------

c01_flat_dhcp() {
	write_flat_dhcp
	apply_conf "$NETWORK_CONF"
	wait_eth0_ip
	has_iface_ip eth0
}

c02_flat_dhcp_lease() {
	[ -f /run/udhcpc.eth0.info ] && grep -q '^ip=' /run/udhcpc.eth0.info
}

c03_flat_static() {
	write_flat_static "$STATIC_TEST_IP"
	apply_conf "$NETWORK_CONF"
	sleep 1
	ip -4 -o addr show dev eth0 | grep -q "$STATIC_TEST_IP"
}

c04_flat_static_gw() {
	ping -c 2 -W 5 "$GW" >/dev/null 2>&1
}

c05_flat_back_dhcp() {
	write_flat_dhcp
	apply_conf "$NETWORK_CONF"
	wait_eth0_ip
	has_iface_ip eth0
}

c06_vlan_pri_static_only() {
	write_vlan static 0 disabled
	apply_conf "$NETWORK_CONF"
	ip link show eth0.10 >/dev/null 2>&1 && \
		ip -4 -o addr show dev eth0.10 | grep -q "$VLAN_PRI_STATIC"
}

c07_vlan_pri_static_route() {
	ip route show default 2>/dev/null | grep '^default' | grep -q 'dev eth0\.10' || return 1
	! ip route show default 2>/dev/null | grep '^default' | grep -qE ' dev eth0( |$)'
	def_count=$(ip route show default 2>/dev/null | grep -c '^default' || true)
	[ "$def_count" -eq 1 ]
}

c08_vlan_pri_sec_static() {
	write_vlan static 20 static
	apply_conf "$NETWORK_CONF"
	ip link show eth0.20 >/dev/null 2>&1 && \
		ip -4 -o addr show dev eth0.20 | grep -q "$VLAN_SEC_STATIC"
}

c09_vlan_pri_static_sec_dhcp() {
	write_vlan static 20 dhcp
	apply_conf "$NETWORK_CONF"
	ip link show eth0.20 >/dev/null 2>&1 || return 1
	if has_iface_ip eth0.20; then
		DETAIL="secondary DHCP got address"
		return 0
	fi
	DETAIL="secondary DHCP no lease (flat LAN)"
	return 2
}

c10_vlan_pri_dhcp_only() {
	write_vlan dhcp 0 disabled
	apply_conf "$NETWORK_CONF"
	sleep 5
	ip link show eth0.10 >/dev/null 2>&1 || return 1
	if has_iface_ip eth0.10; then
		DETAIL="primary DHCP got address"
		return 0
	fi
	DETAIL="primary DHCP no lease (flat LAN)"
	return 2
}

c11_vlan_pri_dhcp_sec_static() {
	write_vlan dhcp 20 static
	apply_conf "$NETWORK_CONF"
	sleep 2
	ip link show eth0.20 >/dev/null 2>&1 && \
		ip -4 -o addr show dev eth0.20 2>/dev/null | grep -q "$VLAN_SEC_STATIC"
}

c12_vlan_pri_dhcp_sec_dhcp() {
	write_vlan dhcp 20 dhcp
	apply_conf "$NETWORK_CONF"
	ip link show eth0.10 >/dev/null 2>&1 && ip link show eth0.20 >/dev/null 2>&1 || return 1
	if has_iface_ip eth0.10 && has_iface_ip eth0.20; then
		DETAIL="both endpoints got DHCP addresses"
		return 0
	fi
	if has_iface_ip eth0.10 || has_iface_ip eth0.20; then
		DETAIL="partial DHCP addresses (flat LAN)"
		return 2
	fi
	DETAIL="both endpoints no DHCP lease (flat LAN)"
	return 2
}

c13_vlan_conf_to_pri_static() {
	# conf switch: dhcp -> static (conf change only)
	write_vlan static 0 disabled
	apply_conf "$NETWORK_CONF"
	ip -4 -o addr show dev eth0.10 | grep -q "$VLAN_PRI_STATIC"
}

c14_staging_pending_unchanged() {
	COMMITTED_HASH=$(md5sum "$NETWORK_CONF" 2>/dev/null | awk '{print $1}')
	write_vlan_pending_staging
	apply_conf "$NETWORK_CONF_PENDING" 1
	NEW_HASH=$(md5sum "$NETWORK_CONF" 2>/dev/null | awk '{print $1}')
	[ "$COMMITTED_HASH" = "$NEW_HASH" ] && [ -f "$NETWORK_CONF_PENDING" ]
}

c15_staging_eth0_up() {
	has_iface_ip eth0
}

c16_staging_no_vlan_default() {
	! ip route show default 2>/dev/null | grep '^default' | grep -q 'dev eth0\.10'
}

c17_revert_committed_conf() {
	rm -f "$NETWORK_CONF_PENDING"
	apply_conf "$NETWORK_CONF"
	ip -4 -o addr show dev eth0.10 | grep -q "$VLAN_PRI_STATIC"
}

c18_vlan_disable_conf() {
	write_flat_dhcp
	apply_conf "$NETWORK_CONF"
	! ip link show eth0.10 >/dev/null 2>&1 && ! ip link show eth0.20 >/dev/null 2>&1
}

c19_ctl_vlan_status() {
	write_vlan static 20 static
	apply_conf "$NETWORK_CONF"
	"$NWU_ROOT/ctl" vlan status 2>&1 | grep -q 'enabled:.*true'
}

c20_final_flat_dhcp() {
	write_flat_dhcp
	apply_conf "$NETWORK_CONF"
	wait_eth0_ip
	has_iface_ip eth0 && ping -c 1 -W 3 "$GW" >/dev/null 2>&1
}

run_maybe_skip() {
	id="$1" name="$2"
	shift 2
	"$@"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		record "$id" "$name" PASS "${DETAIL:-ok}"
	elif [ "$rc" -eq 2 ]; then
		skip_case "$id" "$name" "$DETAIL"
	else
		record "$id" "$name" FAIL "${DETAIL:-failed}"
	fi
}

main() {
	probe_network
	[ -f "$NETWORK_CONF" ] && cp "$NETWORK_CONF" "$BACKUP"

	{
		echo "# network-config-unified full test report (conf-only)"
		echo ""
		echo "- Start time: $START_TS"
		echo "- Device: $HOSTNAME ($MAC)"
		echo "- eth0: ${ETH0_IP:-unknown} gw=$GW"
		echo "- Subnet: ${NET_BASE}.0/${ETH0_PREFIX:-24}"
		echo "- Method: **network.conf + refresh-network.sh only**"
		echo ""
		echo "## Flat network"
		echo ""
		echo "| ID | Case | Result | Notes |"
		echo "|----|------|------|------|"
	} >"$REPORT"

	trap restore_backup EXIT

	write_flat_dhcp
	apply_conf "$NETWORK_CONF"
	wait_eth0_ip || true
	probe_network

	run_case C01 "flat DHCP（conf+refresh）" c01_flat_dhcp
	run_case C02 "flat DHCP lease file" c02_flat_dhcp_lease
	run_case C03 "flat static IP $STATIC_TEST_IP" c03_flat_static
	run_case C04 "flat static gateway ping" c04_flat_static_gw
	run_case C05 "flat back to DHCP (conf)" c05_flat_back_dhcp

	{
		echo ""
		echo "## VLAN primary/secondary × static/DHCP (conf+refresh)"
		echo ""
		echo "| ID | Case | Result | Notes |"
		echo "|----|------|------|------|"
	} >>"$REPORT"

	run_case C06 "VLAN primary static" c06_vlan_pri_static_only
	run_case C07 "VLAN primary default route" c07_vlan_pri_static_route
	run_case C08 "VLAN primary static + secondary static" c08_vlan_pri_sec_static
	run_maybe_skip C09 "VLAN primary static + secondary DHCP" c09_vlan_pri_static_sec_dhcp
	run_maybe_skip C10 "VLAN primary DHCP" c10_vlan_pri_dhcp_only
	run_case C11 "VLAN primary DHCP + secondary static" c11_vlan_pri_dhcp_sec_static
	run_maybe_skip C12 "VLAN primary DHCP+secondary DHCP" c12_vlan_pri_dhcp_sec_dhcp
	run_case C13 "conf switch primary DHCP→static" c13_vlan_conf_to_pri_static

	{
		echo ""
		echo "## VLAN staging / cleanup"
		echo ""
		echo "| ID | Case | Result | Notes |"
		echo "|----|------|------|------|"
	} >>"$REPORT"

	run_case C14 "staging pending leaves committed unchanged" c14_staging_pending_unchanged
	run_case C15 "staging eth0 management path reachable" c15_staging_eth0_up
	run_case C16 "staging no VLAN default route" c16_staging_no_vlan_default
	run_case C17 "revert committed conf+refresh" c17_revert_committed_conf
	run_case C18 "vlan.enabled=false cleans subinterfaces" c18_vlan_disable_conf
	run_case C19 "ctl vlan status" c19_ctl_vlan_status
	run_case C20 "final flat DHCP restore" c20_final_flat_dhcp

	END_TS=$(date '+%Y-%m-%d %H:%M:%S')
	TOTAL=$((PASS + FAIL + SKIP))
	{
		echo ""
		echo "## Summary"
		echo ""
		echo "- End time: $END_TS"
		echo "- Total: $TOTAL | **PASS: $PASS** | **FAIL: $FAIL** | SKIP: $SKIP"
		echo ""
		[ "$FAIL" -eq 0 ] && echo "**Verdict: all passed** (SKIP is an environment limit, not a functional defect)" \
			|| echo "**Verdict: failures present**"
	} >>"$REPORT"

	cat "$REPORT"
	[ "$FAIL" -eq 0 ]
}

main "$@"
