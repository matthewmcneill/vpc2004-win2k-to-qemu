# Migrating Windows 2000 Professional to UTM on Apple Silicon

A definitive step-by-step guide for migrating a Windows 2000 Professional SP4 virtual machine from Microsoft Virtual PC 2004 to UTM on Apple Silicon Macs.

## Overview

This guide covers the complete migration pipeline:

1. **Convert** the Virtual PC `.vhd` disk image to QEMU's `.qcow2` format
2. **Repair** the offline registry to swap Virtual PC hardware drivers for QEMU-compatible ones
3. **Boot** the VM using QEMU to verify it works
4. **Install** the VMware SVGA II display driver inside the guest
5. **Configure** UTM to run the VM with full SPICE display support

### Why This Is Needed

Windows 2000 expects specific hardware. Virtual PC emulates one set of devices; QEMU/UTM emulates a different set. Without offline registry surgery, Windows will blue-screen at boot because it tries to load drivers for hardware that no longer exists. Additionally, UTM's SPICE display protocol has a known incompatibility with the Cirrus VGA adapter on legacy guests — the VMware SVGA II adapter is required for a working display in UTM.

---

## The Surgery: What Must Change and Why

This section documents every modification required at a technical level. The tooling in subsequent sections automates all of this, but understanding the exact changes is essential for debugging and for applying the technique to other legacy Windows guests.

### Hardware Differences: Virtual PC vs QEMU

| Component | Virtual PC 2004 | QEMU (UTM) |
|-----------|----------------|------------|
| **Chipset** | Intel 440BX (PIIX4) | Intel i440FX (PIIX3) |
| **IDE Controller** | PIIX4 (`PCI VEN_8086 DEV_7111`) | PIIX3 (`PCI VEN_8086 DEV_7010`) |
| **Display** | VM Additions S3 Trio32/64 (`vpc-s3.sys`) | VMware SVGA II (`vmx_svga.sys`) |
| **Network** | DEC 21140A | DEC 21140A (compatible) |
| **Sound** | Sound Blaster 16 | Sound Blaster 16 (compatible) |
| **Mouse** | PS/2 | USB Tablet (eliminates capture) |

Windows 2000 binds drivers to specific PCI device IDs at install time. When the hardware changes underneath, it cannot find a matching driver in the `CriticalDeviceDatabase` and blue-screens with `INACCESSIBLE_BOOT_DEVICE` (0x7B).

### Area 1: Disk Image Conversion

**Problem**: Virtual PC uses the `.vhd` (Virtual Hard Disk) format with a VPC-specific footer. QEMU uses `.qcow2`.

**Solution**: Convert with `qemu-img convert -f vpc`. QEMU's VPC driver reads the VHD footer, BAM (Block Allocation Map), and dynamic sectors natively.

**Split VHD caveat**: Virtual PC on FAT32 hosts splits disks at 4GB boundaries into `.vhd` + `.v01` + `.v02` etc. The BAM in the primary `.vhd` may contain stale references that don't account for the continuation files. VirtualBox's `VBoxManage clonemedium` handles this best; simple `cat` concatenation often fails because the VHD footer appears at the end of the first chunk, confusing parsers.

**Partition offset**: Windows 2000 MBR disks use a standard 63-sector offset (63 × 512 = 32,256 bytes). All mount operations must use `--offset 32256`.

### Area 2: IDE Controller (MergeIDE)

This is the most critical fix. Without it, Windows cannot access its own boot disk.

**Problem**: Virtual PC uses the Intel PIIX4 IDE controller (PCI `VEN_8086&DEV_7111`). QEMU's i440FX chipset uses PIIX3 (PCI `VEN_8086&DEV_7010`). Windows 2000 looks up the PCI device ID in the `CriticalDeviceDatabase` registry key during early boot — if no matching entry exists, it cannot load the disk driver and halts with BSOD `0x7B`.

**Registry hive**: `WINNT\system32\config\system` (the `SYSTEM` hive)

**Changes required** (all under the active `ControlSet`, typically `ControlSet001`):

#### 2a. CriticalDeviceDatabase entries

Add PCI-to-driver mappings so Windows recognises the new IDE controller. The critical entry for QEMU is:

```
HKLM\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_8086&dev_7010
  Service    = "intelide"     (REG_SZ)
  ClassGUID  = "{4D36E96A-E325-11CE-BFC1-08002BE10318}"  (REG_SZ)
```

The full MergeIDE set adds entries for ~30 IDE controllers (Intel, VIA, SIS, ALI, CMD, Promise, etc.) to make the image portable across any hardware. Key entries:

| CDD Key | Service | Description |
|---------|---------|-------------|
| `pci#ven_8086&dev_7010` | `intelide` | **PIIX3 — the QEMU controller** |
| `pci#ven_8086&dev_7111` | `intelide` | PIIX4 — the VPC controller |
| `pci#cc_0101` | `pciide` | Generic PCI IDE class code fallback |
| `primary_ide_channel` | `atapi` | Standard primary channel |
| `secondary_ide_channel` | `atapi` | Standard secondary channel |
| `gendisk` | `disk` | Generic disk device |

#### 2b. Service definitions

Ensure the driver loading chain is complete. Each service must have `Start=0` (boot start):

| Service | Group | ImagePath | Purpose |
|---------|-------|-----------|---------|
| `atapi` | SCSI miniport | `System32\DRIVERS\atapi.sys` | ATAPI/IDE miniport driver |
| `IntelIde` | System Bus Extender | `System32\DRIVERS\intelide.sys` | Intel IDE channel driver |
| `PCIIde` | System Bus Extender | `System32\DRIVERS\pciide.sys` | Generic PCI IDE enumerator |
| `Pciidex` | System Bus Extender | `System32\DRIVERS\pciidex.sys` | PCI IDE bus extension |
| `Disk` | SCSI class | `System32\DRIVERS\disk.sys` | Disk class driver |
| `PartMgr` | Boot Bus Extender | `System32\DRIVERS\partmgr.sys` | Partition manager |

The loading chain is: **PCI Bus → PCIIde → Pciidex → IntelIde → atapi → disk → partmgr**

#### 2c. Driver file verification

All six `.sys` files must physically exist in `WINNT\system32\drivers\`. If any are missing, they can be recovered from `WINNT\ServicePackFiles\i386\` (present on SP4 installations).

### Area 3: Virtual PC Additions Removal

**Problem**: Virtual PC Additions installs kernel-mode filter drivers and services that intercept disk I/O, keyboard input, and display rendering. Without VPC hardware, these drivers crash during boot.

**Registry hive**: `WINNT\system32\config\system` (the `SYSTEM` hive)

**Toxic services to disable** (set `Start=4`, meaning "disabled"):

| Service | Type | Purpose in VPC |
|---------|------|---------------|
| `vpc-s3` | Display driver | VPC S3 Trio32/64 display adapter |
| `vpc-8042` | Input driver | VPC keyboard/mouse integration |
| `mrxvpc` | Filesystem filter | VPC shared folders redirector |
| `vmsrvc` | Service | VPC Additions user-mode service |
| `naiavf5x` | Filter driver | McAfee antivirus filter (often bundled) |
| `EntDrv50` | Filter driver | McAfee Enterprise filter |
| `mvstdi5x` | Filter driver | McAfee VSCore filter |

**Driver file neutralisation**: Rename the corresponding `.sys` files in `WINNT\system32\drivers\` to `.sys.disabled`:

- `vpc-s3.sys` → `vpc-s3.sys.disabled`
- `vpc-8042.sys` → `vpc-8042.sys.disabled`
- `mrxvpc.sys` → `mrxvpc.sys.disabled`
- `vmsrvc.sys` → `vmsrvc.sys.disabled`

### Area 4: Display Driver

The display migration happens in two phases — an offline reset and an online driver install.

#### Phase 1: Offline reset (surgery pipeline)

**Problem**: Windows 2000 has the VPC S3 Trio32/64 display driver bound to class instance `0000`. On QEMU hardware, this driver fails silently, producing a black screen after the splash.

**Registry hive**: `WINNT\system32\config\system` (the `SYSTEM` hive)

**Changes required**:

Reset the display class entry to Standard VGA:
```
HKLM\SYSTEM\ControlSet001\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}\0000
  InfPath          = "display.inf"                    (REG_SZ)
  InfSection       = "vga"                            (REG_SZ)
  DriverDesc       = "Video Graphics Adapter (VGA)"   (REG_SZ)
  MatchingDeviceId = "pci\ven_1013&dev_00b8"          (REG_SZ)
```

Ensure `VgaSave` is set to system start:
```
HKLM\SYSTEM\ControlSet001\Services\VgaSave
  Start = 1  (REG_DWORD, system start)
```

Disable the `vpc-s3` service:
```
HKLM\SYSTEM\ControlSet001\Services\vpc-s3
  Start = 4  (REG_DWORD, disabled)
```

#### Phase 2: VMware SVGA II driver install (online, inside guest)

**Problem**: UTM uses the SPICE protocol for display rendering. SPICE requires the guest to handle VGA-to-graphical mode transitions cleanly. The Cirrus GD5446 adapter (QEMU's default) fails this transition — the SPICE client desynchronises and shows a black screen. There is no `spice-vdagent` for Windows 2000 to negotiate resolution.

**Solution**: Switch QEMU to `-vga vmware` (VMware SVGA II adapter, PCI `VEN_15AD&DEV_0405`). This adapter's mode transitions are SPICE-compatible.

**Driver source**: VMware Tools 10.0.12 (`winPreVista.iso`) — the last release supporting Windows 2000.

**Driver files** (extracted from `VmVideo.cab`, using the `_win2k` variants):

| File | Size | Purpose |
|------|------|---------|
| `vmx_svga.inf` | 6.5 KB | Driver information file |
| `vmx_svga.sys` | 100 KB | Kernel-mode display driver |
| `vmx_svga.cat` | 9 KB | Driver catalogue (signature) |
| `vmx_fb.dll` | 1.6 MB | Framebuffer library |
| `vmx_mode.dll` | 16 KB | Mode switching library |
| `vmx_svgaver.dll` | 1.5 KB | Version resource |
| `vmwogl32.dll` | 10.5 MB | OpenGL ICD (software) |

**Installation method**: Manual "Have Disk" via Device Manager, pointing to the `.inf` file on a mounted ISO. This bypasses the VMware Tools MSI installer entirely, avoiding the need for KB891861-v2 (which updates Win2K's crypto stack to validate modern SHA-2 digital signatures).

### Area 5: Boot Configuration

**File**: `C:\boot.ini`

**Required content**:
```ini
[boot loader]
timeout=3
default=multi(0)disk(0)rdisk(0)partition(1)\WINNT
[operating systems]
multi(0)disk(0)rdisk(0)partition(1)\WINNT="Microsoft Windows 2000 Professional" /fastdetect
```

The `/fastdetect` flag is standard for Win2K SP4. The partition path `multi(0)disk(0)rdisk(0)partition(1)` maps to the first partition on the first IDE disk — matching QEMU's `-hda` parameter.

### Area 6: HAL (Hardware Abstraction Layer)

**Usually no change needed**. Both Virtual PC and QEMU's i440FX emulate a standard uniprocessor PC. The HAL binary (`hal.dll`) should be the standard UP HAL. The `fix_hal.sh` script verifies this but rarely needs to make changes.

### Summary: The Migration Equation

```
Working VM = VHD→QCOW2 conversion
           + MergeIDE (CriticalDeviceDatabase + services)
           + VPC Additions removal (services disabled + .sys renamed)
           + Display reset (VGA fallback)
           + VMware SVGA II driver (online install)
           + UTM config: vmware-svga adapter
```

---

## Prerequisites

### Host Machine
- macOS on Apple Silicon (M1/M2/M3/M4)
- [UTM](https://mac.getutm.app/) installed
- [Homebrew](https://brew.sh/) installed
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- QEMU (`brew install qemu`)

### Source Files
- A Windows 2000 Professional SP4 `.vhd` disk image from Virtual PC 2004
- The `.vmc` configuration file (useful for reference but not required)

---

## Step 1: Set Up the Project Structure

```bash
# Create working directory
mkdir -p {scripts,iso,logs}

# Clone or copy the migration toolkit scripts into scripts/
# Required scripts:
#   Dockerfile.surgery
#   mount_vm.sh, unmount_vm.sh
#   fix_ide_controller.sh, fix_filter_drivers.sh
#   fix_hal.sh, fix_bootini.sh, fix_display_driver.sh
#   fix_vm.sh (master orchestrator)
#   launch_vm.sh, launch_vm_vmware.sh
#   snapshot.sh, test_boot.sh
```

---

## Step 2: Build the Surgery Docker Container

The surgery pipeline runs inside a Debian container with `ntfs-3g`, `hivex`, and `chntpw` for offline Windows registry editing.

```bash
cd scripts

# Build the container
docker build -t win2k-surgery -f Dockerfile.surgery .
```

**Dockerfile.surgery:**
```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-utils nbd-client ntfs-3g libhivex-bin chntpw \
    bash coreutils file grep sed gawk util-linux kmod \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /mnt/win2k

COPY mount_vm.sh unmount_vm.sh \
     fix_ide_controller.sh fix_filter_drivers.sh \
     fix_hal.sh fix_bootini.sh \
     /scripts/
COPY registry/ /scripts/registry/

RUN chmod +x /scripts/*.sh
WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
```

---

## Step 3: Convert the VHD Disk Image

### Standard (Single-File) VHD

```bash
# Create a VM directory
mkdir -p "My VM"

# Copy the original VHD as a backup
cp /path/to/cdrive.vhd "My VM"/cdrive.vhd

# Convert VHD → QCOW2
qemu-img convert -f vpc \
  "My VM"/cdrive.vhd \
  -O qcow2 \
  "My VM"/cdrive.qcow2 -p
```

> [!IMPORTANT]
> The QEMU VPC driver expects a 63-sector partition offset (standard for Windows 2000 MBR disks). The `mount_vm.sh` script handles this automatically with `--offset 32256` (63 × 512 bytes).

### Split VHD Files (.vhd + .v01)

Virtual PC on FAT32 hosts splits large VHDs into 4GB chunks (e.g., `cdrive.vhd` + `cdrive.v01`). These require special handling:

```bash
# Option A: Use VirtualBox (recommended)
brew install --cask virtualbox
VBoxManage clonemedium disk cdrive.vhd cdrive_merged.vdi --format VDI
qemu-img convert -f vdi cdrive_merged.vdi -O qcow2 cdrive.qcow2 -p

# Option B: Simple concatenation (may work for some images)
cat cdrive.vhd cdrive.v01 > cdrive_merged.vhd
qemu-img convert -f vpc cdrive_merged.vhd -O qcow2 cdrive.qcow2 -p
```

> [!WARNING]
> Split VHDs may have stale Block Allocation Maps (BAM) that don't reference the `.v01` data. If the converted image has NTFS I/O errors (e.g., `WINNT/system32/config/` is unreadable), the filesystem is likely corrupt at the source. VirtualBox handles split VHD chains most reliably.

---

## Step 4: Run the Surgery Pipeline

The surgery pipeline performs three critical offline fixes to the Windows registry:

1. **IDE Controller Fix (MergeIDE/KB314082)** — Replaces Virtual PC's IDE driver with the generic PIIX3-compatible `atapi.sys`
2. **Filter Driver Removal** — Removes Virtual PC Additions' filter drivers that crash without VPC hardware
3. **Display Driver Reset** — Clears the Cirrus-specific display configuration so Windows falls back to Standard VGA on first boot

```bash
cd scripts

# Run the full pipeline
./fix_vm.sh "My VM"/cdrive.qcow2

# Or with options:
./fix_vm.sh "My VM"/cdrive.qcow2 --dry-run      # Preview changes
./fix_vm.sh "My VM"/cdrive.qcow2 --skip-hal      # Skip HAL check
./fix_vm.sh "My VM"/cdrive.qcow2 --skip-snapshot  # Skip safety snapshot
```

### What the Pipeline Does

| Step | Script | Action |
|------|--------|--------|
| 1 | `snapshot.sh` | Creates a QCOW2 snapshot for rollback |
| 2 | `qemu-img convert` | Converts QCOW2 → raw for container access |
| 3 | Docker | Launches `win2k-surgery` container |
| 4 | `mount_vm.sh` | Loop-mounts the raw image with 63-sector offset |
| 5 | `fix_ide_controller.sh` | Patches `SYSTEM` hive: enables `atapi` service, disjects VPC IDE driver |
| 6 | `fix_filter_drivers.sh` | Patches `SYSTEM` hive: removes VPC filter drivers from `UpperFilters`/`LowerFilters` |
| 7 | `fix_display_driver.sh` | Resets display driver configuration to Standard VGA |
| 8 | `fix_hal.sh` | Verifies HAL compatibility |
| 9 | `fix_bootini.sh` | Ensures `boot.ini` has correct partition references |
| 10 | `unmount_vm.sh` | Cleanly unmounts the image |
| 11 | `qemu-img convert` | Converts raw → QCOW2 with all changes applied |

---

## Step 5: Test Boot with QEMU (Cocoa Display)

Before configuring UTM, verify the VM boots using QEMU directly with the native macOS Cocoa display:

```bash
./launch_vm.sh "My VM"/cdrive.qcow2
```

This uses the following QEMU configuration:

| Parameter | Value | Reason |
|-----------|-------|--------|
| `-machine pc` | i440FX/PIIX3 chipset | Matches the IDE controller fix |
| `-cpu pentium3` | Pentium III emulation | Compatible with Win2K's kernel |
| `-m 512` | 512 MB RAM | Standard for Win2K |
| `-vga vmware` | VMware SVGA II | Works with both Cocoa and SPICE |
| `-net nic,model=tulip` | DEC 21140A NIC | Win2K has built-in drivers |
| `-device sb16` | Sound Blaster 16 | Win2K has built-in drivers |
| `-usb -device usb-tablet` | USB tablet input | Eliminates mouse capture issues |
| `-rtc base=localtime` | Local time RTC | Prevents clock skew in guest |
| `-display cocoa` | Native macOS window | Reliable fallback display |

> [!NOTE]
> On first boot after surgery, Windows 2000 will detect new hardware (IDE controller, NIC, etc.) and may require several automatic reboots. The `-no-reboot` flag in the script converts reboots to shutdowns — simply relaunch the script after each shutdown.

---

## Step 6: Install the VMware SVGA II Display Driver

This is the critical step that enables UTM's SPICE display to work correctly. Without this driver, UTM shows a black screen after the Windows splash because SPICE cannot handle the Cirrus VGA mode transitions.

### Prepare the Driver ISO

```bash
# Download VMware Tools 10.0.12 (the last version supporting Win2K)
curl -L -o iso/winPreVista.iso \
  "https://packages-prod.broadcom.com/tools/frozen/windows/winPreVista.iso"

# Extract the Win2K SVGA driver
mkdir -p iso/vmware_svga_driver
cd iso
7z x winPreVista.iso -o./extracted -y
7z x ./extracted/VmVideo.cab -o./VmVideo -y

# Copy Win2K-specific files with clean names
cp ./VmVideo/_vmx_svga.inf_win2k.* vmware_svga_driver/vmx_svga.inf
cp ./VmVideo/_vmx_svga.sys_win2k.* vmware_svga_driver/vmx_svga.sys
cp ./VmVideo/_vmx_svga.cat_win2k.* vmware_svga_driver/vmx_svga.cat
cp ./VmVideo/_vmx_svgaver.dll_win2k.* vmware_svga_driver/vmx_svgaver.dll
cp ./VmVideo/_vmx_fb.dll_win2k.* vmware_svga_driver/vmx_fb.dll
cp ./VmVideo/_vmx_mode.dll_win2k.* vmware_svga_driver/vmx_mode.dll
cp ./VmVideo/_vmwogl32.dll_win2k.* vmware_svga_driver/vmwogl32.dll

# Create a mountable ISO
hdiutil makehybrid -o vmware_svga_w2k.iso vmware_svga_driver -iso -joliet \
  -default-volume-name "VMSVGA"

# Clean up
rm -rf extracted VmVideo
```

### Install the Driver in the Guest

1. **Boot** the VM with the driver ISO mounted as a CD-ROM:
   ```bash
   ./launch_vm_vmware.sh "My VM"/cdrive.qcow2 iso/vmware_svga_w2k.iso
   ```
   The VM will boot at low resolution (Standard VGA fallback) — this is expected.

2. **Log in** to Windows 2000.

3. **Install the driver** via Device Manager:
   - If the "Found New Hardware Wizard" appears automatically, click **Have Disk** and browse to `D:\`, select `vmx_svga.inf`.
   - If it doesn't appear: Right-click desktop → **Properties** → **Settings** → **Advanced** → **Adapter** → **Properties** → **Driver** → **Update Driver** → "Display a list of known drivers" → **Have Disk** → browse to `D:\` → select `vmx_svga.inf`.

4. **Reboot** the VM. It will now display at full resolution with 32-bit colour.

5. **Set your preferred resolution** (e.g., 1024×768 or higher) via Display Properties → Settings.

6. **Shut down** the VM cleanly.

> [!TIP]
> The manual "Have Disk" installation bypasses the VMware Tools MSI installer entirely. This means you do **not** need to install Windows 2000 Update Rollup 1 (KB891861-v2) — that update is only required if you run the full `setup.exe` installer, which validates modern digital signatures that base Win2K cannot process.

---

## Step 7: Configure UTM

### Create the UTM VM

1. Open **UTM** → **Create a New Virtual Machine** → **Emulate**
2. Select **Other** as the operating system
3. Skip the ISO boot media (we have an existing disk)
4. Configure hardware:
   - **Architecture**: x86_64
   - **System**: Standard PC (i440FX)
   - **Memory**: 512 MB
   - **CPU Cores**: 1
5. Skip shared directory
6. Name the VM (e.g., "My VM")

### Import the Disk

1. Open the VM settings in UTM
2. Under **Drives**, remove any default drive
3. Click **New Drive** → **Import** → select your `cdrive.qcow2`

### Set the Display Adapter

This is the critical configuration change. Edit the UTM config to use `vmware-svga`:

**Via UTM GUI:**
- VM Settings → **Display** → **Emulated Display Card** → select **vmware-svga**

**Via config.plist** (if the GUI doesn't expose the option):
```bash
# Find and edit the config.plist
UTM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents
CONFIG="$UTM_DIR/Your VM.utm/config.plist"

# Change cirrus-vga to vmware-svga
sed -i '' 's/cirrus-vga/vmware-svga/' "$CONFIG"
```

The relevant section in the plist should read:
```xml
<key>Hardware</key>
<string>vmware-svga</string>
```

### Configure Network

- **Network Mode**: Emulated VLAN
- **Emulated Network Card**: `tulip` (DEC 21140A) — Win2K has built-in drivers

### Launch

Start the VM in UTM. Windows 2000 should boot through the splash screen and display the desktop at full resolution inside the UTM window.

> [!NOTE]
> On the first UTM launch after switching from Cocoa/QEMU, Windows may detect a "new PCI device" and ask to install drivers. Click through the wizard and reboot — this is Windows recognising the slightly different QEMU device configuration under SPICE.

---

## Troubleshooting

### Black screen in UTM after Windows splash
**Cause**: The display adapter is set to `cirrus-vga` instead of `vmware-svga`, or the VMware SVGA driver is not installed in the guest.
**Fix**: Boot with `launch_vm_vmware.sh` (Cocoa display) and install the driver from the ISO, then ensure UTM config uses `vmware-svga`.

### VM hangs at "Booting from harddisk..."
**Cause**: The IDE controller fix was not applied, or the NTFS filesystem is corrupt.
**Fix**: Re-run the surgery pipeline. If the issue persists, mount the image in Docker and check if `WINNT/system32/config/` is readable.

### Blue screen (BSOD) on boot
**Cause**: Incompatible driver still loaded. Usually the VPC IDE driver (`vpcide.sys`) or filter drivers.
**Fix**: Re-run `fix_ide_controller.sh` and `fix_filter_drivers.sh` in dry-run mode to verify the fixes were applied.

### Mouse doesn't work / mouse is captured
**Cause**: Missing `-usb -device usb-tablet` argument.
**Fix**: Ensure both `-usb` and `-device usb-tablet` are in the QEMU command line. UTM handles this automatically.

### NTFS I/O errors when mounting disk
**Cause**: Filesystem corruption, often from split VHD merge issues.
**Fix**: Run `ntfsfix` on the partition:
```bash
docker run --rm --privileged -v /path/to/vm:/workspace win2k-surgery -c '
  LOOP=$(losetup --find --show --offset 32256 /workspace/cdrive.raw)
  ntfsfix $LOOP
  ntfsfix -d $LOOP
  losetup -d $LOOP
'
```

---

## Quick Reference

### QEMU Command Line
```bash
qemu-system-i386 \
    -machine pc -cpu pentium3 -m 512 \
    -hda cdrive.qcow2 \
    -vga vmware \
    -net nic,model=tulip -net user \
    -device sb16 \
    -usb -device usb-tablet \
    -rtc base=localtime \
    -display cocoa \
    -no-reboot
```

### Display Adapter Compatibility Matrix

| Adapter | QEMU Flag | Win2K Driver | Cocoa Display | UTM/SPICE Display |
|---------|-----------|--------------|---------------|-------------------|
| **Cirrus GD5446** | `-vga cirrus` | Built-in | ✅ Works | ❌ Black screen |
| **Standard VGA** | `-vga std` | Built-in | ✅ Works | ⚠️ Unstable |
| **QXL** | `-vga qxl` | None (XP+ only) | ❌ No driver | ❌ No driver |
| **VMware SVGA II** | `-vga vmware` | Manual install | ✅ Works | ✅ Works |

### File Inventory

| File | Description |
|------|-------------|
| `scripts/fix_vm.sh` | Master surgery pipeline |
| `scripts/launch_vm.sh` | QEMU launcher (Cocoa display) |
| `scripts/launch_vm_vmware.sh` | QEMU launcher with CD-ROM support |
| `scripts/Dockerfile.surgery` | Docker image for offline registry editing |
| `iso/vmware_svga_w2k.iso` | VMware SVGA II driver for Windows 2000 |
| `iso/winPreVista.iso` | Full VMware Tools 10.0.12 |
