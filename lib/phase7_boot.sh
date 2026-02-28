#!/bin/bash
# lib/phase7_boot.sh — Normal boot of the iOS VM
# Kills any DFU processes, boots the VM normally, optionally starts VNC

run_phase7_boot() {
    phase_banner "7" "Normal Boot"

    CURRENT_LOG_FILE="$LOG_DIR/phase7.log"

    setup_cleanup_trap

    # -------------------------------------------------------------------------
    # 1. Clean up any lingering ramdisk iproxy / DFU processes
    # -------------------------------------------------------------------------
    section "Cleaning up previous VM processes"

    # Kill ramdisk tunnel from Phase 5/6 (port 2222 → 22)
    pkill -f "iproxy 2222" 2>/dev/null || true

    cleanup_pids

    # Also kill any stale DFU VM processes
    pkill -f "vphone-cli.*--dfu" 2>/dev/null || true
    sleep 1

    # -------------------------------------------------------------------------
    # 2. Resolve tools
    # -------------------------------------------------------------------------
    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local vphone_bin
    vphone_bin="$(find "$vphone_dir/.build" -name "vphone-cli" -type f \
        ! -path "*dSYM*" ! -path "*/debug/*" 2>/dev/null | head -1)"
    if [[ -z "$vphone_bin" ]] || [[ ! -x "$vphone_bin" ]]; then
        error "vphone-cli binary not found in $vphone_dir/.build — run Phase 3 first."
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

    # -------------------------------------------------------------------------
    # 3. Boot the VM normally
    #    Upstream: make boot — same flags as boot_dfu but without --dfu
    # -------------------------------------------------------------------------
    section "Starting iOS VM (normal boot)"

    info "Booting VM..."
    info "CPU: $VM_CPU cores, RAM: $((VM_MEMORY / 1024))GB"

    "$vphone_bin" \
        --rom     "$VM_ROM_PATH" \
        --disk    "$VM_DISK" \
        --nvram   "$VM_NVRAM" \
        --sep-rom "$VM_SEP_ROM_PATH" \
        --cpu     "${VM_CPU:-8}" \
        --memory  "${VM_MEMORY:-16384}" \
        --sep-storage "$VM_DIR/SEPStorage" \
        --no-graphics \
        &>/dev/null &
    local vm_pid=$!
    register_pid "$vm_pid"
    info "VM started (PID: $vm_pid)"

    # -------------------------------------------------------------------------
    # 4. Start iproxy tunnels (normal boot)
    #    SSH:  localhost:SSH_LOCAL_PORT (22222) → device:22222
    #    VNC:  localhost:VNC_LOCAL_PORT (5901)  → device:5901
    # -------------------------------------------------------------------------
    section "Starting iproxy tunnels (normal boot)"

    "$iproxy_bin" "$SSH_LOCAL_PORT" 22222 &>/dev/null &
    local iproxy_ssh_pid=$!
    register_pid "$iproxy_ssh_pid"
    info "  SSH tunnel: localhost:$SSH_LOCAL_PORT → device:22222 (PID: $iproxy_ssh_pid)"

    "$iproxy_bin" "$VNC_LOCAL_PORT" 5901 &>/dev/null &
    local iproxy_vnc_pid=$!
    register_pid "$iproxy_vnc_pid"
    info "  VNC tunnel: localhost:$VNC_LOCAL_PORT → device:5901  (PID: $iproxy_vnc_pid)"

    # -------------------------------------------------------------------------
    # 5. Wait for SSH on localhost:SSH_LOCAL_PORT
    # -------------------------------------------------------------------------
    section "Waiting for VM to boot and SSH to become available"

    local ssh_ready=false
    local sshpass_bin
    sshpass_bin="$(command -v sshpass 2>/dev/null || true)"

    info "Polling localhost:$SSH_LOCAL_PORT for SSH (up to 3 min)..."
    local attempt
    for attempt in $(seq 1 60); do
        # Bail out early if the VM process died
        if ! kill -0 "$vm_pid" 2>/dev/null; then
            error "VM process exited unexpectedly — check $VM_DIR/serial.log"
            return 1
        fi

        if [[ -n "$sshpass_bin" ]]; then
            if "$sshpass_bin" -p "$SSH_PASSWORD" ssh \
                   -o ConnectTimeout=3 \
                   -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p "$SSH_LOCAL_PORT" "root@localhost" "uname -a" 2>/dev/null; then
                ssh_ready=true
                break
            fi
        else
            if ssh -o ConnectTimeout=3 \
                   -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -p "$SSH_LOCAL_PORT" "root@localhost" "uname -a" 2>/dev/null; then
                ssh_ready=true
                break
            fi
        fi

        [[ $(( attempt % 10 )) -eq 0 ]] && info "  Still waiting... (${attempt}/60)"
        sleep 3
    done

    if ! $ssh_ready; then
        warn "SSH not available yet on localhost:$SSH_LOCAL_PORT"
        warn "The system may still be booting — check $VM_DIR/serial.log"
        warn "Try manually: ssh -p $SSH_LOCAL_PORT root@localhost  (password: $SSH_PASSWORD)"
    else
        success "SSH is available!"
    fi

    # -------------------------------------------------------------------------
    # 6. First-boot detection
    #    If /var/profile is absent this is the device's first normal boot.
    #    Log it — the system will initialize launchd services on its own.
    # -------------------------------------------------------------------------
    if $ssh_ready; then
        local _ssh_check_cmd
        if [[ -n "$sshpass_bin" ]]; then
            _ssh_check_cmd() { "$sshpass_bin" -p "$SSH_PASSWORD" ssh \
                -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -p "$SSH_LOCAL_PORT" "root@localhost" "$@"; }
        else
            _ssh_check_cmd() { ssh \
                -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -p "$SSH_LOCAL_PORT" "root@localhost" "$@"; }
        fi

        if ! _ssh_check_cmd "test -f /var/profile" 2>/dev/null; then
            info ""
            info "First boot detected (/var/profile absent)."
            info "iOS is initializing — launchd services are starting up."
            info "This may take 1-2 minutes on first boot."
        else
            info "System has booted before — /var/profile present."
        fi
    fi

    # -------------------------------------------------------------------------
    # 7. Print connection info
    # -------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${GREEN}=================================================================${RESET}"
    echo -e "${BOLD}${GREEN}  iOS VM is running!${RESET}"
    echo -e "${BOLD}${GREEN}=================================================================${RESET}"
    echo ""
    echo -e "  ${BOLD}SSH:${RESET}      ssh -p $SSH_LOCAL_PORT root@localhost"
    echo -e "  ${BOLD}Password:${RESET} $SSH_PASSWORD"
    echo -e "  ${BOLD}VNC:${RESET}      vnc://localhost:$VNC_LOCAL_PORT"
    echo -e "  ${BOLD}VM PID:${RESET}   $vm_pid"
    echo ""
    echo -e "  ${DIM}To stop the VM:  kill $vm_pid${RESET}"
    echo -e "  ${DIM}To re-run:       ./setup.sh --phase 7${RESET}"
    echo ""

    save_state "phase7"
    success "Phase 7 complete — iOS VM is booted and running."

    # Keep the script running so cleanup trap works and tunnels stay alive
    info "Press Ctrl+C to stop the VM and iproxy tunnels."
    wait "$vm_pid" 2>/dev/null || true
}

