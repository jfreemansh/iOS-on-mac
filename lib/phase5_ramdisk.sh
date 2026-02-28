#!/bin/bash
# lib/phase5_ramdisk.sh — Restore + SSH ramdisk via upstream Makefile targets

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + Restore + SSH Ramdisk"
    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"
    setup_cleanup_trap

    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local iproxy_bin="$vphone_dir/.limd/bin/iproxy"
    [[ ! -x "$iproxy_bin" ]] && iproxy_bin="$(command -v iproxy 2>/dev/null)"
    [[ -z "$iproxy_bin" ]] && { error "iproxy not found"; return 1; }

    # -------------------------------------------------------------------------
    # Step A: Full restore
    # -------------------------------------------------------------------------
    section "Step A: Full iOS restore"
    info "This requires TWO terminals running simultaneously."
    echo
    echo "  TERMINAL 1 — start VM in DFU mode:"
    echo "    cd \"$vphone_dir\" && make boot_dfu VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  TERMINAL 2 — once VM shows 'VM started in DFU mode', run restore:"
    echo "    cd \"$vphone_dir\" && make restore_get_shsh VM_DIR=\"$VM_DIR\""
    echo "    cd \"$vphone_dir\" && make restore VM_DIR=\"$VM_DIR\""
    echo
    echo "  Wait for restore to complete (progress bar reaches 100%)."
    echo "  Then kill Terminal 1 (Ctrl-C) and wait a few seconds."
    echo
    read -r -p "Press ENTER when restore is complete and Terminal 1 is stopped: "

    success "Restore complete!"

    # -------------------------------------------------------------------------
    # Step B: SSH ramdisk boot
    # -------------------------------------------------------------------------
    section "Step B: SSH ramdisk boot"
    info "This again requires TWO terminals running simultaneously."
    echo
    echo "  TERMINAL 1 — start VM in DFU mode:"
    echo "    cd \"$vphone_dir\" && make boot_dfu VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  TERMINAL 2 — once VM shows 'VM started in DFU mode', send ramdisk:"
    echo "    cd \"$vphone_dir\" && make ramdisk_send VM_DIR=\"$VM_DIR\""
    echo
    echo "  Wait for ramdisk_send to complete (shows 'Boot sequence complete')."
    echo "  Leave Terminal 1 running — the VM must stay up for SSH."
    echo
    read -r -p "Press ENTER when ramdisk_send is complete: "

    success "Ramdisk boot chain sent!"

    # -------------------------------------------------------------------------
    # iproxy + SSH wait
    # -------------------------------------------------------------------------
    pkill -f "iproxy 2222" 2>/dev/null || true
    "$iproxy_bin" 2222 22 >/dev/null 2>&1 &
    register_pid $!
    echo $! > "$WORK_DIR/.iproxy_ramdisk_pid"

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
