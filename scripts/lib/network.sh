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

# ============================================================
# Nätverksparameter för CT-skapning (DHCP vs statisk)
# ============================================================
# Returnerar korrekt --net0-sträng baserat på USE_DHCP
# Användning: NET0=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")
get_net0_param() {
    local ct_ip="$1"
    local cidr="$2"
    local gw="$3"
    
    if [ "${USE_DHCP:-false}" == "true" ]; then
        echo "name=eth0,bridge=vmbr0,ip=dhcp"
    else
        echo "name=eth0,bridge=vmbr0,ip=${ct_ip}/${cidr},gw=${gw}"
    fi
}

# Upptäck faktisk IP för en container efter start
# Användning: ACTUAL_IP=$(discover_ct_ip "$CT_ID" "$FALLBACK_IP" [timeout])
discover_ct_ip() {
    local ct_id="$1"
    local fallback_ip="$2"
    local timeout="${3:-30}"
    local ip=""
    
    # Vänta på att containern får en IP
    for i in $(seq 1 $((timeout / 3))); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            echo "$ip"
            return 0
        fi
        sleep 3
    done
    
    # Fallback till förväntad IP
    if [ -n "$fallback_ip" ]; then
        echo "$fallback_ip"
    fi
    return 1
}

# ============================================================
# IP-tillgänglighetscheck — pinga för att se om IP är ledig
# ============================================================
# Returnerar 0 om IP är ledig, 1 om den är upptagen
check_ip_free() {
    local ip="$1"
    # Snabb ping (1 paket, 1 sek timeout)
    if ping -c 1 -W 1 "$ip" > /dev/null 2>&1; then
        return 1  # Upptagen
    fi
    # Dubbelkolla med arping om tillgängligt (fångar enheter som inte svarar på ping)
    if command -v arping > /dev/null 2>&1; then
        if arping -c 1 -w 1 "$ip" 2>/dev/null | grep -q "reply"; then
            return 1  # Upptagen
        fi
    fi
    return 0  # Ledig
}

# Hitta nästa lediga IP från en startpunkt
# Användning: find_free_ip "192.168.1" 100
# Returnerar: ledigt IP-suffix (t.ex. "100" eller "101" om 100 är upptagen)
find_free_ip() {
    local prefix="$1"
    local start="$2"
    local max_tries=20
    
    for i in $(seq 0 $((max_tries - 1))); do
        local candidate=$((start + i))
        if [ $candidate -gt 254 ]; then
            break
        fi
        if check_ip_free "${prefix}.${candidate}"; then
            echo "$candidate"
            return 0
        fi
    done
    # Ingen ledig hittad
    echo ""
    return 1
}

# Verifiera alla planerade IP-adresser och rapportera konflikter
# Användning: verify_planned_ips
# Läser IP_HA, IP_CLOUDFLARED, IP_NPM, IP_FRIGATE från miljön
verify_planned_ips() {
    local prefix="${NETWORK_PREFIX}"
    local conflicts=0
    local services=("HA:${IP_HA}" "Cloudflared:${IP_CLOUDFLARED}" "NPM:${IP_NPM}" "Frigate:${IP_FRIGATE}")
    # Lägg till fler tjänster om de är konfigurerade
    [ -n "${IP_ADGUARD:-}" ] && services+=("AdGuard:${IP_ADGUARD}")
    [ -n "${IP_GUACAMOLE:-}" ] && services+=("Guacamole:${IP_GUACAMOLE}")
    [ -n "${IP_DESKTOP:-}" ] && services+=("Desktop:${IP_DESKTOP}")
    [ -n "${IP_SAMBA:-}" ] && services+=("Samba:${IP_SAMBA}")
    [ -n "${IP_IMMICH:-}" ] && services+=("Immich:${IP_IMMICH}")
    [ -n "${IP_NUT:-}" ] && services+=("NUT:${IP_NUT}")
    
    msg_info "Kontrollerar att planerade IP-adresser är lediga..."
    
    for entry in "${services[@]}"; do
        local name="${entry%%:*}"
        local suffix="${entry##*:}"
        [ -z "$suffix" ] && continue
        
        local full_ip="${prefix}.${suffix}"
        if ! check_ip_free "$full_ip"; then
            msg_warn "${full_ip} (ämnad för ${name}) är UPPTAGEN!"
            conflicts=$((conflicts + 1))
            
            # Försök hitta nästa lediga
            local free_suffix
            free_suffix=$(find_free_ip "$prefix" "$suffix")
            if [ -n "$free_suffix" ]; then
                msg_info "  Förslag: använd ${prefix}.${free_suffix} istället"
            fi
        else
            msg_ok "${full_ip} (${name}) — ledig"
        fi
    done
    
    return $conflicts
}
