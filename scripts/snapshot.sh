#!/bin/bash
# snapshot.sh — QCOW2 snapshot management (runs on host)
# Usage: snapshot.sh <create|list|restore|delete> <qcow2_path> [snapshot_name]

set -euo pipefail

ACTION="${1:-}"
QCOW2="${2:-}"
SNAP_NAME="${3:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <create|list|restore|delete> <qcow2_path> [snapshot_name]"
    echo ""
    echo "Commands:"
    echo "  create  <qcow2> [name]  — Create a snapshot (default: pre-fix-TIMESTAMP)"
    echo "  list    <qcow2>         — List available snapshots"
    echo "  restore <qcow2> <name>  — Restore to a named snapshot"
    echo "  delete  <qcow2> <name>  — Delete a snapshot"
    exit 1
}

[[ -z "$ACTION" || -z "$QCOW2" ]] && usage
[[ ! -f "$QCOW2" ]] && echo -e "${RED}Error: QCOW2 file not found: $QCOW2${NC}" && exit 1

case "$ACTION" in
    create)
        SNAP_NAME="${SNAP_NAME:-pre-fix-$(date +%Y%m%d-%H%M%S)}"
        echo -e "${CYAN}Creating snapshot '${SNAP_NAME}' on ${QCOW2}...${NC}"
        qemu-img snapshot -c "$SNAP_NAME" "$QCOW2"
        echo -e "${GREEN}✓ Snapshot '${SNAP_NAME}' created successfully${NC}"
        ;;
    list)
        echo -e "${CYAN}Snapshots for ${QCOW2}:${NC}"
        qemu-img snapshot -l "$QCOW2" || echo -e "${YELLOW}No snapshots found${NC}"
        ;;
    restore)
        [[ -z "$SNAP_NAME" ]] && echo -e "${RED}Error: snapshot name required${NC}" && usage
        echo -e "${YELLOW}Restoring snapshot '${SNAP_NAME}' on ${QCOW2}...${NC}"
        qemu-img snapshot -a "$SNAP_NAME" "$QCOW2"
        echo -e "${GREEN}✓ Restored to snapshot '${SNAP_NAME}'${NC}"
        ;;
    delete)
        [[ -z "$SNAP_NAME" ]] && echo -e "${RED}Error: snapshot name required${NC}" && usage
        echo -e "${YELLOW}Deleting snapshot '${SNAP_NAME}' from ${QCOW2}...${NC}"
        qemu-img snapshot -d "$SNAP_NAME" "$QCOW2"
        echo -e "${GREEN}✓ Snapshot '${SNAP_NAME}' deleted${NC}"
        ;;
    *)
        usage
        ;;
esac
