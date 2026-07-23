#!/bin/bash
#
# Atomic Pi GPIO LED Test Script (Safe Version)
#
# The Atomic Pi uses Intel Cherry Trail (Z8350) with INT33FF GPIO controllers:
#   gpiochip0 = INT33FF:00 (Southwest, 98 lines)
#   gpiochip1 = INT33FF:01 (North, 73 lines)
#   gpiochip2 = INT33FF:02 (East, 27 lines)
#   gpiochip3 = INT33FF:03 (Southeast, 86 lines)
#
# WARNING: Some GPIO lines control critical SoC functions.
#          This script only touches lines that are:
#          - Currently configured as INPUT
#          - Not marked as [used]
#          - Not on the known-dangerous skip list
#
# Usage:
#   sudo ./gpio-led-test.sh                     # Try known LED pins
#   sudo ./gpio-led-test.sh scan gpiochip1      # Safe scan (inputs only)
#   sudo ./gpio-led-test.sh gpiochip1 LINE      # Test specific line
#   sudo ./gpio-led-test.sh scanout gpiochip1   # Scan current outputs (RISKY)
#

set +e

# ─── CONFIGURATION ──────────────────────────────────────────────────────────
# Atomic Pi LED mapping (East community / INT33FF:02):
#   GPIO1 (Green)  = gpiochip2 line 18 (MF_ISH_GPIO_1, legacy sysfs 332)
#   GPIO2 (Yellow) = gpiochip2 line 24 (MF_ISH_GPIO_2, legacy sysfs 338)
# LEDs are ACTIVE-LOW: 0 = ON, 1 = OFF
CHIP="gpiochip2"
GPIO1_LINE=18
GPIO2_LINE=24
LED_ON=0
LED_OFF=1

# Lines known to crash/lock the system. Add any you discover.
# Format: "chip:line" entries
SKIP_LIST=(
    "gpiochip1:1"
    "gpiochip1:2"
    "gpiochip1:4"
    "gpiochip1:23"
    "gpiochip1:27"
    "gpiochip1:47"
    "gpiochip1:50"
    "gpiochip1:52"
    "gpiochip1:55"
)
# These are lines that gpioinfo showed as output — they're controlling something.
# We skip them during discovery to avoid crashes.
# gpiochip1 outputs from your gpioinfo: 1, 2, 4, 23, 27, 47, 50, 52, 55

# ─── COLORS ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── HELPERS ─────────────────────────────────────────────────────────────────

check_tools() {
    for tool in gpioset gpioget gpioinfo gpiodetect; do
        if ! command -v "$tool" &>/dev/null; then
            echo -e "${RED}Error: $tool not found. Install gpiod:${NC}"
            echo "  sudo apt install gpiod"
            exit 1
        fi
    done
}

is_skipped() {
    local chip=$1
    local line=$2
    for entry in "${SKIP_LIST[@]}"; do
        if [[ "$entry" == "${chip}:${line}" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract line number from gpioinfo output like "  line   5:  unnamed ..."
get_line_num() {
    echo "$1" | sed -n 's/.*line[[:space:]]*\([0-9]*\):.*/\1/p'
}

# Safe blink: set high, sleep, set low, sleep
# Uses timeout to prevent hanging
blink_line() {
    local chip=$1
    local line=$2
    local on_time=${3:-0.5}
    local off_time=${4:-0.5}

    # Turn ON with a timeout
    timeout 2 gpioset "$chip" "$line"=1 &
    local pid=$!
    sleep "$on_time"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    # Turn OFF with a timeout
    timeout 2 gpioset "$chip" "$line"=0 &
    pid=$!
    sleep "$off_time"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# ─── TEST FUNCTIONS ──────────────────────────────────────────────────────────

test_specific() {
    local chip=$1
    local line=$2
    local count=${3:-5}

    echo -e "${BLUE}=== Testing $chip line $line ===${NC}"
    echo -e "Blinking ${count} times with 0.5s interval (active-low: 0=ON, 1=OFF)"
    echo ""

    for ((i=1; i<=count; i++)); do
        echo -ne "  Blink $i: ON  "
        timeout 2 gpioset "$chip" "$line"=$LED_ON &
        local pid=$!
        sleep 0.5
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        echo "OFF"
        timeout 2 gpioset "$chip" "$line"=$LED_OFF &
        pid=$!
        sleep 0.5
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done

    echo -e "\n${GREEN}Done.${NC}"
}

# SAFE scan: only toggle lines currently set as INPUT and not in skip list
safe_scan() {
    local chip=$1
    echo -e "${BLUE}=== Safe Scan: $chip ===${NC}"
    echo -e "${CYAN}Only testing lines that are: INPUT + unused + not in skip list${NC}"
    echo -e "${YELLOW}Each line ON for 1 second. Watch your LEDs.${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop at any time.${NC}"
    echo ""

    local count=0

    while IFS= read -r line_info; do
        # Only process lines that are: input, unused, active-high
        if echo "$line_info" | grep -q "unused" && echo "$line_info" | grep -q "input"; then
            local line_num
            line_num=$(get_line_num "$line_info")

            if [[ -z "$line_num" ]]; then
                continue
            fi

            if is_skipped "$chip" "$line_num"; then
                echo -e "  ${RED}SKIP${NC} ${chip} line ${line_num} (in skip list)"
                continue
            fi

            echo -ne "  ${chip} line ${line_num} -> ON  "

            # Use timeout as safety net
            timeout 3 gpioset "$chip" "$line_num"=1 &
            local pid=$!
            sleep 1
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true

            echo "OFF"

            # Brief pause between lines
            sleep 0.3
            count=$((count + 1))
        fi
    done < <(gpioinfo "$chip" 2>/dev/null | tail -n +2)

    echo ""
    echo -e "${GREEN}Scanned $count lines safely.${NC}"
    echo ""
    echo "If you saw an LED light up, test it directly:"
    echo "  $0 $chip <line_number>"
}

# Scan lines currently configured as OUTPUT (risky - may crash system!)
scan_outputs() {
    local chip=$1
    echo -e "${RED}=== OUTPUT Scan: $chip (RISKY!) ===${NC}"
    echo -e "${RED}WARNING: Output lines may control critical SoC functions.${NC}"
    echo -e "${RED}The system may lock up if a critical line is toggled.${NC}"
    echo -e "${YELLOW}Lines in the skip list will be skipped.${NC}"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return
    fi

    echo ""

    while IFS= read -r line_info; do
        if echo "$line_info" | grep -q "unused" && echo "$line_info" | grep -q "output"; then
            local line_num
            line_num=$(get_line_num "$line_info")

            if [[ -z "$line_num" ]]; then
                continue
            fi

            if is_skipped "$chip" "$line_num"; then
                echo -e "  ${RED}SKIP${NC} ${chip} line ${line_num} (in skip list)"
                continue
            fi

            echo -ne "  ${chip} line ${line_num} -> ON  "

            timeout 3 gpioset "$chip" "$line_num"=1 &
            local pid=$!
            sleep 1
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true

            echo "OFF"
            sleep 0.3
        fi
    done < <(gpioinfo "$chip" 2>/dev/null | tail -n +2)

    echo ""
    echo -e "${GREEN}Output scan complete.${NC}"
}

# Default test with known LED lines
default_test() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Atomic Pi GPIO LED Test (Safe)         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Target: ${CHIP} lines ${GPIO1_LINE} (GPIO1) and ${GPIO2_LINE} (GPIO2)"
    echo ""

    echo -e "${YELLOW}--- Test 1: Blink GPIO1 (${CHIP} line ${GPIO1_LINE}) ---${NC}"
    test_specific "$CHIP" "$GPIO1_LINE"
    echo ""

    echo -e "${YELLOW}--- Test 2: Blink GPIO2 (${CHIP} line ${GPIO2_LINE}) ---${NC}"
    test_specific "$CHIP" "$GPIO2_LINE"
    echo ""

    echo -e "${YELLOW}--- Test 3: Alternating blink ---${NC}"
    echo "GPIO1 and GPIO2 alternating..."
    for ((i=1; i<=6; i++)); do
        if ((i % 2 == 1)); then
            echo -ne "  GPIO1=ON  GPIO2=OFF  "
            timeout 2 gpioset "$CHIP" "$GPIO1_LINE"=$LED_ON "$GPIO2_LINE"=$LED_OFF &
        else
            echo -ne "  GPIO1=OFF GPIO2=ON   "
            timeout 2 gpioset "$CHIP" "$GPIO1_LINE"=$LED_OFF "$GPIO2_LINE"=$LED_ON &
        fi
        local pid=$!
        sleep 0.5
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo ""
    done

    # Both off
    timeout 2 gpioset "$CHIP" "$GPIO1_LINE"=$LED_OFF "$GPIO2_LINE"=$LED_OFF &
    local pid=$!
    sleep 0.1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}All tests complete.${NC}"
    echo ""
    echo -e "${YELLOW}If LEDs didn't blink, try safe scan:${NC}"
    echo "  $0 scan gpiochip1"
}

# Show current GPIO state for a chip
show_state() {
    local chip=${1:-gpiochip1}
    echo -e "${BLUE}=== GPIO State: $chip ===${NC}"
    echo ""
    echo "Lines configured as OUTPUT (potential LED candidates):"
    gpioinfo "$chip" | grep "output" | grep "unused" || echo "  (none)"
    echo ""
    echo "Lines marked as [used]:"
    gpioinfo "$chip" | grep "\[used\]" || echo "  (none)"
}

# Try a specific list of output lines safely, one at a time
# Tests both active-high and active-low
try_outputs() {
    echo -e "${BLUE}=== Testing known output lines (safe subset) ===${NC}"
    echo -e "${YELLOW}Testing each line HIGH then LOW for 1.5s each.${NC}"
    echo -e "${YELLOW}Watch LEDs - they may be active-low (light up when set to 0).${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop.${NC}"
    echo ""

    # Safe output lines to test (excluding line 4 which crashes)
    # gpiochip0 outputs: 61, 78, 93
    # gpiochip1 outputs: 1, 2, 23, 27, 47, 50, 52, 55 (skip 4)
    # gpiochip2 outputs: 2, 16, 18, 19, 20, 22
    # gpiochip3 outputs: 2

    local tests=(
        "gpiochip1:23"
        "gpiochip1:27"
        "gpiochip1:52"
        "gpiochip1:55"
        "gpiochip0:61"
        "gpiochip0:78"
        "gpiochip0:93"
        "gpiochip2:2"
        "gpiochip2:16"
        "gpiochip2:18"
        "gpiochip2:19"
        "gpiochip2:20"
        "gpiochip2:22"
        "gpiochip3:2"
    )

    for entry in "${tests[@]}"; do
        local chip="${entry%%:*}"
        local line="${entry##*:}"

        echo -ne "  ${chip} line ${line}:  HIGH="
        timeout 3 gpioset "$chip" "$line"=1 &
        local pid=$!
        sleep 1.5
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        echo -ne "done  LOW="
        timeout 3 gpioset "$chip" "$line"=0 &
        pid=$!
        sleep 1.5
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        echo "done"
        sleep 0.3
    done

    echo ""
    echo -e "${GREEN}All done. If an LED lit up during HIGH or LOW, note the chip:line.${NC}"
    echo "Then test it: $0 <gpiochipN> <line>"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

check_tools

case "${1:-}" in
    scan)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 scan <gpiochipN>"
            exit 1
        fi
        safe_scan "$2"
        ;;
    scanout)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 scanout <gpiochipN>"
            exit 1
        fi
        scan_outputs "$2"
        ;;
    tryouts)
        try_outputs
        ;;
    state)
        show_state "${2:-gpiochip1}"
        ;;
    gpiochip*)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 <gpiochipN> <line_number>"
            exit 1
        fi
        test_specific "$1" "$2"
        ;;
    skip)
        # Add a line to the skip list permanently
        if [[ -z "${2:-}" || -z "${3:-}" ]]; then
            echo "Usage: $0 skip <gpiochipN> <line>"
            echo "Adds a line to the dangerous skip list in the script."
            exit 1
        fi
        echo "Add \"${2}:${3}\" to the SKIP_LIST array in this script."
        ;;
    help|--help|-h)
        echo "Atomic Pi GPIO LED Test (Safe Version)"
        echo ""
        echo "Usage:"
        echo "  $0                        Test known GPIO1/GPIO2 LED lines"
        echo "  $0 scan gpiochipN         Safe scan: only INPUT lines"
        echo "  $0 scanout gpiochipN      Risky scan: OUTPUT lines (may crash!)"
        echo "  $0 state [gpiochipN]      Show current output/used state"
        echo "  $0 gpiochipN LINE         Test a specific chip and line"
        echo "  $0 help                   This help message"
        echo ""
        echo "Current LED defaults: $CHIP lines $GPIO1_LINE and $GPIO2_LINE"
        echo ""
        echo "Skip list (lines that crash the system):"
        for entry in "${SKIP_LIST[@]}"; do
            echo "  $entry"
        done
        echo ""
        echo "Strategy:"
        echo "  1. Run '$0 state' to see which lines are outputs"
        echo "  2. Run '$0 scan gpiochip1' to safely test input lines"
        echo "  3. If not found, carefully use '$0 scanout gpiochipN'"
        echo "  4. Once found, edit GPIO1_LINE/GPIO2_LINE at top of script"
        ;;
    *)
        default_test
        ;;
esac
