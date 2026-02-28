#!/bin/bash
# lib/phase7_boot.sh — Normal boot of the iOS VM

run_phase7_boot() {
    phase_banner "7" "Normal Boot"
    CURRENT_LOG_FILE="$LOG_DIR/phase7.log"
    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    pkill -f "vphone-cli" 2>/dev/null || true
    sleep 1
    section "Normal Boot"
    echo
    echo "  Run in a terminal:"
    echo "    cd \"$vphone_dir\" && make boot VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  In a separate terminal, start iproxy tunnels:"
    echo "    iproxy 22222 22222   # SSH"
    echo "    iproxy 5901 5901     # VNC"
    echo
    echo "  SSH:  ssh -p 22222 root@localhost"
    echo "  VNC:  vnc://localhost:5901"
    echo
    read -r -p "Press ENTER when the VM is booted: "
    save_state "phase7"
    success "Phase 7 complete — iOS VM is running."
}
