#!/bin/bash
# lib/phase1_environment.sh — Install required tools for iOS virtualization
# Installs: ipsw, img4lib, ldid2, keystone-engine (Rosetta), Python venv

run_phase1_environment() {
    phase_banner "1" "Environment Setup"

    ensure_dir "$WORK_DIR" "$DOWNLOADS_DIR" "$LOG_DIR" "$VM_DIR"
    CURRENT_LOG_FILE="$LOG_DIR/phase1.log"

    # Homebrew refuses to run as root; delegate to the real user when under sudo
    _brew() {
        if [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "${SUDO_USER}" brew "$@"
        else
            brew "$@"
        fi
    }

    # -------------------------------------------------------------------------
    # 1. Homebrew dependencies
    # -------------------------------------------------------------------------
    section "Installing Homebrew packages"

    local brew_packages=(
        cmake
        ninja
        pkg-config
        libusb
        openssl
        wget
        jq
        unzip
        p7zip
    )

    for pkg in "${brew_packages[@]}"; do
        if _brew list "$pkg" &>/dev/null; then
            info "Already installed: $pkg"
        else
            run_or_fail "brew install $pkg" _brew install "$pkg"
        fi
    done

    # -------------------------------------------------------------------------
    # 2. ipsw — Apple firmware analysis tool
    # -------------------------------------------------------------------------
    section "Installing ipsw"

    if check_command ipsw; then
        info "ipsw already installed: $(ipsw version 2>/dev/null || echo 'unknown')"
    else
        info "Installing ipsw via Homebrew..."
        run_or_fail "brew install ipsw" _brew install blacktop/tap/ipsw
    fi

    # -------------------------------------------------------------------------
    # 3. img4lib — IMG4 manipulation library
    # -------------------------------------------------------------------------
    section "Installing img4lib"

    local img4lib_dir="$WORK_DIR/tools/img4lib"
    if [[ -f "$img4lib_dir/img4" ]]; then
        info "img4lib already built"
    else
        ensure_dir "$WORK_DIR/tools"
        if [[ -d "$img4lib_dir" ]]; then
            info "Updating img4lib..."
            git -C "$img4lib_dir" pull --ff-only 2>/dev/null || true
        else
            run_or_fail "Clone img4lib" \
                git clone https://github.com/xerub/img4lib.git "$img4lib_dir"
        fi
        info "Building img4lib..."
        (
            cd "$img4lib_dir"
            # img4lib needs lzfse
            if [[ ! -d lzfse ]]; then
                git clone https://github.com/lzfse/lzfse.git
            fi
            (cd lzfse && mkdir -p build && cd build && cmake .. && make -j"$(sysctl -n hw.ncpu)")
            make -j"$(sysctl -n hw.ncpu)" \
                CFLAGS="-Ilzfse/src -Iinclude" \
                LDFLAGS="-Llzfse/build"
        )
        if [[ -f "$img4lib_dir/img4" ]]; then
            success "img4lib built successfully"
        else
            error "img4lib build failed"
            return 1
        fi
    fi
    export PATH="$img4lib_dir:$PATH"

    # -------------------------------------------------------------------------
    # 4. ldid2 — Link Identity Editor (for entitlements)
    # -------------------------------------------------------------------------
    section "Installing ldid2"

    if check_command ldid; then
        info "ldid already installed"
    else
        run_or_fail "brew install ldid" _brew install ldid
    fi

    # -------------------------------------------------------------------------
    # 5. Rosetta 2 (required for keystone-engine x86_64 build)
    # -------------------------------------------------------------------------
    section "Setting up Rosetta 2"

    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        info "Rosetta 2 is already installed"
    else
        info "Installing Rosetta 2..."
        softwareupdate --install-rosetta --agree-to-license
    fi

    # -------------------------------------------------------------------------
    # 6. Python x86_64 venv with keystone-engine
    # -------------------------------------------------------------------------
    section "Setting up x86_64 Python venv (keystone-engine)"

    if [[ -f "$ROSETTA_VENV/bin/activate" ]] && \
       run_in_rosetta_venv "python3 -c 'import keystone'" 2>/dev/null; then
        info "Rosetta Python venv with keystone-engine already configured"
    else
        info "Creating x86_64 Python virtual environment..."

        # Use the system Python under Rosetta
        /usr/bin/arch -x86_64 /bin/zsh -c "
            /usr/bin/python3 -m venv '$ROSETTA_VENV'
            source '$ROSETTA_VENV/bin/activate'
            pip install --upgrade pip
            pip install keystone-engine
        "

        if run_in_rosetta_venv "python3 -c 'import keystone; print(\"keystone OK\")'"; then
            success "keystone-engine installed in Rosetta venv"
        else
            error "Failed to install keystone-engine"
            return 1
        fi
    fi

    # -------------------------------------------------------------------------
    # 7. kairos — iBoot patcher (if available)
    # -------------------------------------------------------------------------
    section "Checking kairos (iBoot patcher)"

    local kairos_dir="$WORK_DIR/tools/kairos"
    if [[ -f "$kairos_dir/kairos" ]]; then
        info "kairos already built"
    else
        ensure_dir "$WORK_DIR/tools"
        if [[ -d "$kairos_dir" ]]; then
            git -C "$kairos_dir" pull --ff-only 2>/dev/null || true
        else
            info "Cloning kairos..."
            git clone https://github.com/dayt0n/kairos.git "$kairos_dir" 2>/dev/null || \
                warn "kairos not available — firmware patching will use manual methods"
        fi
        if [[ -d "$kairos_dir" ]]; then
            info "Building kairos..."
            (
                cd "$kairos_dir"
                cmake -B build -G Ninja
                cmake --build build
            ) 2>&1 | tee -a "$CURRENT_LOG_FILE" || true
            if [[ -f "$kairos_dir/build/kairos" ]]; then
                success "kairos built successfully"
            else
                warn "kairos build failed — will fall back to manual patching"
            fi
        fi
    fi
    [[ -f "$kairos_dir/kairos" || -f "$kairos_dir/build/kairos" ]] && \
        export PATH="$kairos_dir/build:$kairos_dir:$PATH"

    # -------------------------------------------------------------------------
    # 8. sshpass (for automated SSH to ramdisk)
    # -------------------------------------------------------------------------
    section "Installing sshpass"

    if check_command sshpass; then
        info "sshpass already installed"
    else
        run_or_fail "brew install sshpass" _brew install esolitos/ipa/sshpass
    fi

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    echo ""
    section "Environment Summary"
    local tools=("ipsw" "img4" "ldid" "sshpass" "cmake" "ninja" "jq" "wget")
    for tool in "${tools[@]}"; do
        if check_command "$tool"; then
            success "  $tool: $(command -v "$tool")"
        else
            warn "  $tool: NOT FOUND"
        fi
    done

    save_state "phase1"
    success "Phase 1 complete — environment is ready."
}
