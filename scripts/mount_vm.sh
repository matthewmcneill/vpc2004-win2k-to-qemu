#!/bin/bash
# mount_vm.sh — Mount a raw disk image's NTFS partition (runs inside Docker container)
# Uses loop device with auto-detected partition offset.
# Usage: mount_vm.sh <raw_image_path> [mount_point]

set -euo pipefail

IMAGE="${1:-}"
MOUNT_POINT="${2:-/mnt/win2k}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ -z "$IMAGE" ]]; then
    echo -e "${RED}Usage: $0 <raw_image_path> [mount_point]${NC}"
    exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
    echo -e "${RED}Error: Image file not found: $IMAGE${NC}"
    exit 1
fi

echo -e "${CYAN}=== Mounting VM Image ===${NC}"

# Step 1: Detect partition start sector
echo -e "${CYAN}[1/4] Detecting partition layout...${NC}"
START_SECTOR=$(file -s "$IMAGE" | grep -oP 'startsector \K[0-9]+' | head -1)
if [[ -z "$START_SECTOR" ]]; then
    echo -e "${YELLOW}  ⚠ Could not auto-detect start sector, defaulting to 63${NC}"
    START_SECTOR=63
fi
OFFSET=$((START_SECTOR * 512))
echo -e "${GREEN}  ✓ Partition at sector ${START_SECTOR} (offset ${OFFSET})${NC}"

# Step 2: Set up loop device
echo -e "${CYAN}[2/4] Setting up loop device...${NC}"
LOOP_DEV=$(losetup --find --show --offset "$OFFSET" "$IMAGE")
echo -e "${GREEN}  ✓ Loop device: ${LOOP_DEV}${NC}"

# Verify it's NTFS
FSTYPE=$(file -s "$LOOP_DEV" | head -1)
if ! echo "$FSTYPE" | grep -q "NTFS"; then
    echo -e "${RED}  ✗ Not an NTFS partition: ${FSTYPE}${NC}"
    losetup -d "$LOOP_DEV"
    exit 1
fi
echo -e "${GREEN}  ✓ NTFS filesystem confirmed${NC}"

# Step 3: Run ntfsfix
echo -e "${CYAN}[3/4] Running ntfsfix consistency check...${NC}"
ntfsfix "$LOOP_DEV" 2>&1 | grep -E '(Processing|NTFS|OK|SUCCESS|FIXED|completed)' || true

# Step 4: Mount NTFS
echo -e "${CYAN}[4/4] Mounting NTFS at ${MOUNT_POINT}...${NC}"
mkdir -p "$MOUNT_POINT"
ntfs-3g "$LOOP_DEV" "$MOUNT_POINT" -o rw,remove_hiberfile
echo -e "${GREEN}  ✓ NTFS mounted${NC}"

# Verify critical files
echo ""
echo -e "${CYAN}=== Verification ===${NC}"

SYSTEM_HIVE=""
for path in "$MOUNT_POINT"/WINNT/system32/config/system \
            "$MOUNT_POINT"/WINNT/system32/config/SYSTEM \
            "$MOUNT_POINT"/WINNT/System32/config/SYSTEM; do
    if [[ -f "$path" ]]; then
        SYSTEM_HIVE="$path"
        break
    fi
done

DRIVERS_DIR=""
for path in "$MOUNT_POINT"/WINNT/system32/drivers \
            "$MOUNT_POINT"/WINNT/System32/Drivers \
            "$MOUNT_POINT"/WINNT/System32/drivers; do
    if [[ -d "$path" ]]; then
        DRIVERS_DIR="$path"
        break
    fi
done

[[ -n "$SYSTEM_HIVE" ]] && echo -e "${GREEN}  ✓ SYSTEM hive: ${SYSTEM_HIVE}${NC}" || echo -e "${RED}  ✗ SYSTEM hive NOT found${NC}"
[[ -n "$DRIVERS_DIR" ]] && echo -e "${GREEN}  ✓ Drivers dir: ${DRIVERS_DIR}${NC}" || echo -e "${RED}  ✗ Drivers dir NOT found${NC}"

echo -e "${GREEN}=== Mount Complete ===${NC}"
