#!/bin/bash
# lib/phase3_build.sh — Build the VM tool (vphone-cli or super-tart)
# Compiles the chosen virtualization tool from source with required entitlements

run_phase3_build() {
    phase_banner "3" "Build VM Tool"

    CURRENT_LOG_FILE="$LOG_DIR/phase3.log"

    # Load firmware paths from phase 2
    if [[ -f "$WORK_DIR/.firmware_paths" ]]; then
        source "$WORK_DIR/.firmware_paths"
    fi

    case "$VM_APPROACH" in
        vphone-cli)
            _build_vphone_cli
            ;;
        super-tart)
            _build_super_tart
            ;;
        *)
            error "Unknown VM_APPROACH: $VM_APPROACH"
            error "Set VM_APPROACH to 'vphone-cli' or 'super-tart' in config.sh"
            return 1
            ;;
    esac

    save_state "phase3"
    success "Phase 3 complete — VM tool built."
}

# =============================================================================
# vphone-cli (Lakr233)
# =============================================================================
_build_vphone_cli() {
    section "Building vphone-cli"

    local vphone_dir="$WORK_DIR/tools/vphone-cli"

    if [[ -d "$vphone_dir/.git" ]]; then
        info "Updating vphone-cli..."
        git -C "$vphone_dir" pull --ff-only 2>/dev/null || true
    else
        ensure_dir "$WORK_DIR/tools"
        run_or_fail "Clone vphone-cli" \
            git clone "$VPHONE_CLI_REPO" "$vphone_dir"
    fi

    info "Building vphone-cli with Swift..."
    (
        cd "$vphone_dir"
        swift build -c release 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )

    local vphone_bin
    vphone_bin="$(find "$vphone_dir/.build/release" -name "vphone-cli" -type f 2>/dev/null | head -1)"
    if [[ -z "$vphone_bin" ]]; then
        # Try alternative binary name
        vphone_bin="$(find "$vphone_dir/.build/release" -maxdepth 1 -type f -perm +111 2>/dev/null | head -1)"
    fi

    if [[ -n "$vphone_bin" ]]; then
        success "vphone-cli built: $vphone_bin"
    else
        error "vphone-cli build failed — no binary found"
        return 1
    fi

    # Apply entitlements — required for Virtualization.framework private APIs
    section "Signing with entitlements"
    local entitlements_file="$SCRIPT_DIR/templates/vphone-entitlements.plist"

    if [[ -f "$entitlements_file" ]]; then
        codesign --force --sign - --entitlements "$entitlements_file" \
            --deep "$vphone_bin" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        success "Entitlements applied to vphone-cli"
    else
        warn "Entitlements template not found at $entitlements_file"
        warn "The binary may not be able to use private Virtualization APIs"

        # Try to sign with embedded entitlements from the project
        local project_entitlements
        project_entitlements="$(find "$vphone_dir" -name "*.entitlements" -o -name "*entitlements.plist" | head -1)"
        if [[ -n "$project_entitlements" ]]; then
            info "Using project entitlements: $project_entitlements"
            codesign --force --sign - --entitlements "$project_entitlements" \
                --deep "$vphone_bin" 2>&1 | tee -a "$CURRENT_LOG_FILE"
            success "Signed with project entitlements"
        fi
    fi

    # Create a symlink for easy access
    ln -sf "$vphone_bin" "$WORK_DIR/tools/vphone-cli-bin"
    export PATH="$(dirname "$vphone_bin"):$PATH"
    info "vphone-cli added to PATH"
}

# =============================================================================
# super-tart (wh1te4ever)
# =============================================================================
_build_super_tart() {
    section "Building super-tart-vphone"

    local tart_dir="$WORK_DIR/tools/super-tart-vphone"

    if [[ -d "$tart_dir/.git" ]]; then
        info "Updating super-tart-vphone..."
        git -C "$tart_dir" pull --ff-only 2>/dev/null || true
    else
        ensure_dir "$WORK_DIR/tools"
        run_or_fail "Clone super-tart-vphone" \
            git clone "$SUPER_TART_REPO" "$tart_dir"
    fi

    # Also clone the writeup for reference scripts
    local writeup_dir="$WORK_DIR/tools/super-tart-vphone-writeup"
    if [[ ! -d "$writeup_dir/.git" ]]; then
        git clone "$SUPER_TART_WRITEUP_REPO" "$writeup_dir" 2>/dev/null || \
            warn "Could not clone writeup repo"
    fi

    info "Building super-tart..."
    (
        cd "$tart_dir"
        swift build -c release 2>&1 | tee -a "$CURRENT_LOG_FILE"
    )

    local tart_bin
    tart_bin="$(find "$tart_dir/.build/release" -name "tart" -type f 2>/dev/null | head -1)"
    if [[ -z "$tart_bin" ]]; then
        tart_bin="$(find "$tart_dir/.build/release" -maxdepth 1 -type f -perm +111 2>/dev/null | head -1)"
    fi

    if [[ -n "$tart_bin" ]]; then
        success "super-tart built: $tart_bin"
    else
        error "super-tart build failed — no binary found"
        return 1
    fi

    # Apply entitlements
    section "Signing with entitlements"
    local entitlements_file="$SCRIPT_DIR/templates/vphone-entitlements.plist"

    if [[ -f "$entitlements_file" ]]; then
        codesign --force --sign - --entitlements "$entitlements_file" \
            --deep "$tart_bin" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        success "Entitlements applied to super-tart"
    else
        # Try project entitlements
        local project_entitlements
        project_entitlements="$(find "$tart_dir" -name "*.entitlements" -o -name "*entitlements.plist" | head -1)"
        if [[ -n "$project_entitlements" ]]; then
            codesign --force --sign - --entitlements "$project_entitlements" \
                --deep "$tart_bin" 2>&1 | tee -a "$CURRENT_LOG_FILE"
        fi
    fi

    ln -sf "$tart_bin" "$WORK_DIR/tools/super-tart-bin"
    export PATH="$(dirname "$tart_bin"):$PATH"
    info "super-tart added to PATH"
}
