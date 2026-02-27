#!/bin/bash
# lib/phase1_environment.sh — Install required tools for iOS virtualization
# Installs: ipsw, img4lib, ldid2, keystone (brew C library), Python venv via upstream setup_venv.sh

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
        libirecovery
        keystone          # C assembler library; setup_venv.sh builds libkeystone.dylib from it
        autoconf          # required by setup_libimobiledevice.sh
        automake          # required by setup_libimobiledevice.sh
        libtool           # required by setup_libimobiledevice.sh
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

    # Detect stale binaries linked against shared liblzfse.dylib with no LC_RPATH
    # (built before the -DBUILD_SHARED_LIBS=OFF fix).  They crash at runtime with
    # "dyld: Library not loaded: @rpath/liblzfse.dylib / Reason: no LC_RPATH's found".
    # Removing the stale binary forces the clean static-link rebuild below.
    if [[ -f "$img4lib_dir/img4" ]] && \
       otool -L "$img4lib_dir/img4" 2>/dev/null | grep -q '@rpath/liblzfse.dylib' && \
       ! otool -l "$img4lib_dir/img4" 2>/dev/null | grep -q 'LC_RPATH'; then
        warn "img4 binary linked against shared liblzfse.dylib (no rpath) — removing stale binary for static rebuild"
        rm -f "$img4lib_dir/img4"
    fi

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
            # Clone or repair lzfse dependency
            if [[ ! -d lzfse ]]; then
                git clone https://github.com/lzfse/lzfse.git
            elif [[ ! -f lzfse/CMakeLists.txt ]]; then
                # Incomplete clone (e.g. from a prior root run); redo it
                rm -rf lzfse
                git clone https://github.com/lzfse/lzfse.git
            fi
            # Clear stale CMakeCache so cmake -B works cleanly
            rm -rf lzfse/build
            # -DCMAKE_POLICY_VERSION_MINIMUM=3.5: lzfse's old CMakeLists.txt requires cmake < 3.5
            # -DBUILD_SHARED_LIBS=OFF: build only liblzfse.a so img4 links statically (no dylib rpath needed)
            (cd lzfse && cmake -B build -S . -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF && cmake --build build --parallel "$(sysctl -n hw.ncpu)")
            # Locate openssl (Homebrew puts headers in a non-default prefix)
            openssl_prefix="$(_brew --prefix openssl@3 2>/dev/null || _brew --prefix openssl 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
            # -DiOS10 enables ep_info/compression fields in TheImg4Payload
            make -j"$(sysctl -n hw.ncpu)" \
                CFLAGS="-DLZFSE -DiOS10 -I. -Ilzfse/src -Iinclude -I${openssl_prefix}/include" \
                LDFLAGS="-Llzfse/build -L${openssl_prefix}/lib"
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
    # 5. Rosetta 2 (may be needed by vphone-cli build or x86_64 tooling)
    # -------------------------------------------------------------------------
    section "Setting up Rosetta 2"

    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        info "Rosetta 2 is already installed"
    else
        info "Installing Rosetta 2..."
        softwareupdate --install-rosetta --agree-to-license
    fi

    # -------------------------------------------------------------------------
    # 6. Python patching tools — venv built by setup_venv.sh in Phase 4
    # -------------------------------------------------------------------------
    section "Python patching tools prerequisite check"

    # In Phase 4, _verify_python_patching_tools() runs the upstream
    # setup_venv.sh which creates vphone-cli/.venv and builds libkeystone.dylib
    # from the Homebrew static library.  The brew 'keystone' package (installed
    # above) is the only Phase 1 prerequisite; pip3 is NOT used for patching.
    if brew list keystone &>/dev/null 2>&1; then
        info "Homebrew keystone present — setup_venv.sh will build libkeystone.dylib in Phase 4"
    else
        warn "Homebrew keystone not installed — Phase 4 will attempt to install it"
    fi

    # -------------------------------------------------------------------------
    # 7. SHSH blobs directory
    # -------------------------------------------------------------------------
    section "Creating SHSH blobs directory"

    ensure_dir "$WORK_DIR/shsh"
    if [[ -z "$(ls -A "$WORK_DIR/shsh" 2>/dev/null)" ]]; then
        warn "No SHSH blobs found in $WORK_DIR/shsh/"
        warn "ramdisk_build.py needs a saved .shsh/.shsh2 blob to sign firmware images."
        warn "Obtain blobs with: ipsw download appledb --device vphone600 --version <iOS>"
        warn "Then copy the .shsh2 file to: $WORK_DIR/shsh/"
    else
        info "SHSH blobs present: $(ls "$WORK_DIR/shsh/" | tr '\n' ' ')"
    fi

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
    local tools=("ipsw" "img4" "ldid" "sshpass" "cmake" "ninja" "jq" "wget" "irecovery")
    for tool in "${tools[@]}"; do
        if check_command "$tool"; then
            success "  $tool: $(command -v "$tool")"
        else
            warn "  $tool: NOT FOUND"
        fi
    done

    # Python patching venv is built by setup_venv.sh in Phase 4
    if brew list keystone &>/dev/null 2>&1; then
        success "  brew/keystone: $(brew --prefix keystone 2>/dev/null)/lib/libkeystone.a"
    else
        warn "  brew/keystone: NOT INSTALLED (required for Phase 4)"
    fi

    save_state "phase1"
    success "Phase 1 complete — environment is ready."
}
