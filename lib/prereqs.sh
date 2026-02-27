#!/bin/bash
# lib/prereqs.sh — Prerequisites checker for iOS virtualization setup
# Validates system configuration and reports pass/fail status.

run_phase_prereqs() {
    phase_banner "0" "Prerequisites Check"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local results=()

    # -------------------------------------------------------------------------
    # Check 1: macOS
    # -------------------------------------------------------------------------
    step 1 "Checking operating system..."
    if [[ "$(uname)" == "Darwin" ]]; then
        local macos_version
        macos_version="$(sw_vers -productVersion)"
        local major_version="${macos_version%%.*}"
        if [[ "$major_version" -ge 15 ]]; then
            results+=("PASS|macOS version|$macos_version (>= 15.0 required)")
            pass_count=$((pass_count + 1))
        else
            results+=("FAIL|macOS version|$macos_version (need >= 15.0 Sequoia)")
            fail_count=$((fail_count + 1))
        fi
    else
        results+=("FAIL|Operating System|$(uname) (macOS required)")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 2: Apple Silicon
    # -------------------------------------------------------------------------
    step 2 "Checking CPU architecture..."
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "arm64" ]]; then
        results+=("PASS|CPU Architecture|$arch (Apple Silicon)")
        pass_count=$((pass_count + 1))
    else
        results+=("FAIL|CPU Architecture|$arch (arm64 required)")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 3: SIP Status
    # -------------------------------------------------------------------------
    step 3 "Checking System Integrity Protection (SIP)..."
    local sip_status
    sip_status="$(csrutil status 2>/dev/null || echo 'unknown')"
    if echo "$sip_status" | grep -qi "disabled"; then
        results+=("PASS|SIP (System Integrity Protection)|Disabled")
        pass_count=$((pass_count + 1))
    else
        results+=("FAIL|SIP (System Integrity Protection)|Enabled — must be disabled")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 4: Research Guests
    # -------------------------------------------------------------------------
    step 4 "Checking research guests..."
    # Research guests status is part of csrutil output on supported macOS versions
    if echo "$sip_status" | grep -qi "allow-research-guests.*enabled\|research.*enabled"; then
        results+=("PASS|Research Guests|Enabled")
        pass_count=$((pass_count + 1))
    else
        # On macOS 26+ this might be in a different format; check nvram too
        local nvram_args
        nvram_args="$(nvram boot-args 2>/dev/null || echo '')"
        if echo "$nvram_args" | grep -q "allow-research-guests"; then
            results+=("PASS|Research Guests|Enabled (via nvram)")
            pass_count=$((pass_count + 1))
        else
            results+=("WARN|Research Guests|Unknown/Not confirmed — may need enabling")
            warn_count=$((warn_count + 1))
        fi
    fi

    # -------------------------------------------------------------------------
    # Check 5: AMFI Status
    # -------------------------------------------------------------------------
    step 5 "Checking AMFI (Apple Mobile File Integrity)..."
    local boot_args
    boot_args="$(nvram boot-args 2>/dev/null || echo '')"
    if echo "$boot_args" | grep -q "amfi_get_out_of_my_way=1"; then
        results+=("PASS|AMFI|Disabled (amfi_get_out_of_my_way=1)")
        pass_count=$((pass_count + 1))
    else
        results+=("FAIL|AMFI|Not disabled — required for unsigned code")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 6: Xcode Command Line Tools
    # -------------------------------------------------------------------------
    step 6 "Checking Xcode Command Line Tools..."
    if xcode-select -p &>/dev/null; then
        local xcode_path
        xcode_path="$(xcode-select -p)"
        results+=("PASS|Xcode CLT|$xcode_path")
        pass_count=$((pass_count + 1))
    else
        results+=("FAIL|Xcode CLT|Not installed")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 7: Homebrew
    # -------------------------------------------------------------------------
    step 7 "Checking Homebrew..."
    if check_command brew; then
        local brew_version
        brew_version="$(brew --version 2>/dev/null | head -1)"
        results+=("PASS|Homebrew|$brew_version")
        pass_count=$((pass_count + 1))
    else
        results+=("FAIL|Homebrew|Not installed")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 8: Disk Space
    # -------------------------------------------------------------------------
    step 8 "Checking available disk space..."
    local available_gb
    available_gb="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "$available_gb" ]]; then
        # Fallback for systems where df -g isn't available
        available_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')"
    fi
    if [[ -n "$available_gb" ]] && [[ "$available_gb" -ge 100 ]]; then
        results+=("PASS|Disk Space|${available_gb}GB available (>= 100GB recommended)")
        pass_count=$((pass_count + 1))
    elif [[ -n "$available_gb" ]] && [[ "$available_gb" -ge 50 ]]; then
        results+=("WARN|Disk Space|${available_gb}GB available (100GB+ recommended, 50GB minimum)")
        warn_count=$((warn_count + 1))
    else
        results+=("FAIL|Disk Space|${available_gb:-?}GB available (need at least 50GB)")
        fail_count=$((fail_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Check 9: Rosetta 2
    # -------------------------------------------------------------------------
    step 9 "Checking Rosetta 2 (required for keystone-engine)..."
    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        results+=("PASS|Rosetta 2|Installed")
        pass_count=$((pass_count + 1))
    else
        results+=("WARN|Rosetta 2|Not installed — will be installed in Phase 1")
        warn_count=$((warn_count + 1))
    fi

    # -------------------------------------------------------------------------
    # Print Results Table
    # -------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}=== Prerequisites Summary ===${RESET}"
    echo ""
    printf "  %-6s %-35s %s\n" "Status" "Check" "Details"
    printf "  %-6s %-35s %s\n" "------" "-----" "-------"

    for result in "${results[@]}"; do
        IFS='|' read -r status check details <<< "$result"
        local color
        case "$status" in
            PASS) color="$GREEN" ;;
            FAIL) color="$RED" ;;
            WARN) color="$YELLOW" ;;
        esac
        printf "  ${color}%-6s${RESET} %-35s %s\n" "$status" "$check" "$details"
    done

    echo ""
    echo -e "  ${GREEN}Passed: $pass_count${RESET}  ${YELLOW}Warnings: $warn_count${RESET}  ${RED}Failed: $fail_count${RESET}"
    echo ""

    # -------------------------------------------------------------------------
    # Handle Failures
    # -------------------------------------------------------------------------
    if [[ "$fail_count" -gt 0 ]]; then
        # Print remediation instructions for common failures
        for result in "${results[@]}"; do
            IFS='|' read -r status check _ <<< "$result"
            if [[ "$status" != "FAIL" ]]; then continue; fi

            case "$check" in
                *SIP*)
                    manual_action "Disable SIP" \
                        "1. Shut down your Mac" \
                        "2. Press and hold the Power button until 'Loading startup options' appears" \
                        "3. Select 'Options' -> Open Terminal" \
                        "4. Run: csrutil disable" \
                        "5. Run: csrutil allow-research-guests enable" \
                        "6. Reboot and re-run this script"
                    ;;
                *AMFI*)
                    manual_action "Disable AMFI" \
                        "Run this command and then reboot:" \
                        "" \
                        "  sudo nvram boot-args=\"amfi_get_out_of_my_way=1 -v\"" \
                        "" \
                        "Or, if in Recovery Mode (recommended — do it together with SIP):" \
                        "  nvram boot-args=\"amfi_get_out_of_my_way=1 -v\""

                    if prompt_yes_no "Would you like to set AMFI boot-args now? (requires sudo, then reboot)"; then
                        sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
                        warn "boot-args set. You MUST reboot for this to take effect."
                        warn "After rebooting, re-run: ./setup.sh"
                    fi
                    ;;
                *Research*)
                    manual_action "Enable Research Guests" \
                        "This must be done in Recovery Mode:" \
                        "1. Shut down your Mac" \
                        "2. Hold Power button -> Options -> Terminal" \
                        "3. Run: csrutil allow-research-guests enable" \
                        "4. Reboot and re-run this script"
                    ;;
                *Xcode*)
                    manual_action "Install Xcode Command Line Tools" \
                        "Run: xcode-select --install" \
                        "Then re-run this script."
                    ;;
                *Homebrew*)
                    manual_action "Install Homebrew" \
                        "Run:" \
                        '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
                        "Then re-run this script."
                    ;;
                *Disk*)
                    manual_action "Free Disk Space" \
                        "At least 50GB is required (100GB recommended)." \
                        "The setup needs space for firmware downloads (~20GB)," \
                        "extracted firmware (~20GB), and VM disk image (~64GB)."
                    ;;
            esac
        done

        error "Some prerequisites are not met. Please resolve the issues above and re-run."
        error "Run: ./setup.sh"
        return 1
    fi

    success "All prerequisites passed!"
    return 0
}
