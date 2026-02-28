#!/bin/bash
# lib/phase6_install.sh — First boot: generate SSH host keys via console

run_phase6_install() {
    phase_banner "6" "First Boot (Console Setup)"

    CURRENT_LOG_FILE="$LOG_DIR/phase6.log"

    local vphone_dir="$WORK_DIR/tools/vphone-cli"

    section "First Boot — Console Setup"
    echo
    echo "  Run in a terminal:"
    echo "    cd \"$vphone_dir\" && make boot VM_DIR=\"$VM_DIR\" CPU=${VM_CPU:-8} MEMORY=${VM_MEMORY:-16384}"
    echo
    echo "  When you see  bash-4.4#  press Enter and run these commands:"
    echo
    echo '    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'
    echo '    mkdir -p /var/dropbear'
    echo '    cp /iosbinpack64/etc/profile /var/profile'
    echo '    cp /iosbinpack64/etc/motd /var/motd'
    echo '    dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key'
    echo '    dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key'
    echo '    shutdown -h now'
    echo
    echo "  Wait for shutdown to complete (terminal returns to prompt)."
    echo
    read -r -p "Press ENTER when shutdown is complete: "

    save_state "phase6"
    success "Phase 6 complete — first boot done, SSH keys generated."
}
