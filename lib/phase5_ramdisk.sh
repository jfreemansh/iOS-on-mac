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

    _ensure_vm_exists "$vm_tool" "$vm_name"

    # -------------------------------------------------------------------------
    # 2. Boot into DFU mode
    # -------------------------------------------------------------------------
    section "Booting VM into DFU mode"

    info "Starting VM in DFU mode..."
    info "The VM will wait for firmware to be loaded."

    "$vm_tool" run "$vm_name" --dfu &
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

    # Retry getting IP for up to 60 seconds
    for attempt in $(seq 1 30); do
        vm_ip="$("$vm_tool" ip "$vm_name" 2>/dev/null || echo "")"
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


_ensure_vm_exists() {
    local vm_tool="$1"
    local vm_name="$2"

    # Check if VM already exists
    if "$vm_tool" list 2>/dev/null | grep -q "$vm_name"; then
        info "VM '$vm_name' already exists"
        return 0
    fi

    info "Creating VM '$vm_name'..."

    # Create VM with the appropriate configuration
    case "$VM_APPROACH" in
        vphone-cli)
            "$vm_tool" create "$vm_name" \
                --cpu "$VM_CPU" \
                --memory "$VM_MEMORY" \
                --display "${VM_DISPLAY_WIDTH}x${VM_DISPLAY_HEIGHT}" \
                2>&1 | tee -a "$CURRENT_LOG_FILE" || true
            ;;
        super-tart)
            "$vm_tool" create "$vm_name" \
                --cpu "$VM_CPU" \
                --memory "$VM_MEMORY" \
                2>&1 | tee -a "$CURRENT_LOG_FILE" || true
            ;;
    esac

    success "VM '$vm_name' created"
}

_load_bootchain_vphone() {
    local vm_tool="$1"
    local vm_name="$2"

    # vphone-cli has its own boot chain loading
    # It typically uses the CFW directory or a boot script
    local cfw_dir="$SCRIPT_DIR/CFW"
    local boot_rd_script="$cfw_dir/boot_rd.sh"

    if [[ -f "$boot_rd_script" ]]; then
        info "Loading boot chain via boot_rd.sh..."
        (cd "$cfw_dir" && bash ./boot_rd.sh) 2>&1 | tee -a "$CURRENT_LOG_FILE"
    else
        # Manual boot chain loading
        info "Loading boot chain components manually..."

        local patched_dir="$WORK_DIR/patched"

        for component in iBSS iBEC kernelcache DeviceTree; do
            local fw_file="$patched_dir/${component}.img4"
            [[ -f "$fw_file" ]] || fw_file="$patched_dir/${component}.patched"
            [[ -f "$fw_file" ]] || continue

            info "  Sending $component..."
            "$vm_tool" restore "$vm_name" --component "$component" \
                --file "$fw_file" 2>&1 | tee -a "$CURRENT_LOG_FILE" || \
                warn "  Failed to send $component"
        done

        # Send ramdisk
        local ramdisk
        ramdisk="$(find "$WORK_DIR/firmware" -iname "*RestoreRamDisk*" 2>/dev/null | head -1)"
        if [[ -n "$ramdisk" ]]; then
            info "  Sending ramdisk..."
            "$vm_tool" restore "$vm_name" --component ramdisk \
                --file "$ramdisk" 2>&1 | tee -a "$CURRENT_LOG_FILE" || \
                warn "  Failed to send ramdisk"
        fi

        # Send trust cache
        local trustcache
        trustcache="$(find "$VM_DIR" -iname "*TrustCache*" 2>/dev/null | head -1)"
        if [[ -n "$trustcache" ]]; then
            info "  Sending trust cache..."
            "$vm_tool" restore "$vm_name" --component trustcache \
                --file "$trustcache" 2>&1 | tee -a "$CURRENT_LOG_FILE" || \
                warn "  Failed to send trust cache"
        fi
    fi
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
