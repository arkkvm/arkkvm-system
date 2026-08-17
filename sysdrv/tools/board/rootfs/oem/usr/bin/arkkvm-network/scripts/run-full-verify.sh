#!/bin/sh
# One-shot from Mac: local tests → deploy → on-device full verify → fetch report
set -e

NWU_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEVICE_IP="${1:-${DEVICE_IP:-192.168.5.116}}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/procscope_ed25519}"
SERIAL_PORT="${SERIAL_PORT:-/dev/cu.usbserial-120}"
REPORT_LOCAL="${REPORT_LOCAL:-$NWU_ROOT/test-report-$(date +%Y%m%d-%H%M%S).md}"
LATEST_REPORT="$NWU_ROOT/test-report-latest.md"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=8"

echo "======== network-config-unified full verification ========"
echo "Local:  $NWU_ROOT"
echo "Device: root@$DEVICE_IP"
echo "Report: $REPORT_LOCAL"
echo "=================================================="

echo ""
echo ">>> [1/3] Local dry-run tests"
if ! "$NWU_ROOT/ctl" test; then
	echo "Local tests failed, aborting" >&2
	exit 1
fi

echo ""
echo ">>> [2/3] Deploy to device"
DEVICE_IP="$DEVICE_IP" SSH_KEY="$SSH_KEY" "$NWU_ROOT/scripts/deploy-to-device.sh" "$DEVICE_IP"

ssh_ok=0
if ssh $SSH_OPTS "root@$DEVICE_IP" 'echo ok' >/dev/null 2>&1; then
	ssh_ok=1
fi

if [ "$ssh_ok" -eq 0 ]; then
	echo "SSH unreachable, trying serial probe..." >&2
	SERIAL_PY="/tmp/serialvenv/bin/python"
	if [ -x "$SERIAL_PY" ]; then
		"$SERIAL_PY" "$NWU_ROOT/scripts/lib/serial-probe.py" "$SERIAL_PORT" || true
	fi
	echo "Error: cannot SSH to $DEVICE_IP" >&2
	exit 1
fi

echo ""
echo ">>> [3/3] On-device verify (including VLAN)"
ssh $SSH_OPTS "root@$DEVICE_IP" "
	export NWU_ROOT=/oem/usr/bin/arkkvm-network
	export NWU_VERIFY_REPORT=/tmp/nwu-verify-report.md
	chmod +x \$NWU_ROOT/scripts/verify-device.sh
	\$NWU_ROOT/scripts/verify-device.sh
" || VERIFY_RC=$?

scp $SSH_OPTS "root@$DEVICE_IP:/tmp/nwu-verify-report.md" "$REPORT_LOCAL" 2>/dev/null || true
cp "$REPORT_LOCAL" "$LATEST_REPORT" 2>/dev/null || true

echo ""
echo "Report saved: $REPORT_LOCAL"
echo "Latest report: $LATEST_REPORT"
if [ -f "$REPORT_LOCAL" ]; then
	echo ""
	cat "$REPORT_LOCAL"
fi

exit "${VERIFY_RC:-0}"
