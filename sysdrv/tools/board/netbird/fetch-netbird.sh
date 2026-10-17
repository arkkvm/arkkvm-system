#!/bin/sh
#
# Fetch the pinned NetBird client release for ArkKVM (RV1106, ARMv7) and place it
# into the rootfs overlay at oem/usr/bin/netbird/netbird.
#
# NetBird's release binary is a static Go build (CGO_ENABLED=0, GOARM=6), so it
# runs on the uClibc userspace without additional libraries.
#
# Usage: sysdrv/tools/board/netbird/fetch-netbird.sh [--force]
#
# To bump the version, update NETBIRD_VERSION and NETBIRD_SHA256 from
# https://github.com/netbirdio/netbird/releases/download/v<ver>/netbird_<ver>_checksums.txt
#

set -eu

NETBIRD_VERSION="0.81.2"
NETBIRD_SHA256="fb7702adae6b9fde723c94a2cca1217ab9a13160efcdc5f8ba72beaa6be61f7c"
NETBIRD_ARCHIVE="netbird_${NETBIRD_VERSION}_linux_armv6.tar.gz"
NETBIRD_URL="https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/${NETBIRD_ARCHIVE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../rootfs/oem/usr/bin/netbird"
DEST_BIN="$DEST_DIR/netbird"
VERSION_FILE="$DEST_DIR/VERSION"

if [ "${1:-}" != "--force" ] && [ -x "$DEST_BIN" ] && [ -f "$VERSION_FILE" ] \
	&& [ "$(cat "$VERSION_FILE")" = "$NETBIRD_VERSION" ]; then
	echo "[NetBird] $NETBIRD_VERSION already present at $DEST_BIN"
	exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo "[NetBird] Downloading $NETBIRD_URL"
curl -fsSL -o "$TMP_DIR/$NETBIRD_ARCHIVE" "$NETBIRD_URL"

echo "$NETBIRD_SHA256  $TMP_DIR/$NETBIRD_ARCHIVE" | sha256sum -c -

tar -xzf "$TMP_DIR/$NETBIRD_ARCHIVE" -C "$TMP_DIR" netbird LICENSE LICENSES

mkdir -p "$DEST_DIR"
install -m 0755 "$TMP_DIR/netbird" "$DEST_BIN"
# Ship the license texts alongside the binary (BSD-3-Clause client, see LICENSE).
cp "$TMP_DIR/LICENSE" "$DEST_DIR/LICENSE"
cp -r "$TMP_DIR/LICENSES" "$DEST_DIR/"
printf '%s\n' "$NETBIRD_VERSION" > "$VERSION_FILE"

echo "[NetBird] Installed $NETBIRD_VERSION to $DEST_BIN ($(du -h "$DEST_BIN" | cut -f1))"
