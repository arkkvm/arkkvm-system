#!/bin/sh
# Install init/S16network to /etc/init.d/
set -e

NWU_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SRC="$NWU_ROOT/init/S16network"
DEST="${1:-/etc/init.d/S16network}"
DEFAULTS="/etc/default/network-unified"

if [ "$(id -u)" -ne 0 ]; then
	echo "Need root: sudo $0" >&2
	exit 1
fi

[ -f "$SRC" ] || { echo "Missing $SRC" >&2; exit 1; }

cp "$SRC" "$DEST"
chmod 755 "$DEST"

if [ ! -f "$DEFAULTS" ]; then
	mkdir -p "$(dirname "$DEFAULTS")"
	cat >"$DEFAULTS" <<EOF
# network-config-unified boot autostart config
NWU_ROOT=$NWU_ROOT
NETWORK_CONF=/userdata/arkkvm/network.conf
USERDATA_DIR=/userdata/arkkvm
WAIT_USERDATA_SEC=30
EOF
	echo "Wrote $DEFAULTS"
fi

echo "Installed: $DEST"
echo ""
echo "Suggested:"
echo "  1. Confirm NWU_ROOT in $DEFAULTS is correct (often /oem/usr/bin/arkkvm-network on device)"
echo "  2. Remove legacy DHCP scripts (if present):"
echo "       rm -f /etc/init.d/S15dhcpcd 2>/dev/null || true"
echo "  3. Test: $DEST start"
echo "  4. Reboot to verify"
