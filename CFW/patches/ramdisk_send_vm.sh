#!/bin/zsh
# ramdisk_send_vm.sh — variant of upstream ramdisk_send.sh for virtual devices.
#
# VF virtual USB devices are private-bus and do NOT appear in system_profiler.
# Use 'irecovery -q' with a bounded timeout (2s) to poll for the device after
# each DFU stage transition, rather than fixed sleeps or unbounded polls.
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

# Resolve a 'timeout' command: macOS may ship gtimeout (coreutils) or timeout.
# Falls back to a background-kill approach if neither is found.
_TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

# Poll for irecovery device using a bounded timeout per call.
# 'irecovery -q' hangs ~7s when no device is found; we cap it at 2s per attempt.
# VF virtual USB devices do NOT appear in system_profiler — must use irecovery.
_wait_device() {
    local label="$1" max_secs="$2"
    echo "  [*] Polling for device ($label, up to ${max_secs}s)..."
    local elapsed=0
    while [[ $elapsed -lt $max_secs ]]; do
        local rc=0
        if [[ -n "$_TIMEOUT" ]]; then
            "$_TIMEOUT" 2 "$IRECOVERY" -q &>/dev/null 2>&1 || rc=$?
        else
            # No timeout binary: run irecovery -q in background, kill after 2s
            "$IRECOVERY" -q &>/dev/null 2>&1 &
            local bg=$!
            sleep 2
            if kill -0 "$bg" 2>/dev/null; then
                # Still running after 2s = device not found; kill it
                kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
                rc=1
            else
                # Exited before 2s = device found (or errored)
                wait "$bg" 2>/dev/null; rc=$?
            fi
        fi
        if [[ $rc -eq 0 ]]; then
            echo "  [*] Device ready after ${elapsed}s ($label)"
            return 0
        fi
        sleep 0.5
        (( elapsed += 3 )) || true   # ~3s per attempt (2s timeout + 0.5s sleep + overhead)
    done
    echo "  [!] No device after ${max_secs}s ($label) — attempting anyway"
    return 1
}

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

# 1. iBSS — after upload the DFU device briefly disconnects and re-enumerates.
echo "  [1/8] Loading iBSS..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

# Wait for device to reappear after iBSS (DFU re-enumerates, window is brief).
_wait_device "post-iBSS" 15 || true

# 2. iBEC — send file (same DFU mode as iBSS).
echo "  [2/8] Loading iBEC..."
"$IRECOVERY" -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"

# After iBEC loads the device executes it and re-enumerates into recovery shell.
# Poll for recovery device before sending 'go'.
_wait_device "post-iBEC" 15 || true
"$IRECOVERY" -c go

# After 'go', device transitions again — poll before sending firmware.
_wait_device "post-go" 30 || true

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
