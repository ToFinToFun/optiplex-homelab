#!/usr/bin/env bash

# UI Helpers för OptiPlex Homelab Wizard

# Färger
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export CYAN='\033[0;36m'
export BOLD='\033[1m'
export NC='\033[0m' # No Color

# Ikoner
export ICON_OK="[${GREEN}✓${NC}]"
export ICON_FAIL="[${RED}✗${NC}]"
export ICON_INFO="[${BLUE}i${NC}]"
export ICON_WARN="[${YELLOW}!${NC}]"
export ICON_SKIP="[${CYAN}⏭${NC}]"

# Funktioner
msg_info() { echo -e "${ICON_INFO} $1"; }
msg_ok() { echo -e "${ICON_OK} $1"; }
msg_warn() { echo -e "${ICON_WARN} ${YELLOW}$1${NC}"; }
msg_err() { echo -e "${ICON_FAIL} ${RED}$1${NC}"; }
msg_skip() { echo -e "${ICON_SKIP} ${CYAN}$1${NC}"; }
msg_header() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"; }

print_banner() {
    local title="$1"
    local desc="$2"
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║${NC} ${BOLD}%-62s${NC} ${CYAN}║\n${NC}" "$title"
    printf "${CYAN}║${NC} %-62s ${CYAN}║\n${NC}" ""
    
    # Hantera multiline description
    while IFS= read -r line; do
        printf "${CYAN}║${NC} %-62s ${CYAN}║\n${NC}" "$line"
    done <<< "$desc"
    
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer
    
    if [ "$default" = "Y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    echo -ne "${BOLD}${prompt}${NC}"
    read answer
    
    if [ -z "$answer" ]; then
        answer="$default"
    fi
    
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

ask_string() {
    local prompt="$1"
    local default="$2"
    local is_secret="$3"
    local answer
    
    if [ -n "$default" ]; then
        prompt="$prompt [${default}]: "
    else
        prompt="$prompt: "
    fi
    
    echo -ne "${BOLD}${prompt}${NC}"
    
    if [ "$is_secret" = "true" ]; then
        read -s answer
        echo ""
    else
        read answer
    fi
    
    if [ -z "$answer" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}
