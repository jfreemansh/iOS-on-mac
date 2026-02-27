#!/bin/bash
# lib/common.sh — Shared utilities for iOS virtualization setup
# Provides logging, error handling, colored output, and helper functions.

# Prevent double-sourcing
[[ -n "$_COMMON_SH_LOADED" ]] && return 0
_COMMON_SH_LOADED=1

# =============================================================================
# Colors (disabled if not a terminal)
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

# =============================================================================
# Logging Functions
# =============================================================================

_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_to_file() {
    local msg="$1"
    if [[ -n "${CURRENT_LOG_FILE:-}" ]]; then
        echo "[$(_timestamp)] $msg" >> "$CURRENT_LOG_FILE"
    fi
}

info() {
    local msg="$*"
    echo -e "${GREEN}[INFO]${RESET} $msg"
    _log_to_file "[INFO] $msg"
}

warn() {
    local msg="$*"
    echo -e "${YELLOW}[WARN]${RESET} $msg"
    _log_to_file "[WARN] $msg"
}

error() {
    local msg="$*"
    echo -e "${RED}[ERROR]${RESET} $msg" >&2
    _log_to_file "[ERROR] $msg"
}

success() {
    local msg="$*"
    echo -e "${GREEN}[OK]${RESET} $msg"
    _log_to_file "[OK] $msg"
}

step() {
    local num="$1"
    shift
    local msg="$*"
    echo -e "  ${CYAN}[$num]${RESET} $msg"
    _log_to_file "  [$num] $msg"
}

# Print a prominent phase banner
phase_banner() {
    local phase_num="$1"
    local phase_name="$2"
    echo ""
    echo -e "${BOLD}${MAGENTA}=================================================================${RESET}"
    echo -e "${BOLD}${MAGENTA}  Phase $phase_num: $phase_name${RESET}"
    echo -e "${BOLD}${MAGENTA}=================================================================${RESET}"
    echo ""
    _log_to_file "=== Phase $phase_num: $phase_name ==="
}

# Print a section header within a phase
section() {
    local msg="$*"
    echo ""
    echo -e "${BOLD}--- $msg ---${RESET}"
    _log_to_file "--- $msg ---"
}

# =============================================================================
# User Interaction (Guided Steps Mode)
# =============================================================================

# Wait for user to press Enter
prompt_continue() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    echo -e "${BOLD}${BLUE}>> $msg${RESET}"
    read -r
}

# Ask yes/no question, default to yes
prompt_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local prompt_str
    if [[ "$default" == "y" ]]; then
        prompt_str="[Y/n]"
    else
        prompt_str="[y/N]"
    fi
    echo -e "${BOLD}${BLUE}>> $question $prompt_str${RESET} "
    read -r answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Print a manual action required box
manual_action() {
    local title="$1"
    shift
    echo ""
    echo -e "${BOLD}${YELLOW}=================================================================${RESET}"
    echo -e "${BOLD}${YELLOW}  MANUAL ACTION REQUIRED: $title${RESET}"
    echo -e "${BOLD}${YELLOW}=================================================================${RESET}"
    for line in "$@"; do
        echo -e "  ${YELLOW}$line${RESET}"
    done
    echo -e "${BOLD}${YELLOW}=================================================================${RESET}"
    echo ""
}

# =============================================================================
# Command Helpers
# =============================================================================

# Check if a command exists on PATH
check_command() {
    command -v "$1" &>/dev/null
}

# Run a command, logging output. Exit on failure.
run_or_fail() {
    local desc="$1"
    shift
    info "Running: $desc"
    _log_to_file "CMD: $*"
    if ! "$@" 2>&1 | tee -a "${CURRENT_LOG_FILE:-/dev/null}"; then
        error "Failed: $desc"
        error "Command: $*"
        return 1
    fi
}

# Run a command silently, only show output on failure
run_quiet() {
    local desc="$1"
    shift
    _log_to_file "CMD (quiet): $*"
    local output
    if output=$("$@" 2>&1); then
        echo "$output" >> "${CURRENT_LOG_FILE:-/dev/null}"
        return 0
    else
        error "Failed: $desc"
        echo "$output" >&2
        echo "$output" >> "${CURRENT_LOG_FILE:-/dev/null}"
        return 1
    fi
}

# =============================================================================
# State Management (Resume Support)
# =============================================================================

save_state() {
    local phase="$1"
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$phase" > "$STATE_FILE"
    _log_to_file "State saved: $phase"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo ""
    fi
}

is_phase_complete() {
    local phase="$1"
    local current_state
    current_state="$(load_state)"
    # Phase is complete if state file shows a later phase
    local -A phase_order=(
        [prereqs]=0 [phase1]=1 [phase2]=2 [phase3]=3
        [phase4]=4 [phase5]=5 [phase6]=6 [phase7]=7
    )
    local current_num="${phase_order[$current_state]:-0}"
    local check_num="${phase_order[$phase]:-99}"
    [[ "$current_num" -gt "$check_num" ]]
}

clear_state() {
    rm -f "$STATE_FILE"
    info "State cleared. Will start from the beginning."
}

# =============================================================================
# Directory Helpers
# =============================================================================

ensure_dir() {
    for dir in "$@"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            _log_to_file "Created directory: $dir"
        fi
    done
}

# =============================================================================
# Process Management
# =============================================================================

# Array to track background PIDs for cleanup
BACKGROUND_PIDS=()

# Register a background PID for cleanup
register_pid() {
    BACKGROUND_PIDS+=("$1")
}

# Kill all registered background processes
cleanup_pids() {
    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done
    BACKGROUND_PIDS=()
}

# Set up cleanup trap
setup_cleanup_trap() {
    trap 'cleanup_pids; exit' EXIT INT TERM HUP
}

# =============================================================================
# Download Helpers
# =============================================================================

# Download a file with resume support and optional checksum verification
download_file() {
    local url="$1"
    local dest="$2"
    local sha256="${3:-}"

    # Skip if file already exists and checksum matches
    if [[ -f "$dest" ]] && [[ -n "$sha256" ]]; then
        local actual_hash
        actual_hash="$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')"
        if [[ "$actual_hash" == "$sha256" ]]; then
            info "Already downloaded (checksum OK): $(basename "$dest")"
            return 0
        fi
    elif [[ -f "$dest" ]] && [[ -z "$sha256" ]]; then
        info "Already downloaded: $(basename "$dest")"
        return 0
    fi

    info "Downloading: $(basename "$dest")"
    info "  URL: $url"

    if check_command wget; then
        wget -c -q --show-progress -O "$dest" "$url"
    elif check_command curl; then
        curl -L -C - --progress-bar -o "$dest" "$url"
    else
        error "Neither wget nor curl found. Cannot download files."
        return 1
    fi

    # Verify checksum if provided
    if [[ -n "$sha256" ]]; then
        local actual_hash
        actual_hash="$(shasum -a 256 "$dest" | awk '{print $1}')"
        if [[ "$actual_hash" != "$sha256" ]]; then
            error "Checksum mismatch for $(basename "$dest")"
            error "  Expected: $sha256"
            error "  Got:      $actual_hash"
            rm -f "$dest"
            return 1
        fi
        success "Checksum verified: $(basename "$dest")"
    fi
}

# Extract an IPSW file (which is just a ZIP archive)
extract_ipsw() {
    local ipsw="$1"
    local dest="$2"
    info "Extracting IPSW: $(basename "$ipsw") → $dest"
    ensure_dir "$dest"
    unzip -o -q "$ipsw" -d "$dest"
    chmod -R u+w "$dest"
    success "Extracted: $(basename "$ipsw")"
}

# =============================================================================
# Rosetta Helper
# =============================================================================

# Run a command under Rosetta x86_64 with the patching venv
run_in_rosetta_venv() {
    local cmd="$1"
    env /usr/bin/arch -x86_64 /bin/zsh -c "
        source \"$ROSETTA_VENV/bin/activate\"
        $cmd
    "
}
