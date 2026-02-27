#!/bin/bash
# lib/phase5_ramdisk.sh — Boot VM in DFU mode and load SSH ramdisk
# Starts the VM, boots into DFU, loads patched firmware + ramdisk,
# and waits for SSH access.

run_phase5_ramdisk() {
    phase_banner "5" "DFU Boot + SSH Ramdisk"

    CURRENT_LOG_FILE="$LOG_DIR/phase5.log"

    setup_cleanup_trap

    # Load firmware paths
    if [[ -f "$WORK_DIR/.firmware_paths" ]]; then
        source "$WORK_DIR/.firmware_paths"
    fi

    local vm_tool=""
    local vm_name="vphone"

    case "$VM_APPROACH" in
        vphone-cli)
            vm_tool="$(_find_vm_tool "vphone-cli")"
            ;;
        super-tart)
            vm_tool="$(_find_vm_tool "tart")"
            ;;
    esac

    if [[ -z "$vm_tool" ]]; then
        error "VM tool not found. Run Phase 3 first."
        return 1
    fi
    info "Using VM tool: $vm_tool"

    # -------------------------------------------------------------------------
    # 1. Create VM if it doesn't exist
    # -------------------------------------------------------------------------
    section "Preparing VM"

    _ensure_vm_disk_exists "$vm_tool" "$vm_name"

    # -------------------------------------------------------------------------
    # 2. Boot into DFU mode
    # -------------------------------------------------------------------------
    section "Booting VM into DFU mode"

    info "Starting VM in DFU mode..."
    info "The VM will wait for firmware to be loaded."

    # vphone-cli takes direct flags; it has no 'run <name>' subcommand.
    "$vm_tool" \
        --rom    "$VM_ROM_PATH" \
        --disk   "$VM_DISK" \
        --nvram  "$VM_NVRAM" \
        --sep-rom "$VM_SEP_ROM_PATH" \
        --cpu    "$VM_CPU" \
        --memory "$VM_MEMORY" \
        --dfu --no-graphics &
    local dfu_pid=$!
    register_pid "$dfu_pid"

    # Give the VM time to start and enter DFU
    info "Waiting for VM to enter DFU mode..."
    sleep 5

    if ! kill -0 "$dfu_pid" 2>/dev/null; then
        error "VM process exited unexpectedly"
        wait "$dfu_pid" 2>/dev/null
        return 1
    fi

    success "VM is running in DFU mode (PID: $dfu_pid)"

    # -------------------------------------------------------------------------
    # 3. Load patched boot chain via DFU
    # -------------------------------------------------------------------------
    section "Loading patched boot chain"

    # The boot chain loading depends on the tool
    local _bootchain_rc=0
    case "$VM_APPROACH" in
        vphone-cli)
            _load_bootchain_vphone "$vm_tool" "$vm_name" || _bootchain_rc=$?
            ;;
        super-tart)
            _load_bootchain_supertart "$vm_tool" "$vm_name" || _bootchain_rc=$?
            ;;
    esac
    if [[ $_bootchain_rc -ne 0 ]]; then
        error "Boot chain loading failed — cannot proceed to SSH wait."
        kill "$dfu_pid" 2>/dev/null; wait "$dfu_pid" 2>/dev/null
        error "Check $VM_DIR/serial.log for details."
        return 1
    fi

    # -------------------------------------------------------------------------
    # 4. Wait for SSH ramdisk to become available
    # -------------------------------------------------------------------------
    section "Waiting for SSH ramdisk"

    local vm_ip=""
    info "Getting VM IP address..."

    # vphone-cli has no 'ip <name>' subcommand; detect the guest IP from the
    # Virtualization.framework DHCP lease table or via arp on the private subnet.
    for attempt in $(seq 1 30); do
        vm_ip="$(_get_vphone_ip 2>/dev/null || echo '')"
        if [[ -n "$vm_ip" ]] && [[ "$vm_ip" != "0.0.0.0" ]]; then
            break
        fi
        sleep 2
    done

    local ssh_port
    if [[ -z "$vm_ip" ]] || [[ "$vm_ip" == "0.0.0.0" ]]; then
        warn "Could not get VM IP automatically."
        warn "The VM may use port forwarding instead."
        vm_ip="localhost"
        ssh_port="$SSH_LOCAL_PORT"
    else
        info "VM IP: $vm_ip"
        ssh_port=22
    fi

    # Save VM IP for later phases
    echo "$vm_ip" > "$WORK_DIR/.vm_ip"
    echo "$ssh_port" > "$WORK_DIR/.ssh_port"

    # Wait for SSH to become available
    info "Waiting for SSH to become available..."
    local ssh_ready=false

    for attempt in $(seq 1 60); do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -p "$ssh_port" "root@${vm_ip}" "echo ok" 2>/dev/null; then
            ssh_ready=true
            break
        fi

        # Try with sshpass if available
        if check_command sshpass; then
            if sshpass -p "$SSH_PASSWORD" ssh \
                   -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p "$ssh_port" "root@${vm_ip}" "echo ok" 2>/dev/null; then
                ssh_ready=true
                break
            fi
        fi

        if [[ $(( attempt % 10 )) -eq 0 ]]; then
            info "  Still waiting... (attempt $attempt/60)"
        fi
        sleep 2
    done

    if $ssh_ready; then
        success "SSH ramdisk is ready!"
        success "  Host: $vm_ip"
        success "  Port: $ssh_port"
        success "  Password: $SSH_PASSWORD"
    else
        error "SSH ramdisk did not become available within timeout."
        error "You may need to manually verify the VM state."
        error ""
        error "Try connecting manually:"
        error "  ssh -p $ssh_port root@$vm_ip  (password: $SSH_PASSWORD)"
        return 1
    fi

    save_state "phase5"
    success "Phase 5 complete — SSH ramdisk is running."
    info ""
    info "The VM is now running with SSH access."
    info "Phase 6 will install iOS to the VM disk via SSH."
    info ""
    info "DFU VM PID: $dfu_pid"
}

# =============================================================================
# Helpers
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

    local vphone_dir
    vphone_dir="$(dirname "$(dirname "$(_find_vm_tool vphone-cli)")")"

    local ramdisk_dir="$WORK_DIR/Ramdisk"
    if [[ ! -d "$ramdisk_dir" ]]; then
        error "Ramdisk directory not found: $ramdisk_dir"
        error "Run Phase 4 first (ramdisk_build.py must succeed with SHSH blobs)."
        return 1
    fi

    local send_script="$vphone_dir/scripts/ramdisk_send.sh"
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
