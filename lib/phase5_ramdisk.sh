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

    local _skip_restore=false
    local _shsh_file
    _shsh_file="$(find "$VM_DIR/shsh" -name "*.shsh" 2>/dev/null | head -1)"
    if [[ -n "$_shsh_file" ]]; then
        echo "  Existing SHSH blob found: $_shsh_file"
        read -r -p "  Restore already done? Skip Step A? [Y/n]: " _ans
        [[ "${_ans:-Y}" =~ ^[Yy]$ ]] && _skip_restore=true
    fi

    if ! $_skip_restore; then
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
    fi

    success "Restore complete!"

    # -------------------------------------------------------------------------
    # Step B: SSH ramdisk boot
    # -------------------------------------------------------------------------
    section "Step B: SSH ramdisk boot"

    pkill -f "vphone-cli" 2>/dev/null || true
    sleep 2

    info "This requires TWO terminals running simultaneously."
    echo
    echo "  TERMINAL 1 — start VM in DFU mode:"
    echo "    cd \"$vphone_dir\" && make boot_dfu VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  TERMINAL 2 — once VM shows 'VM started in DFU mode':"
    echo "    cd \"$vphone_dir\" && make ramdisk_build VM_DIR=\"$VM_DIR\""
    echo "    cd \"$vphone_dir\" && make ramdisk_send VM_DIR=\"$VM_DIR\""
    echo
    echo "  Wait for 'Boot sequence complete'. Leave Terminal 1 running."
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
