#!/bin/bash
# fix_bootini.sh — Fix boot.ini for diagnostic booting
# Runs inside Docker container. Expects NTFS already mounted.
# Usage: fix_bootini.sh [--dry-run] [mount_point]

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

echo -e "${CYAN}=== Fix boot.ini ===${NC}"
$DRY_RUN && echo -e "${YELLOW}*** DRY RUN MODE — no changes will be written ***${NC}"

# Find boot.ini (should be at root of the partition)
BOOTINI=""
for path in "$MOUNT_POINT"/boot.ini \
            "$MOUNT_POINT"/BOOT.INI \
            "$MOUNT_POINT"/Boot.ini; do
    if [[ -f "$path" ]]; then
        BOOTINI="$path"
        break
    fi
done

if [[ -z "$BOOTINI" ]]; then
    echo -e "${RED}Error: boot.ini not found at ${MOUNT_POINT}${NC}"
    echo "  Directory listing:"
    ls -la "$MOUNT_POINT"/ | head -20
    exit 1
fi

echo -e "${GREEN}  ✓ Found: ${BOOTINI}${NC}"

# Display current contents
echo ""
echo -e "${CYAN}Current boot.ini:${NC}"
echo "---"
cat "$BOOTINI"
echo "---"
echo ""

# Check for issues
echo -e "${CYAN}Analyzing...${NC}"

# Check ARC path
if grep -q 'multi(0)disk(0)rdisk(0)partition(1)' "$BOOTINI"; then
    echo -e "${GREEN}  ✓ ARC path is correct: multi(0)disk(0)rdisk(0)partition(1)${NC}"
else
    echo -e "${YELLOW}  ⚠ ARC path may not match IDE 0:0 — check manually${NC}"
fi

# Check for stray /kernel= or /hal= switches
if grep -qE '/kernel=' "$BOOTINI"; then
    echo -e "${RED}  ⚠ Found stray /kernel= switch — will remove${NC}"
fi
if grep -qE '/hal=' "$BOOTINI"; then
    echo -e "${RED}  ⚠ Found stray /hal= switch — will remove${NC}"
fi

# Check for existing /SOS
if grep -qE '/SOS' "$BOOTINI"; then
    echo -e "${GREEN}  ✓ /SOS flag already present${NC}"
else
    echo -e "${YELLOW}  Adding /SOS flag for diagnostic boot${NC}"
fi

# Check for existing /BASEVIDEO
if grep -qE '/BASEVIDEO' "$BOOTINI"; then
    echo -e "${GREEN}  ✓ /BASEVIDEO flag already present${NC}"
else
    echo -e "${YELLOW}  Adding /BASEVIDEO flag for safe video mode${NC}"
fi

if $DRY_RUN; then
    echo -e "${YELLOW}  [DRY RUN] Would modify boot.ini — see analysis above${NC}"
else
    # Backup original
    cp "$BOOTINI" "${BOOTINI}.bak"
    echo -e "${GREEN}  ✓ Backed up as boot.ini.bak${NC}"

    # Extract the WINNT directory name from the existing OS entry
    # (handles cases where it might be WINNT, WINDOWS, etc.)
    WINDIR=$(grep -oP 'partition\(1\)\\[^"=]+' "$BOOTINI" | head -1 | sed 's/partition(1)\\//')
    WINDIR="${WINDIR:-WINNT}"
    # Strip any trailing \r
    WINDIR="${WINDIR%%$'\r'}"

    # Extract the OS description string
    OS_DESC=$(grep -oP '"[^"]+"' "$BOOTINI" | head -1)
    OS_DESC="${OS_DESC:-\"Microsoft Windows 2000 Professional\"}"
    # Strip any trailing \r
    OS_DESC="${OS_DESC%%$'\r'}"

    # Write a clean boot.ini with proper Windows CRLF line endings.
    # CRITICAL: Use printf with explicit \r\n — never use read/sed on
    # Windows text files in Linux, as \r gets embedded mid-line and
    # corrupts NTLDR's parser (causes duplicate boot menu entries).
    ARC_PATH="multi(0)disk(0)rdisk(0)partition(1)\\${WINDIR}"
    printf "[boot loader]\r\ntimeout=30\r\ndefault=${ARC_PATH}\r\n[operating systems]\r\n${ARC_PATH}=${OS_DESC} /fastdetect /SOS\r\n" > "$BOOTINI"

    echo -e "${GREEN}  ✓ boot.ini rewritten (clean CRLF)${NC}"

    echo ""
    echo -e "${CYAN}Updated boot.ini:${NC}"
    echo "---"
    cat "$BOOTINI"
    echo "---"
fi

echo ""
echo -e "${GREEN}=== boot.ini Fix Complete ===${NC}"
