#!/bin/bash
# lib/phase4_patch.sh — Patch firmware using upstream vphone-cli Python scripts
# Uses fw_patch.py (IBootPatcher + KernelPatcher + TXMPatcher) instead of kairos.
# Builds the SSH ramdisk via ramdisk_build.py.
# Also builds the Metal compiler plugin for paravirtualized GPU support.

run_phase4_patch() {
    phase_banner "4" "Firmware Patching"

    CURRENT_LOG_FILE="$LOG_DIR/phase4.log"

    # Load firmware paths from phase 2
    if [[ -f "$WORK_DIR/.firmware_paths" ]]; then
        source "$WORK_DIR/.firmware_paths"
    else
        error "Firmware paths not found. Run Phase 2 first."
        return 1
    fi

    # --repatch flag: wipe previous patching stamps and Ramdisk output
    if [[ "${FORCE_REPATCH:-0}" == "1" ]]; then
        info "--repatch: removing stale patched output..."
        rm -f "$IPHONE_EXTRACT/.cloudos_merged" "$IPHONE_EXTRACT/.fw_patched"
        rm -rf "$WORK_DIR/Ramdisk" "$WORK_DIR/ramdisk_builder_temp"
        success "Stale output removed — will re-patch from scratch"
    fi

    # -------------------------------------------------------------------------
    # 0. SHSH blobs — fetch automatically via idevicerestore -t if not present
    # -------------------------------------------------------------------------
    ensure_dir "$WORK_DIR/shsh"
    if [[ -z "$(ls -A "$WORK_DIR/shsh" 2>/dev/null)" ]]; then
        section "Fetching SHSH blobs"
        _fetch_shsh_blobs || {
            warn "SHSH auto-fetch failed — ramdisk build step will be skipped."
            warn "Place a .shsh/.shsh2 file in $WORK_DIR/shsh/ and re-run with --repatch."
        }
    else
        info "SHSH blobs: $(ls "$WORK_DIR/shsh/" | tr '\n' ' ')"
    fi

    # -------------------------------------------------------------------------
    # 1. Merge cloudOS firmware into iPhone directory
    # -------------------------------------------------------------------------
    section "Merging cloudOS firmware into iPhone directory"
    _merge_cloudos_firmware

    # -------------------------------------------------------------------------
    # 2. Create compatibility symlink so upstream scripts find the restore dir
    #    fw_patch.py calls find_restore_dir(vm_dir) which looks for *Restore*
    # -------------------------------------------------------------------------
    local restore_link="$WORK_DIR/iphone_Restore"
    if [[ ! -L "$restore_link" ]] || [[ "$(readlink "$restore_link")" != "$IPHONE_EXTRACT" ]]; then
        ln -sfn "$IPHONE_EXTRACT" "$restore_link"
        info "Compatibility symlink: $restore_link -> $IPHONE_EXTRACT"
    fi

    # -------------------------------------------------------------------------
    # 3. Verify and install Python patching dependencies
    # -------------------------------------------------------------------------
    section "Verifying Python patching tools"
    _verify_python_patching_tools

    # -------------------------------------------------------------------------
    # 4. Run fw_patch.py — patches iBSS, iBEC, LLB, TXM, kernelcache in-place
    # -------------------------------------------------------------------------
    section "Patching firmware (fw_patch.py)"
    _run_fw_patch_py

    # -------------------------------------------------------------------------
    # 5. Build Metal compiler plugin (paravirtualized GPU)
    # -------------------------------------------------------------------------
    section "Metal Compiler Plugin (Paravirtualized GPU)"
    _build_metal_plugin

    # -------------------------------------------------------------------------
    # 6. Build SSH ramdisk (ramdisk_build.py → Ramdisk/)
    # -------------------------------------------------------------------------
    section "Building SSH ramdisk"
    _build_ramdisk_upstream

    save_state "phase4"
    success "Phase 4 complete — firmware patched and ramdisk staged."
}

# =============================================================================
# SHSH blob auto-fetch
# Boots the VM in DFU mode, uses the patched idevicerestore -t to request the
# TSS ticket (SHSH blob) from Apple's signing server, then kills the DFU boot.
# Requires: patched idevicerestore built by Phase 3 (_build_libimobiledevice),
#           VM ROM files from Virtualization.framework, and VM_DISK to exist.
# =============================================================================
_fetch_shsh_blobs() {
    local vphone_dir="$WORK_DIR/tools/vphone-cli"
    local idevicerestore="$vphone_dir/.limd/bin/idevicerestore"

    # ---- Prerequisites ----
    if [[ ! -x "$idevicerestore" ]]; then
        warn "Patched idevicerestore not found at $idevicerestore"
        warn "Re-run Phase 3 to build the patched libimobiledevice stack."
        return 1
    fi

    local vphone_bin
    vphone_bin="$(find "$vphone_dir/.build" -name "vphone-cli" -type f \
        ! -path "*dSYM*" ! -path "*/debug/*" 2>/dev/null | head -1)"
    if [[ -z "$vphone_bin" ]] || [[ ! -x "$vphone_bin" ]]; then
        warn "vphone-cli binary not found — cannot start DFU boot for SHSH fetch."
        return 1
    fi

    if [[ ! -f "$VM_ROM_PATH" ]]; then
        warn "AVPBooter ROM not found at $VM_ROM_PATH"
        warn "Requires a macOS build that ships the vresearch1 ROM."
        return 1
    fi

    if [[ ! -f "$VM_SEP_ROM_PATH" ]]; then
        warn "SEP ROM not found at $VM_SEP_ROM_PATH"
        return 1
    fi

    # Check restore dir symlink exists (created earlier in run_phase4_patch)
    if [[ ! -e "$WORK_DIR/iphone_Restore" ]]; then
        warn "iphone_Restore symlink not found — firmware merge may not have run yet."
        return 1
    fi

    # ---- Ensure minimal VM runtime files exist for DFU boot ----
    ensure_dir "$VM_DIR"

    if [[ ! -f "$VM_DISK" ]]; then
        info "  Creating sparse VM disk image (${VM_DISK_SIZE:-64g})..."
        # Use dd with seek to create a sparse file; APFS/HFS+ won't allocate
        # physical blocks for the holes, so this only uses ~0 bytes on disk.
        local _sectors
        _sectors="$(( ${VM_DISK_SIZE:-64} * 2097152 ))"   # default 64g = sectors
        case "${VM_DISK_SIZE:-64g}" in
            *g) _gb="${VM_DISK_SIZE//g/}" ; _sectors=$(( _gb * 2097152 )) ;;
            *m) _mb="${VM_DISK_SIZE//m/}" ; _sectors=$(( _mb * 2048 ))    ;;
            *)  _sectors=$(( 64 * 2097152 )) ;;
        esac
        dd if=/dev/zero of="$VM_DISK" bs=512 count=0 seek="$_sectors" 2>/dev/null || {
            warn "  Could not create disk image at $VM_DISK"
            return 1
        }
        info "  Sparse disk created: $VM_DISK"
    fi

    if [[ ! -f "$VM_DIR/SEPStorage" ]]; then
        info "  Creating SEP storage (64 MB)..."
        dd if=/dev/zero of="$VM_DIR/SEPStorage" bs=1m count=64 2>/dev/null || true
    fi

    if [[ ! -f "$VM_NVRAM" ]]; then
        touch "$VM_NVRAM"
    fi

    # ---- Boot VM in DFU mode ----
    info "  Starting VM in DFU mode (PID will be killed after SHSH fetch)..."
    "$vphone_bin" \
        --rom    "$VM_ROM_PATH"       \
        --disk   "$VM_DISK"           \
        --nvram  "$VM_NVRAM"          \
        --cpu    "${VM_CPU:-4}"       \
        --memory "${VM_MEMORY:-8192}" \
        --serial-log "$VM_DIR/serial_shsh.log" \
        --stop-on-panic --stop-on-fatal-error \
        --sep-rom     "$VM_SEP_ROM_PATH"   \
        --sep-storage "$VM_DIR/SEPStorage" \
        --no-graphics --dfu &>/dev/null &
    local dfu_pid=$!
    register_pid "$dfu_pid"
    info "  DFU boot PID: $dfu_pid"

    # ---- Wait for DFU device to enumerate on USB (up to 60s) ----
    info "  Waiting for DFU device to appear on USB..."
    local dfu_ready=false
    for _i in $(seq 1 30); do
        if irecovery -q 2>/dev/null | grep -qi "DFU\|Recovery\|CPID"; then
            dfu_ready=true
            break
        fi
        sleep 2
    done

    if ! $dfu_ready; then
        warn "  DFU device did not enumerate after 60s."
        kill "$dfu_pid" 2>/dev/null; wait "$dfu_pid" 2>/dev/null
        warn "  Check $VM_DIR/serial_shsh.log for boot errors."
        return 1
    fi
    success "  DFU device detected."

    # ---- Fetch SHSH blob (TSS ticket only, no actual restore) ----
    # Run from $WORK_DIR so idevicerestore writes shsh/ to $WORK_DIR/shsh/.
    # ./iphone_Restore is the symlink created earlier pointing at $IPHONE_EXTRACT.
    info "  Fetching SHSH blob via idevicerestore -t ..."
    (
        cd "$WORK_DIR"
        "$idevicerestore" -e -y ./iphone_Restore -t 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local rc=$?

    # ---- Kill DFU boot ----
    kill "$dfu_pid" 2>/dev/null
    wait "$dfu_pid" 2>/dev/null

    if [[ $rc -ne 0 ]]; then
        warn "  idevicerestore -t exited $rc — check $CURRENT_LOG_FILE"
        return 1
    fi

    # ---- Verify output ----
    local blob_count
    blob_count="$(find "$WORK_DIR/shsh" \( -name "*.shsh" -o -name "*.shsh2" \) \
        2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$blob_count" -gt 0 ]]; then
        success "  SHSH blob(s) saved ($blob_count):"
        find "$WORK_DIR/shsh" \( -name "*.shsh" -o -name "*.shsh2" \) | \
            while read -r f; do info "    $(basename "$f")"; done
    else
        warn "  idevicerestore -t completed but no .shsh/.shsh2 found in $WORK_DIR/shsh/"
        return 1
    fi
}

# =============================================================================
# Firmware merge: cloudOS → iPhone directory
# Copies vresearch101/vphone600 variants from cloudOS into the iPhone extract,
# mirroring what the upstream fw_prepare.sh does.
# =============================================================================
_merge_cloudos_firmware() {
    local iphone_dir="$IPHONE_EXTRACT"
    local cloudos_dir="$CLOUDOS_EXTRACT"

    if [[ ! -d "$iphone_dir" ]]; then
        error "iPhone extract directory not found: $iphone_dir"
        return 1
    fi
    if [[ ! -d "$cloudos_dir" ]]; then
        error "cloudOS extract directory not found: $cloudos_dir"
        return 1
    fi

    local stamp="$iphone_dir/.cloudos_merged"
    if [[ "${FORCE_REPATCH:-0}" != "1" ]] && [[ -f "$stamp" ]]; then
        info "cloudOS already merged into iPhone directory"
        return 0
    fi

    info "Merging cloudOS Firmware/ subdirs into iPhone Firmware/..."
    for sub in agx all_flash ane dfu pmp; do
        local src_sub="$cloudos_dir/Firmware/$sub"
        local dst_sub="$iphone_dir/Firmware/$sub"
        if [[ -d "$src_sub" ]]; then
            mkdir -p "$dst_sub"
            # -n = don't overwrite iPhone originals; they may be newer
            cp -n "$src_sub"/* "$dst_sub"/ 2>/dev/null || true
            info "  Merged Firmware/$sub/ ($(ls "$src_sub" | wc -l | tr -d ' ') files)"
        fi
    done

    # Firmware/*.im4p at the Firmware/ root (e.g. txm.iphoneos.research.im4p)
    if ls "$cloudos_dir/Firmware/"*.im4p &>/dev/null 2>&1; then
        mkdir -p "$iphone_dir/Firmware"
        cp -n "$cloudos_dir/Firmware/"*.im4p "$iphone_dir/Firmware"/ 2>/dev/null || true
        info "  Merged Firmware/*.im4p"
    fi

    # kernelcache.* files at the IPSW root (e.g. kernelcache.research.vphone600)
    if ls "$cloudos_dir"/kernelcache.* &>/dev/null 2>&1; then
        cp -n "$cloudos_dir"/kernelcache.* "$iphone_dir"/ 2>/dev/null || true
        info "  Merged kernelcache.*"
    fi

    # .dmg files (-n = don't overwrite iPhone's restore DMGs)
    if ls "$cloudos_dir"/*.dmg &>/dev/null 2>&1; then
        cp -n "$cloudos_dir"/*.dmg "$iphone_dir"/ 2>/dev/null || true
        info "  Merged *.dmg"
    fi

    touch "$stamp"

    # Verify key vresearch101/vphone600 variants are now present
    local found_ibss found_kc
    found_ibss="$(find "$iphone_dir/Firmware/dfu" \
        \( -name "*vresearch101*iBSS*" -o -name "*iBSS*vresearch101*" \) 2>/dev/null | head -1)"
    found_kc="$(find "$iphone_dir" -maxdepth 1 -name "kernelcache.research.vphone600" 2>/dev/null | head -1)"

    if [[ -n "$found_ibss" ]]; then
        success "  vresearch101 iBSS: $(basename "$found_ibss")"
    else
        warn "  vresearch101 iBSS NOT found after merge — cloudOS IPSW may be missing dfu/ dir"
    fi
    if [[ -n "$found_kc" ]]; then
        success "  kernelcache.research.vphone600 found"
    else
        warn "  kernelcache.research.vphone600 NOT found — check cloudOS IPSW"
    fi
}

# =============================================================================
# Python dependency check — uses upstream setup_venv.sh
# setup_venv.sh creates PROJECT_ROOT/.venv, installs pip packages, then
# builds libkeystone.dylib from Homebrew's static libkeystone.a and injects
# it into the venv so that keystone-engine can load it at runtime.
# Sets the global VENV_PYTHON used by _run_fw_patch_py and _build_ramdisk_upstream.
# =============================================================================
_verify_python_patching_tools() {
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"
    local venv_dir="$WORK_DIR/tools/vphone-cli/.venv"
    # Export so callers can use this Python for all script invocations
    VENV_PYTHON="$venv_dir/bin/python3"

    if [[ ! -d "$scripts_dir" ]]; then
        error "vphone-cli scripts not found at $scripts_dir"
        error "Run Phase 3 first to clone vphone-cli."
        return 1
    fi
    if [[ ! -f "$scripts_dir/fw_patch.py" ]]; then
        error "fw_patch.py not found in $scripts_dir"
        error "Update vphone-cli:  git -C $WORK_DIR/tools/vphone-cli pull"
        return 1
    fi
    if [[ ! -f "$scripts_dir/setup_venv.sh" ]]; then
        error "setup_venv.sh not found in $scripts_dir"
        error "Update vphone-cli:  git -C $WORK_DIR/tools/vphone-cli pull"
        return 1
    fi

    # Check whether the venv is already set up and all imports work.
    # keystone-engine needs libkeystone.dylib which setup_venv.sh builds from brew.
    local _needs_setup=false
    if [[ ! -x "$VENV_PYTHON" ]]; then
        _needs_setup=true
    elif ! "$VENV_PYTHON" -c "import keystone, capstone, pyimg4" &>/dev/null 2>&1; then
        _needs_setup=true
    fi

    if $_needs_setup; then
        # Ensure the brew C library is present before setup_venv.sh tries to build the dylib
        if ! brew list keystone &>/dev/null 2>&1; then
            info "Installing Homebrew keystone (required by setup_venv.sh)..."
            brew install keystone 2>&1 | tee -a "$CURRENT_LOG_FILE" || {
                error "Failed to install keystone via Homebrew."
                return 1
            }
        fi

        info "Running setup_venv.sh to build venv + libkeystone.dylib..."
        (
            cd "$scripts_dir"
            bash setup_venv.sh 2>&1 | tee -a "$CURRENT_LOG_FILE"
        )
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            error "setup_venv.sh failed (exit code $rc)"
            error "Check logs: $CURRENT_LOG_FILE"
            return 1
        fi
    fi

    # Final verification
    if ! "$VENV_PYTHON" -c "import keystone, capstone, pyimg4" 2>/dev/null; then
        error "Python imports still failing after setup_venv.sh"
        error "  venv python: $VENV_PYTHON"
        error "  Run manually: cd $scripts_dir && bash setup_venv.sh"
        return 1
    fi

    success "Python patching venv ready: $venv_dir"
    "$VENV_PYTHON" -c "import keystone, capstone, pyimg4; print('  keystone / capstone / pyimg4: OK')"
}

# =============================================================================
# fw_patch.py — patch iBSS, iBEC, LLB, TXM, kernelcache in-place
# =============================================================================
_run_fw_patch_py() {
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"
    local stamp="$IPHONE_EXTRACT/.fw_patched"

    if [[ "${FORCE_REPATCH:-0}" != "1" ]] && [[ -f "$stamp" ]]; then
        info "Firmware already patched (stamp found).  Use --repatch to redo."
        return 0
    fi

    # fw_patch.py looks for AVPBooter*.bin directly in vm_dir ($WORK_DIR).
    # VM_ROM_PATH already points to the correct file in Virtualization.framework.
    if ! ls "$WORK_DIR"/AVPBooter*.bin &>/dev/null 2>&1; then
        local avp_src="${VM_ROM_PATH:-}"
        if [[ -z "$avp_src" ]] || [[ ! -f "$avp_src" ]]; then
            avp_src="$(find /System/Library/Frameworks/Virtualization.framework \
                -name "AVPBooter*.bin" 2>/dev/null | head -1)"
        fi
        if [[ -n "$avp_src" ]] && [[ -f "$avp_src" ]]; then
            cp "$avp_src" "$WORK_DIR/"
            info "  Staged AVPBooter: $(basename "$avp_src")"
        else
            warn "  AVPBooter not found — fw_patch.py will fail on AVPBooter component"
        fi
    else
        info "  AVPBooter already present in $WORK_DIR"
    fi

    info "Running fw_patch.py with vm_dir=$WORK_DIR ..."
    (
        cd "$scripts_dir"
        "${VENV_PYTHON:-python3}" fw_patch.py "$WORK_DIR" 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        error "fw_patch.py failed (exit code $rc)"
        error "Check logs: $CURRENT_LOG_FILE"
        return 1
    fi

    touch "$stamp"
    success "All boot-chain components patched"
}

# =============================================================================
# ramdisk_build.py — build signed IMG4 Ramdisk/ directory
# =============================================================================
_build_ramdisk_upstream() {
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"

    if [[ ! -f "$scripts_dir/ramdisk_build.py" ]]; then
        warn "ramdisk_build.py not found ($scripts_dir)"
        warn "Update vphone-cli:  git -C $WORK_DIR/tools/vphone-cli pull"
        warn "Skipping ramdisk build — Phase 5 will need Ramdisk/ to be present."
        return 0
    fi

    # Check for SHSH blobs (required for IMG4 signing)
    local shsh_dir="$WORK_DIR/shsh"
    if ! ls "$shsh_dir"/*.shsh "$shsh_dir"/*.shsh2 &>/dev/null 2>&1; then
        warn "No SHSH blobs found in $shsh_dir/"
        warn "SHSH blobs are required to sign ramdisk IMG4 components."
        warn ""
        warn "To obtain the SHSH blob for the virtual device:"
        warn "  1. Boot the VM at least once to a partial state"
        warn "  2. Extract the SHSH from the device or use pccvre"
        warn "  3. Place the .shsh/.shsh2 file in: $shsh_dir/"
        warn ""
        warn "Skipping ramdisk build — place SHSH blobs and re-run with --repatch."
        return 0
    fi

    # Check for ramdisk_input resources
    if [[ ! -d "$WORK_DIR/ramdisk_input" ]]; then
        local archive
        archive="$(find "$scripts_dir" \( -path "*/resources/ramdisk_input.tar.zst" \
                   -o -name "ramdisk_input.tar.zst" \) 2>/dev/null | head -1)"
        if [[ -z "$archive" ]]; then
            warn "ramdisk_input/ not found and no ramdisk_input.tar.zst archive."
            warn "This archive ships with the vphone-cli CFW resources."
            warn "Skipping ramdisk build."
            return 0
        fi
    fi

    if [[ -d "$WORK_DIR/Ramdisk" ]] && [[ "${FORCE_REPATCH:-0}" != "1" ]]; then
        info "Ramdisk/ already built.  Use --repatch to rebuild."
        return 0
    fi

    info "Running ramdisk_build.py with vm_dir=$WORK_DIR ..."
    (
        cd "$scripts_dir"
        "${VENV_PYTHON:-python3}" ramdisk_build.py "$WORK_DIR" 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        error "ramdisk_build.py failed (exit code $rc)"
        error "Check logs: $CURRENT_LOG_FILE"
        return 1
    fi

    success "SSH ramdisk built:"
    ls "$WORK_DIR/Ramdisk/"/*.img4 2>/dev/null | while read -r f; do
        info "  $(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
}

# =============================================================================
# iBEC patching (legacy placeholder — now done by fw_patch.py)
# Kept so that the if block below compiles; the control flow never reaches it.
#
# NOTE: the old kairos-based patching block that previously appeared here has
# been removed.  All iBSS/iBEC/LLB/TXM/kernelcache patching is now handled
# by fw_patch.py using IBootPatcher, TXMPatcher, and KernelPatcher.
# =============================================================================

# Keep the old variable assignments so save_state and the rest of runtime
# doesn't break if sourced separately.
_noop_legacy_kairos() { return 0; }

# Dummy to satisfy the old caller sites that referenced ibec_patched
_patch_ibec_legacy() {
    warn "Legacy kairos-based iBEC patching called — this is a no-op."
    warn "fw_patch.py handles iBEC patching now."
}

# =============================================================================
# Metal Compiler Plugin Build
# =============================================================================

_build_metal_plugin() {
    local plugin_src_dir="$SCRIPT_DIR/CFW/libAppleParavirtCompilerPluginIOGPUFamily"
    local plugin_dylib="$plugin_src_dir/libAppleParavirtCompilerPluginIOGPUFamily.dylib"

    if [[ -f "$plugin_dylib" ]]; then
        info "Metal compiler plugin already built"
        return 0
    fi

    if [[ ! -f "$plugin_src_dir/main.mm" ]]; then
        warn "Metal plugin source (main.mm) not found."
        warn "Download it first:"
        warn "  cd $plugin_src_dir && ./download.sh"
        warn ""
        warn "Or manually download from:"
        warn "  https://zeroxjf.github.io/blog/assets/metal-patch/main.mm"
        warn "  https://zeroxjf.github.io/blog/assets/metal-patch/build.sh"

        if [[ -f "$plugin_src_dir/download.sh" ]]; then
            if prompt_yes_no "Attempt to download Metal plugin sources now?"; then
                bash "$plugin_src_dir/download.sh" || {
                    warn "Download failed — you may need to download manually"
                    return 0
                }
            fi
        fi
    fi

    if [[ -f "$plugin_src_dir/main.mm" ]] && [[ -f "$plugin_src_dir/build.sh" ]]; then
        info "Building Metal compiler plugin..."
        (cd "$plugin_src_dir" && bash ./build.sh) 2>&1 | tee -a "$CURRENT_LOG_FILE"

        if [[ -f "$plugin_dylib" ]]; then
            success "Metal compiler plugin built: $plugin_dylib"
        else
            local any_dylib
            any_dylib="$(find "$plugin_src_dir" -name "*.dylib" | head -1)"
            if [[ -n "$any_dylib" ]]; then
                success "Metal compiler plugin built: $any_dylib"
            else
                warn "Metal plugin build may have failed — check $plugin_src_dir"
            fi
        fi
    else
        warn "Metal plugin sources not available — GPU acceleration may not work"
        warn "The VM will boot but Metal/GPU features will be limited."
        warn ""
        warn "To fix this later, run:"
        warn "  cd $plugin_src_dir && ./download.sh && ./build.sh"
    fi
}
