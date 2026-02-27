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
    # vphone-cli has no 'restore <name> --component' subcommand.
    # The virtual device appears to the host as a USB DFU device and is loaded
    # via irecovery exactly like a physical iPhone in DFU mode.

    if ! check_command irecovery; then
        error "irecovery not found in PATH."
        error "Install via:  brew install libirecovery"
        error "Or re-run Phase 1 — it now installs libirecovery automatically."
        return 1
    fi

    local patched_dir="$WORK_DIR/patched"

    # -------------------------------------------------------------------------
    # Helper: poll until irecovery can see a recovery/DFU device (up to ~60 s)
    # After each DFU stage transition the virtual device re-enumerates over USB
    # and irecovery needs time to reconnect to the new device identity.
    # -------------------------------------------------------------------------
    _irecovery_wait() {
        local label="$1"
        local max_attempts="${2:-30}"
        info "  Waiting for device to re-enumerate ($label)..."
        local attempt
        for attempt in $(seq 1 "$max_attempts"); do
            if irecovery -q &>/dev/null; then
                info "  Device ready ($label, attempt $attempt)"
                return 0
            fi
            sleep 2
        done
        warn "  Device not detected after ${label} — continuing anyway"
        return 1
    }

    # Step 0: Wait for the initial DFU device to appear
    _irecovery_wait "initial DFU" 20 || true

    # Step 1: iBSS
    # After iBSS the device transitions DFU → iBSS mode and re-enumerates.
    local ibss="$patched_dir/iBSS.img4"
    [[ -f "$ibss" ]] || ibss="$patched_dir/iBSS.patched"
    if [[ -f "$ibss" ]]; then
        info "  Sending iBSS..."
        irecovery -f "$ibss" 2>&1 | tee -a "$CURRENT_LOG_FILE" || warn "  iBSS send returned non-zero"
        # Device re-enumerates; wait before the next irecovery call
        _irecovery_wait "post-iBSS (iBSS/Recovery mode)" 30
    else
        warn "  iBSS not found in $patched_dir"
    fi

    # Step 2: iBEC
    # After iBEC the device transitions iBSS → iBEC/Recovery mode and re-enumerates.
    local ibec="$patched_dir/iBEC.img4"
    [[ -f "$ibec" ]] || ibec="$patched_dir/iBEC.patched"
    if [[ -f "$ibec" ]]; then
        info "  Sending iBEC..."
        irecovery -f "$ibec" 2>&1 | tee -a "$CURRENT_LOG_FILE" || warn "  iBEC send returned non-zero"
        # Device re-enumerates again into recovery (iBEC) mode
        _irecovery_wait "post-iBEC (Recovery mode)" 30
    else
        warn "  iBEC not found in $patched_dir"
    fi

    # Step 3: set boot-args for ramdisk boot
    info "  Setting boot-args for ramdisk..."
    irecovery -s "setenv boot-args $BOOT_ARGS_RAMDISK" 2>&1 | tee -a "$CURRENT_LOG_FILE" || true
    irecovery -s "saveenv"                              2>&1 | tee -a "$CURRENT_LOG_FILE" || true
    sleep 1

    # Step 4: kernelcache
    local kc="$patched_dir/kernelcache.img4"
    [[ -f "$kc" ]] || kc="$patched_dir/kernelcache.patched"
    if [[ -f "$kc" ]]; then
        info "  Sending kernelcache..."
        irecovery -f "$kc" 2>&1 | tee -a "$CURRENT_LOG_FILE" || warn "  kernelcache send returned non-zero"
        sleep 2
    else
        warn "  kernelcache not found in $patched_dir"
    fi

    # Step 5: ramdisk
    # Modern IPSWs store the ramdisk with a cryptic filename (e.g. 048-xxxxx.dmg).
    # Try an explicit name match first, then fall back to BuildManifest.plist lookup.
    local ramdisk=""
    ramdisk="$(find "$WORK_DIR/firmware" -iname "*RestoreRamDisk*" 2>/dev/null | head -1)"

    if [[ -z "$ramdisk" ]]; then
        # Parse BuildManifest.plist from the extracted IPSW to resolve the path
        local build_manifest
        build_manifest="$(find "$WORK_DIR/firmware" -maxdepth 3 -name "BuildManifest.plist" 2>/dev/null | head -1)"
        if [[ -n "$build_manifest" ]]; then
            local manifest_dir
            manifest_dir="$(dirname "$build_manifest")"
            # Extract RestoreRamDisk path via Python plistlib (available everywhere on macOS)
            local rd_rel
            rd_rel="$(python3 - "$build_manifest" 2>/dev/null <<'PYEOF'
import sys, plistlib, pathlib
with open(sys.argv[1], "rb") as f:
    m = plistlib.load(f)
for identity in m.get("BuildIdentities", []):
    rd = identity.get("Manifest", {}).get("RestoreRamDisk", {})
    path = rd.get("Info", {}).get("Path", "")
    if path:
        print(path)
        sys.exit(0)
PYEOF
)"
            if [[ -n "$rd_rel" ]]; then
                local rd_candidate="$manifest_dir/$rd_rel"
                [[ -f "$rd_candidate" ]] && ramdisk="$rd_candidate"
            fi
        fi
    fi

    if [[ -n "$ramdisk" ]]; then
        info "  Sending ramdisk: $(basename "$ramdisk")..."
        irecovery -f "$ramdisk" 2>&1 | tee -a "$CURRENT_LOG_FILE" || warn "  ramdisk send returned non-zero"
        sleep 2
    else
        warn "  RestoreRamDisk not found under $WORK_DIR/firmware"
        warn "  (checked by name and via BuildManifest.plist)"
    fi

    # Step 6: boot
    info "  Sending boot command..."
    irecovery -s "bootx" 2>&1 | tee -a "$CURRENT_LOG_FILE" || true
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
