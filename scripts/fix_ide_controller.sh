#!/bin/bash
# fix_ide_controller.sh — Inject MergeIDE entries into offline Windows 2000 registry
# Uses hivexsh for write operations (hivexregedit not available in Debian)
# Runs inside Docker container. Expects NTFS already mounted at /mnt/win2k
# Usage: fix_ide_controller.sh [--dry-run] [mount_point]

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

echo -e "${CYAN}=== Fix IDE Controller (MergeIDE KB314082) ===${NC}"
$DRY_RUN && echo -e "${YELLOW}*** DRY RUN MODE ***${NC}"

# Find SYSTEM hive
SYSTEM_HIVE=$(find "$MOUNT_POINT" -path "*/system32/config/system" -o -path "*/System32/config/SYSTEM" -o -path "*/system32/config/SYSTEM" 2>/dev/null | head -1)
if [[ -z "$SYSTEM_HIVE" ]]; then
    echo -e "${RED}Error: SYSTEM hive not found${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ SYSTEM hive: ${SYSTEM_HIVE}${NC}"

# Determine active ControlSet
CS_NUM=$(hivexget "$SYSTEM_HIVE" Select Current 2>/dev/null || echo "1")
CS_NUM="${CS_NUM:-1}"
CS="ControlSet$(printf '%03d' "$CS_NUM")"
echo -e "${GREEN}  ✓ Active ControlSet: ${CS}${NC}"

CDD="${CS}\\Control\\CriticalDeviceDatabase"

# Function: add a CriticalDeviceDatabase entry
add_cdd_entry() {
    local KEY_NAME="$1"
    local SERVICE="$2"
    local CLASS_GUID="$3"

    # Check if key already exists
    if hivexget "$SYSTEM_HIVE" "${CDD}\\${KEY_NAME}" Service &>/dev/null; then
        echo -e "  ${GREEN}✓ ${KEY_NAME} — already exists${NC}"
        return
    fi

    echo -e "  ${CYAN}+ ${KEY_NAME} → ${SERVICE}${NC}"

    if ! $DRY_RUN; then
        printf "cd ${CDD//\\/\\\\}\nadd ${KEY_NAME}\ncd ${KEY_NAME}\nsetval 2\nService\nstring:${SERVICE}\nClassGUID\nstring:${CLASS_GUID}\ncommit\n" | hivexsh -w "$SYSTEM_HIVE" 2>&1 || {
            echo -e "  ${RED}✗ Failed to add ${KEY_NAME}${NC}"
            return 1
        }
    fi
}

# Function: ensure a service key exists with all required fields
ensure_service() {
    local SVC_NAME="$1"
    local SVC_GROUP="$2"
    local SVC_IMAGE="$3"
    local SVC_TAG="${4:-1}"
    local SVC_PATH="${CS}\\Services\\${SVC_NAME}"

    # Check if service key exists and is complete
    CURRENT_START=$(hivexget "$SYSTEM_HIVE" "$SVC_PATH" Start 2>/dev/null || echo "")
    CURRENT_TYPE=$(hivexget "$SYSTEM_HIVE" "$SVC_PATH" Type 2>/dev/null || echo "")

    if [[ "$CURRENT_START" == "0" && -n "$CURRENT_TYPE" ]]; then
        echo -e "  ${GREEN}✓ ${SVC_NAME} — complete (Start=0, Type=${CURRENT_TYPE})${NC}"
        return
    fi

    if [[ -z "$CURRENT_START" ]]; then
        # Service key doesn't exist at all — create it
        echo -e "  ${CYAN}+ Creating ${SVC_NAME} service key${NC}"
        if ! $DRY_RUN; then
            printf "cd ${CS//\\/\\\\}\\\\Services\nadd ${SVC_NAME}\ncd ${SVC_NAME}\nsetval 6\nStart\ndword:0\nType\ndword:1\nErrorControl\ndword:1\nTag\ndword:${SVC_TAG}\nGroup\nstring:${SVC_GROUP}\nImagePath\nstring:${SVC_IMAGE}\ncommit\n" | hivexsh -w "$SYSTEM_HIVE" 2>&1
        fi
    else
        # Key exists but may be incomplete
        echo -e "  ${YELLOW}→ Updating ${SVC_NAME} (Start=${CURRENT_START}→0)${NC}"
        if ! $DRY_RUN; then
            # Set Start=0 and fill in missing fields
            printf "cd ${SVC_PATH//\\/\\\\}\nsetval 6\nStart\ndword:0\nType\ndword:1\nErrorControl\ndword:1\nTag\ndword:${SVC_TAG}\nGroup\nstring:${SVC_GROUP}\nImagePath\nstring:${SVC_IMAGE}\ncommit\n" | hivexsh -w "$SYSTEM_HIVE" 2>&1
        fi
    fi
}

IDE_GUID="{4D36E96A-E325-11CE-BFC1-08002BE10318}"
DISK_GUID="{4D36E967-E325-11CE-BFC1-08002BE10318}"

echo ""
echo -e "${CYAN}[1/3] Injecting CriticalDeviceDatabase entries...${NC}"

# Standard IDE channels (Service: atapi)
add_cdd_entry "primary_ide_channel" "atapi" "$IDE_GUID"
add_cdd_entry "secondary_ide_channel" "atapi" "$IDE_GUID"
add_cdd_entry "*pnp0600" "atapi" "$IDE_GUID"
add_cdd_entry "*azt0502" "atapi" "$IDE_GUID"

# Generic disk (Service: disk)
add_cdd_entry "gendisk" "disk" "$DISK_GUID"

# Generic PCI IDE class code (Service: pciide)
add_cdd_entry "pci#cc_0101" "pciide" "$IDE_GUID"

# Compaq
add_cdd_entry "pci#ven_0e11&dev_ae33" "pciide" "$IDE_GUID"

# SIS
add_cdd_entry "pci#ven_1039&dev_0601" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1039&dev_5513" "pciide" "$IDE_GUID"

# PC Technology
add_cdd_entry "pci#ven_1042&dev_1000" "pciide" "$IDE_GUID"

# Promise Technology
add_cdd_entry "pci#ven_105a&dev_4d33" "pciide" "$IDE_GUID"

# CMD Technology
add_cdd_entry "pci#ven_1095&dev_0640" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1095&dev_0646" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1095&dev_0646&REV_05" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1095&dev_0646&REV_07" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1095&dev_0648" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_1095&dev_0649" "pciide" "$IDE_GUID"

# Appian
add_cdd_entry "pci#ven_1097&dev_0038" "pciide" "$IDE_GUID"

# Symphony Labs
add_cdd_entry "pci#ven_10ad&dev_0001" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_10ad&dev_0150" "pciide" "$IDE_GUID"

# ALI
add_cdd_entry "pci#ven_10b9&dev_5215" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_10b9&dev_5219" "pciide" "$IDE_GUID"
add_cdd_entry "pci#ven_10b9&dev_5229" "pciide" "$IDE_GUID"

# SMC
add_cdd_entry "pci#ven_1055&dev_9130" "pciide" "$IDE_GUID"

# VIA
add_cdd_entry "pci#ven_1106&dev_0571" "pciide" "$IDE_GUID"

# Toshiba
add_cdd_entry "pci#ven_1179&dev_0105" "pciide" "$IDE_GUID"

# Intel — the critical PIIX3 (QEMU) and PIIX4 (VPC) entries
add_cdd_entry "pci#ven_8086&dev_1222" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_1230" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_2411" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_2421" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_7010" "intelide" "$IDE_GUID"  # PIIX3 — the QEMU controller!
add_cdd_entry "pci#ven_8086&dev_7111" "intelide" "$IDE_GUID"  # PIIX4 — the VPC controller
add_cdd_entry "pci#ven_8086&dev_7199" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_244a" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_244b" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_248a" "intelide" "$IDE_GUID"
add_cdd_entry "pci#ven_8086&dev_7601" "intelide" "$IDE_GUID"

echo ""
echo -e "${CYAN}[2/3] Ensuring boot-critical service definitions...${NC}"
# The driver loading chain: PCI Bus → PCIIde → Pciidex → IntelIde → atapi → disk → partmgr
ensure_service "atapi"   "SCSI miniport"       "System32\\DRIVERS\\atapi.sys"    25
ensure_service "IntelIde" "System Bus Extender" "System32\\DRIVERS\\intelide.sys" 4
ensure_service "PCIIde"  "System Bus Extender"  "System32\\DRIVERS\\pciide.sys"   3
ensure_service "Pciidex" "System Bus Extender"  "System32\\DRIVERS\\pciidex.sys"  3
ensure_service "Disk"    "SCSI class"           "System32\\DRIVERS\\disk.sys"     1
ensure_service "PartMgr" "Boot Bus Extender"    "System32\\DRIVERS\\partmgr.sys"  1

echo ""
echo -e "${CYAN}[3/3] Verifying critical driver files...${NC}"
DRIVERS_DIR=$(find "$MOUNT_POINT" -type d -path "*/system32/drivers" -o -type d -path "*/System32/Drivers" 2>/dev/null | head -1)

CRITICAL_DRIVERS=("atapi.sys" "intelide.sys" "pciide.sys" "pciidex.sys" "disk.sys" "partmgr.sys")
MISSING=()
for drv in "${CRITICAL_DRIVERS[@]}"; do
    FOUND=$(find "$DRIVERS_DIR" -maxdepth 1 -iname "$drv" -print -quit)
    if [[ -n "$FOUND" ]]; then
        SIZE=$(stat -c %s "$FOUND" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓ ${drv} (${SIZE} bytes)${NC}"
    else
        echo -e "  ${RED}✗ ${drv} — MISSING${NC}"
        MISSING+=("$drv")
    fi
done

# Auto-recover missing drivers
if [[ ${#MISSING[@]} -gt 0 ]]; then
    SP_DIR=$(find "$MOUNT_POINT" -type d -ipath "*/servicepackfiles/i386" 2>/dev/null | head -1)
    for drv in "${MISSING[@]}"; do
        if [[ -n "$SP_DIR" ]]; then
            SP_FILE=$(find "$SP_DIR" -maxdepth 1 -iname "$drv" -print -quit)
            if [[ -n "$SP_FILE" ]] && ! $DRY_RUN; then
                cp "$SP_FILE" "$DRIVERS_DIR/$drv"
                echo -e "  ${GREEN}✓ Recovered ${drv} from ServicePackFiles${NC}"
            elif [[ -n "$SP_FILE" ]]; then
                echo -e "  ${YELLOW}[DRY RUN] Would recover ${drv} from ServicePackFiles${NC}"
            else
                echo -e "  ${YELLOW}⚠ ${drv} not in ServicePackFiles — may need driver.cab extraction${NC}"
            fi
        fi
    done
fi

echo ""
echo -e "${GREEN}=== IDE Controller Fix Complete ===${NC}"
