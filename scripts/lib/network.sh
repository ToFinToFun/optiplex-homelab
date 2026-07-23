#!/usr/bin/env bash
# ============================================================
# Nätverksdetektering — Automatisk identifiering av nätverksinställningar
# ============================================================

# Detektera nätverksinställningar automatiskt
# Returnerar: DETECTED_GATEWAY, DETECTED_PREFIX, DETECTED_DNS, DETECTED_IP, DETECTED_NIC
detect_network() {
    # Timeout-wrapper — kör kommando med max 3 sekunders timeout
    _net_cmd() {
        timeout 3 bash -c "$1" 2>/dev/null || echo ""
    }

    # Hitta primärt nätverkskort
    DETECTED_NIC=$(_net_cmd "ip route show default | awk '{print \$5}' | head -1")
    DETECTED_PHYSICAL_NIC=""
    
    if [[ "$DETECTED_NIC" == vmbr* ]]; then
        # Hitta det fysiska NIC:et som är slavat till bryggan
        DETECTED_PHYSICAL_NIC=$(_net_cmd "ip -o link show master $DETECTED_NIC | awk -F': ' '{print \$2}' | head -1")
        if [ -z "$DETECTED_PHYSICAL_NIC" ]; then
            DETECTED_PHYSICAL_NIC=$(_net_cmd "bridge link show | grep $DETECTED_NIC | awk '{print \$2}' | tr -d ':' | head -1")
        fi
    fi
    
    if [ -z "$DETECTED_NIC" ]; then
        # Fallback: hitta första aktiva NIC
        DETECTED_NIC=$(_net_cmd "ip -o link show up | grep -v 'lo\|vmbr\|tap\|veth' | awk -F': ' '{print \$2}' | head -1")
    fi
    
    # Gateway
    DETECTED_GATEWAY=$(_net_cmd "ip route show default | awk '{print \$3}' | head -1")
    
    # Vår egen IP
    if [ -n "$DETECTED_NIC" ]; then
        DETECTED_IP=$(_net_cmd "ip -4 addr show $DETECTED_NIC | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1")
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(_net_cmd "hostname -I | awk '{print \$1}'")
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
        DETECTED_CIDR=$(_net_cmd "ip -4 addr show $DETECTED_NIC | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 | cut -d/ -f2")
    fi
    DETECTED_CIDR="${DETECTED_CIDR:-24}"
}

# Visa detekterade inställningar och fråga om de stämmer
# Returnerar 0 om användaren bekräftar, 1 om de vill ändra
confirm_network() {
    detect_network
    
    # Om detektering misslyckades helt — gå direkt till manuell inmatning
    if [ -z "$DETECTED_IP" ] && [ -z "$DETECTED_GATEWAY" ]; then
        tty_echo "\n  ${YELLOW}[INFO]${NC} Kunde inte detektera nätverket automatiskt."
        tty_echo "  Du får ange inställningarna manuellt.\n"
        return 1
    fi
    
    tty_echo "\n  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    tty_echo "  ${CYAN}║${NC} ${BOLD}Jag hittade ditt nätverk:${NC}                                  ${CYAN}║${NC}"
    tty_echo "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    tty_printf "  ${CYAN}║${NC}   Gateway:     ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "${DETECTED_GATEWAY:-ej hittad}"
    tty_printf "  ${CYAN}║${NC}   Prefix:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "${DETECTED_PREFIX:-ej hittad}"
    tty_printf "  ${CYAN}║${NC}   Din IP:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "${DETECTED_IP:-ej hittad}"
    tty_printf "  ${CYAN}║${NC}   DNS:         ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "${DETECTED_DNS:-ej hittad}"
    # Visa NIC med fysiskt interface om det är en brygga
    if [ -n "$DETECTED_PHYSICAL_NIC" ]; then
        NIC_DISPLAY="${DETECTED_NIC} (brygga → ${DETECTED_PHYSICAL_NIC})"
    else
        NIC_DISPLAY="${DETECTED_NIC:-ej hittad}"
    fi
    tty_printf "  ${CYAN}║${NC}   NIC:         ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "$NIC_DISPLAY"
    tty_printf "  ${CYAN}║${NC}   Subnät:      ${GREEN}%-42s${NC} ${CYAN}║${NC}\n" "/${DETECTED_CIDR}"
    tty_echo "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    if ask_yes_no "Stämmer detta?" "Y"; then
        # Exportera till variabler som setup.sh använder
        NETWORK_PREFIX="$DETECTED_PREFIX"
        NETWORK_CIDR="$DETECTED_CIDR"
        GATEWAY="$DETECTED_GATEWAY"
        return 0
    else
        return 1
    fi
}
