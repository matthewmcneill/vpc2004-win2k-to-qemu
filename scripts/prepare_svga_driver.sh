#!/usr/bin/env bash
# prepare_svga_driver.sh — Download and extract VMware SVGA II driver for Windows 2000
#
# Downloads VMware Tools 10.0.12 (the last version supporting Windows 2000),
# extracts the Win2K-specific SVGA display driver files, and creates a
# mountable ISO for installation inside the guest.
#
# Prerequisites: curl, p7zip (brew install p7zip), hdiutil (macOS) or genisoimage (Linux)
#
# Usage: ./prepare_svga_driver.sh [output_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$(dirname "$SCRIPT_DIR")/drivers}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

VMTOOLS_URL="https://packages-prod.broadcom.com/tools/frozen/windows/winPreVista.iso"
VMTOOLS_ISO="$OUTPUT_DIR/winPreVista.iso"
DRIVER_DIR="$OUTPUT_DIR/vmware_svga"
DRIVER_ISO="$OUTPUT_DIR/vmware_svga_w2k.iso"
TEMP_DIR="$OUTPUT_DIR/.extract_tmp"

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  VMware SVGA II Driver Preparation for Win2K    ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

mkdir -p "$OUTPUT_DIR" "$DRIVER_DIR"

# Check prerequisites
for cmd in curl 7z; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Error: '$cmd' not found. Install with: brew install ${cmd/7z/p7zip}${NC}"
        exit 1
    fi
done

# Step 1: Download VMware Tools 10.0.12
if [[ -f "$VMTOOLS_ISO" ]]; then
    echo -e "${GREEN}  ✓ VMware Tools ISO already downloaded${NC}"
else
    echo -e "${CYAN}Downloading VMware Tools 10.0.12...${NC}"
    curl -L -o "$VMTOOLS_ISO" "$VMTOOLS_URL" --progress-bar
    echo -e "${GREEN}  ✓ Downloaded $(du -h "$VMTOOLS_ISO" | cut -f1)${NC}"
fi

# Step 2: Extract VmVideo.cab from the ISO
echo -e "${CYAN}Extracting driver files...${NC}"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

7z x "$VMTOOLS_ISO" -o"$TEMP_DIR/iso" -y > /dev/null 2>&1

if [[ ! -f "$TEMP_DIR/iso/VmVideo.cab" ]]; then
    # VMware Tools bundles everything inside setup.exe
    echo -e "${YELLOW}  Extracting from setup.exe...${NC}"
    7z x "$TEMP_DIR/iso/setup.exe" -o"$TEMP_DIR/setup" -y > /dev/null 2>&1
    if [[ ! -f "$TEMP_DIR/setup/VmVideo.cab" ]]; then
        echo -e "${RED}Error: VmVideo.cab not found in VMware Tools ISO${NC}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    7z x "$TEMP_DIR/setup/VmVideo.cab" -o"$TEMP_DIR/video" -y > /dev/null 2>&1
else
    7z x "$TEMP_DIR/iso/VmVideo.cab" -o"$TEMP_DIR/video" -y > /dev/null 2>&1
fi

# Step 3: Copy Win2K-specific driver files with clean names
echo -e "${CYAN}Extracting Win2K driver files...${NC}"

# Map the mangled CAB names to clean filenames
# Win2K files have the _win2k suffix (GUID: BFE1940C_27A8_11E2_BE11_47336288709B)
WIN2K_GUID="BFE1940C_27A8_11E2_BE11_47336288709B"

declare -A FILE_MAP=(
    ["vmx_svga.inf"]="_vmx_svga.inf_win2k.${WIN2K_GUID}"
    ["vmx_svga.sys"]="_vmx_svga.sys_win2k.${WIN2K_GUID}"
    ["vmx_svga.cat"]="_vmx_svga.cat_win2k.${WIN2K_GUID}"
    ["vmx_svgaver.dll"]="_vmx_svgaver.dll_win2k.${WIN2K_GUID}"
    ["vmx_fb.dll"]="_vmx_fb.dll_win2k.${WIN2K_GUID}"
    ["vmx_mode.dll"]="_vmx_mode.dll_win2k.${WIN2K_GUID}"
    ["vmwogl32.dll"]="_vmwogl32.dll_win2k.${WIN2K_GUID}"
)

FOUND=0
for clean_name in "${!FILE_MAP[@]}"; do
    mangled="${FILE_MAP[$clean_name]}"
    if [[ -f "$TEMP_DIR/video/$mangled" ]]; then
        cp "$TEMP_DIR/video/$mangled" "$DRIVER_DIR/$clean_name"
        SIZE=$(du -h "$DRIVER_DIR/$clean_name" | cut -f1)
        echo -e "  ${GREEN}✓ ${clean_name} (${SIZE})${NC}"
        FOUND=$((FOUND + 1))
    else
        echo -e "  ${RED}✗ ${clean_name} — source not found${NC}"
    fi
done

echo ""

if [[ $FOUND -lt 7 ]]; then
    echo -e "${YELLOW}Warning: Only ${FOUND}/7 driver files found.${NC}"
    echo -e "${YELLOW}The GUID may differ in your VMware Tools version.${NC}"
    echo -e "${YELLOW}Check $TEMP_DIR/video/ for available files.${NC}"
fi

# Step 4: Create mountable ISO
echo -e "${CYAN}Creating driver ISO...${NC}"

if command -v hdiutil &>/dev/null; then
    # macOS
    hdiutil makehybrid -o "$DRIVER_ISO" "$DRIVER_DIR" \
        -iso -joliet -default-volume-name "VMSVGA" > /dev/null 2>&1
elif command -v genisoimage &>/dev/null; then
    # Linux
    genisoimage -o "$DRIVER_ISO" -V "VMSVGA" -J -r "$DRIVER_DIR" 2>/dev/null
elif command -v mkisofs &>/dev/null; then
    # Linux alternative
    mkisofs -o "$DRIVER_ISO" -V "VMSVGA" -J -r "$DRIVER_DIR" 2>/dev/null
else
    echo -e "${YELLOW}Warning: No ISO creation tool found (hdiutil/genisoimage/mkisofs)${NC}"
    echo -e "${YELLOW}Driver files are in: $DRIVER_DIR${NC}"
    echo -e "${YELLOW}You can mount this directory or create an ISO manually.${NC}"
    rm -rf "$TEMP_DIR"
    exit 0
fi

echo -e "${GREEN}  ✓ Driver ISO: ${DRIVER_ISO} ($(du -h "$DRIVER_ISO" | cut -f1))${NC}"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo -e "${BOLD}${GREEN}Done!${NC}"
echo ""
echo "Driver files: $DRIVER_DIR/"
echo "Driver ISO:   $DRIVER_ISO"
echo ""
echo "To install in the guest:"
echo "  1. Boot VM with: -vga vmware -cdrom $DRIVER_ISO"
echo "  2. In Windows: Device Manager → Display → Update Driver → Have Disk → D:\\"
echo "  3. Select vmx_svga.inf and complete the wizard"
echo "  4. Reboot"
