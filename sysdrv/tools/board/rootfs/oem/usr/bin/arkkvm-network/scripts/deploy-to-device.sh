#!/bin/sh
# Deploy network-config-unified to ArkKVM device
#
# Access methods:
#   Day-to-day/fallback: serial minicom → /dev/cu.usbserial-120  (115200 8N1, root/ArkKVM)
#   Deploy/verify: SSH → ssh -i ~/.ssh/procscope_ed25519 root@$DEVICE_IP
#
# Usage:
#   DEVICE_IP=192.168.5.116 ./scripts/deploy-to-device.sh
#   ./scripts/deploy-to-device.sh 192.168.5.116

set -e

NWU_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEVICE_IP="${1:-${DEVICE_IP:-192.168.5.116}}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/procscope_ed25519}"
REMOTE_DEST="${REMOTE_DEST:-/oem/usr/bin/arkkvm-network}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=8"

echo "======== deploy network-config-unified ========"
echo "Device: root@$DEVICE_IP"
echo "Target: $REMOTE_DEST"
echo "Key:    $SSH_KEY"
echo "Serial: /dev/cu.usbserial-120 (fallback when SSH unreachable)"
echo "============================================="

if ! ssh $SSH_OPTS "root@$DEVICE_IP" 'echo ssh_ok'; then
	echo "Error: SSH connection failed. Confirm Mac and device share a subnet, or check IP via serial." >&2
	exit 1
fi

rsync -avz --delete -e "ssh $SSH_OPTS" \
	--exclude '.test-run' --exclude '.git' --exclude 'test-report-*.md' \
	"$NWU_ROOT/" "root@$DEVICE_IP:$REMOTE_DEST/"

ssh $SSH_OPTS "root@$DEVICE_IP" "
	find $REMOTE_DEST -type f \( -name 'ctl' -o -name '*.sh' -o -name '*.script' -o -path '*/init/S16network' \) -exec chmod +x {} +
	rm -f /etc/init.d/S15dhcpcd /etc/init.d/K15dhcpcd.disabled /etc/init.d/S16network-unified 2>/dev/null || true
	$REMOTE_DEST/scripts/install-init.sh /etc/init.d/S16network 2>/dev/null || true
	chmod +x /etc/init.d/S16network 2>/dev/null || true
	lsmod | grep -q 8021q && echo '8021q: loaded' || echo '8021q: not loaded (modprobe 8021q on refresh)'
	$REMOTE_DEST/ctl conf /userdata/arkkvm/network.conf 2>/dev/null | head -5 || true
"

echo "[done] Deployed to root@$DEVICE_IP:$REMOTE_DEST"
