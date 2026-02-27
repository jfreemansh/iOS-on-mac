#!/bin/bash
# lib/phase7_boot.sh — Normal boot of the iOS VM
# Kills any DFU processes, boots the VM normally, optionally starts VNC

run_phase7_boot() {
    phase_banner "7" "Normal Boot"

    CURRENT_LOG_FILE="$LOG_DIR/phase7.log"

    setup_cleanup_trap

    local vm_tool=""
    local vm_name="vphone"

    case "$VM_APPROACH" in
        vphone-cli)
            vm_tool="$(_find_vm_tool_p7 "vphone-cli")"
            ;;
        super-tart)
            vm_tool="$(_find_vm_tool_p7 "tart")"
            ;;
    esac

    if [[ -z "$vm_tool" ]]; then
        error "VM tool not found. Run Phase 3 first."
        return 1
    fi

    # -------------------------------------------------------------------------
    # 1. Kill any lingering DFU/ramdisk VM processes
    # -------------------------------------------------------------------------
    section "Cleaning up previous VM processes"

    cleanup_pids

    # Also try to find and kill any stale VM processes
    local stale_pids
    stale_pids="$(pgrep -f "$vm_name.*--dfu" 2>/dev/null || true)"
    if [[ -n "$stale_pids" ]]; then
        info "Killing stale DFU processes: $stale_pids"
        echo "$stale_pids" | xargs kill 2>/dev/null || true
        sleep 2
    fi

    # -------------------------------------------------------------------------
    # 2. Boot the VM normally
    # -------------------------------------------------------------------------
    section "Starting iOS VM"

    info "Booting VM '$vm_name' in normal mode..."
    info "Display: ${VM_DISPLAY_WIDTH}x${VM_DISPLAY_HEIGHT} @ ${VM_DISPLAY_PPI}ppi"
    info "CPU: $VM_CPU cores, RAM: $((VM_MEMORY / 1024))GB"

    local boot_cmd=("$vm_tool" "run" "$vm_name")

    # Add VNC support if available
    boot_cmd+=("--vnc-experimental")

    info ""
    info "Boot command: ${boot_cmd[*]}"
    info ""

    # Start the VM in the background
    "${boot_cmd[@]}" &
    local vm_pid=$!
    register_pid "$vm_pid"

    info "VM started (PID: $vm_pid)"

    # -------------------------------------------------------------------------
    # 3. Wait for boot and get IP
    # -------------------------------------------------------------------------
    section "Waiting for VM to boot"

    local vm_ip=""
    info "Waiting for VM to obtain IP address..."

    for attempt in $(seq 1 90); do
        if ! kill -0 "$vm_pid" 2>/dev/null; then
            error "VM process exited unexpectedly"
            wait "$vm_pid" 2>/dev/null
            return 1
        fi

        vm_ip="$("$vm_tool" ip "$vm_name" 2>/dev/null || echo "")"
        if [[ -n "$vm_ip" ]] && [[ "$vm_ip" != "0.0.0.0" ]]; then
            break
        fi

        if (( attempt % 15 == 0 )); then
            info "  Still waiting for boot... (${attempt}s / 180s)"
        fi
        sleep 2
    done

    if [[ -n "$vm_ip" ]] && [[ "$vm_ip" != "0.0.0.0" ]]; then
        success "VM IP address: $vm_ip"
    else
        warn "Could not determine VM IP — it may still be booting"
        vm_ip="localhost"
    fi

    # -------------------------------------------------------------------------
    # 4. Wait for SSH
    # -------------------------------------------------------------------------
    section "Checking SSH connectivity"

    local ssh_port=22
    [[ "$vm_ip" == "localhost" ]] && ssh_port="$SSH_LOCAL_PORT"

    local ssh_ready=false
    for attempt in $(seq 1 30); do
        if sshpass -p "$SSH_PASSWORD" ssh \
               -o ConnectTimeout=3 \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -p "$ssh_port" "root@${vm_ip}" "uname -a" 2>/dev/null; then
            ssh_ready=true
            break
        fi
        sleep 3
    done

    if $ssh_ready; then
        success "SSH is available!"
    else
        warn "SSH not yet available — the system may still be booting"
        warn "Try manually: ssh -p $ssh_port root@$vm_ip (password: $SSH_PASSWORD)"
    fi

    # -------------------------------------------------------------------------
    # 5. Print connection info
    # -------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}${GREEN}=================================================================${RESET}"
    echo -e "${BOLD}${GREEN}  iOS VM is running!${RESET}"
    echo -e "${BOLD}${GREEN}=================================================================${RESET}"
    echo ""
    echo -e "  ${BOLD}SSH:${RESET}  ssh -p $ssh_port root@$vm_ip"
    echo -e "  ${BOLD}Password:${RESET}  $SSH_PASSWORD"
    echo -e "  ${BOLD}VNC:${RESET}  vnc://$vm_ip:$VNC_LOCAL_PORT"
    echo -e "  ${BOLD}VM PID:${RESET}  $vm_pid"
    echo ""
    echo -e "  ${DIM}To stop the VM:  kill $vm_pid${RESET}"
    echo -e "  ${DIM}To re-run:       ./setup.sh --phase 7${RESET}"
    echo ""

    save_state "phase7"
    success "Phase 7 complete — iOS VM is booted and running."

    # Keep the script running so cleanup trap works
    info "Press Ctrl+C to stop the VM."
    wait "$vm_pid" 2>/dev/null || true
}

# =============================================================================
# Helper (duplicated to avoid dependency on phase5)
# =============================================================================

_find_vm_tool_p7() {
    local name="$1"

    if check_command "$name"; then
        command -v "$name"
        return 0
    fi

    local build_bin
    build_bin="$(find "$WORK_DIR/tools" -name "$name" -type f -perm +111 2>/dev/null | head -1)"
    if [[ -n "$build_bin" ]]; then
        echo "$build_bin"
        return 0
    fi

    local link="$WORK_DIR/tools/${name}-bin"
    if [[ -x "$link" ]]; then
        echo "$link"
        return 0
    fi

    return 1
}
