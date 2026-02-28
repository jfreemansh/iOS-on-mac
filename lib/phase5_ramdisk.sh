#!/bin/bash
# lib/phase5_ramdisk.sh — Restore + SSH ramdisk via upstream Makefile targets

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + Restore + SSH Ramdisk"
    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"
    setup_cleanup_trap

    # Kill any stale vphone-cli from a previous interrupted run — it holds
    # Disk.img/nvram.bin/SEPStorage locks and will cause Code=35 immediately.
    pkill -f "vphone-cli.*--dfu" 2>/dev/null || true
    sleep 2

    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local iproxy_bin="$vphone_dir/.limd/bin/iproxy"
    [[ ! -x "$iproxy_bin" ]] && iproxy_bin="$(command -v iproxy 2>/dev/null)"
    [[ -z "$iproxy_bin" ]] && { error "iproxy not found"; return 1; }

    # Thin wrapper: passes VM_DIR so all upstream targets resolve paths correctly
    _mk() {
        make -C "$vphone_dir" --no-print-directory \
            VM_DIR="$VM_DIR" CPU="${VM_CPU:-8}" MEMORY="${VM_MEMORY:-16384}" \
            "$@" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        return "${PIPESTATUS[0]}"
    }

    # Step A: restore
    # upstream: terminal 1 = make boot_dfu, terminal 2 = make restore
    # idevicerestore has built-in device retry so no sleep needed
    section "Step A: Full iOS restore"
    rm -f "$VM_DIR"/shsh/*.shsh "$VM_DIR"/shsh/*.shsh2 2>/dev/null || true
    _mk boot_dfu &
    local dfu_a=$!; register_pid "$dfu_a"
    _mk restore_get_shsh
    _mk restore; local rc=$?
    # Kill make AND its vphone-cli child — make doesn't propagate signals to children,
    # so vphone-cli would keep holding Disk.img/nvram.bin locks otherwise.
    kill "$dfu_a" 2>/dev/null
    pkill -f "vphone-cli.*--dfu" 2>/dev/null || true
    sleep 3  # wait for VZ file locks to be released
    wait "$dfu_a" 2>/dev/null
    [[ $rc -ne 0 ]] && { error "restore failed"; return 1; }
    success "Restore complete!"

    # Step B: ramdisk
    # upstream: terminal 1 = make boot_dfu, terminal 2 = make ramdisk_send
    # After each iBSS/iBEC stage the virtual USB device re-enumerates; irecovery
    # has no built-in retry, so we wrap it: retry up to 8x with 5s sleep.
    # Passed via IRECOVERY= make variable — upstream script untouched.
    local irecovery_real="$vphone_dir/.limd/bin/irecovery"
    local irecovery_wrap="$WORK_DIR/.irecovery_retry.sh"
    printf '#!/bin/bash\nfor i in $(seq 1 8); do\n  "%s" "$@" && exit 0\n  [ $i -lt 8 ] && sleep 5\ndone\nexit 1\n' \
        "$irecovery_real" > "$irecovery_wrap"
    chmod +x "$irecovery_wrap"

    section "Step B: SSH ramdisk boot"
    _mk boot_dfu &
    local dfu_b=$!; register_pid "$dfu_b"
    info "Waiting 15s for VM to present DFU device..."
    sleep 15
    _mk ramdisk_send IRECOVERY="$irecovery_wrap"; rc=$?
    kill "$dfu_b" 2>/dev/null
    pkill -f "vphone-cli.*--dfu" 2>/dev/null || true
    wait "$dfu_b" 2>/dev/null
    [[ $rc -ne 0 ]] && { error "ramdisk_send failed"; return 1; }
    success "Ramdisk boot chain sent!"

    # iproxy 2222->22 (cfw_install.sh expects SSH on localhost:2222)
    pkill -f "iproxy 2222" 2>/dev/null || true
    "$iproxy_bin" 2222 22 >/dev/null 2>&1 &
    register_pid $!; echo $! > "$WORK_DIR/.iproxy_ramdisk_pid"

    # Wait for SSH
    section "Waiting for SSH ramdisk (localhost:2222)"
    local up=false attempt
    for attempt in $(seq 1 60); do
        ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -p 2222 root@localhost "echo ok" 2>/dev/null && { up=true; break; }
        sleep 2
    done
    $up || { error "SSH ramdisk never came up"; return 1; }
    success "SSH ramdisk ready: ssh -p 2222 root@localhost"
    echo "localhost" > "$WORK_DIR/.vm_ip"
    echo "2222"      > "$WORK_DIR/.ssh_port"
    save_state "phase5"
}
