#!/bin/sh
###
 # @Purpose:
 # @Descripttion:
 # @version:
 # @Author: zhanglei
 # @Date: 2025-11-25 11:05:55
 # @LastEditors: wuhao
 # @LastEditTime: 2026-10-09 15:24:00
###
# Diagnostic artifact name, e.g. arkkvm-diagnostic-20251202-182430
DATE_TAG="$(date +%Y%m%d-%H%M%S)"
DIAGNOSTIC_NAME="arkkvm-diagnostic-${DATE_TAG}"
REKVM_BASE="/userdata/arkkvm"
# Product cap for /userdata/arkkvm/log is 50 MiB per app file; skip anything above that.
MAX_LOG_FILE_BYTES=52428800  # 50 MiB
# Device IP: prefer server_ip from SSH_CONNECTION, else from local interfaces
if [ -n "$SSH_CONNECTION" ]; then
  # SSH_CONNECTION format: client_ip client_port server_ip server_port
  set -- $SSH_CONNECTION
  SSH_IP="$3"
else
  # No SSH_CONNECTION: pick first IP from local interfaces (adjust iface name if needed)
  SSH_IP="$(ip addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
  [ -z "$SSH_IP" ] && SSH_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

[ -z "$SSH_IP" ] && SSH_IP="unknown_ip"

# Evidence artifact pattern: arkkvm-diagnostic-YYYYMMDD-HHMMSS.{zip,tgz} or staging dir
_EVIDENCE_PREFIX='arkkvm-diagnostic-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'

echo "Removing previous evidence archives and staging directories..."
for _old in "$REKVM_BASE"/*.zip "$REKVM_BASE"/*.tgz; do
  [ -f "$_old" ] || continue
  _base=$(basename "$_old")
  case "$_base" in
    $_EVIDENCE_PREFIX*)
      echo "Removing old archive: $_old"
      rm -f "$_old"
      ;;
  esac
done

for _old_dir in "$REKVM_BASE"/$_EVIDENCE_PREFIX*; do
  [ -d "$_old_dir" ] || continue
  echo "Removing old staging directory: $_old_dir"
  rm -rf "$_old_dir"
done

OUTPUT_DIR="${REKVM_BASE}/${DIAGNOSTIC_NAME}"
LOG_DIR="$OUTPUT_DIR/log"
# Archive name: prefer zip, fall back to tgz
ARCHIVE_NAME="${OUTPUT_DIR}.tgz"

echo "Creating output directory..."
mkdir -p "$LOG_DIR"

echo "Collecting arkkvm_ui file attributes..."
ls -lh /oem/usr/bin/arkkvm_ui > "$OUTPUT_DIR/ls_arkkvm_ui.log" 2>&1

echo "Exporting process list..."
ps aux > "$OUTPUT_DIR/ps.log" 2>&1

echo "Collecting system info..."
{
  echo "=== uname ==="
  uname -a
  echo ""
  echo "=== uptime ==="
  uptime
  echo ""
  echo "=== hostname ==="
  hostname
  echo ""
  echo "=== date ==="
  date
} > "$OUTPUT_DIR/sysinfo.log" 2>&1

echo "Collecting network info..."
{
  echo "=== ip addr ==="
  ip addr show 2>&1
  echo ""
  echo "=== ip route ==="
  ip route show 2>&1
  echo ""
  echo "=== arp -n ==="
  arp -n 2>&1
  echo ""
  echo "=== netstat -tnlp (all listening ports) ==="
  netstat -tnlp 2>&1
  echo ""
  echo "=== netstat -s (protocol statistics) ==="
  netstat -s 2>&1
} > "$OUTPUT_DIR/network_full.log" 2>&1

echo "Collecting firewall/iptables rules..."
{
  echo "=== iptables -L -n -v ==="
  iptables -L -n -v 2>&1
  echo ""
  echo "=== iptables -t nat -L -n -v ==="
  iptables -t nat -L -n -v 2>&1
} > "$OUTPUT_DIR/iptables.log" 2>&1

echo "Collecting USB device info..."
{
  echo "=== lsusb ==="
  lsusb 2>&1
  echo ""
  echo "=== /sys/kernel/config/usb_gadget ==="
  find /sys/kernel/config/usb_gadget -type f 2>/dev/null | while read -r _uf; do
    echo "--- $_uf ---"
    cat "$_uf" 2>/dev/null
  done
} > "$OUTPUT_DIR/usb_info.log" 2>&1

echo "Collecting arkkvm config files..."
{
  echo "=== /userdata/arkkvm/config ==="
  cat "$REKVM_BASE/config" 2>/dev/null || echo "file not found"
  echo ""
  echo "=== /userdata/arkkvm/config.json ==="
  cat "$REKVM_BASE/config.json" 2>/dev/null || echo "file not found"
  echo ""
  echo "=== /oem/etc/arkkvm* ==="
  find /oem/etc -name 'arkkvm*' -type f 2>/dev/null | while read -r _cf; do
    echo "--- $_cf ---"
    cat "$_cf" 2>/dev/null
  done
} > "$OUTPUT_DIR/arkkvm_config.log" 2>&1

echo "Copying arkkvm/log and arkkvm/logs..."

# /userdata/arkkvm/log (skip files over 50 MiB — above product per-app cap)
if [ -d "$REKVM_BASE/log" ]; then
  mkdir -p "$LOG_DIR/arkkvm_log"
  find "$REKVM_BASE/log" -maxdepth 3 -type f | while read -r _f; do
    _size=$(stat -c %s "$_f" 2>/dev/null || stat -f %z "$_f" 2>/dev/null)
    if [ -n "$_size" ] && [ "$_size" -gt "$MAX_LOG_FILE_BYTES" ]; then
      echo "   -> skip log/$(basename "$_f") (${_size} bytes > 50 MiB)"
      continue
    fi
    cp "$_f" "$LOG_DIR/arkkvm_log/" 2>/dev/null || true
  done
fi

# /userdata/arkkvm/logs
if [ -d "$REKVM_BASE/logs" ]; then
  mkdir -p "$LOG_DIR/arkkvm_logs"
  find "$REKVM_BASE/logs" -maxdepth 3 -type f | while read -r _f; do
    cp "$_f" "$LOG_DIR/arkkvm_logs/" 2>/dev/null || true
  done
fi

echo "Copying system log files..."
find /var/log -maxdepth 3 -type f | while read -r _f; do
  cp "$_f" "$LOG_DIR/" 2>/dev/null || true
done

echo "Collecting system error logs (OOM / crash / segfault)..."
dmesg | grep -Ei 'Killed|OOM|segfault|illegal|fault|panic|reset' > "$OUTPUT_DIR/dmesg_error.log" 2>&1

echo "Capturing system resource snapshot..."
free -h > "$OUTPUT_DIR/free.log"
df -h > "$OUTPUT_DIR/df.log"
timeout 5 top -b -n 1 > "$OUTPUT_DIR/top.log" 2>&1 \
  || ps aux --sort=-%cpu > "$OUTPUT_DIR/top.log" 2>&1 \
  || ps aux > "$OUTPUT_DIR/top.log" 2>&1

echo "Collecting HDMI status..."
if [ -f "/sys/kernel/debug/rk628/3-0050/hdmirx/status" ]; then
  cat /sys/kernel/debug/rk628/3-0050/hdmirx/status > "$OUTPUT_DIR/hdmi_status.log" 2>&1
  echo "HDMI status saved"
else
  echo "HDMI status file not found, skipped" > "$OUTPUT_DIR/hdmi_status.log"
fi

echo "Collecting RK628 debug parameters..."
{
  echo "=== rk628_csi debug parameter ==="
  if [ -f "/sys/module/rk628_csi/parameters/debug" ]; then
    cat /sys/module/rk628_csi/parameters/debug 2>&1
  else
    echo "file not found"
  fi
  echo ""
  echo "=== rk628 debug parameter ==="
  if [ -f "/sys/kernel/debug/rk628/3-0050/debug" ]; then
    cat /sys/kernel/debug/rk628/3-0050/debug 2>&1
  else
    echo "file not found"
  fi
} > "$OUTPUT_DIR/rk628_debug_params.log" 2>&1

echo "Archiving collected data..."

# Directory name without path prefix
DIR_NAME="${DIAGNOSTIC_NAME}"
_archive_ok=1

if command -v zip >/dev/null 2>&1; then
  echo "zip found, creating .zip archive..."
  ARCHIVE_NAME="${OUTPUT_DIR}.zip"
  cd "$REKVM_BASE" || exit 1
  zip -r "$ARCHIVE_NAME" "$DIR_NAME" >/dev/null 2>&1
  _archive_ok=$?
else
  # BusyBox tar has no -z; always pipe through gzip (works on GNU tar too).
  echo "zip not found, falling back to .tgz (tar | gzip)..."
  ARCHIVE_NAME="${OUTPUT_DIR}.tgz"
  cd "$REKVM_BASE" || exit 1
  if tar -cf - "$DIR_NAME" | gzip > "$ARCHIVE_NAME"; then
    _archive_ok=0
  else
    _archive_ok=1
    rm -f "$ARCHIVE_NAME"
  fi
fi

if [ "$_archive_ok" -eq 0 ] && [ -s "$ARCHIVE_NAME" ]; then
  rm -rf "$OUTPUT_DIR"
  echo "Removed staging directory: $OUTPUT_DIR"
else
  echo "Archive failed; staging directory kept: $OUTPUT_DIR" >&2
  exit 1
fi

echo "Done!"
echo "Archive path: $ARCHIVE_NAME"
echo ""
echo "Download to local machine (run on your workstation):"
echo "scp root@${SSH_IP}:${ARCHIVE_NAME} ~/Downloads/"
echo "$(basename "$ARCHIVE_NAME")"
