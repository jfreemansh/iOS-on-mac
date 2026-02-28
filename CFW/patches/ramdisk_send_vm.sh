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

# 1. iBSS — send, then wait for device re-enumeration with a fixed sleep.
# After iBSS loads the VM briefly disconnects and re-enumerates (DFU→recovery).
# irecovery -q hangs ~7s per attempt so we use a plain sleep instead of polling.
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"
echo "  [*] Waiting for re-enumeration after iBSS (15s)..."
sleep 15
echo "  [*] USB devices visible now:"
system_profiler SPUSBDataType 2>/dev/null | grep -E "Apple|0x05ac|Product ID|Vendor ID" | sed 's/^/      /' || true
echo "  [*] Serial log tail:"
tail -5 /Users/john/ios-vm/VM/serial_phase5.log 2>/dev/null | sed 's/^/      /' || echo "      (empty)"
echo "  [*] vphone-cli process:"
pgrep -a vphone-cli 2>/dev/null | sed 's/^/      /' || echo "      (not running!)"

# 2. iBEC + go — send file and issue 'go' in one irecovery session.
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
