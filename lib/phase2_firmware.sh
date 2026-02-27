#!/bin/bash
# lib/phase2_firmware.sh — Download and extract firmware (IPSW) files
# Downloads: iPhone IPSW, cloudOS/PCC IPSW; extracts components

run_phase2_firmware() {
    phase_banner "2" "Firmware Preparation"

    CURRENT_LOG_FILE="$LOG_DIR/phase2.log"
    ensure_dir "$DOWNLOADS_DIR"

    local ipsw_extract_dir="$WORK_DIR/firmware"
    local iphone_extract_dir="$ipsw_extract_dir/iphone"
    local cloudos_extract_dir="$ipsw_extract_dir/cloudos"
    ensure_dir "$ipsw_extract_dir" "$iphone_extract_dir" "$cloudos_extract_dir"

    # -------------------------------------------------------------------------
    # 1. iPhone IPSW
    # -------------------------------------------------------------------------
    section "iPhone Firmware (IPSW)"

    local iphone_ipsw="$DOWNLOADS_DIR/iphone.ipsw"

    if [[ -n "$IPHONE_IPSW_URL" ]]; then
        info "Using configured IPSW URL"
        download_file "$IPHONE_IPSW_URL" "$iphone_ipsw"
    elif check_command ipsw; then
        info "Looking up latest iPhone17,3 IPSW..."
        local ipsw_url
        ipsw_url="$(ipsw download ipsw --device iPhone17,3 --latest --urls 2>/dev/null | head -1)"
        if [[ -n "$ipsw_url" ]]; then
            IPHONE_IPSW_URL="$ipsw_url"
            info "Found: $ipsw_url"
            download_file "$ipsw_url" "$iphone_ipsw"
        else
            error "Could not find iPhone17,3 IPSW URL."
            error "Set IPHONE_IPSW_URL in config.sh manually."
            return 1
        fi
    else
        error "No IPSW URL configured and 'ipsw' tool not available."
        error "Set IPHONE_IPSW_URL in config.sh"
        return 1
    fi

    # Extract iPhone IPSW
    if [[ -d "$iphone_extract_dir/Firmware" ]] || \
       [[ -f "$iphone_extract_dir/BuildManifest.plist" ]]; then
        info "iPhone IPSW already extracted"
    else
        extract_ipsw "$iphone_ipsw" "$iphone_extract_dir"
    fi

    # -------------------------------------------------------------------------
    # 2. cloudOS / PCC IPSW
    # -------------------------------------------------------------------------
    section "cloudOS / PCC Firmware"

    local cloudos_ipsw="$DOWNLOADS_DIR/cloudos.ipsw"

    if [[ -n "$CLOUDOS_IPSW_URL" ]]; then
        info "Using configured cloudOS IPSW URL"
        download_file "$CLOUDOS_IPSW_URL" "$cloudos_ipsw"
    else
        info "Attempting to obtain cloudOS IPSW via pccvre..."

        # Try Apple's PCC Virtual Research Environment tool
        if check_command pccvre; then
            info "Using pccvre to download PCC release $PCC_RELEASE..."
            # pccvre downloads to the current directory; cd into downloads dir
            (cd "$DOWNLOADS_DIR" && pccvre release download --release "$PCC_RELEASE") \
                2>&1 | tee -a "$CURRENT_LOG_FILE"

            # Look for the downloaded IPSW (pccvre may nest it in a subdirectory)
            local pcc_ipsw
            pcc_ipsw="$(find "$DOWNLOADS_DIR" -name "*.ipsw" | head -1)"
            if [[ -n "$pcc_ipsw" ]]; then
                [[ "$pcc_ipsw" != "$cloudos_ipsw" ]] && mv "$pcc_ipsw" "$cloudos_ipsw"
                success "cloudOS IPSW obtained via pccvre"
            fi
        fi

        if [[ ! -f "$cloudos_ipsw" ]]; then
            manual_action "Provide cloudOS IPSW" \
                "The cloudOS / PCC firmware could not be automatically downloaded." \
                "" \
                "Option A: Use pccvre (Apple's PCC Virtual Research Environment):" \
                "  1. Download pccvre from Apple: https://security.apple.com/pcc" \
                "  2. Run: pccvre release download --release $PCC_RELEASE" \
                "  3. Place the .ipsw at: $cloudos_ipsw" \
                "" \
                "Option B: Set CLOUDOS_IPSW_URL in config.sh" \
                "" \
                "Then re-run: ./setup.sh --resume"

            if [[ ! -f "$cloudos_ipsw" ]]; then
                prompt_continue "Press Enter after placing the cloudOS IPSW at $cloudos_ipsw ..."
            fi

            if [[ ! -f "$cloudos_ipsw" ]]; then
                error "cloudOS IPSW not found at $cloudos_ipsw"
                return 1
            fi
        fi
    fi

    # Extract cloudOS IPSW
    if [[ -d "$cloudos_extract_dir/Firmware" ]] || \
       [[ -f "$cloudos_extract_dir/BuildManifest.plist" ]]; then
        info "cloudOS IPSW already extracted"
    else
        extract_ipsw "$cloudos_ipsw" "$cloudos_extract_dir"
    fi

    # -------------------------------------------------------------------------
    # 3. Identify key firmware components
    # -------------------------------------------------------------------------
    section "Locating Firmware Components"

    # iPhone components
    local iphone_boardconfig="$DEVICE_BOARD_CONFIG"

    info "Scanning iPhone firmware for $iphone_boardconfig components..."

    # Find iBSS, iBEC, kernelcache, devicetree, ramdisk, trustcache
    for component in iBSS iBEC kernelcache DeviceTree RestoreRamDisk StaticTrustCache; do
        local found
        found="$(find "$iphone_extract_dir" -iname "*${component}*" 2>/dev/null | head -1)"
        if [[ -n "$found" ]]; then
            success "  Found $component: $(basename "$found")"
        else
            warn "  $component not found in iPhone IPSW"
        fi
    done

    # cloudOS components
    info "Scanning cloudOS firmware..."
    for component in iBSS iBEC kernelcache DeviceTree RestoreRamDisk StaticTrustCache; do
        local found
        found="$(find "$cloudos_extract_dir" -iname "*${component}*" 2>/dev/null | head -1)"
        if [[ -n "$found" ]]; then
            success "  Found $component: $(basename "$found")"
        else
            warn "  $component not found in cloudOS IPSW"
        fi
    done

    # -------------------------------------------------------------------------
    # 4. Extract the root filesystem disk image
    # -------------------------------------------------------------------------
    section "Extracting Root Filesystem"

    local rootfs_dmg
    rootfs_dmg="$(find "$iphone_extract_dir" -maxdepth 1 -name "*.dmg" \
                  ! -iname "*Update*" ! -iname "*restore*" 2>/dev/null | head -1)"

    if [[ -z "$rootfs_dmg" ]]; then
        # Try the largest .dmg file
        rootfs_dmg="$(find "$iphone_extract_dir" -name "*.dmg" -exec ls -S {} + 2>/dev/null | head -1)"
    fi

    if [[ -n "$rootfs_dmg" ]]; then
        success "Root filesystem image: $(basename "$rootfs_dmg")"
        # Store path for later phases
        echo "$rootfs_dmg" > "$WORK_DIR/.rootfs_dmg_path"
    else
        warn "Root filesystem DMG not found — may need manual identification"
    fi

    # -------------------------------------------------------------------------
    # 5. Save firmware paths for later phases
    # -------------------------------------------------------------------------
    cat > "$WORK_DIR/.firmware_paths" << PATHS
IPHONE_IPSW="$iphone_ipsw"
IPHONE_EXTRACT="$iphone_extract_dir"
CLOUDOS_IPSW="$cloudos_ipsw"
CLOUDOS_EXTRACT="$cloudos_extract_dir"
ROOTFS_DMG="${rootfs_dmg:-}"
PATHS
    success "Firmware paths saved to $WORK_DIR/.firmware_paths"

    save_state "phase2"
    success "Phase 2 complete — firmware downloaded and extracted."
}
