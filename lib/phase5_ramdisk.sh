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
    case "$VM_APPROACH" in
        vphone-cli)
            _load_bootchain_vphone "$vm_tool" "$vm_name"
            ;;
        super-tart)
            _load_bootchain_supertart "$vm_tool" "$vm_name"
            ;;
    esac

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
    # Send firmware via irecovery following the upstream ramdisk_send.sh sequence.
    # All IMG4 components are pre-signed and come from $WORK_DIR/Ramdisk/
    # (built by ramdisk_build.py in Phase 4).
    #
    # Sequence (mirrors scripts/ramdisk_send.sh):
    #   iBSS → sleep 1 → iBEC → go → sleep 1
    #   → SPTM+firmware → TXM+firmware → trustcache+firmware
    #   → sleep 2 → ramdisk → sleep 2 → ramdisk-cmd
    #   → DeviceTree+devicetree → SEP+firmware → krnl+bootx

    if ! check_command irecovery; then
        error "irecovery not found. Install via:  brew install libirecovery"
        return 1
    fi

    local ramdisk_dir="$WORK_DIR/Ramdisk"
    if [[ ! -d "$ramdisk_dir" ]]; then
        error "Ramdisk directory not found: $ramdisk_dir"
        error "Run Phase 4 first (ramdisk_build.py must succeed with SHSH blobs)."
        return 1
    fi

    # -------------------------------------------------------------------------
    # Helper: send one IMG4 file via irecovery
    # -------------------------------------------------------------------------
    _send_img4() {
        local path="$1"
        local label="$2"
        if [[ ! -f "$path" ]]; then
            warn "  $label: file not found — $path"
            return 1
        fi
        info "  Sending $label ($(basename "$path"), $(du -h "$path" | cut -f1))..."
        irecovery -f "$path" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        return 0
    }

    # -------------------------------------------------------------------------
    # Helper: poll until irecovery sees a DFU/recovery device
    # -------------------------------------------------------------------------
    _irecovery_wait() {
        local label="$1"
        local max_attempts="${2:-15}"
        for attempt in $(seq 1 "$max_attempts"); do
            if irecovery -q &>/dev/null; then
                info "  Device ready ($label, attempt $attempt)"
                return 0
            fi
            sleep 2
        done
        warn "  Device not detected after $label — continuing anyway"
        return 1
    }

    # Wait for the initial DFU device to appear before we start
    _irecovery_wait "initial DFU" 20 || true

    # ── Step 1: iBSS ──────────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/iBSS.vresearch101.RELEASE.img4" "iBSS" || return 1
    sleep 1
    _irecovery_wait "post-iBSS" 15 || true

    # ── Step 2: iBEC + go ─────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/iBEC.vresearch101.RELEASE.img4" "iBEC" || return 1
    info "  Sending irecovery command: go"
    irecovery -c go 2>&1 | tee -a "$CURRENT_LOG_FILE" || true
    sleep 1
    _irecovery_wait "post-iBEC/go" 15 || true

    # ── Step 3: SPTM ─────────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/sptm.vresearch1.release.img4" "SPTM" || true
    info "  Sending irecovery command: firmware (SPTM)"
    irecovery -c firmware 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 4: TXM ──────────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/txm.img4" "TXM" || true
    info "  Sending irecovery command: firmware (TXM)"
    irecovery -c firmware 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 5: trustcache ────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/trustcache.img4" "trustcache" || true
    info "  Sending irecovery command: firmware (trustcache)"
    irecovery -c firmware 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 6: ramdisk ───────────────────────────────────────────────────────
    sleep 2
    _send_img4 "$ramdisk_dir/ramdisk.img4" "ramdisk" || return 1
    sleep 2
    info "  Sending irecovery command: ramdisk"
    irecovery -c ramdisk 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 7: DeviceTree ────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/DeviceTree.vphone600ap.img4" "DeviceTree" || true
    info "  Sending irecovery command: devicetree"
    irecovery -c devicetree 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 8: SEP ───────────────────────────────────────────────────────────
    _send_img4 "$ramdisk_dir/sep-firmware.vresearch101.RELEASE.img4" "SEP" || true
    info "  Sending irecovery command: firmware (SEP)"
    irecovery -c firmware 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

    # ── Step 9: kernelcache → bootx ───────────────────────────────────────────
    _send_img4 "$ramdisk_dir/krnl.img4" "kernelcache" || return 1
    info "  Sending irecovery command: bootx"
    irecovery -c bootx 2>&1 | tee -a "$CURRENT_LOG_FILE" || true

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
