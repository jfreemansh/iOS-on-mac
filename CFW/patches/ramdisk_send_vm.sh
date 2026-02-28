#!/bin/zsh
# ramdisk_send_vm.sh — variant of upstream ramdisk_send.sh for virtual devices.
#
# Matches upstream ramdisk_send.sh exactly for iBSS/iBEC timing (no wait between
# them). The only difference: iBEC + go are sent in a single irecovery session
# via a recovery script (-e), avoiding a reconnect between -f and -c go.
#
# Usage:
#   IRECOVERY=/path/to/irecovery zsh ramdisk_send_vm.sh <Ramdisk_dir>
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-Ramdisk}"

if [ ! -d "$RAMDISK_DIR" ]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. iBSS — upload to DFU device (no wait after, matching upstream timing)
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

# 2. iBEC + go — use a recovery script so the file upload and 'go' command
# run in a SINGLE irecovery session. A separate '-c go' call requires a
# reconnect which fails because the device transitions state after iBEC loads.
echo "  [2/8] Loading iBEC..."
_ibec_script="$(mktemp /tmp/ibec_send.XXXXXX)"
printf '/send %s\ngo\n/exit\n' "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4" > "$_ibec_script"
"$IRECOVERY" -e "$_ibec_script"
rm -f "$_ibec_script"

# 3. SPTM
echo "  [3/8] Loading SPTM..."
"$IRECOVERY" -f "$RAMDISK_DIR/sptm.vresearch1.release.img4"
"$IRECOVERY" -c firmware

# 4. TXM
echo "  [4/8] Loading TXM..."
"$IRECOVERY" -f "$RAMDISK_DIR/txm.img4"
"$IRECOVERY" -c firmware

# 5. trustcache
echo "  [5/8] Loading trustcache..."
"$IRECOVERY" -f "$RAMDISK_DIR/trustcache.img4"
"$IRECOVERY" -c firmware

# 6. ramdisk
echo "  [6/8] Loading ramdisk..."
"$IRECOVERY" -f "$RAMDISK_DIR/ramdisk.img4"
sleep 2
"$IRECOVERY" -c ramdisk

# 7. DeviceTree
echo "  [7/8] Loading device tree..."
"$IRECOVERY" -f "$RAMDISK_DIR/DeviceTree.vphone600ap.img4"
"$IRECOVERY" -c devicetree

# 8. SEP
echo "  [8/8] Loading SEP..."
"$IRECOVERY" -f "$RAMDISK_DIR/sep-firmware.vresearch101.RELEASE.img4"
"$IRECOVERY" -c firmware

# Boot
echo "  [*] Booting kernel..."
"$IRECOVERY" -f "$RAMDISK_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo "[+] Boot sequence complete. Device should be booting into ramdisk."
