#!/bin/bash
# fix_vm.sh — Master orchestration script for Windows 2000 VM recovery
# Runs on HOST. Converts QCOW2→raw for container access, manages Docker lifecycle.
# Usage: fix_vm.sh <qcow2_path> [--dry-run] [--skip-hal] [--skip-snapshot]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW2=""
DRY_RUN=""
SKIP_HAL=""
SKIP_SNAPSHOT=false
DOCKER_IMAGE="win2k-surgery"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="--dry-run" ;;
        --skip-hal) SKIP_HAL="yes" ;;
        --skip-snapshot) SKIP_SNAPSHOT=true ;;
        *) QCOW2="$arg" ;;
    esac
done

if [[ -z "$QCOW2" ]]; then
    echo "Usage: $0 <qcow2_path> [--dry-run] [--skip-hal] [--skip-snapshot]"
    exit 1
fi

QCOW2="$(cd "$(dirname "$QCOW2")" && pwd)/$(basename "$QCOW2")"
QCOW2_DIR="$(dirname "$QCOW2")"
QCOW2_NAME="$(basename "$QCOW2")"
RAW_NAME="${QCOW2_NAME%.qcow2}.raw"
RAW_PATH="${QCOW2_DIR}/${RAW_NAME}"

if [[ ! -f "$QCOW2" ]]; then
    echo -e "${RED}Error: QCOW2 file not found: $QCOW2${NC}"
    exit 1
fi

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Windows 2000 VM Recovery — Fix Pipeline      ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "QCOW2: $QCOW2"
echo "Options: ${DRY_RUN:-none} ${SKIP_HAL:+skip-hal}"
echo ""

# Step 1: Snapshot
if ! $SKIP_SNAPSHOT; then
    echo -e "${BOLD}${CYAN}[1/8] Creating safety snapshot...${NC}"
    "$SCRIPT_DIR/snapshot.sh" create "$QCOW2"
    echo ""
else
    echo -e "${YELLOW}[1/8] Skipping snapshot${NC}"
    echo ""
fi

# Step 2: Convert QCOW2 → raw for container access
echo -e "${BOLD}${CYAN}[2/8] Converting QCOW2 → raw for surgery...${NC}"
qemu-img convert -f qcow2 -O raw -p "$QCOW2" "$RAW_PATH"
echo -e "${GREEN}  ✓ Raw image created: ${RAW_PATH}${NC}"
RAW_SIZE=$(ls -lh "$RAW_PATH" | awk '{print $5}')
echo -e "  Size: ${RAW_SIZE}"
echo ""

# Step 3: Verify Docker image
echo -e "${BOLD}${CYAN}[3/8] Checking Docker surgery image...${NC}"
if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo -e "${YELLOW}  Building Docker image '${DOCKER_IMAGE}'...${NC}"
    docker build -t "$DOCKER_IMAGE" -f "$SCRIPT_DIR/Dockerfile.surgery" "$SCRIPT_DIR"
fi
echo -e "${GREEN}  ✓ Docker image ready${NC}"
echo ""

# Step 4: Run surgery inside Docker container
echo -e "${BOLD}${CYAN}[4/8] Launching surgery container...${NC}"
echo ""

SURGERY_CMD="set -e; "
SURGERY_CMD+="echo '--- Mounting Image ---'; "
SURGERY_CMD+="/scripts/mount_vm.sh /workspace/${RAW_NAME}; "
SURGERY_CMD+="echo ''; "
SURGERY_CMD+="echo '--- IDE Controller Fix (MergeIDE KB314082) ---'; "
SURGERY_CMD+="/scripts/fix_ide_controller.sh ${DRY_RUN}; "
SURGERY_CMD+="echo ''; "
SURGERY_CMD+="echo '--- Filter Driver Fix ---'; "
SURGERY_CMD+="/scripts/fix_filter_drivers.sh ${DRY_RUN}; "
SURGERY_CMD+="echo ''; "
SURGERY_CMD+="echo '--- Display Driver Fix ---'; "
SURGERY_CMD+="/scripts/fix_display_driver.sh ${DRY_RUN}; "

if [[ -z "$SKIP_HAL" ]]; then
    SURGERY_CMD+="echo ''; "
    SURGERY_CMD+="echo '--- HAL Verification ---'; "
    SURGERY_CMD+="/scripts/fix_hal.sh ${DRY_RUN}; "
fi

SURGERY_CMD+="echo ''; "
SURGERY_CMD+="echo '--- Boot.ini Fix ---'; "
SURGERY_CMD+="/scripts/fix_bootini.sh ${DRY_RUN}; "
SURGERY_CMD+="echo ''; "
SURGERY_CMD+="echo '--- Unmounting ---'; "
SURGERY_CMD+="/scripts/unmount_vm.sh; "

docker run --rm \
    --privileged \
    -v "${QCOW2_DIR}:/workspace" \
    "$DOCKER_IMAGE" \
    -c "$SURGERY_CMD"

echo ""

# Step 5: Convert raw → QCOW2
echo -e "${BOLD}${CYAN}[5/8] Converting raw → QCOW2 with changes...${NC}"
mv "$QCOW2" "${QCOW2}.pre-surgery"
qemu-img convert -f raw -O qcow2 -p "$RAW_PATH" "$QCOW2"
echo -e "${GREEN}  ✓ Updated QCOW2 created${NC}"

# Step 6: Cleanup
echo -e "${BOLD}${CYAN}[6/8] Cleaning up temporary files...${NC}"
rm -f "$RAW_PATH"
echo -e "${GREEN}  ✓ Removed raw image${NC}"
rm -f "${QCOW2}.pre-surgery"
echo -e "${GREEN}  ✓ Removed pre-surgery backup${NC}"
echo ""

# Step 7: Report
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║           Surgery Pipeline Complete              ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${CYAN}Next steps:${NC}"
echo "  1. Run headless boot test:"
echo "     $SCRIPT_DIR/test_boot.sh \"$QCOW2\""
echo ""
echo "  2. If FAIL, check logs in: $(dirname "$SCRIPT_DIR")/logs/"
echo ""
echo "  3. To rollback:"
echo "     $SCRIPT_DIR/snapshot.sh list \"$QCOW2\""
echo "     $SCRIPT_DIR/snapshot.sh restore \"$QCOW2\" <snapshot_name>"
