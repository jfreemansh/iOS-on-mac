#!/bin/zsh
# ramdisk_send_vm.sh — variant of upstream ramdisk_send.sh for virtual devices.
#
# Mirrors upstream ramdisk_send.sh exactly: iBSS and iBEC are sent back-to-back
# with no polling wait in between.  In the virtual device the DFU connection
# stays open (or re-enumerates fast enough) that an immediate iBEC send works.
# Inserting a polling wait between iBSS and iBEC causes "Unable to connect to
# device" because irecovery -q hangs ~7 s per attempt and the device moves on.
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

# 1. iBSS — send immediately, do NOT poll/wait before iBEC
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

# 2. iBEC + go — send file and issue 'go' in one irecovery session.
# A separate '-c go' call would need to reconnect after the file transfer, but
# the device transitions USB state immediately after iBEC loads and the new
# connection attempt fails. Combining -f and -c into one call avoids the
# reconnect and issues 'go' on the same already-open connection.
echo "  [2/8] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4" -c go

sleep 1

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
