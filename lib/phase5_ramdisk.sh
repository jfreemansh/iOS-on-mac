#!/bin/bash
# lib/phase5_ramdisk.sh — Restore + SSH ramdisk via upstream Makefile targets

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + Restore + SSH Ramdisk"
    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"
    setup_cleanup_trap

    local vphone_dir="$WORK_DIR/tools/vphone-cli"

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
    # Step B: Ramdisk + CFW
    # -------------------------------------------------------------------------
    section "Step B: Ramdisk + CFW"

    pkill -f "vphone-cli" 2>/dev/null || true
    sleep 2

    info "This requires TWO terminals running simultaneously."
    echo
    echo "  TERMINAL 1 — start VM in DFU mode (keep running):"
    echo "    cd \"$vphone_dir\" && make boot_dfu VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  TERMINAL 2 — once VM shows 'VM started in DFU mode':"
    echo "    cd \"$vphone_dir\" && make ramdisk_build VM_DIR=\"$VM_DIR\""
    echo "    cd \"$vphone_dir\" && make ramdisk_send VM_DIR=\"$VM_DIR\""
    echo "    iproxy 2222 22"
    echo "    cd \"$vphone_dir\" && make cfw_install VM_DIR=\"$VM_DIR\""
    echo
    echo "  Wait for cfw_install to complete. Then Ctrl+C Terminal 1 (boot_dfu)."
    echo
    read -r -p "Press ENTER when cfw_install is complete and Terminal 1 is stopped: "

    pkill -f "vphone-cli" 2>/dev/null || true
    sleep 2

    success "CFW installed!"
    save_state "phase5"
}
