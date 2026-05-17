#!/usr/bin/env bash
# launch_vm_vmware.sh — Launch a Windows 2000 VM with VMware SVGA II adapter
#
# Usage: ./launch_vm_vmware.sh <qcow2_path> [cdrom_iso]
# Example: ./launch_vm_vmware.sh "/path/to/cdrive.qcow2"
# Example: ./launch_vm_vmware.sh "/path/to/cdrive.qcow2" "/path/to/vmware_svga_w2k.iso"
#
# Uses -vga vmware instead of -vga cirrus. The VMware SVGA II adapter:
#   - Supports higher resolutions and 32-bit colour
#   - Works correctly with UTM's SPICE display (no black screen)
#   - Requires the VMware SVGA driver to be installed in the guest
#
# On first boot with -vga vmware, Windows will fall back to Standard VGA.
# Mount the driver ISO and install via Device Manager → Display → Update Driver.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

QCOW2="${1:-}"
CDROM="${2:-}"

if [[ -z "$QCOW2" ]]; then
    echo "Usage: $0 <qcow2_path> [cdrom_iso]"
    echo "Example: $0 \"/path/to/cdrive.qcow2\""
    echo "         $0 \"/path/to/cdrive.qcow2\" \"$SCRIPT_DIR/../drivers/vmware_svga_w2k.iso\""
    exit 1
fi

QCOW2="$(cd "$(dirname "$QCOW2")" && pwd)/$(basename "$QCOW2")"

if [[ ! -f "$QCOW2" ]]; then
    echo -e "${RED}Error: QCOW2 not found: $QCOW2${NC}"
    exit 1
fi

# Build CDROM args if provided
CDROM_ARGS=""
if [[ -n "$CDROM" ]]; then
    CDROM="$(cd "$(dirname "$CDROM")" && pwd)/$(basename "$CDROM")"
    if [[ ! -f "$CDROM" ]]; then
        echo -e "${RED}Error: ISO not found: $CDROM${NC}"
        exit 1
    fi
    CDROM_ARGS="-cdrom $CDROM"
fi

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Windows 2000 VM — VMware SVGA II Launcher     ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Disk:    $QCOW2"
echo "  Machine: pc (i440FX/PIIX3)"
echo "  CPU:     pentium3"
echo "  RAM:     512 MB"
echo "  Display: VMware SVGA II (Cocoa native window)"
echo "  Network: tulip (DEC 21140A) — NAT"
echo "  Sound:   sb16"
if [[ -n "$CDROM" ]]; then
    echo -e "  CD-ROM:  ${YELLOW}$CDROM${NC}"
fi
echo ""
echo -e "${GREEN}Launching...${NC}"
echo ""

exec qemu-system-i386 \
    -machine pc \
    -cpu pentium3 \
    -m 512 \
    -hda "$QCOW2" \
    -vga vmware \
    $CDROM_ARGS \
    -net nic,model=tulip -net user \
    -device sb16 \
    -usb -device usb-tablet \
    -rtc base=localtime \
    -display cocoa \
    -no-reboot
