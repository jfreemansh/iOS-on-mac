#!/bin/zsh
# ramdisk_send_vm.sh — variant of upstream ramdisk_send.sh for virtual devices.
#
# After iBSS is sent the VM briefly disconnects and re-enumerates the USB
# device (DFU → iBSS/recovery mode).  On real hardware irecovery reconnects
# instantly; on the VM the re-enumeration takes a few seconds so we poll
# for the device explicitly before sending iBEC.
#
# Usage:
#   IRECOVERY=/path/to/irecovery zsh ramdisk_send_vm.sh <Ramdisk_dir>
#
# Environment:
#   IRECOVERY       — irecovery binary (default: irecovery)
#   IBSS_POLL_SECS  — max seconds to wait for device after iBSS (default: 30)
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
RAMDISK_DIR="${1:-Ramdisk}"
IBSS_POLL_SECS="${IBSS_POLL_SECS:-30}"

if [ ! -d "$RAMDISK_DIR" ]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

# Poll until irecovery sees any device (DFU or recovery) or timeout
_wait_device() {
    local label="$1" max="$2"
    echo "  [*] Waiting for device ($label, up to ${max}s)..."
    local i=0
    while [[ $i -lt $max ]]; do
        if "$IRECOVERY" -q &>/dev/null 2>&1; then
            echo "  [*] Device ready after ${i}s ($label)"
            return 0
        fi
        sleep 1
        (( i++ )) || true
    done
    echo "  [!] Device not seen after ${max}s ($label) — attempting anyway"
    return 1
}

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. iBSS — after upload the VM executes it and re-enumerates USB
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

# Poll for device re-enumeration after iBSS (may take several seconds on VM)
_wait_device "post-iBSS" "$IBSS_POLL_SECS" || true

# 2. iBEC + go
echo "  [2/8] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"
"$IRECOVERY" -c go

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
