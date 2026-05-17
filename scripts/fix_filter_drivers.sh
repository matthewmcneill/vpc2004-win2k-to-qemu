#!/bin/bash
# fix_filter_drivers.sh — Scrub orphaned McAfee/VPC filter drivers from device classes
# Runs inside Docker container. Expects NTFS already mounted at /mnt/win2k
# Usage: fix_filter_drivers.sh [--dry-run] [mount_point]

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

echo -e "${CYAN}=== Fix Filter Drivers ===${NC}"
$DRY_RUN && echo -e "${YELLOW}*** DRY RUN MODE — no changes will be written ***${NC}"

# Drivers to remove from UpperFilters/LowerFilters
TOXIC_DRIVERS=("naiavf5x" "EntDrv50" "mvstdi5x" "mrxvpc" "vmsrvc")

# Find SYSTEM hive
SYSTEM_HIVE=$(find "$MOUNT_POINT" -path "*/system32/config/system" -o -path "*/System32/config/SYSTEM" -o -path "*/system32/config/SYSTEM" 2>/dev/null | head -1)

if [[ -z "$SYSTEM_HIVE" ]]; then
    echo -e "${RED}Error: SYSTEM hive not found${NC}"
    exit 1
fi

# Determine active ControlSet
CS_NUM=$(hivexget "$SYSTEM_HIVE" Select Current 2>/dev/null || echo "1")
CS_NUM="${CS_NUM:-1}"
CONTROL_SET="ControlSet$(printf '%03d' "$CS_NUM")"
echo -e "${GREEN}  Active ControlSet: ${CONTROL_SET}${NC}"

CHANGES_MADE=0

# Check and disable McAfee/VPC services
echo ""
echo -e "${CYAN}Checking toxic services...${NC}"
TOXIC_SERVICES=("naiavf5x" "EntDrv50" "mvstdi5x" "mrxvpc" "vmsrvc" "vpc-s3" "vpc-8042")

for SVC in "${TOXIC_SERVICES[@]}"; do
    # Use hivexget to check if service exists and its Start value
    SVC_START=$(hivexget "$SYSTEM_HIVE" "${CONTROL_SET}\\Services\\${SVC}" Start 2>/dev/null || echo "")

    if [[ -n "$SVC_START" ]]; then
        if [[ "$SVC_START" == "4" ]]; then
            echo -e "  ${GREEN}✓ ${SVC}: already disabled (Start=4)${NC}"
        else
            echo -e "  ${RED}⚠ ${SVC}: Start=${SVC_START} — needs disabling${NC}"
            CHANGES_MADE=$((CHANGES_MADE + 1))
            if ! $DRY_RUN; then
                SVC_PATH="${CONTROL_SET}\\Services\\${SVC}"
                printf "cd ${SVC_PATH//\\/\\\\}\nsetval 1\nStart\ndword:4\ncommit\n" | hivexsh -w "$SYSTEM_HIVE" 2>&1
                echo -e "  ${GREEN}  ✓ ${SVC} disabled${NC}"
            fi
        fi
    fi
done

# Check UpperFilters/LowerFilters in device class keys
echo ""
echo -e "${CYAN}Checking device class filter entries...${NC}"
echo -e "${YELLOW}  Note: UpperFilters/LowerFilters are multi-string values.${NC}"
echo -e "${YELLOW}  Automated scrubbing of individual entries requires chntpw.${NC}"
echo -e "${YELLOW}  Disabling the services (above) is the primary fix.${NC}"

# Verify the .sys files have been renamed (for informational purposes on fresh image)
echo ""
echo -e "${CYAN}Checking toxic driver files on disk...${NC}"
DRIVERS_DIR=$(find "$MOUNT_POINT" -type d -path "*/system32/drivers" -o -type d -path "*/System32/Drivers" 2>/dev/null | head -1)

if [[ -n "$DRIVERS_DIR" ]]; then
    TOXIC_FILES=("naiavf5x.sys" "EntDrv50.sys" "mvstdi5x.sys" "mrxvpc.sys" "vmsrvc.sys" "vpc-s3.sys" "vpc-8042.sys")
    for f in "${TOXIC_FILES[@]}"; do
        FOUND=$(find "$DRIVERS_DIR" -maxdepth 1 -iname "$f" -print -quit)
        OLD=$(find "$DRIVERS_DIR" -maxdepth 1 -iname "${f}.old" -print -quit)
        if [[ -n "$FOUND" ]]; then
            echo -e "  ${YELLOW}⚠ ${f} — still present (active!)${NC}"
            if ! $DRY_RUN; then
                mv "$FOUND" "${FOUND}.disabled"
                echo -e "  ${GREEN}  ✓ Renamed to ${f}.disabled${NC}"
                CHANGES_MADE=$((CHANGES_MADE + 1))
            fi
        elif [[ -n "$OLD" ]]; then
            echo -e "  ${GREEN}✓ ${f} — already renamed to .old${NC}"
        else
            echo -e "  ${GREEN}✓ ${f} — not present${NC}"
        fi
    done
fi

echo ""
echo -e "${GREEN}=== Filter Driver Fix Complete (${CHANGES_MADE} changes made) ===${NC}"
