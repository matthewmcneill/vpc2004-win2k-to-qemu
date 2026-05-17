#!/bin/bash
# test_boot.sh — Headless boot verification for Windows 2000 VM
# Runs on HOST using qemu-system-i386.
# Uses serial console + /SOS boot flag to detect BSOD vs. successful boot.
# Usage: test_boot.sh <qcow2_path> [--timeout 120] [--interactive]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
QCOW2=""
TIMEOUT=120
INTERACTIVE=false

prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --interactive) INTERACTIVE=true ;;
        --timeout)     : ;; # handled by next arg
        *)
            if [[ "$prev_arg" == "--timeout" ]]; then
                TIMEOUT="$arg"
            else
                QCOW2="$arg"
            fi
            ;;
    esac
    prev_arg="$arg"
done

if [[ -z "$QCOW2" ]]; then
    echo "Usage: $0 <qcow2_path> [--timeout 120] [--interactive]"
    exit 1
fi

QCOW2="$(cd "$(dirname "$QCOW2")" && pwd)/$(basename "$QCOW2")"
if [[ ! -f "$QCOW2" ]]; then
    echo "Error: QCOW2 file not found: $QCOW2"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/boot_${TIMESTAMP}.log"
RESULT_FILE="${LOG_DIR}/boot_${TIMESTAMP}.result"

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║    Windows 2000 VM — Headless Boot Test          ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "QCOW2: $QCOW2"
echo "Timeout: ${TIMEOUT}s"
echo "Log: $LOG_FILE"
echo ""

# QEMU command line (clean baseline from research)
QEMU_CMD=(
    qemu-system-i386
    -machine "pc"
    -cpu "pentium3"
    -m 512
    -drive "file=${QCOW2},format=qcow2,if=ide,index=0"
    -vga cirrus
    -net "nic,model=tulip"
    -net user
    -device sb16
    -usb
    -device usb-tablet
    -rtc "base=localtime"
)

if $INTERACTIVE; then
    # Interactive mode: show QEMU window
    echo -e "${CYAN}Starting QEMU in interactive mode (close window to stop)...${NC}"
    "${QEMU_CMD[@]}" 2>&1 | tee "$LOG_FILE"
    exit 0
fi

# Headless mode: serial console capture
QEMU_CMD+=(
    -nographic
    -serial stdio
    -monitor none
)

echo -e "${CYAN}Starting QEMU in headless mode...${NC}"
echo -e "${CYAN}Watching serial output for boot progress indicators...${NC}"
echo ""

# Run QEMU with timeout, capture output
BOOT_RESULT="TIMEOUT"
STOP_CODE=""

# Start QEMU in background, capture PID
"${QEMU_CMD[@]}" > "$LOG_FILE" 2>&1 &
QEMU_PID=$!

# Monitor the log file for success/failure indicators
ELAPSED=0
LAST_LINE_COUNT=0
PROGRESS_SEEN=false
DRIVER_COUNT=0

while [[ $ELAPSED -lt $TIMEOUT ]] && kill -0 "$QEMU_PID" 2>/dev/null; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))

    # Check for BSOD patterns
    if grep -qi "STOP:" "$LOG_FILE" 2>/dev/null; then
        STOP_CODE=$(grep -i "STOP:" "$LOG_FILE" | head -1)
        BOOT_RESULT="FAIL"
        break
    fi

    if grep -qi "0x0000007B" "$LOG_FILE" 2>/dev/null; then
        STOP_CODE="STOP 0x0000007B (INACCESSIBLE_BOOT_DEVICE)"
        BOOT_RESULT="FAIL"
        break
    fi

    if grep -qi "0x000000A5" "$LOG_FILE" 2>/dev/null; then
        STOP_CODE="STOP 0x000000A5 (ACPI_BIOS_ERROR)"
        BOOT_RESULT="FAIL"
        break
    fi

    if grep -qi "0x00000079" "$LOG_FILE" 2>/dev/null; then
        STOP_CODE="STOP 0x00000079 (MISMATCHED_HAL)"
        BOOT_RESULT="FAIL"
        break
    fi

    # Check for success indicators (driver loading via /SOS)
    CURRENT_LINES=$(cat "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    CURRENT_LINES=${CURRENT_LINES:-0}
    if [[ $CURRENT_LINES -gt $LAST_LINE_COUNT ]]; then
        LAST_LINE_COUNT=$CURRENT_LINES
        PROGRESS_SEEN=true

        # Count loaded drivers (rough indicator)
        NEW_DRIVERS=$(grep -ci "loaded driver" "$LOG_FILE" 2>/dev/null || true)
        NEW_DRIVERS=$(echo "$NEW_DRIVERS" | head -1 | tr -d ' ')
        NEW_DRIVERS=${NEW_DRIVERS:-0}
        if [[ $NEW_DRIVERS -gt $DRIVER_COUNT ]]; then
            DRIVER_COUNT=$NEW_DRIVERS
            echo -e "  [${ELAPSED}s] Loaded ${DRIVER_COUNT} drivers..."
        fi
    fi

    # Check for login prompt or shell (deep success)
    if grep -qi "win32k.sys" "$LOG_FILE" 2>/dev/null; then
        echo -e "  [${ELAPSED}s] win32k.sys loaded — boot is deep into GUI init!"
        BOOT_RESULT="PASS"
        # Give it a few more seconds to stabilize
        sleep 5
        break
    fi

    if grep -qi "Windows 2000" "$LOG_FILE" 2>/dev/null && [[ $DRIVER_COUNT -gt 20 ]]; then
        BOOT_RESULT="PASS"
        sleep 5
        break
    fi
done

# Kill QEMU
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

# Report results
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"

case "$BOOT_RESULT" in
    PASS)
        echo -e "${BOLD}${GREEN}  RESULT: PASS${NC}"
        echo -e "${GREEN}  Boot progressed past driver loading (${DRIVER_COUNT} drivers loaded)${NC}"
        echo -e "${GREEN}  The VM appears to be booting successfully!${NC}"
        echo "PASS" > "$RESULT_FILE"
        ;;
    FAIL)
        echo -e "${BOLD}${RED}  RESULT: FAIL${NC}"
        echo -e "${RED}  ${STOP_CODE}${NC}"
        echo -e "${YELLOW}  Check full serial log: ${LOG_FILE}${NC}"
        echo "FAIL: $STOP_CODE" > "$RESULT_FILE"
        ;;
    TIMEOUT)
        echo -e "${BOLD}${YELLOW}  RESULT: TIMEOUT${NC}"
        if $PROGRESS_SEEN; then
            echo -e "${YELLOW}  Some boot progress detected (${DRIVER_COUNT} drivers) but timed out${NC}"
            echo -e "${YELLOW}  Try increasing --timeout or check for CPU lock/ACPI issue${NC}"
        else
            echo -e "${YELLOW}  No boot progress detected in ${TIMEOUT}s${NC}"
            echo -e "${YELLOW}  The VM may be completely stuck or QEMU config is wrong${NC}"
        fi
        echo "TIMEOUT (${DRIVER_COUNT} drivers)" > "$RESULT_FILE"
        ;;
esac

echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo "Full serial log: $LOG_FILE"
echo "Log size: $(wc -c < "$LOG_FILE") bytes, $(wc -l < "$LOG_FILE") lines"
echo ""

# Show last few lines of the log for context
echo -e "${CYAN}Last 10 lines of serial output:${NC}"
tail -10 "$LOG_FILE"
