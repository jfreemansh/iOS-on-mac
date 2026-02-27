#!/bin/zsh
# ramdisk_send_vm.sh — variant of upstream ramdisk_send.sh for virtual devices.
#
# On real hardware irecovery's internal USB reconnect logic catches the
# DFU→recovery transition immediately after iBSS.  On the VM the re-
# enumeration takes an extra second, so a short sleep is needed between
# iBSS and iBEC.  Everything else is identical to upstream ramdisk_send.sh.
#
# Usage:
#   IRECOVERY=/path/to/irecovery zsh ramdisk_send_vm.sh <Ramdisk_dir>
#
# Environment:
#   IRECOVERY   — path to irecovery binary (default: irecovery)
#   IBSS_SLEEP  — seconds to wait after iBSS before sending iBEC (default: 3)
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-Ramdisk}"
IBSS_SLEEP="${IBSS_SLEEP:-3}"

if [ ! -d "$RAMDISK_DIR" ]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. Load iBSS — device re-enumerates after this; sleep lets the VM catch up
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

echo "  [*] Waiting ${IBSS_SLEEP}s for VM to re-enumerate after iBSS..."
sleep "$IBSS_SLEEP"

# 2. Load iBEC + go
echo "  [2/8] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"
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

# Boot
echo "  [*] Booting kernel..."
"$IRECOVERY" -f "$RAMDISK_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo "[+] Boot sequence complete. Device should be booting into ramdisk."
