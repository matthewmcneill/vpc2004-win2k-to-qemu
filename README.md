# vpc2004-win2k-to-qemu

Migrate a **Windows 2000 Professional** virtual machine from **Microsoft Virtual PC 2004** to **QEMU** — with a proven path for [UTM](https://mac.getutm.app/) on Apple Silicon.

This toolkit performs offline registry surgery on the guest disk image to swap Virtual PC hardware drivers for QEMU-compatible ones, then installs the VMware SVGA II display driver to enable native display rendering in UTM's SPICE protocol.

## The Problem

Windows 2000 binds kernel-mode drivers to specific PCI device IDs at install time. Virtual PC 2004 emulates an Intel PIIX4 chipset with an S3 Trio32/64 display adapter. QEMU emulates an Intel i440FX (PIIX3) chipset. When you convert a VHD and try to boot it in QEMU, Windows cannot find a matching IDE controller driver and halts with:

```
*** STOP: 0x0000007B (INACCESSIBLE_BOOT_DEVICE)
```

Even after fixing the IDE controller, UTM's SPICE display shows a **black screen** after the Windows splash because the Cirrus VGA adapter doesn't handle the VGA-to-graphical mode transition that SPICE expects.

This toolkit solves both problems.

## What It Does

| Step | Script | Action |
|------|--------|--------|
| 1 | `fix_ide_controller.sh` | Injects [MergeIDE](https://support.microsoft.com/en-us/topic/kb314082) entries into the offline registry so Windows recognises the PIIX3 IDE controller |
| 2 | `fix_filter_drivers.sh` | Disables Virtual PC Additions filter drivers (`vpc-s3`, `vpc-8042`, `mrxvpc`, `vmsrvc`) that crash without VPC hardware |
| 3 | `fix_display_driver.sh` | Resets the display class from VPC S3 Trio32/64 to Standard VGA for safe first boot |
| 4 | `fix_bootini.sh` | Verifies `boot.ini` partition references |
| 5 | `fix_hal.sh` | Verifies HAL compatibility |
| 6 | `prepare_svga_driver.sh` | Downloads VMware Tools 10.0.12, extracts the Win2K SVGA driver, and creates an ISO |

All registry surgery runs inside a Docker container with `ntfs-3g` and `hivex` — no need to install Linux filesystem tools on your host.

## Quick Start

### Prerequisites

- [Docker](https://www.docker.com/products/docker-desktop/)
- [QEMU](https://www.qemu.org/) (`brew install qemu` on macOS)
- [p7zip](https://p7zip.sourceforge.net/) (`brew install p7zip` on macOS)
- A Windows 2000 SP4 `.vhd` disk image from Virtual PC 2004

### 1. Clone and build

```bash
git clone https://github.com/youruser/vpc2004-win2k-to-qemu.git
cd vpc2004-win2k-to-qemu

# Build the surgery Docker container
docker build -t win2k-surgery -f scripts/Dockerfile.surgery scripts/
```

### 2. Convert the disk image

```bash
# Single-file VHD
qemu-img convert -f vpc /path/to/cdrive.vhd -O qcow2 cdrive.qcow2 -p

# Split VHD (.vhd + .v01) — use VirtualBox if available
VBoxManage clonemedium disk /path/to/cdrive.vhd cdrive.vdi --format VDI
qemu-img convert -f vdi cdrive.vdi -O qcow2 cdrive.qcow2 -p
```

### 3. Run the surgery pipeline

```bash
# Automated — runs all fixes in sequence
scripts/fix_vm.sh cdrive.qcow2

# Or with a dry run first
scripts/fix_vm.sh cdrive.qcow2 --dry-run
```

### 4. Test boot

```bash
scripts/launch_vm.sh cdrive.qcow2
```

Windows will detect new hardware and may restart several times. The `--no-reboot` flag converts restarts to shutdowns — just relaunch the script each time.

### 5. Install the VMware SVGA II driver

This step enables UTM's SPICE display (and higher resolutions + 32-bit colour).

```bash
# Download and prepare the driver ISO
scripts/prepare_svga_driver.sh

# Boot with the driver CD mounted
scripts/launch_vm_vmware.sh cdrive.qcow2 drivers/vmware_svga_w2k.iso
```

Inside Windows:
1. **Device Manager** → Display adapters → right-click → **Update Driver**
2. Choose **"Have Disk"** → browse to **D:\\** → select `vmx_svga.inf`
3. Complete the wizard and **reboot**

### 6. Run in UTM (optional)

If using UTM on macOS:
1. Create a new VM (Emulate → Other → x86_64 → Standard PC)
2. Import your `cdrive.qcow2` as the drive
3. Set the display adapter to **vmware-svga** (not cirrus-vga)
4. Set the network adapter to **tulip** (DEC 21140A)

## QEMU Configuration

The tested QEMU configuration for Windows 2000:

```bash
qemu-system-i386 \
    -machine pc \          # i440FX/PIIX3 chipset
    -cpu pentium3 \        # Compatible with Win2K kernel
    -m 512 \               # 512 MB RAM
    -hda cdrive.qcow2 \
    -vga vmware \          # VMware SVGA II (after driver install)
    -net nic,model=tulip \ # DEC 21140A — Win2K has built-in drivers
    -net user \
    -device sb16 \         # Sound Blaster 16 — built-in drivers
    -usb -device usb-tablet \  # Eliminates mouse capture
    -rtc base=localtime \
    -display cocoa \       # macOS: cocoa | Linux: gtk | Headless: vnc
    -no-reboot
```

## Display Adapter Compatibility

| Adapter | QEMU Flag | Win2K Driver | QEMU Native | UTM / SPICE |
|---------|-----------|--------------|-------------|-------------|
| Cirrus GD5446 | `-vga cirrus` | Built-in | ✅ Works | ❌ Black screen |
| Standard VGA | `-vga std` | Built-in | ✅ Works | ⚠️ Unstable |
| QXL | `-vga qxl` | None for Win2K | ❌ | ❌ |
| **VMware SVGA II** | **`-vga vmware`** | **Manual install** | **✅ Works** | **✅ Works** |

## Project Structure

```
vpc2004-win2k-to-qemu/
├── README.md
├── LICENSE
├── docs/
│   └── migration-guide.md      # Detailed technical reference
├── scripts/
│   ├── Dockerfile.surgery       # Debian container with ntfs-3g + hivex
│   ├── fix_vm.sh                # Master orchestrator
│   ├── fix_ide_controller.sh    # MergeIDE (CriticalDeviceDatabase + services)
│   ├── fix_filter_drivers.sh    # VPC Additions removal
│   ├── fix_display_driver.sh    # Display reset to Standard VGA
│   ├── fix_hal.sh               # HAL verification
│   ├── fix_bootini.sh           # boot.ini validation
│   ├── mount_vm.sh              # Loop-mount with 63-sector offset
│   ├── unmount_vm.sh            # Clean unmount
│   ├── launch_vm.sh             # QEMU launcher
│   ├── launch_vm_vmware.sh      # QEMU launcher with CD-ROM
│   ├── prepare_svga_driver.sh   # VMware SVGA driver ISO builder
│   ├── snapshot.sh              # QCOW2 snapshot management
│   ├── test_boot.sh             # Headless boot test
│   └── registry/
│       └── mergeide.reg         # Reference MergeIDE entries
└── tools/
    └── merge_split_vhd.py       # Split VHD (.v01) merge utility
```

## How It Works

See [docs/migration-guide.md](docs/migration-guide.md) for the full technical reference, including:

- Exact registry paths and values modified
- The IDE driver loading chain (`PCI Bus → PCIIde → Pciidex → IntelIde → atapi → disk → partmgr`)
- Why SPICE fails with Cirrus VGA on legacy guests
- The VMware Tools 10.0.12 driver extraction process
- Split VHD format handling

## Applicability

This toolkit was built and tested for:
- **Guest**: Windows 2000 Professional SP4
- **Source**: Microsoft Virtual PC 2004 SP1
- **Target**: QEMU 9.x / UTM 4.x on Apple Silicon (macOS)

The MergeIDE fix and display driver approach are likely applicable to:
- Windows XP and Server 2003 guests (adjust `WINNT` → `WINDOWS` paths)
- Other source hypervisors (replace VPC Additions removal with VMware Tools / Hyper-V IC removal)
- Linux QEMU hosts (replace `-display cocoa` with `-display gtk`)

PRs welcome for extending support.

## License

[MIT](LICENSE)
