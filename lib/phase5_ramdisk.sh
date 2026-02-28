#!/bin/bash
# lib/phase5_ramdisk.sh — Boot VM in DFU mode and load SSH ramdisk
# Starts the VM, boots into DFU, loads patched firmware + ramdisk,
# and waits for SSH access.

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + Restore + SSH Ramdisk"

    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"

    setup_cleanup_trap

    # Load firmware paths
    if [[ -f "$WORK_DIR/.firmware_paths" ]]; then
        source "$WORK_DIR/.firmware_paths"
    fi

    # -------------------------------------------------------------------------
    # Resolve tools
    # -------------------------------------------------------------------------
    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local vphone_bin
    vphone_bin="$(find "$vphone_dir/.build" -name "vphone-cli" -type f \
        ! -path "*dSYM*" ! -path "*/debug/*" 2>/dev/null | head -1)"
    if [[ -z "$vphone_bin" ]] || [[ ! -x "$vphone_bin" ]]; then
        error "vphone-cli binary not found in $vphone_dir/.build — run Phase 3 first."
        return 1
    fi

    local idevicerestore="$vphone_dir/.limd/bin/idevicerestore"
    if [[ ! -x "$idevicerestore" ]]; then
        error "idevicerestore not found at $idevicerestore — run Phase 3 first."
        return 1
    fi

    local irecovery_bin="$vphone_dir/.limd/bin/irecovery"
    if [[ ! -x "$irecovery_bin" ]]; then
        error "irecovery not found at $irecovery_bin — run Phase 3 first."
        return 1
    fi

    local iproxy_bin="$vphone_dir/.limd/bin/iproxy"
    if [[ ! -x "$iproxy_bin" ]]; then
        warn "iproxy not found at $iproxy_bin — falling back to system iproxy"
        iproxy_bin="$(command -v iproxy 2>/dev/null || true)"
        if [[ -z "$iproxy_bin" ]]; then
            error "iproxy not found. Install via: brew install libimobiledevice"
            return 1
        fi
    fi

    # Verify prerequisites
    if [[ ! -e "$WORK_DIR/iPhone_Restore" ]]; then
        error "iPhone_Restore not found in $WORK_DIR — run Phase 4 first."
        return 1
    fi

    local ramdisk_dir="$WORK_DIR/Ramdisk"
    if [[ ! -d "$ramdisk_dir" ]]; then
        error "Ramdisk/ not found — run Phase 4 first (ramdisk_build.py must succeed)."
        return 1
    fi

    if [[ ! -f "$VM_DISK" ]]; then
        error "VM disk not found: $VM_DISK — run Phase 4 first (SHSH fetch creates the disk)."
        return 1
    fi
    if [[ ! -f "$VM_NVRAM" ]]; then
        touch "$VM_NVRAM"
    fi

    # Common DFU boot flags shared between Step A and Step B
    local _dfu_flags=(
        --rom     "$VM_ROM_PATH"
        --disk    "$VM_DISK"
        --nvram   "$VM_NVRAM"
        --sep-rom "$VM_SEP_ROM_PATH"
        --cpu     "${VM_CPU:-8}"
        --memory  "${VM_MEMORY:-16384}"
        --no-graphics
        --dfu
        --sep-storage "$VM_DIR/SEPStorage"
    )

    # Helper: wait for DFU/Recovery device to enumerate (up to 60 s)
    _wait_for_dfu() {
        local label="$1"
        info "  Waiting for DFU device ($label)..."
        local _i
        for _i in $(seq 1 30); do
            if "$irecovery_bin" -q 2>/dev/null | grep -qi "CPID\|DFU\|Recovery"; then
                info "  DFU device ready (attempt $_i)"
                return 0
            fi
            sleep 2
        done
        error "  DFU device did not appear after 60 s"
        return 1
    }

    # =========================================================================
    # Step A — Full restore via idevicerestore
    # Upstream: make boot_dfu (terminal 1) + make restore (terminal 2)
    # =========================================================================
    section "Step A: Full iOS restore (idevicerestore -e -y)"

    # Remove any stale SHSH blobs from Phase 4 — they were fetched with a
    # different DFU nonce and will prevent restore_get_shsh from saving a
    # fresh blob that matches the current session's nonce.
    rm -f "$WORK_DIR"/shsh/*.shsh "$WORK_DIR"/shsh/*.shsh2 2>/dev/null || true
    info "Cleared stale SHSH blobs (will re-fetch in this session)"

    info "Starting VM in DFU mode for restore..."
    "$vphone_bin" "${_dfu_flags[@]}" &>/dev/null &
    local dfu_pid_a=$!
    register_pid "$dfu_pid_a"
    info "  DFU boot PID: $dfu_pid_a"

    if ! _wait_for_dfu "restore"; then
        kill "$dfu_pid_a" 2>/dev/null; wait "$dfu_pid_a" 2>/dev/null
        return 1
    fi

    # --- upstream: make restore_get_shsh ---
    # Fetch SHSH blob NOW (same DFU session = same nonce).
    # This overwrites any stale blob from Phase 4 that was fetched with a
    # different nonce, so the subsequent full-restore call finds a match.
    info "Fetching SHSH blob for current nonce (restore_get_shsh)..."
    (
        cd "$WORK_DIR"
        "$idevicerestore" -e -y ./iPhone_Restore -t 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    # -t exits 0 on success; non-zero is non-fatal (we'll try the restore anyway)
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        success "SHSH blob saved for current nonce"
    else
        warn "SHSH fetch returned non-zero — continuing with restore anyway"
    fi

    # --- upstream: make restore ---
    info "Running idevicerestore (full restore, same DFU session)..."
    (
        cd "$WORK_DIR"
        "$idevicerestore" -e -y ./iPhone_Restore 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local restore_rc=${PIPESTATUS[0]}

    info "Stopping DFU VM (restore done)..."
    kill "$dfu_pid_a" 2>/dev/null; wait "$dfu_pid_a" 2>/dev/null

    if [[ $restore_rc -ne 0 ]]; then
        error "idevicerestore failed (exit code $restore_rc)"
        error "Check: $CURRENT_LOG_FILE"
        return 1
    fi
    success "iOS restore complete!"

    # Brief pause before next DFU boot
    sleep 3

    # =========================================================================
    # Step B — Ramdisk boot for SSH access
    # Upstream: make boot_dfu (terminal 1) + make ramdisk_send (terminal 2)
    # =========================================================================
    section "Step B: SSH ramdisk boot (ramdisk_send.sh)"

    # Resolve ramdisk_send.sh — prefer local VM wrapper, fall back to upstream
    local send_script
    local _wrapper="$SCRIPT_DIR/CFW/patches/ramdisk_send_vm.sh"
    if [[ -f "$_wrapper" ]]; then
        send_script="$_wrapper"
        info "  Using VM send wrapper: $send_script"
    else
        send_script="$vphone_dir/scripts/ramdisk_send.sh"
        info "  Using upstream ramdisk_send.sh"
    fi
    if [[ ! -f "$send_script" ]]; then
        error "ramdisk_send.sh not found at $send_script"
        return 1
    fi

    info "Starting VM in DFU mode for ramdisk..."
    "$vphone_bin" "${_dfu_flags[@]}" &>/dev/null &
    local dfu_pid_b=$!
    register_pid "$dfu_pid_b"
    info "  DFU boot PID: $dfu_pid_b"

    if ! _wait_for_dfu "ramdisk"; then
        kill "$dfu_pid_b" 2>/dev/null; wait "$dfu_pid_b" 2>/dev/null
        return 1
    fi

    info "Sending ramdisk boot chain..."
    (
        cd "$WORK_DIR"
        IRECOVERY="$irecovery_bin" zsh "$send_script" "$ramdisk_dir" \
            2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local send_rc=${PIPESTATUS[0]}

    if [[ $send_rc -ne 0 ]]; then
        error "ramdisk_send.sh failed (exit code $send_rc)"
        kill "$dfu_pid_b" 2>/dev/null; wait "$dfu_pid_b" 2>/dev/null
        return 1
    fi
    success "Ramdisk boot chain sent — device booting ramdisk..."

    # -------------------------------------------------------------------------
    # Start iproxy 2222 → 22 for ramdisk SSH
    # (cfw_install.sh hardcodes SSH_PORT=2222, SSH_HOST=localhost)
    # -------------------------------------------------------------------------
    section "Starting iproxy (ramdisk SSH: localhost:2222 → device:22)"

    pkill -f "iproxy 2222" 2>/dev/null || true
    sleep 1

    "$iproxy_bin" 2222 22 &>/dev/null &
    local iproxy_pid=$!
    register_pid "$iproxy_pid"
    echo "$iproxy_pid" > "$WORK_DIR/.iproxy_ramdisk_pid"
    info "  iproxy 2222→22 started (PID: $iproxy_pid)"

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
                ssh_ready=true
                break
            fi
        else
            if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p 2222 "root@localhost" "echo ok" 2>/dev/null; then
                ssh_ready=true
                break
            fi
        fi
        [[ $(( attempt % 10 )) -eq 0 ]] && info "  Still waiting... (attempt $attempt/60)"
        sleep 2
    done

    if $ssh_ready; then
        success "SSH ramdisk is ready!"
        success "  ssh -p 2222 root@localhost  (password: $SSH_PASSWORD)"
    else
        error "SSH ramdisk did not become available on localhost:2222"
        error "Check: $VM_DIR/serial_ramdisk.log"
        return 1
    fi

    # Save connection info for Phase 6
    echo "localhost" > "$WORK_DIR/.vm_ip"
    echo "2222"      > "$WORK_DIR/.ssh_port"

    save_state "phase5"
    success "Phase 5 complete — SSH ramdisk running on localhost:2222."
    info "Phase 6 will run cfw_install.sh and install the Metal plugin."
}

# =============================================================================
# Helpers (legacy — kept for reference; no longer called by run_phase5_ramdisk)
# =============================================================================


_ensure_vm_disk_exists() {
    local vm_tool="$1"
    local vm_name="$2"

    if [[ "$VM_APPROACH" != "vphone-cli" ]]; then
        # super-tart retains Tart-style create/list subcommands
        if ! "$vm_tool" list 2>/dev/null | grep -q "$vm_name"; then
            info "Creating VM '$vm_name' (super-tart)..."
            "$vm_tool" create "$vm_name" \
                --cpu "$VM_CPU" \
                --memory "$VM_MEMORY" \
                2>&1 | tee -a "$CURRENT_LOG_FILE" || true
            success "VM '$vm_name' created"
        else
            info "VM '$vm_name' already exists"
        fi
        return 0
    fi

    # vphone-cli: just need a disk image on disk — no VM registry.
    if [[ -f "$VM_DISK" ]]; then
        info "VM disk already exists: $VM_DISK"
    else
        info "Creating sparse VM disk image ($VM_DISK_SIZE) at $VM_DISK ..."
        ensure_dir "$(dirname "$VM_DISK")"
        # hdiutil creates <name>.sparseimage; rename to <name>.img for vphone-cli
        hdiutil create -size "$VM_DISK_SIZE" -type SPARSE -layout NONE \
            "${VM_DISK%.img}" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        if [[ -f "${VM_DISK%.img}.sparseimage" ]]; then
            mv "${VM_DISK%.img}.sparseimage" "$VM_DISK"
        fi
        success "VM disk created: $VM_DISK"
    fi

    # Validate the ROM binary exists before we try to boot
    if [[ ! -f "$VM_ROM_PATH" ]]; then
        error "AVPBooter ROM not found: $VM_ROM_PATH"
        error "Expected in: /System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/"
        return 1
    fi
    info "ROM: $VM_ROM_PATH"
}

_load_bootchain_vphone() {
    # Delegate directly to upstream ramdisk_send.sh with the patched irecovery.
    # Previously we duplicated the sequence here, but inserting _irecovery_wait
    # between iBSS and iBEC caused "Unable to connect to device" — the device
    # transitions USB modes immediately after iBSS and irecovery must connect
    # again right away.  ramdisk_send.sh has the exact timings correct.

    # vphone-cli binary is at: <repo>/.build/<arch>/release/vphone-cli
    # Go up 3 levels to reach the repo root.
    local vphone_bin
    vphone_bin="$(_find_vm_tool vphone-cli)"
    local vphone_dir
    vphone_dir="$(dirname "$(dirname "$(dirname "$(dirname "$vphone_bin")")")")"

    local ramdisk_dir="$WORK_DIR/Ramdisk"
    if [[ ! -d "$ramdisk_dir" ]]; then
        error "Ramdisk directory not found: $ramdisk_dir"
        error "Run Phase 4 first (ramdisk_build.py must succeed with SHSH blobs)."
        return 1
    fi

    local send_script
    # Prefer our VM-specific wrapper (adds post-iBSS sleep for re-enumeration).
    # Fall back to upstream ramdisk_send.sh if the wrapper is missing.
    local _wrapper
    _wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CFW/patches/ramdisk_send_vm.sh"
    if [[ -f "$_wrapper" ]]; then
        send_script="$_wrapper"
        info "  Using VM send wrapper: $send_script"
    else
        send_script="$vphone_dir/scripts/ramdisk_send.sh"
        warn "  VM send wrapper missing — using upstream ramdisk_send.sh (may fail on VM)"
    fi

    if [[ ! -f "$send_script" ]]; then
        error "ramdisk_send.sh not found at $send_script"
        error "Update vphone-cli: git -C $vphone_dir pull"
        return 1
    fi

    # Prefer the patched irecovery built by Phase 3; fall back to system one.
    local irecovery_bin
    if [[ -x "$vphone_dir/.limd/bin/irecovery" ]]; then
        irecovery_bin="$vphone_dir/.limd/bin/irecovery"
        info "  Using patched irecovery: $irecovery_bin"
    else
        irecovery_bin="$(command -v irecovery 2>/dev/null || true)"
        if [[ -z "$irecovery_bin" ]]; then
            error "irecovery not found. Install via:  brew install libirecovery"
            return 1
        fi
        warn "  Patched irecovery not available — using system irecovery (may not see virtual device)"
    fi

    # Wait for the initial DFU device before starting the send script.
    info "  Waiting for DFU device before boot chain..."
    local _found=false
    for _i in $(seq 1 20); do
        if "$irecovery_bin" -q &>/dev/null; then
            _found=true
            info "  DFU device ready (attempt $_i)"
            break
        fi
        sleep 2
    done
    if ! $_found; then
        error "DFU device never appeared — VM may have failed to start."
        return 1
    fi

    info "  Running ramdisk_send.sh..."
    (
        cd "$WORK_DIR"
        IRECOVERY="$irecovery_bin" zsh "$send_script" "$ramdisk_dir" \
            2>&1 | tee -a "$CURRENT_LOG_FILE"
        exit "${PIPESTATUS[0]}"
    )
    if [[ $? -ne 0 ]]; then
        error "ramdisk_send.sh failed"
        return 1
    fi

    success "Boot chain loaded — device is booting ramdisk..."
}

_load_bootchain_supertart() {
    local vm_tool="$1"
    local vm_name="$2"

    # super-tart uses the writeup's vma2pwn.sh script flow
    local writeup_dir="$WORK_DIR/tools/super-tart-vphone-writeup"

    if [[ -f "$writeup_dir/vma2pwn.sh" ]]; then
        info "Loading boot chain via vma2pwn.sh..."
        (cd "$writeup_dir" && bash ./vma2pwn.sh) 2>&1 | tee -a "$CURRENT_LOG_FILE"
    else
        # Fall back to manual component loading (same as vphone approach)
        _load_bootchain_vphone "$vm_tool" "$vm_name"
    fi
}
