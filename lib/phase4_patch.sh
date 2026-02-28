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

    # Capital-I symlink for cfw_install.sh's find_restore_dir() glob: iPhone*_Restore
    local restore_link_cap="$WORK_DIR/iPhone_Restore"
    if [[ ! -L "$restore_link_cap" ]] || [[ "$(readlink "$restore_link_cap")" != "$IPHONE_EXTRACT" ]]; then
        ln -sfn "$IPHONE_EXTRACT" "$restore_link_cap"
        info "Compatibility symlink: $restore_link_cap -> $IPHONE_EXTRACT"
    fi

    # -------------------------------------------------------------------------
    # 3. Verify and install Python patching dependencies
    # -------------------------------------------------------------------------
    section "Verifying Python patching tools"
    _verify_python_patching_tools

    # -------------------------------------------------------------------------
    # 3b. Apply local fixes to upstream vphone-cli scripts
    #     (patches that haven't been merged upstream yet)
    # -------------------------------------------------------------------------
    _apply_upstream_patches

    # -------------------------------------------------------------------------
    # 4. Run fw_patch.py — patches iBSS, iBEC, LLB, TXM, kernelcache in-place
    # -------------------------------------------------------------------------
    section "Patching firmware (fw_patch.py)"
    _run_fw_patch_py

    # -------------------------------------------------------------------------
    # 5. Fetch SHSH blobs (requires patched firmware + DFU boot)
    #    Done here — after fw_patch.py — matching upstream's order:
    #    fw_patch → boot_dfu → restore_get_shsh → ramdisk_build
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
    # 6. Build Metal compiler plugin (paravirtualized GPU)
    # -------------------------------------------------------------------------
    section "Metal Compiler Plugin (Paravirtualized GPU)"
    _build_metal_plugin

    # -------------------------------------------------------------------------
    # 7. Build SSH ramdisk (ramdisk_build.py → Ramdisk/)
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

    # ---- Prerequisites: SIP / research entitlements check ----
    # vphone-cli --dfu requires SIP disabled and research guests enabled.
    # The DFU USB device will never appear if these are not in place.
    local _sip_status
    _sip_status="$(csrutil status 2>/dev/null)"
    if echo "$_sip_status" | grep -qi 'enabled'; then
        warn "SIP appears to be enabled: $_sip_status"
        warn "DFU boot requires SIP disabled. Boot Recovery OS and run:"
        warn "  csrutil disable"
        warn "  csrutil allow-research-guests enable"
        return 1
    fi

    # ---- Prerequisites: idevicerestore + vphone-cli ----
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
        # Use Python os.ftruncate to create a proper sparse raw disk image.
        # dd count=0 does NOT work on macOS (APFS allocates a 4096-byte stub),
        # and DiskImages2 rejects that stub with "sparseimage format not supported".
        # os.ftruncate issues a single ftruncate(2) syscall; APFS creates a true
        # sparse file with no physical block allocation.
        local _size_bytes
        case "${VM_DISK_SIZE:-64g}" in
            *g) _size_bytes=$(( ${VM_DISK_SIZE//g/} * 1024 * 1024 * 1024 )) ;;
            *m) _size_bytes=$(( ${VM_DISK_SIZE//m/} * 1024 * 1024 ))        ;;
            *)  _size_bytes=$(( 64 * 1024 * 1024 * 1024 ))                  ;;
        esac
        "${VENV_PYTHON:-python3}" -c "
import os, sys
path = sys.argv[1]; size = int(sys.argv[2])
fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o644)
os.ftruncate(fd, size)
os.close(fd)
print(f'  Sparse disk: {size // (1024**3)} GB at {path}')
" "$VM_DISK" "$_size_bytes" || {
            warn "  Could not create disk image at $VM_DISK"
            return 1
        }
        info "  Sparse disk created: $VM_DISK"
    fi

    # SEPStorage: DO NOT pre-create — vphone-cli's Virtualization.framework
    # initialises the SEP storage file itself (512 KB with proper format).
    # Pre-creating it with zeros (even 64 MB) causes:
    #   VZErrorDomain Code=2 "The coprocessor configuration is invalid."
    # Just ensure the directory exists; vphone-cli will create the file.

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
    # Prefer patched irecovery from .limd/bin/ — the stock Homebrew irecovery
    # does not have the vresearch101ap/0xFE01 entry and will never see the VM.
    local _irecovery_bin
    if [[ -x "$vphone_dir/.limd/bin/irecovery" ]]; then
        _irecovery_bin="$vphone_dir/.limd/bin/irecovery"
        info "  Using patched irecovery: $_irecovery_bin"
    else
        _irecovery_bin="irecovery"
        warn "  Patched irecovery not available — using stock (may not see virtual device)"
    fi

    info "  Waiting for DFU device to appear on USB..."
    local dfu_ready=false
    for _i in $(seq 1 30); do
        if "$_irecovery_bin" -q 2>/dev/null | grep -qi "DFU\|Recovery\|CPID"; then
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
            # Force-copy (no -n): cloudOS variants must overwrite iPhone originals.
            # Upstream fw_prepare.sh uses plain `cp` here for the same reason.
            cp "$src_sub"/* "$dst_sub"/ 2>/dev/null || true
            info "  Merged Firmware/$sub/ ($(ls "$src_sub" | wc -l | tr -d ' ') files)"
        fi
    done

    # Firmware/*.im4p at the Firmware/ root (e.g. txm.iphoneos.research.im4p)
    # Force-copy: cloudOS TXM binary is different from the iPhone one and
    # fw_patch.py's txm.py was written against the cloudOS variant.  Using -n
    # kept the iPhone TXM in place, causing "binary search pattern not found".
    if ls "$cloudos_dir/Firmware/"*.im4p &>/dev/null 2>&1; then
        mkdir -p "$iphone_dir/Firmware"
        cp "$cloudos_dir/Firmware/"*.im4p "$iphone_dir/Firmware"/ 2>/dev/null || true
        info "  Merged Firmware/*.im4p (cloudOS variants override iPhone originals)"
    fi

    # kernelcache.* files at the IPSW root (e.g. kernelcache.research.vphone600)
    if ls "$cloudos_dir"/kernelcache.* &>/dev/null 2>&1; then
        cp "$cloudos_dir"/kernelcache.* "$iphone_dir"/ 2>/dev/null || true
        info "  Merged kernelcache.*"
    fi

    # .dmg and .dmg.trustcache files — keep iPhone originals if present (-n)
    if ls "$cloudos_dir"/*.dmg &>/dev/null 2>&1; then
        cp -n "$cloudos_dir"/*.dmg "$iphone_dir"/ 2>/dev/null || true
        info "  Merged *.dmg"
    fi
    if ls "$cloudos_dir/Firmware/"*.dmg.trustcache &>/dev/null 2>&1; then
        cp -n "$cloudos_dir/Firmware/"*.dmg.trustcache "$iphone_dir/Firmware"/ 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # Generate hybrid BuildManifest.plist + Restore.plist via fw_manifest.py.
    # Without this, BuildManifest.plist only contains real iPhone identities and
    # idevicerestore refuses: "not suitable for the current device" because
    # vresearch101ap / BDID 0x90 is absent.
    # Upstream fw_prepare.sh does this immediately after the copy step.
    # -------------------------------------------------------------------------
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"
    if [[ -f "$scripts_dir/fw_manifest.py" ]]; then
        info "  Generating hybrid BuildManifest.plist (fw_manifest.py)..."
        # Always ensure fw_manifest.py reads the original iPhone manifest, not
        # a previously-generated hybrid.  On first run we back it up; on
        # subsequent repatch runs we restore from the backup first.
        if [[ -f "$iphone_dir/BuildManifest-iPhone.plist" ]]; then
            cp "$iphone_dir/BuildManifest-iPhone.plist" "$iphone_dir/BuildManifest.plist"
        else
            cp "$iphone_dir/BuildManifest.plist" "$iphone_dir/BuildManifest-iPhone.plist"
        fi
        "${VENV_PYTHON:-python3}" "$scripts_dir/fw_manifest.py" \
            "$iphone_dir" "$cloudos_dir" \
            2>&1 | tee -a "${CURRENT_LOG_FILE:-/dev/null}"
        if [[ -f "$iphone_dir/BuildManifest.plist" ]]; then
            success "  Hybrid BuildManifest.plist generated"
        else
            warn "  fw_manifest.py did not produce BuildManifest.plist"
        fi
    else
        warn "  fw_manifest.py not found — idevicerestore may refuse vresearch101ap device"
        warn "  Update vphone-cli: git -C $WORK_DIR/tools/vphone-cli pull"
    fi

    touch "$stamp"

    # -------------------------------------------------------------------------
    # Create vresearch101/vphone600 compatibility symlinks so fw_patch.py can
    # find the expected filenames.  pccvre-downloaded IPSWs use board-config
    # naming (iBSS.d47.RESEARCH_RELEASE.im4p, kernelcache.research.iphone17)
    # while fw_patch.py hardcodes:
    #   Firmware/dfu/iBSS.vresearch101.RELEASE.im4p
    #   Firmware/dfu/iBEC.vresearch101.RELEASE.im4p
    #   Firmware/all_flash/LLB.vresearch101.RELEASE.im4p
    #   kernelcache.research.vphone600
    # -------------------------------------------------------------------------
    info "  Creating vresearch101/vphone600 compatibility symlinks..."

    # Helper: symlink $target -> $src (basename) if target absent and src exists
    _ln_compat() {
        local src="$1" target="$2"
        [[ -e "$target" ]] && return 0   # already present
        [[ -f "$src" ]]   || return 0   # source not found, skip silently
        ln -sf "$(basename "$src")" "$target"
        info "    $(basename "$target") -> $(basename "$src")"
    }

    local dfu_dir="$iphone_dir/Firmware/dfu"
    local all_flash_dir="$iphone_dir/Firmware/all_flash"

    # iBSS: prefer RESEARCH_RELEASE, fall back to any other variant
    local ibss_src
    ibss_src="$(find "$dfu_dir" -maxdepth 1 -name 'iBSS.*.im4p' \
        ! -name '*.plist' ! -name '*vresearch101*' 2>/dev/null | head -1)"
    _ln_compat "$ibss_src" "$dfu_dir/iBSS.vresearch101.RELEASE.im4p"

    # iBEC: prefer RELEASE variant (strip the .plist sidecar)
    local ibec_src
    ibec_src="$(find "$dfu_dir" -maxdepth 1 -name 'iBEC.*.im4p' \
        ! -name '*.plist' ! -name '*vresearch101*' 2>/dev/null | head -1)"
    _ln_compat "$ibec_src" "$dfu_dir/iBEC.vresearch101.RELEASE.im4p"

    # LLB: all_flash/
    local llb_src
    llb_src="$(find "$all_flash_dir" -maxdepth 1 -name 'LLB.*.im4p' \
        ! -name '*.plist' ! -name '*vresearch101*' 2>/dev/null | head -1)"
    _ln_compat "$llb_src" "$all_flash_dir/LLB.vresearch101.RELEASE.im4p"

    # kernelcache: map any kernelcache.research.* to the vphone600 name
    local kc_src
    kc_src="$(find "$iphone_dir" -maxdepth 1 -name 'kernelcache.research.*' \
        ! -name '*vphone600*' 2>/dev/null | head -1)"
    _ln_compat "$kc_src" "$iphone_dir/kernelcache.research.vphone600"

    # Verify the four files fw_patch.py requires are now present
    local -i _missing=0
    for _f in \
        "$dfu_dir/iBSS.vresearch101.RELEASE.im4p" \
        "$dfu_dir/iBEC.vresearch101.RELEASE.im4p" \
        "$all_flash_dir/LLB.vresearch101.RELEASE.im4p" \
        "$iphone_dir/Firmware/txm.iphoneos.research.im4p" \
        "$iphone_dir/kernelcache.research.vphone600"; do
        if [[ -e "$_f" ]]; then
            success "  Found: $(basename "$_f")"
        else
            warn "  Missing: $_f"
            (( _missing++ )) || true
        fi
    done
    if [[ $_missing -gt 0 ]]; then
        warn "  $_missing fw_patch.py component(s) missing — patching will fail"
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
# Apply local patches to upstream vphone-cli scripts.
# Called after the venv is confirmed ready so VENV_PYTHON is set.
# Each patch script is idempotent — safe to re-run.
# =============================================================================
_apply_upstream_patches() {
    local scripts_dir="$WORK_DIR/tools/vphone-cli/scripts"
    local patches_dir="$(dirname "${BASH_SOURCE[0]}")/../CFW/patches"
    # Resolve relative path
    patches_dir="$(cd "$patches_dir" && pwd)"

    # ── txm.py: replace PACIBSP scan-back with ±0x4000 window search ──
    # Upstream txm.py uses PACIBSP to find function boundaries, which breaks on
    # CloudOS 26.1 (23B85) due to an inline hint #27 instruction 0x24 bytes
    # before the marker constant.  fix_txm_patcher.py replaces that logic.
    local txm_py="$scripts_dir/patchers/txm.py"
    if [[ -f "$txm_py" ]] && [[ -f "$patches_dir/fix_txm_patcher.py" ]]; then
        info "  Applying txm.py fix (PACIBSP → window search)..."
        "${VENV_PYTHON:-python3}" "$patches_dir/fix_txm_patcher.py" "$txm_py" \
            2>&1 | tee -a "$CURRENT_LOG_FILE"
    fi
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
    # Use find -o instead of ls glob: ls *.shsh *.shsh2 exits non-zero when
    # only one extension exists (e.g. no *.shsh2), causing a false "not found".
    local shsh_dir="$WORK_DIR/shsh"
    if [[ -z "$(find "$shsh_dir" \( -name "*.shsh" -o -name "*.shsh2" \) 2>/dev/null | head -1)" ]]; then
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
