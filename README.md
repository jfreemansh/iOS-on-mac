# iOS-on-Mac

Run iOS in a virtual machine on Apple Silicon Macs using the Virtualization.framework private APIs.

Automates the full workflow: prerequisites → firmware download → boot chain patching → DFU boot → disk installation → Metal GPU support → normal boot.

## Requirements

| Requirement | Details |
|---|---|
| **Mac** | Apple Silicon (M1/M2/M3/M4) |
| **macOS** | 15.0 (Sequoia) or later |
| **RAM** | 32GB+ recommended (16GB allocated to VM by default) |
| **Disk** | 100GB+ free space |
| **SIP** | Disabled |
| **AMFI** | Disabled |
| **Research Guests** | Enabled |
| **Xcode CLT** | Installed |
| **Homebrew** | Installed |
| **Rosetta 2** | Installed (for keystone-engine) |

## One-Time Mac Setup (Recovery Mode)

These steps require booting into Recovery Mode. Do them all at once:

1. Shut down your Mac
2. Press and hold the Power button until "Loading startup options" appears
3. Select **Options** → open **Terminal**
4. Run these commands:

```bash
csrutil disable
csrutil allow-research-guests enable
nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

5. Reboot

After rebooting, install Xcode Command Line Tools if you haven't:

```bash
xcode-select --install
```

## Quick Start

```bash
git clone https://github.com/jfreemansh/iOS-on-mac.git
cd iOS-on-mac
```

### 1. Edit Configuration

Open `config.sh` and review the settings. Key options:

```bash
VM_APPROACH="vphone-cli"   # or "super-tart"
VM_CPU=8                   # CPU cores for the VM
VM_MEMORY=16384            # RAM in MB
```

If you have a specific IPSW URL, set it:

```bash
IPHONE_IPSW_URL="https://..."
CLOUDOS_IPSW_URL="https://..."
```

### 2. Run Prerequisites Check

```bash
./setup.sh --check
```

This validates your system configuration and tells you what needs fixing.

### 3. Run Full Setup

```bash
./setup.sh
```

This runs all 8 phases sequentially. Each phase saves progress, so if something fails you can resume:

```bash
./setup.sh --resume
```

Or run a specific phase:

```bash
./setup.sh --phase 4
```

## Phases

| Phase | What it does |
|---|---|
| **0** | Prerequisites check (macOS version, SIP, AMFI, disk space, etc.) |
| **1** | Install tools (ipsw, img4lib, ldid2, kairos, keystone-engine, sshpass) |
| **2** | Download and extract iPhone + cloudOS/PCC firmware (IPSW files) |
| **3** | Build VM tool (vphone-cli or super-tart) from source, sign with entitlements |
| **4** | Patch boot chain (iBSS, iBEC, kernelcache), build Metal GPU plugin |
| **5** | Boot VM in DFU mode, load patched firmware, wait for SSH ramdisk |
| **6** | Mount rootfs via SSH, patch seputil + launchd_cache_loader, install Metal plugin, configure SSH |
| **7** | Normal boot with VNC display |

## Metal GPU Support

The VM uses Apple's ParavirtualizedGraphics framework for Metal acceleration. A compiler plugin (`libAppleParavirtCompilerPluginIOGPUFamily.dylib`) must be built and installed into the guest rootfs.

### Automatic (during setup)

Phase 4 attempts to build the plugin and Phase 6 installs it. If the source files aren't present, you'll be prompted to download them.

### Manual

```bash
cd CFW/libAppleParavirtCompilerPluginIOGPUFamily
./download.sh    # Fetches main.mm + build.sh from zeroxjf's blog
./build.sh       # Compiles the dylib
```

Then re-run Phase 6 to install it:

```bash
./setup.sh --phase 6
```

The plugin is installed to:
```
/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/libAppleParavirtCompilerPluginIOGPUFamily.dylib
```

Reference: https://zeroxjf.github.io/blog/metal-patch.html

## Connecting to the VM

After Phase 7 boots the VM, connection info is printed:

```
SSH:       ssh -p 22 root@<vm-ip>
Password:  alpine
VNC:       vnc://<vm-ip>:5901
```

## VM Approaches

### vphone-cli (default, recommended)

[Lakr233/vphone-cli](https://github.com/Lakr233/vphone-cli) — Swift CLI for iOS virtualization with full automation scripts.

### super-tart

[wh1te4ever/super-tart-vphone](https://github.com/wh1te4ever/super-tart-vphone) — Fork of tart with iOS VM support. Uses the [writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup) scripts for the boot chain.

Set in `config.sh`:

```bash
VM_APPROACH="super-tart"
```

## Troubleshooting

### Prerequisites fail

Run `./setup.sh --check` and follow the remediation instructions for each failure.

### Firmware download fails

Set `IPHONE_IPSW_URL` and/or `CLOUDOS_IPSW_URL` manually in `config.sh`. For cloudOS, you may need Apple's [PCC Virtual Research Environment](https://security.apple.com/pcc) tool.

### VM won't boot past DFU

- Verify SIP is disabled: `csrutil status`
- Verify AMFI is disabled: `nvram boot-args` should show `amfi_get_out_of_my_way=1`
- Check logs in `~/ios-vm/logs/`

### No Metal/GPU acceleration

Make sure the Metal compiler plugin is installed. Run:

```bash
cd CFW/libAppleParavirtCompilerPluginIOGPUFamily
./download.sh && ./build.sh
./setup.sh --phase 6   # re-install to VM
```

### Start over

```bash
./setup.sh --reset
```

## Project Structure

```
├── setup.sh          Main orchestrator
├── config.sh         User-configurable parameters
├── CFW/
│   └── libAppleParavirtCompilerPluginIOGPUFamily/
│       └── download.sh       Fetches Metal plugin source
├── lib/
│   ├── common.sh             Shared utilities
│   ├── prereqs.sh            System validation
│   ├── phase1_environment.sh Tool installation
│   ├── phase2_firmware.sh    Firmware download/extract
│   ├── phase3_build.sh       Build VM tool
│   ├── phase4_patch.sh       Firmware patching
│   ├── phase5_ramdisk.sh     DFU boot + SSH ramdisk
│   ├── phase6_install.sh     Rootfs patching + Metal plugin
│   └── phase7_boot.sh        Normal boot
└── templates/
    └── vphone-entitlements.plist   Virtualization.framework entitlements
```

## Credits

- [Lakr233/vphone-cli](https://github.com/Lakr233/vphone-cli)
- [wh1te4ever/super-tart-vphone](https://github.com/wh1te4ever/super-tart-vphone)
- [zeroxjf — Metal patch](https://zeroxjf.github.io/blog/metal-patch.html)
- [xerub/img4lib](https://github.com/xerub/img4lib)
- [dayt0n/kairos](https://github.com/dayt0n/kairos)
