#!/bin/bash
# fix_display_driver.sh — Reset VPC S3 display driver to standard VGA
# Runs inside Docker container. Expects NTFS already mounted.
# Usage: fix_display_driver.sh [--dry-run] [mount_point]
#
# Windows 2000 under VPC 2004 uses the "VM Additions S3 Trio32/64" display
# driver (vpc-s3.sys/dll). This driver doesn't exist on QEMU hardware, causing
# a black screen after the splash screen when Windows switches to graphical mode.
#
# This script:
# 1. Resets the Display class 0000 entry from vpc-s3 to standard VGA
# 2. Adds a CriticalDeviceDatabase entry for Cirrus Logic GD5446
#    (QEMU's default -vga cirrus device, PCI VEN_1013 DEV_00B8)
# 3. Ensures VgaSave is set to system start (Start=1)

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

echo -e "${CYAN}=== Fix Display Driver ===${NC}"
$DRY_RUN && echo -e "${YELLOW}*** DRY RUN MODE — no changes will be written ***${NC}"

# --- Locate SYSTEM hive ---
HIVE=""
for path in "$MOUNT_POINT"/WINNT/system32/config/system \
            "$MOUNT_POINT"/WINNT/System32/config/system \
            "$MOUNT_POINT"/WINDOWS/system32/config/system \
            "$MOUNT_POINT"/Windows/System32/config/system; do
    if [[ -f "$path" ]]; then
        HIVE="$path"
        break
    fi
done

if [[ -z "$HIVE" ]]; then
    # Case-insensitive fallback
    HIVE=$(find "$MOUNT_POINT" -ipath "*/system32/config/system" -not -ipath "*repair*" 2>/dev/null | head -1)
fi

if [[ -z "$HIVE" ]]; then
    echo -e "${RED}Error: SYSTEM hive not found${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ SYSTEM hive: ${HIVE}${NC}"

# --- Determine active ControlSet ---
CURRENT=$(hivexget "$HIVE" "Select" Current 2>/dev/null)
CS="ControlSet00${CURRENT}"
echo -e "${GREEN}  ✓ Active ControlSet: ${CS}${NC}"

DISP_GUID="{4D36E968-E325-11CE-BFC1-08002BE10318}"

# --- Check current display driver ---
echo ""
echo -e "${CYAN}Current display class 0000:${NC}"
printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\\\\0000\nlsval\n" | hivexsh "$HIVE" 2>&1 | head -20

CURRENT_DRIVER=$(printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\\\\0000\nlsval\n" | hivexsh "$HIVE" 2>/dev/null | grep InfSection | sed 's/.*="\(.*\)"/\1/')
echo ""
echo -e "  Current driver: ${YELLOW}${CURRENT_DRIVER}${NC}"

if [[ "$CURRENT_DRIVER" != "vpc-s3" && "$CURRENT_DRIVER" != *"S3"* && "$CURRENT_DRIVER" != *"s3"* ]]; then
    echo -e "${GREEN}  ✓ Display driver is not VPC S3 — no reset needed${NC}"
    # Still add CDD entry for Cirrus if missing
else
    echo -e "${YELLOW}  ⚠ VPC S3 driver detected — will reset to standard VGA${NC}"
fi

if $DRY_RUN; then
    echo -e "${YELLOW}  [DRY RUN] Would reset display driver — see above${NC}"
    exit 0
fi

# --- Reset display class 0000 to standard VGA ---
echo ""
echo -e "${CYAN}Resetting display class to standard VGA...${NC}"

# MatchingDeviceId set to Cirrus GD5446 (QEMU's cirrus-vga device)
printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\\\\0000
setval 4
InfPath
string:display.inf
InfSection
string:vga
DriverDesc
string:Video Graphics Adapter (VGA)
MatchingDeviceId
string:pci\\ven_1013&dev_00b8
commit
" | hivexsh -w "$HIVE" 2>&1

echo -e "${GREEN}  ✓ Display class 0000 reset to VGA${NC}"

# --- Ensure VgaSave is system-start ---
echo ""
VGASTART=$(hivexget "$HIVE" "${CS}\\Services\\VgaSave" Start 2>/dev/null || echo "")
if [[ "$VGASTART" == "1" ]]; then
    echo -e "${GREEN}  ✓ VgaSave already set to system start${NC}"
else
    echo -e "${YELLOW}  Setting VgaSave to system start (Start=1)...${NC}"
    printf "cd ${CS}\\\\Services\\\\VgaSave
setval 1
Start
dword:00000001
commit
" | hivexsh -w "$HIVE" 2>&1
    echo -e "${GREEN}  ✓ VgaSave set to system start${NC}"
fi

# --- Add CDD entry for Cirrus Logic GD5446 ---
echo ""
CDD_KEY="pci#ven_1013&dev_00b8"
CDD_PATH="${CS}\\Control\\CriticalDeviceDatabase\\${CDD_KEY}"

EXISTING=$(hivexget "$HIVE" "$CDD_PATH" Service 2>/dev/null || echo "")
if [[ -n "$EXISTING" ]]; then
    echo -e "${GREEN}  ✓ CDD entry for Cirrus GD5446 already exists (Service=${EXISTING})${NC}"
else
    echo -e "${YELLOW}  Adding CDD entry for Cirrus GD5446...${NC}"
    printf "cd ${CS}\\\\Control\\\\CriticalDeviceDatabase
add ${CDD_KEY}
cd ${CDD_KEY}
setval 2
Service
string:VgaSave
ClassGUID
string:${DISP_GUID}
commit
" | hivexsh -w "$HIVE" 2>&1
    echo -e "${GREEN}  ✓ CDD entry created${NC}"
fi

# --- Disable vpc-s3 service if present ---
echo ""
VPC_S3_START=$(hivexget "$HIVE" "${CS}\\Services\\vpc-s3" Start 2>/dev/null || echo "NOT_FOUND")
if [[ "$VPC_S3_START" != "NOT_FOUND" && "$VPC_S3_START" != "4" ]]; then
    echo -e "${YELLOW}  Disabling vpc-s3 service (was Start=${VPC_S3_START})...${NC}"
    printf "cd ${CS}\\\\Services\\\\vpc-s3
setval 1
Start
dword:00000004
commit
" | hivexsh -w "$HIVE" 2>&1
    echo -e "${GREEN}  ✓ vpc-s3 service disabled${NC}"
elif [[ "$VPC_S3_START" == "4" ]]; then
    echo -e "${GREEN}  ✓ vpc-s3 service already disabled${NC}"
else
    echo -e "${GREEN}  ✓ vpc-s3 service not present${NC}"
fi

# --- Verify ---
echo ""
echo -e "${CYAN}Verification:${NC}"
printf "cd ${CS}\\\\Control\\\\Class\\\\${DISP_GUID}\\\\0000
lsval
" | hivexsh "$HIVE" 2>&1

echo ""
echo -e "${GREEN}=== Display Driver Fix Complete ===${NC}"
