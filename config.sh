#!/bin/bash
# config.sh — User-configurable parameters for iOS virtualization setup
# Edit these values before running setup.sh

# =============================================================================
# VM Resource Allocation (optimized for Mac M4 Max 128GB)
# =============================================================================
VM_CPU=8                              # CPU cores for VM (M4 Max has 16 total)
VM_MEMORY=16384                       # RAM in MB (16GB of 128GB available)

# =============================================================================
# VM Approach — which tool to use for virtualization
# =============================================================================
# "vphone-cli"  — Lakr233/vphone-cli (recommended, has full automation scripts)
# "super-tart"  — wh1te4ever/super-tart-vphone (alternative approach)
VM_APPROACH="vphone-cli"

# =============================================================================
# Directory Layout
# =============================================================================
WORK_DIR="${WORK_DIR:-$HOME/ios-vm}"  # Main working directory
VM_DIR="$WORK_DIR/VM"                 # VM runtime files (ROM, disk, nvram)
DOWNLOADS_DIR="$WORK_DIR/downloads"   # Cached firmware downloads
LOG_DIR="$WORK_DIR/logs"              # Per-phase log files
STATE_FILE="$WORK_DIR/.setup_state"   # Resume state tracking
ROSETTA_VENV="$WORK_DIR/.venv_rosetta" # legacy: x86_64 Rosetta venv (no longer used for patching)

# =============================================================================
# Repository URLs
# =============================================================================
VPHONE_CLI_REPO="https://github.com/Lakr233/vphone-cli.git"
SUPER_TART_REPO="https://github.com/wh1te4ever/super-tart-vphone.git"
SUPER_TART_WRITEUP_REPO="https://github.com/wh1te4ever/super-tart-vphone-writeup.git"

# =============================================================================
# Firmware Configuration
# =============================================================================
# PCC (Private Cloud Compute) release for research VM
# NOTE: Upstream (vphone-cli) pairs iOS 26.3 (23D127) with CloudOS 26.1 (23B85).
# CLOUDOS_IPSW_URL below is pinned to 26.1 — do NOT use pccvre latest (gives 26.3
# which breaks fw_patch.py / txm.py).  Update both together when upstream bumps.
PCC_RELEASE="35622"  # 26.3 — NOT used when CLOUDOS_IPSW_URL is set
PCC_INSTANCE_NAME="pcc-research"
PCC_VARIANT="research"

# iPhone 16 (iPhone17,3) iOS IPSW
# Leave empty — Phase 2 auto-detects via `ipsw` tool (installed in Phase 1).
# Only set manually if auto-detection fails.
# Upstream-tested pairs (both work with CloudOS 26.1/23B85):
#   iPhone17,3_26.1_23B85_Restore.ipsw  (exact match with CloudOS build)
#   iPhone17,3_26.3_23D127_Restore.ipsw (also confirmed working)
IPHONE_IPSW_URL=""

# cloudOS/PCC IPSW — pinned to CloudOS 26.1 (23B85) matching upstream vphone-cli.
# This URL is the exact version fw_patch.py and txm.py were written/verified for.
# To override with pccvre: clear this and set PCC_RELEASE to the desired release.
CLOUDOS_IPSW_URL="https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"

# Device identifiers
DEVICE_BOARD_CONFIG="vphone600ap"
DEVICE_PLATFORM="vresearch1"
DEVICE_CPID="65025"   # 0xFE01
DEVICE_BDID="145"     # 0x91

# =============================================================================
# Network / Port Forwarding
# =============================================================================
SSH_LOCAL_PORT=22222              # Local port → VM port 22 (SSH)
VNC_LOCAL_PORT=5901              # Local port → VM port 5901 (VNC)
SSH_PASSWORD="alpine"            # Default ramdisk/jailbreak SSH password

# =============================================================================
# Boot Arguments
# =============================================================================
BOOT_ARGS_DFU="serial=3 debug=0x104c04"
BOOT_ARGS_RAMDISK="serial=3 -v debug=0x2014e rd=md0 nand-enable-reformat=1 -progress"
BOOT_ARGS_NORMAL="serial=3 -v debug=0x2014e"

# =============================================================================
# Display Configuration (iPhone 14 Pro Max / iPhone 16 Plus specs)
# =============================================================================
VM_DISPLAY_WIDTH=1290
VM_DISPLAY_HEIGHT=2796
VM_DISPLAY_PPI=460

# =============================================================================
# VM Runtime File Paths (vphone-cli)
# vphone-cli is a single-invocation binary that takes direct --rom/--disk flags;
# it has no create/list/run/ip subcommands like Tart.
# =============================================================================
_AVP_RESOURCES="/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources"
VM_ROM_PATH="$_AVP_RESOURCES/AVPBooter.vresearch1.bin"
VM_SEP_ROM_PATH="$_AVP_RESOURCES/AVPSEPBooter.vresearch1.bin"
VM_DISK="$VM_DIR/disk.img"
VM_NVRAM="$VM_DIR/nvram.bin"
VM_DISK_SIZE="64g"   # Sparse disk image size for the iOS install
