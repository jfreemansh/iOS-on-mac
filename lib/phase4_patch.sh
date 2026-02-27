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
    # 0. SHSH blob pre-flight check
    #    ramdisk_build.py requires SHSH blobs to sign the IMG4 ramdisk images.
    #    Warn early so the user can supply them before the long patching steps.
    # -------------------------------------------------------------------------
    ensure_dir "$WORK_DIR/shsh"
    if [[ -z "$(ls -A "$WORK_DIR/shsh" 2>/dev/null)" ]]; then
        warn "======================================================================"
        warn "  SHSH BLOB REQUIRED — $WORK_DIR/shsh/ is empty"
        warn "======================================================================"
        warn "  ramdisk_build.py cannot sign the ramdisk without a saved SHSH blob."
        warn ""
        warn "  To obtain blobs, run ONE of the following:"
        warn "    ipsw download appledb --device iPhone15,2 --version <iOS version>"
        warn "    OR save blobs from a running vphone VM with blobsaver/tsschecker"
        warn ""
        warn "  Copy the resulting .shsh/.shsh2 file to:"
        warn "    $WORK_DIR/shsh/"
        warn ""
        warn "  Patching will continue, but the ramdisk build step will be skipped."
        warn "======================================================================"
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
# Python dependency check
# =============================================================================
_verify_python_patching_tools() {
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"

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

    # keystone-engine installs as module 'keystone', capstone stays 'capstone'
    local pip_pkgs=()
    python3 -c "import keystone" 2>/dev/null  || pip_pkgs+=("keystone-engine")
    python3 -c "import capstone" 2>/dev/null  || pip_pkgs+=("capstone")
    python3 -c "import pyimg4"   2>/dev/null  || pip_pkgs+=("pyimg4")

    if [[ ${#pip_pkgs[@]} -gt 0 ]]; then
        info "Installing missing Python packages: ${pip_pkgs[*]}"
        pip3 install "${pip_pkgs[@]}" 2>&1 | tee -a "$CURRENT_LOG_FILE" || {
            error "pip3 install failed.  Run manually:"
            error "  pip3 install keystone-engine capstone pyimg4"
            return 1
        }
    fi

    success "Python patching dependencies satisfied ($scripts_dir)"
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
        python3 fw_patch.py "$WORK_DIR" 2>&1 | tee -a "$CURRENT_LOG_FILE"
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
        python3 ramdisk_build.py "$WORK_DIR" 2>&1 | tee -a "$CURRENT_LOG_FILE"
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
