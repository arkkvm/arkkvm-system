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

# Mozilla CA bundle (curl.se extract). The rootfs ships no CA certificates, and
# NetBird (Go) needs them to verify TLS to the management/signal/relay servers.
# To bump: https://curl.se/docs/caextract.html
CA_BUNDLE_DATE="2026-09-25"
CA_BUNDLE_SHA256="a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505"
CA_BUNDLE_URL="https://curl.se/ca/cacert-${CA_BUNDLE_DATE}.pem"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../rootfs/oem/usr/bin/netbird"
DEST_BIN="$DEST_DIR/netbird"
VERSION_FILE="$DEST_DIR/VERSION"
STAMP="${NETBIRD_VERSION}+ca-${CA_BUNDLE_DATE}"

if [ "${1:-}" != "--force" ] && [ -x "$DEST_BIN" ] && [ -f "$VERSION_FILE" ] \
	&& [ -s "$DEST_DIR/cacert.pem" ] && [ "$(cat "$VERSION_FILE")" = "$STAMP" ]; then
	echo "[NetBird] $STAMP already present at $DEST_DIR"
	exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo "[NetBird] Downloading $NETBIRD_URL"
curl -fsSL -o "$TMP_DIR/$NETBIRD_ARCHIVE" "$NETBIRD_URL"

echo "$NETBIRD_SHA256  $TMP_DIR/$NETBIRD_ARCHIVE" | sha256sum -c -

tar -xzf "$TMP_DIR/$NETBIRD_ARCHIVE" -C "$TMP_DIR" netbird LICENSE LICENSES

echo "[NetBird] Downloading $CA_BUNDLE_URL"
curl -fsSL -o "$TMP_DIR/cacert.pem" "$CA_BUNDLE_URL"
echo "$CA_BUNDLE_SHA256  $TMP_DIR/cacert.pem" | sha256sum -c -

mkdir -p "$DEST_DIR"
install -m 0755 "$TMP_DIR/netbird" "$DEST_BIN"
# Ship the license texts alongside the binary (BSD-3-Clause client, see LICENSE).
cp "$TMP_DIR/LICENSE" "$DEST_DIR/LICENSE"
cp -r "$TMP_DIR/LICENSES" "$DEST_DIR/"
install -m 0644 "$TMP_DIR/cacert.pem" "$DEST_DIR/cacert.pem"
printf '%s\n' "$STAMP" > "$VERSION_FILE"

echo "[NetBird] Installed $STAMP to $DEST_DIR ($(du -h "$DEST_BIN" | cut -f1))"
