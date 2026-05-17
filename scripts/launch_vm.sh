#!/usr/bin/env bash
# launch_vm.sh — Launch a migrated Windows 2000 VM using QEMU with Cocoa display
#
# Usage: ./launch_vm.sh <qcow2_path>
# Example: ./launch_vm.sh "/path/to/cdrive.qcow2"
#
# This bypasses UTM and uses QEMU's native macOS Cocoa display.
# Uses VMware SVGA II adapter which works with both Cocoa and UTM/SPICE.
# The VMware SVGA driver must be installed in the guest OS first
# (see drivers/ for the driver files).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

QCOW2="${1:-}"

if [[ -z "$QCOW2" ]]; then
    echo "Usage: $0 <qcow2_path>"
    echo "Example: $0 \"/path/to/cdrive.qcow2\""
    exit 1
fi

QCOW2="$(cd "$(dirname "$QCOW2")" && pwd)/$(basename "$QCOW2")"

if [[ ! -f "$QCOW2" ]]; then
    echo -e "${RED}Error: QCOW2 not found: $QCOW2${NC}"
    exit 1
fi

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Windows 2000 VM — QEMU/Cocoa Launcher       ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Disk:    $QCOW2"
echo "  Machine: pc (i440FX/PIIX3)"
echo "  CPU:     pentium3"
echo "  RAM:     512 MB"
echo "  Display: VMware SVGA II (Cocoa native window)"
echo "  Network: tulip (DEC 21140A) — NAT"
echo "  Sound:   sb16"
echo ""
echo -e "${GREEN}Launching...${NC}"
echo ""

exec qemu-system-i386 \
    -machine pc \
    -cpu pentium3 \
    -m 512 \
    -hda "$QCOW2" \
    -vga vmware \
    -net nic,model=tulip -net user \
    -device sb16 \
    -usb -device usb-tablet \
    -rtc base=localtime \
    -display cocoa \
    -no-reboot
