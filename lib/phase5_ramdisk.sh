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
    # Step B: SSH ramdisk boot (automated with manual fallback)
    # -------------------------------------------------------------------------
    section "Step B: SSH ramdisk boot"

    local ramdisk_wrapper="$SCRIPT_DIR/lib/ramdisk_send_wrapper.sh"
    local irecovery_bin="$vphone_dir/.limd/bin/irecovery"
    local dfu_log
    dfu_log="$(mktemp /tmp/boot_dfu_XXXXXX.log)"
    local dfu_pid=""

    _cleanup_dfu() {
        [[ -n "$dfu_pid" ]] && kill "$dfu_pid" 2>/dev/null || true
        rm -f "$dfu_log"
    }

    info "Starting VM in DFU mode (background)..."
    (
        cd "$vphone_dir"
        make boot_dfu VM_DIR="$VM_DIR" CPU="${VM_CPU:-8}" MEMORY="${VM_MEMORY:-16384}"
    ) >"$dfu_log" 2>&1 &
    dfu_pid=$!
    register_pid "$dfu_pid"

    # Wait for DFU ready signal
    info "Waiting for 'VM started in DFU mode'..."
    local dfu_ready=false
    for _i in $(seq 1 60); do
        if ! kill -0 "$dfu_pid" 2>/dev/null; then
            warn "boot_dfu process exited early — check $dfu_log"
            break
        fi
        if grep -q "VM started in DFU mode" "$dfu_log" 2>/dev/null; then
            dfu_ready=true
            break
        fi
        sleep 2
    done

    local ramdisk_ok=false
    if $dfu_ready; then
        success "VM is in DFU mode. Sending ramdisk..."
        sleep 1
        if IRECOVERY="$irecovery_bin" zsh "$ramdisk_wrapper" "$VM_DIR/Ramdisk"; then
            ramdisk_ok=true
        else
            warn "ramdisk_send_wrapper failed (exit $?)"
        fi
    else
        warn "DFU ready signal not detected within timeout."
    fi

    if ! $ramdisk_ok; then
        # Manual fallback
        warn "Automated ramdisk send failed. Falling back to manual mode."
        _cleanup_dfu
        echo
        echo "  TERMINAL 1 — start VM in DFU mode:"
        echo "    cd \"$vphone_dir\" && make boot_dfu VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
        echo
        echo "  TERMINAL 2 — once VM shows 'VM started in DFU mode':"
        echo "    IRECOVERY=\"$irecovery_bin\" zsh \"$ramdisk_wrapper\" \"$VM_DIR/Ramdisk\""
        echo
        echo "  Wait for 'Boot sequence complete'. Leave Terminal 1 running."
        echo
        read -r -p "Press ENTER when ramdisk_send is complete: "
    fi

    rm -f "$dfu_log"
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
