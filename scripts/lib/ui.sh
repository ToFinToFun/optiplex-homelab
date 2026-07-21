#!/usr/bin/env bash

# UI Helpers för OptiPlex Homelab Wizard

# Färger
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export CYAN='\033[0;36m'
export BOLD='\033[1m'
export DIM='\033[2m'
export NC='\033[0m' # No Color

# Ikoner
export ICON_OK="[${GREEN}✓${NC}]"
export ICON_FAIL="[${RED}✗${NC}]"
export ICON_INFO="[${BLUE}i${NC}]"
export ICON_WARN="[${YELLOW}!${NC}]"
export ICON_SKIP="[${CYAN}⏭${NC}]"
export ICON_DRY="[${DIM}DRY${NC}]"

# Dry-run mode (sätts via --dry-run flagga i setup.sh)
export DRY_RUN="${DRY_RUN:-false}"

# Funktioner
msg_info() { echo -e "${ICON_INFO} $1"; }
msg_ok() { echo -e "${ICON_OK} $1"; }
msg_warn() { echo -e "${ICON_WARN} ${YELLOW}$1${NC}"; }
msg_err() { echo -e "${ICON_FAIL} ${RED}$1${NC}"; }
msg_skip() { echo -e "${ICON_SKIP} ${CYAN}$1${NC}"; }
msg_header() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"; }
msg_dry() { echo -e "${ICON_DRY} ${DIM}(dry-run) Skulle: $1${NC}"; }

# Dry-run wrapper — kör kommando om inte dry-run
run_cmd() {
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "$*"
        return 0
    else
        "$@"
    fi
}

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

# ============================================================
# Progressbar / Stegindikator
# ============================================================
# Användning: show_progress <current_step> <total_steps> <step_name>
show_progress() {
    local current=$1
    local total=$2
    local name="$3"
    local width=30
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="■"; done
    for ((i=0; i<empty; i++)); do bar+="□"; done
    
    echo -e "\n  ${CYAN}┌─────────────────────────────────────────────────────────┐${NC}" > /dev/tty
    echo -e "  ${CYAN}│${NC}  [${GREEN}${bar}${NC}] Steg ${BOLD}${current}/${total}${NC} — ${name}  ${CYAN}│${NC}" > /dev/tty
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────────┘${NC}" > /dev/tty
}

# ============================================================
# Spinner med tidräknare
# ============================================================
# Användning: wait_for_service <host> <port> <name> <timeout_secs>
wait_for_service() {
    local host="$1"
    local port="$2"
    local name="$3"
    local timeout="${4:-120}"
    local elapsed=0
    local spinner='|/-\\'
    local spin_i=0
    
    while [ $elapsed -lt $timeout ]; do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            printf "\r  ${GREEN}\u2713${NC} ${name} svarar! (${elapsed}s)                    \n" > /dev/tty
            return 0
        fi
        
        local s=${spinner:$spin_i:1}
        printf "\r  ${CYAN}%s${NC} V\u00e4ntar p\u00e5 ${name}... (%ds/%ds)" "$s" "$elapsed" "$timeout" > /dev/tty
        spin_i=$(( (spin_i + 1) % 4 ))
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    printf "\r  ${YELLOW}\u26a0${NC} ${name} svarade inte inom ${timeout}s.          \n" > /dev/tty
    return 1
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
    
    # Skriv prompt direkt till terminalen (inte via tee/pipe)
    echo -ne "${BOLD}${prompt}${NC}" > /dev/tty
    read answer < /dev/tty
    
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
    
    # Skriv prompt direkt till terminalen (inte via tee/pipe)
    echo -ne "${BOLD}${prompt}${NC}" > /dev/tty
    
    if [ "$is_secret" = "true" ]; then
        read -s answer < /dev/tty
        echo "" > /dev/tty
    else
        read answer < /dev/tty
    fi
    
    if [ -z "$answer" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}
