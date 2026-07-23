#!/bin/bash
#
# Atomic Pi - All GPIO Test (Kernel 6.x)
#
# Tests all 8 user-accessible GPIO lines on gpiochip2 (East community):
#   - 2 on-board LEDs (active-low)
#   - 6 header pins (accent on 26-pin connector)
#
# Usage:
#   sudo ./gpio-all-test.sh           # Run all tests
#   sudo ./gpio-all-test.sh leds      # LEDs only
#   sudo ./gpio-all-test.sh header    # Header pins only
#   sudo ./gpio-all-test.sh chase     # LED chase pattern
#

CHIP="gpiochip2"

# On-board LEDs (active-low: 0=ON, 1=OFF)
LED1_LINE=18   # GPIO1 Green  (MF_ISH_GPIO_1)
LED2_LINE=24   # GPIO2 Yellow (MF_ISH_GPIO_2)
LED_ON=0
LED_OFF=1

# 26-pin header GPIOs (accent active-high for external devices)
# These output 3.3V logic levels
declare -A HEADER_PINS=(
    [ISH_GPIO_0]="21"   # 26-pin: 24, Enchilada: 9
    [ISH_GPIO_1]="18"   # 26-pin: 25, Enchilada: 10 (shared with LED1)
    [ISH_GPIO_2]="24"   # 26-pin: 26, Enchilada: 11 (shared with LED2)
    [ISH_GPIO_3]="15"   # 26-pin: 18, Enchilada: 3
    [ISH_GPIO_4]="22"   # 26-pin: 19, Enchilada: 4
    [ISH_GPIO_7]="16"   # 26-pin: 20, Enchilada: 5
)

# All 6 unique lines in order (excluding LED duplicates)
HEADER_LINES=(21 15 22 16)  # GPIO_0, GPIO_3, GPIO_4, GPIO_7 (non-LED header pins)
ALL_LINES=(18 24 21 15 22 16)  # All 6 unique lines

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

check_tools() {
    if ! command -v gpioset &>/dev/null; then
        echo -e "${RED}Error: gpioset not found. Install gpiod:${NC}"
        echo "  sudo apt install gpiod"
        exit 1
    fi
}

# Hold a pin at a value for a duration, then release
pulse() {
    local chip=$1 line=$2 value=$3 duration=$4
    timeout $((${duration%.*} + 2)) gpioset "$chip" "$line"="$value" &
    local pid=$!
    sleep "$duration"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# ─── LED TESTS ───────────────────────────────────────────────────────────────

test_leds() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   On-Board LED Test (Active-Low)         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${GREEN}--- GPIO1 (Green) - gpiochip2 line 18 ---${NC}"
    for ((i=1; i<=3; i++)); do
        echo -ne "  Blink $i "
        pulse $CHIP $LED1_LINE $LED_ON 0.3
        pulse $CHIP $LED1_LINE $LED_OFF 0.3
    done
    echo ""

    echo -e "${YELLOW}--- GPIO2 (Yellow) - gpiochip2 line 24 ---${NC}"
    for ((i=1; i<=3; i++)); do
        echo -ne "  Blink $i "
        pulse $CHIP $LED2_LINE $LED_ON 0.3
        pulse $CHIP $LED2_LINE $LED_OFF 0.3
    done
    echo ""

    echo -e "${CYAN}--- Alternating ---${NC}"
    for ((i=1; i<=4; i++)); do
        if ((i % 2 == 1)); then
            echo -ne "  Green=ON  Yellow=OFF "
            timeout 2 gpioset $CHIP $LED1_LINE=$LED_ON $LED2_LINE=$LED_OFF &
        else
            echo -ne "  Green=OFF Yellow=ON  "
            timeout 2 gpioset $CHIP $LED1_LINE=$LED_OFF $LED2_LINE=$LED_ON &
        fi
        local pid=$!
        sleep 0.4
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo ""
    done

    # Both off
    timeout 1 gpioset $CHIP $LED1_LINE=$LED_OFF $LED2_LINE=$LED_OFF &
    local pid=$!
    sleep 0.1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo -e "  ${GREEN}LEDs off.${NC}"
    echo ""
}

# ─── HEADER PIN TESTS ────────────────────────────────────────────────────────

test_header() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   26-Pin Header GPIO Test                ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Cycling each header pin HIGH for 1 second.${NC}"
    echo -e "${CYAN}Use a multimeter or LED on the header to verify.${NC}"
    echo ""

    echo -e "  ${BLUE}Pin${NC}  ${BLUE}Schematic${NC}      ${BLUE}Chip:Line${NC}  ${BLUE}26-pin${NC}  ${BLUE}Status${NC}"
    echo "  ───  ───────────  ─────────  ──────  ──────"

    local names=("ISH_GPIO_0" "ISH_GPIO_3" "ISH_GPIO_4" "ISH_GPIO_7" "ISH_GPIO_1" "ISH_GPIO_2")
    local lines=(21 15 22 16 18 24)
    local pins=("24" "18" "19" "20" "25" "26")

    for ((i=0; i<${#names[@]}; i++)); do
        local name="${names[$i]}"
        local line="${lines[$i]}"
        local pin="${pins[$i]}"

        printf "  %3s  %-13s  %s:%-4s  %-6s  " "$((i+1))" "$name" "$CHIP" "$line" "Pin $pin"

        # Drive HIGH
        timeout 3 gpioset $CHIP "$line"=1 &
        local pid=$!
        sleep 1
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true

        echo -e "${GREEN}✓ toggled${NC}"
        sleep 0.2
    done

    echo ""
    echo -e "${GREEN}All header pins tested.${NC}"
    echo ""
}

# ─── CHASE PATTERN ───────────────────────────────────────────────────────────

chase_leds() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   LED Chase Pattern                      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Running chase pattern on all 6 GPIO lines.${NC}"
    echo -e "${YELLOW}On-board LEDs are active-low; header pins go HIGH.${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop.${NC}"
    echo ""

    # Chase order: GPIO1(green), GPIO2(yellow), GPIO_0, GPIO_3, GPIO_4, GPIO_7
    local lines=(18 24 21 15 22 16)
    local names=("GPIO1-Grn" "GPIO2-Yel" "ISH_GPIO_0" "ISH_GPIO_3" "ISH_GPIO_4" "ISH_GPIO_7")
    # First two are active-low LEDs, rest are header pins (active-high for external LEDs)
    local active_vals=(0 0 1 1 1 1)     # value that turns the device "on"
    local inactive_vals=(1 1 0 0 0 0)   # value that turns the device "off"

    local rounds=3

    for ((r=1; r<=rounds; r++)); do
        echo -ne "  Round $r: "
        for ((i=0; i<${#lines[@]}; i++)); do
            local line="${lines[$i]}"
            local on="${active_vals[$i]}"
            local off="${inactive_vals[$i]}"

            echo -ne "${names[$i]} "

            # Turn on
            timeout 2 gpioset $CHIP "$line"="$on" &
            local pid=$!
            sleep 0.15
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true

            # Turn off
            timeout 2 gpioset $CHIP "$line"="$off" &
            pid=$!
            sleep 0.05
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
        echo ""
    done

    echo ""
    echo -e "${GREEN}Chase complete.${NC}"
}

# ─── READ ALL ────────────────────────────────────────────────────────────────

read_all() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Read All GPIO States                   ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    local names=("ISH_GPIO_0" "ISH_GPIO_1/LED1" "ISH_GPIO_2/LED2" "ISH_GPIO_3" "ISH_GPIO_4" "ISH_GPIO_7")
    local lines=(21 18 24 15 22 16)
    local pins=("24" "25/LED" "26/LED" "18" "19" "20")

    echo -e "  ${BLUE}Schematic${NC}        ${BLUE}Line${NC}  ${BLUE}26-pin${NC}   ${BLUE}Value${NC}"
    echo "  ─────────────  ────  ───────  ─────"

    for ((i=0; i<${#names[@]}; i++)); do
        local name="${names[$i]}"
        local line="${lines[$i]}"
        local pin="${pins[$i]}"
        local val

        val=$(gpioget $CHIP "$line" 2>/dev/null || echo "?")
        printf "  %-15s  %2s    %-7s  %s\n" "$name" "$line" "$pin" "$val"
    done

    echo ""
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

check_tools

case "${1:-all}" in
    all)
        test_leds
        test_header
        ;;
    leds)
        test_leds
        ;;
    header)
        test_header
        ;;
    chase)
        chase_leds
        ;;
    read)
        read_all
        ;;
    help|--help|-h)
        echo "Atomic Pi - All GPIO Test (Kernel 6.x)"
        echo ""
        echo "Usage:"
        echo "  $0              Run LED + header tests"
        echo "  $0 leds         On-board LEDs only"
        echo "  $0 header       26-pin header GPIOs only"
        echo "  $0 chase        Chase pattern across all lines"
        echo "  $0 read         Read current state of all GPIOs"
        echo ""
        echo "GPIO Map (all on gpiochip2 / East community):"
        echo "  Line 18  ISH_GPIO_1  LED Green (active-low)"
        echo "  Line 24  ISH_GPIO_2  LED Yellow (active-low)"
        echo "  Line 21  ISH_GPIO_0  26-pin header pin 24"
        echo "  Line 15  ISH_GPIO_3  26-pin header pin 18"
        echo "  Line 22  ISH_GPIO_4  26-pin header pin 19"
        echo "  Line 16  ISH_GPIO_7  26-pin header pin 20"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Try: $0 help"
        exit 1
        ;;
esac
