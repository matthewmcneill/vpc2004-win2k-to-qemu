#!/bin/bash
# unmount_vm.sh — Safely unmount a VM image (runs inside Docker container)
# Handles both NBD and loop device cleanup
# Usage: unmount_vm.sh [mount_point]

set -euo pipefail

MOUNT_POINT="${1:-/mnt/win2k}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Unmounting VM Image ===${NC}"

# Step 1: Unmount NTFS
echo -e "${CYAN}[1/2] Unmounting ${MOUNT_POINT}...${NC}"
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    sync
    umount "$MOUNT_POINT"
    echo -e "${GREEN}  ✓ Unmounted${NC}"
else
    echo -e "${YELLOW}  ⚠ Not mounted${NC}"
fi

# Step 2: Clean up devices
echo -e "${CYAN}[2/2] Cleaning up devices...${NC}"

# Disconnect any NBD
qemu-nbd --disconnect /dev/nbd0 2>/dev/null && echo -e "${GREEN}  ✓ NBD disconnected${NC}" || true

# Detach any loop devices we created
for loop in /dev/loop*; do
    if losetup "$loop" 2>/dev/null | grep -q '/workspace/'; then
        losetup -d "$loop" 2>/dev/null && echo -e "${GREEN}  ✓ Loop device ${loop} detached${NC}" || true
    fi
done

echo -e "${GREEN}=== Unmount Complete ===${NC}"
