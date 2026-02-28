#!/bin/bash
# lib/phase5_ramdisk.sh — Boot VM in DFU mode and load SSH ramdisk
# Starts the VM, boots into DFU, loads patched firmware + ramdisk,
# and waits for SSH access.

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + Restore + SSH Ramdisk"

    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"
    setup_cleanup_trap

    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local irecovery_bin="$vphone_dir/.limd/bin/irecovery"
    local iproxy_bin="$vphone_dir/.limd/bin/iproxy"

    if [[ ! -x "$irecovery_bin" ]]; then
        error "irecovery not found at $irecovery_bin — run Phase 3 first."
        return 1
    fi
    if [[ ! -x "$iproxy_bin" ]]; then
        warn "iproxy not found at $iproxy_bin — falling back to system iproxy"
        iproxy_bin="$(command -v iproxy 2>/dev/null || true)"
        [[ -z "$iproxy_bin" ]] && { error "iproxy not found"; return 1; }
    fi

    # ── thin wrappers around upstream Makefile targets ──────────────────────
    # All targets use VM_DIR so cwd, shsh/, iPhone*_Restore glob all match
    # exactly what upstream expects.
    _mk_bg() {
        # Run a make target in background; caller saves $! immediately.
        make -C "$vphone_dir" --no-print-directory \
            VM_DIR="$VM_DIR" CPU="${VM_CPU:-8}" MEMORY="${VM_MEMORY:-16384}" \
            "$@" >>"$CURRENT_LOG_FILE" 2>&1 &
    }
    _mk_fg() {
        # Run a make target in foreground, tee output.
        make -C "$vphone_dir" --no-print-directory \
            VM_DIR="$VM_DIR" CPU="${VM_CPU:-8}" MEMORY="${VM_MEMORY:-16384}" \
            "$@" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        return "${PIPESTATUS[0]}"
    }

    # Wait for DFU/Recovery device to enumerate (up to 60 s)
    _wait_for_dfu() {
        info "  Waiting for DFU device ($1)..."
        local _i
        for _i in $(seq 1 30); do
            if "$irecovery_bin" -q 2>/dev/null | grep -qi "CPID\|DFU\|Recovery"; then
                info "  DFU device ready (attempt $_i)"; return 0
            fi
            sleep 2
        done
        error "  DFU device did not appear after 60 s"; return 1
    }

    # =========================================================================
    # Step A — upstream: boot_dfu → restore_get_shsh → restore
    # =========================================================================
    section "Step A: Full iOS restore"

    # Clear any stale SHSH blobs in VM_DIR/shsh/ so restore_get_shsh is forced
    # to write a fresh one with the current DFU session's nonce.
    rm -f "$VM_DIR"/shsh/*.shsh "$VM_DIR"/shsh/*.shsh2 2>/dev/null || true
    info "Cleared stale SHSH blobs from $VM_DIR/shsh/"

    section "  make boot_dfu (Step A)"
    _mk_bg boot_dfu
    local dfu_pid_a=$!
    register_pid "$dfu_pid_a"
    info "  boot_dfu PID: $dfu_pid_a"

    if ! _wait_for_dfu "restore"; then
        kill "$dfu_pid_a" 2>/dev/null; wait "$dfu_pid_a" 2>/dev/null
        return 1
    fi

    section "  make restore_get_shsh"
    _mk_fg restore_get_shsh

    section "  make restore"
    _mk_fg restore
    local restore_rc=$?

    kill "$dfu_pid_a" 2>/dev/null; wait "$dfu_pid_a" 2>/dev/null

    if [[ $restore_rc -ne 0 ]]; then
        error "make restore failed (exit $restore_rc) — check $CURRENT_LOG_FILE"
        return 1
    fi
    success "iOS restore complete!"
    sleep 3

    # =========================================================================
    # Step B — upstream: boot_dfu → ramdisk_send
    # =========================================================================
    section "Step B: SSH ramdisk boot"

    section "  make boot_dfu (Step B)"
    _mk_bg boot_dfu
    local dfu_pid_b=$!
    register_pid "$dfu_pid_b"
    info "  boot_dfu PID: $dfu_pid_b"

    if ! _wait_for_dfu "ramdisk"; then
        kill "$dfu_pid_b" 2>/dev/null; wait "$dfu_pid_b" 2>/dev/null
        return 1
    fi

    section "  make ramdisk_send"
    _mk_fg ramdisk_send
    local send_rc=$?

    if [[ $send_rc -ne 0 ]]; then
        error "make ramdisk_send failed (exit $send_rc) — check $CURRENT_LOG_FILE"
        kill "$dfu_pid_b" 2>/dev/null; wait "$dfu_pid_b" 2>/dev/null
        return 1
    fi
    success "Ramdisk boot chain sent!"

    # -------------------------------------------------------------------------
    # iproxy 2222 → 22  (cfw_install.sh hardcodes SSH_PORT=2222)
    # -------------------------------------------------------------------------
    section "Starting iproxy (ramdisk SSH: localhost:2222 → device:22)"

    pkill -f "iproxy 2222" 2>/dev/null || true
    sleep 1
    "$iproxy_bin" 2222 22 &>/dev/null &
    local iproxy_pid=$!
    register_pid "$iproxy_pid"
    echo "$iproxy_pid" > "$WORK_DIR/.iproxy_ramdisk_pid"
    info "  iproxy 2222→22 PID: $iproxy_pid"

    # -------------------------------------------------------------------------
    # Wait for SSH on localhost:2222
    # -------------------------------------------------------------------------
    section "Waiting for SSH ramdisk"

    local ssh_ready=false
    local sshpass_bin
    sshpass_bin="$(command -v sshpass 2>/dev/null || true)"

    info "Polling localhost:2222 for SSH..."
    local attempt
    for attempt in $(seq 1 60); do
        if [[ -n "$sshpass_bin" ]]; then
            if "$sshpass_bin" -p "$SSH_PASSWORD" ssh \
                   -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p 2222 "root@localhost" "echo ok" 2>/dev/null; then
                ssh_ready=true; break
            fi
        else
            if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p 2222 "root@localhost" "echo ok" 2>/dev/null; then
                ssh_ready=true; break
            fi
        fi
        [[ $(( attempt % 10 )) -eq 0 ]] && info "  Still waiting... ($attempt/60)"
        sleep 2
    done

    if $ssh_ready; then
        success "SSH ramdisk is ready!"
        success "  ssh -p 2222 root@localhost  (password: $SSH_PASSWORD)"
    else
        error "SSH ramdisk did not become available on localhost:2222"
        error "Check: $CURRENT_LOG_FILE"
        return 1
    fi

    echo "localhost" > "$WORK_DIR/.vm_ip"
    echo "2222"      > "$WORK_DIR/.ssh_port"

    save_state "phase5"
    success "Phase 5 complete — SSH ramdisk running on localhost:2222."
    info "Phase 6 will run cfw_install.sh and install the Metal plugin."
}

