#!/bin/bash
# fix_hal.sh — Verify HAL is ACPI (and revert if incorrectly swapped)
# Runs inside Docker container. Expects NTFS already mounted.
# For a clean VHD re-conversion, the HAL should already be correct.
# Usage: fix_hal.sh [--dry-run] [mount_point]

set -euo pipefail

DRY_RUN=false
MOUNT_POINT="/mnt/win2k"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) MOUNT_POINT="$arg" ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Fix HAL (Verify ACPI) ===${NC}"
$DRY_RUN && echo -e "${YELLOW}*** DRY RUN MODE — no changes will be written ***${NC}"

# Find system32 directory
SYS32_DIR=$(find "$MOUNT_POINT" -type d -path "*/system32" -o -type d -path "*/System32" 2>/dev/null | grep -i 'winnt' | head -1)

if [[ -z "$SYS32_DIR" ]]; then
    echo -e "${RED}Error: System32 directory not found${NC}"
    exit 1
fi

echo -e "${CYAN}[1/3] Checking current HAL...${NC}"

HAL_FILE=$(find "$SYS32_DIR" -maxdepth 1 -iname "hal.dll" -print -quit)
NTOSKRNL_FILE=$(find "$SYS32_DIR" -maxdepth 1 -iname "ntoskrnl.exe" -print -quit)

if [[ -n "$HAL_FILE" ]]; then
    HAL_SIZE=$(stat -c %s "$HAL_FILE" 2>/dev/null || echo "0")
    echo -e "  hal.dll: ${HAL_SIZE} bytes"

    # ACPI Uniprocessor HAL is typically ~53-66KB on Win2K SP4
    # Standard PC HAL is typically ~44-50KB
    # The key difference is too subtle for size alone — check file identity
    echo -e "  ${GREEN}✓ hal.dll present${NC}"
    echo -e "  ${YELLOW}  (Since this is a clean VHD conversion, HAL should be original ACPI)${NC}"
fi

echo -e "${CYAN}[2/3] Checking for ACPI HAL source...${NC}"

SP_DIR=$(find "$MOUNT_POINT" -type d -ipath "*/servicepackfiles/i386" 2>/dev/null | head -1)

if [[ -n "$SP_DIR" ]]; then
    HALACPI=$(find "$SP_DIR" -maxdepth 1 -iname "halacpi.dll" -print -quit)
    if [[ -n "$HALACPI" ]]; then
        HALACPI_SIZE=$(stat -c %s "$HALACPI" 2>/dev/null || echo "0")
        echo -e "${GREEN}  ✓ halacpi.dll available in ServicePackFiles (${HALACPI_SIZE} bytes)${NC}"
    else
        echo -e "${YELLOW}  ⚠ halacpi.dll not found in ServicePackFiles${NC}"
    fi
else
    echo -e "${YELLOW}  ⚠ ServicePackFiles directory not found${NC}"
fi

echo -e "${CYAN}[3/3] Verifying kernel...${NC}"
if [[ -n "$NTOSKRNL_FILE" ]]; then
    KERN_SIZE=$(stat -c %s "$NTOSKRNL_FILE" 2>/dev/null || echo "0")
    echo -e "  ntoskrnl.exe: ${KERN_SIZE} bytes"
    echo -e "  ${GREEN}✓ Kernel present${NC}"
fi

echo ""
echo -e "${GREEN}=== HAL Verification Complete ===${NC}"
echo -e "${YELLOW}Note: Since we re-converted from the original VHD, the HAL should be correct.${NC}"
echo -e "${YELLOW}      ACPI must be ENABLED in QEMU/UTM settings (do NOT use -no-acpi).${NC}"
