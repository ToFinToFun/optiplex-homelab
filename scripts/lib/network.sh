#!/usr/bin/env bash
# ============================================================
# Nätverksdetektering — Automatisk identifiering av nätverksinställningar
# ============================================================

# Detektera nätverksinställningar automatiskt
# Returnerar: DETECTED_GATEWAY, DETECTED_PREFIX, DETECTED_DNS, DETECTED_IP, DETECTED_NIC
detect_network() {
    # Hitta primärt nätverkskort (inte lo, inte vmbr)
    DETECTED_NIC=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [ -z "$DETECTED_NIC" ]; then
        # Fallback: hitta första aktiva NIC
        DETECTED_NIC=$(ip -o link show up | grep -v "lo\|vmbr\|tap\|veth" | awk -F': ' '{print $2}' | head -1)
    fi
    
    # Gateway
    DETECTED_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    
    # Vår egen IP
    if [ -n "$DETECTED_NIC" ]; then
        DETECTED_IP=$(ip -4 addr show "$DETECTED_NIC" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # Nätverksprefix (första 3 oktetter)
    if [ -n "$DETECTED_IP" ]; then
        DETECTED_PREFIX=$(echo "$DETECTED_IP" | cut -d. -f1-3)
    elif [ -n "$DETECTED_GATEWAY" ]; then
        DETECTED_PREFIX=$(echo "$DETECTED_GATEWAY" | cut -d. -f1-3)
    fi
    
    # DNS-server
    DETECTED_DNS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')
    if [ -z "$DETECTED_DNS" ]; then
        DETECTED_DNS="$DETECTED_GATEWAY"
    fi
    
    # Subnet mask
    if [ -n "$DETECTED_NIC" ]; then
        DETECTED_CIDR=$(ip -4 addr show "$DETECTED_NIC" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 | cut -d/ -f2)
    fi
    DETECTED_CIDR="${DETECTED_CIDR:-24}"
}

# Visa detekterade inställningar och fråga om de stämmer
# Returnerar 0 om användaren bekräftar, 1 om de vill ändra
confirm_network() {
    detect_network
    
    echo -e "\n  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC} ${BOLD}Jag hittade ditt nätverk:${NC}                                  ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}" > /dev/tty
    printf "  ${CYAN}║${NC}   Gateway:     ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$DETECTED_GATEWAY" > /dev/tty
    printf "  ${CYAN}║${NC}   Prefix:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$DETECTED_PREFIX" > /dev/tty
    printf "  ${CYAN}║${NC}   Din IP:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$DETECTED_IP" > /dev/tty
    printf "  ${CYAN}║${NC}   DNS:         ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$DETECTED_DNS" > /dev/tty
    printf "  ${CYAN}║${NC}   NIC:         ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$DETECTED_NIC" > /dev/tty
    printf "  ${CYAN}║${NC}   Subnät:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "/${DETECTED_CIDR}" > /dev/tty
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n" > /dev/tty
    
    if ask_yes_no "Stämmer detta?" "Y"; then
        # Exportera till variabler som setup.sh använder
        NETWORK_PREFIX="$DETECTED_PREFIX"
        GATEWAY="$DETECTED_GATEWAY"
        return 0
    else
        return 1
    fi
}
