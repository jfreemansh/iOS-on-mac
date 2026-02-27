#!/bin/bash
# setup.sh — Main orchestrator for iOS-on-Mac virtualization setup
# Usage: ./setup.sh [--phase N] [--resume] [--reset] [--check]
#
# Phases:
#   0  Prerequisites check
#   1  Environment setup (install tools)
#   2  Firmware preparation (download & extract IPSW)
#   3  Build VM tool (vphone-cli or super-tart)
#   4  Firmware patching (boot chain + Metal GPU plugin)
#   5  DFU boot + SSH ramdisk
#   6  iOS installation via SSH
#   7  Normal boot

set -euo pipefail

# =============================================================================
# Resolve script directory and load libraries
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/prereqs.sh"
source "$SCRIPT_DIR/lib/phase1_environment.sh"
source "$SCRIPT_DIR/lib/phase2_firmware.sh"
source "$SCRIPT_DIR/lib/phase3_build.sh"
source "$SCRIPT_DIR/lib/phase4_patch.sh"
source "$SCRIPT_DIR/lib/phase5_ramdisk.sh"
source "$SCRIPT_DIR/lib/phase6_install.sh"
source "$SCRIPT_DIR/lib/phase7_boot.sh"

# =============================================================================
# CLI Argument Parsing
# =============================================================================
REQUESTED_PHASE=""
RESUME=false
OPT_RESET=false
CHECK_ONLY=false
FORCE_REPATCH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase|-p)
            REQUESTED_PHASE="$2"
            shift 2
            ;;
        --resume|-r)
            RESUME=true
            shift
            ;;
        --reset)
            OPT_RESET=true
            shift
            ;;
        --check|-c)
            CHECK_ONLY=true
            shift
            ;;
        --repatch)
            FORCE_REPATCH=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --phase N, -p N   Run only phase N (0-7)"
            echo "  --resume, -r      Resume from last completed phase"
            echo "  --reset           Clear saved state and start over"
            echo "  --check, -c       Run prerequisites check only"
            echo "  --repatch         Delete stale patched firmware and re-run Phase 4 from scratch"
            echo "  --help, -h        Show this help"
            echo ""
            echo "Phases:"
            echo "  0  Prerequisites check"
            echo "  1  Environment setup (install tools)"
            echo "  2  Firmware preparation (download/extract IPSW)"
            echo "  3  Build VM tool (vphone-cli or super-tart)"
            echo "  4  Firmware patching (boot chain + Metal plugin)"
            echo "  5  DFU boot + SSH ramdisk"
            echo "  6  iOS installation via SSH"
            echo "  7  Normal boot"
            echo ""
            echo "Configuration: edit config.sh before running."
            echo "Approach: VM_APPROACH=$VM_APPROACH"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            error "Run: $0 --help"
            exit 1
            ;;
    esac
done

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}=================================================================${RESET}"
echo -e "${BOLD}${CYAN}  iOS-on-Mac Virtualization Setup${RESET}"
echo -e "${BOLD}${CYAN}=================================================================${RESET}"
echo -e "  ${DIM}Approach:  $VM_APPROACH${RESET}"
echo -e "  ${DIM}Work dir:  $WORK_DIR${RESET}"
echo -e "  ${DIM}VM cores:  $VM_CPU   RAM: $((VM_MEMORY / 1024))GB${RESET}"
echo ""

# =============================================================================
# Handle --reset
# =============================================================================
if $OPT_RESET; then
    clear_state
    info "State cleared. Starting fresh."
fi

# Export FORCE_REPATCH (0/1) so phase4 can read it as an environment variable
if $FORCE_REPATCH; then
    export FORCE_REPATCH=1
else
    export FORCE_REPATCH=0
fi

# --repatch wipes stale patched files then runs from the beginning (phase 0)
# so prereqs, env checks, etc. all pass before re-patching.
# An explicit --phase N still overrides this.
if $FORCE_REPATCH; then
    info "--repatch: stale patched firmware will be wiped; starting from Phase 0"
fi

# =============================================================================
# Handle --check (prereqs only)
# =============================================================================
if $CHECK_ONLY; then
    run_phase_prereqs
    exit $?
fi

# =============================================================================
# Determine starting phase
# =============================================================================
start_phase=0

if [[ -n "$REQUESTED_PHASE" ]]; then
    start_phase="$REQUESTED_PHASE"
elif $RESUME; then
    local_state="$(load_state)"
    case "$local_state" in
        prereqs) start_phase=1 ;;
        phase1)  start_phase=2 ;;
        phase2)  start_phase=3 ;;
        phase3)  start_phase=4 ;;
        phase4)  start_phase=5 ;;
        phase5)  start_phase=6 ;;
        phase6)  start_phase=7 ;;
        phase7)
            success "All phases already complete!"
            info "To re-run a specific phase: $0 --phase N"
            info "To start over: $0 --reset"
            exit 0
            ;;
        *)       start_phase=0 ;;
    esac
    info "Resuming from phase $start_phase"
fi

# =============================================================================
# Run phases
# =============================================================================

run_phase() {
    local phase_num="$1"

    case "$phase_num" in
        0)
            run_phase_prereqs || exit 1
            save_state "prereqs"
            ;;
        1) run_phase1_environment || exit 1 ;;
        2) run_phase2_firmware || exit 1 ;;
        3) run_phase3_build || exit 1 ;;
        4) run_phase4_patch || exit 1 ;;
        5) run_phase5_ramdisk || exit 1 ;;
        6) run_phase6_install || exit 1 ;;
        7) run_phase7_boot || exit 1 ;;
        *)
            error "Unknown phase: $phase_num"
            exit 1
            ;;
    esac
}

if [[ -n "$REQUESTED_PHASE" ]]; then
    # Run only the requested phase
    run_phase "$REQUESTED_PHASE"
else
    # Run all phases from start_phase onward
    for phase in $(seq "$start_phase" 7); do
        run_phase "$phase"

        # Phases 5-7 are interactive / long-running, so pause between them
        if [[ "$phase" -ge 4 ]] && [[ "$phase" -lt 7 ]]; then
            echo ""
            prompt_continue "Phase $phase complete. Press Enter to continue to Phase $((phase + 1))..."
        fi
    done
fi

echo ""
echo -e "${BOLD}${GREEN}=================================================================${RESET}"
echo -e "${BOLD}${GREEN}  Setup Complete!${RESET}"
echo -e "${BOLD}${GREEN}=================================================================${RESET}"
echo ""
