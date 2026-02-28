#!/bin/zsh
# lib/ramdisk_send_wrapper.sh — Mirrors upstream ramdisk_send.sh with a timing fix.
#
# Upstream ramdisk_send.sh has no delay between iBSS and iBEC. After iBSS loads,
# the virtual device re-enumerates from DFU → Recovery mode and irecovery needs a
# moment before it can reconnect. This wrapper adds that sleep.
#
# Does NOT modify any upstream vphone-cli files.
#
# Usage:
#   IRECOVERY=/path/to/irecovery zsh ramdisk_send_wrapper.sh /path/to/Ramdisk

set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-Ramdisk}"

if [ ! -d "$RAMDISK_DIR" ]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    exit 1
fi

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. Load iBSS — device transitions DFU → Recovery after this
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

echo "  [*] Waiting for device to re-enumerate in Recovery mode..."
sleep 3

# 2. Load iBEC — retry until device is visible (re-enumeration timing varies)
echo "  [2/8] Loading iBEC..."
_ibec_ok=false
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    echo "    attempt $_attempt/10..."
    if "$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4" 2>/dev/null; then
        _ibec_ok=true
        break
    fi
    sleep 3
done
if ! $_ibec_ok; then
    echo "[-] iBEC: Unable to connect after 10 attempts"
    exit 1
fi
"$IRECOVERY" -c go

sleep 1

# 3. Load SPTM
echo "  [3/8] Loading SPTM..."
"$IRECOVERY" -f "$RAMDISK_DIR/sptm.vresearch1.release.img4"
"$IRECOVERY" -c firmware

# 4. Load TXM
echo "  [4/8] Loading TXM..."
"$IRECOVERY" -f "$RAMDISK_DIR/txm.img4"
"$IRECOVERY" -c firmware

# 5. Load trustcache
echo "  [5/8] Loading trustcache..."
"$IRECOVERY" -f "$RAMDISK_DIR/trustcache.img4"
"$IRECOVERY" -c firmware

# 6. Load ramdisk
echo "  [6/8] Loading ramdisk..."
"$IRECOVERY" -f "$RAMDISK_DIR/ramdisk.img4"
sleep 2
"$IRECOVERY" -c ramdisk

# 7. Load device tree
echo "  [7/8] Loading device tree..."
"$IRECOVERY" -f "$RAMDISK_DIR/DeviceTree.vphone600ap.img4"
"$IRECOVERY" -c devicetree

# 8. Load SEP
echo "  [8/8] Loading SEP..."
"$IRECOVERY" -f "$RAMDISK_DIR/sep-firmware.vresearch101.RELEASE.img4"
"$IRECOVERY" -c firmware

# 9. Load kernel and boot
echo "  [*] Booting kernel..."
"$IRECOVERY" -f "$RAMDISK_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo "[+] Boot sequence complete. Device should be booting into ramdisk."
