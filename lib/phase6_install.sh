#!/bin/bash
# lib/phase6_install.sh — Install iOS to VM disk via SSH ramdisk
# Mounts rootfs, patches filesystem, installs Metal plugin, configures SSH

run_phase6_install() {
    phase_banner "6" "iOS Installation via SSH Ramdisk"

    CURRENT_LOG_FILE="$LOG_DIR/phase6.log"

    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local cfw_install_sh="$vphone_dir/scripts/cfw_install.sh"

    if [[ ! -f "$cfw_install_sh" ]]; then
        error "cfw_install.sh not found at $cfw_install_sh"
        error "Update vphone-cli: git -C $vphone_dir pull"
        return 1
    fi

    # Load firmware paths (used by _install_metal_plugin indirectly)
    if [[ -f "$WORK_DIR/.firmware_paths" ]]; then
        source "$WORK_DIR/.firmware_paths"
    fi

    # SSH helpers targeting ramdisk on localhost:2222
    # (cfw_install.sh also hardcodes SSH_PORT=2222 SSH_HOST=localhost)
    local _ssh_host="localhost"
    local _ssh_port="2222"
    local sshpass_bin
    sshpass_bin="$(command -v sshpass 2>/dev/null || true)"

    _ssh_cmd() {
        if [[ -n "$sshpass_bin" ]]; then
            "$sshpass_bin" -p "$SSH_PASSWORD" ssh \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -p "$_ssh_port" "root@${_ssh_host}" "$@"
        else
            ssh -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -p "$_ssh_port" "root@${_ssh_host}" "$@"
        fi
    }

    _scp_to() {
        local src="$1"
        local dest="$2"
        if [[ -n "$sshpass_bin" ]]; then
            "$sshpass_bin" -p "$SSH_PASSWORD" scp \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -P "$_ssh_port" "$src" "root@${_ssh_host}:${dest}"
        else
            scp -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -P "$_ssh_port" "$src" "root@${_ssh_host}:${dest}"
        fi
    }

    # -------------------------------------------------------------------------
    # 1. Verify SSH on localhost:2222 (ramdisk)
    # -------------------------------------------------------------------------
    section "Verifying SSH ramdisk connection"

    if ! _ssh_cmd "echo connected" &>/dev/null; then
        error "Cannot connect to SSH ramdisk on localhost:2222"
        error "Make sure Phase 5 completed successfully and the VM is still running."
        return 1
    fi
    success "SSH ramdisk connected (localhost:2222)"

    # -------------------------------------------------------------------------
    # 2. Run upstream cfw_install.sh
    #    Upstream: cd $(VM_DIR) && zsh cfw_install.sh .
    # -------------------------------------------------------------------------
    section "Running cfw_install.sh"

    # Expose venv binaries so cfw.py can import pyimg4/capstone/keystone
    local venv_python="$vphone_dir/.venv/bin/python3"
    if [[ -x "$venv_python" ]]; then
        export PATH="$vphone_dir/.venv/bin:$PATH"
        info "  Python venv activated: $vphone_dir/.venv"
    fi

    info "Running cfw_install.sh from $WORK_DIR ..."
    (
        cd "$WORK_DIR"
        zsh "$cfw_install_sh" . 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local cfw_rc=${PIPESTATUS[0]}

    if [[ $cfw_rc -ne 0 ]]; then
        error "cfw_install.sh failed (exit code $cfw_rc)"
        error "Check: $CURRENT_LOG_FILE"
        return 1
    fi
    success "cfw_install.sh completed!"

    # -------------------------------------------------------------------------
    # 3. Install Metal compiler plugin (custom addition — not in upstream)
    # -------------------------------------------------------------------------
    section "Installing Metal Compiler Plugin"

    _install_metal_plugin

    # -------------------------------------------------------------------------
    # 4. Tear down ramdisk SSH tunnel
    # -------------------------------------------------------------------------
    section "Tearing down ramdisk SSH tunnel"

    local _iproxy_pid_file="$WORK_DIR/.iproxy_ramdisk_pid"
    if [[ -f "$_iproxy_pid_file" ]]; then
        local _piproxy
        _piproxy="$(cat "$_iproxy_pid_file")"
        if kill -0 "$_piproxy" 2>/dev/null; then
            kill "$_piproxy" 2>/dev/null
            info "  Stopped iproxy PID $_piproxy"
        fi
        rm -f "$_iproxy_pid_file"
    fi
    # Belt-and-suspenders kill
    pkill -f "iproxy 2222" 2>/dev/null || true

    save_state "phase6"
    success "Phase 6 complete — CFW installed on VM disk."
    info ""
    info "The VM disk is now ready for normal boot (Phase 7)."
}

# =============================================================================
# Metal Plugin Installation
# =============================================================================

_install_metal_plugin() {
    local plugin_src_dir="$SCRIPT_DIR/CFW/libAppleParavirtCompilerPluginIOGPUFamily"
    local dylib_name="libAppleParavirtCompilerPluginIOGPUFamily.dylib"
    local bundle_path="/mnt1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"

    # Find the dylib — check both the source dir and any build output
    local dylib_path=""
    if [[ -f "$plugin_src_dir/$dylib_name" ]]; then
        dylib_path="$plugin_src_dir/$dylib_name"
    else
        # Check for dylib in common build locations
        local found
        found="$(find "$plugin_src_dir" -name "*.dylib" 2>/dev/null | head -1)"
        if [[ -n "$found" ]]; then
            dylib_path="$found"
        fi
    fi

    if [[ -z "$dylib_path" ]]; then
        warn "Metal compiler plugin dylib not found."
        warn "Build it first: cd $plugin_src_dir && ./download.sh && ./build.sh"
        warn ""
        warn "GPU/Metal acceleration will not work without this plugin."
        warn "You can install it later by re-running Phase 6."
        return 0
    fi

    info "Installing Metal compiler plugin to VM..."

    # Check if the bundle directory exists on the rootfs
    if _ssh_cmd "test -d $bundle_path" 2>/dev/null; then
        info "  Bundle directory exists: $bundle_path"
    else
        info "  Creating bundle directory: $bundle_path"
        _ssh_cmd "mkdir -p $bundle_path"
    fi

    # Copy the dylib to the VM
    info "  Uploading $dylib_name..."
    _scp_to "$dylib_path" "$bundle_path/$dylib_name"

    # Re-sign on device with ldid
    info "  Re-signing dylib on device..."
    _ssh_cmd "ldid -S $bundle_path/$dylib_name" 2>&1 | tee -a "$CURRENT_LOG_FILE" || {
        warn "  ldid signing failed — trying codesign fallback"
        _ssh_cmd "codesign -f -s - $bundle_path/$dylib_name" 2>/dev/null || true
    }

    # Verify
    if _ssh_cmd "test -f $bundle_path/$dylib_name" 2>/dev/null; then
        success "Metal compiler plugin installed and signed"
        success "  Location: $bundle_path/$dylib_name"
    else
        warn "Metal plugin installation may have failed — verify manually"
    fi
}
