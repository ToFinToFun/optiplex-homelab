#!/usr/bin/env bash

# OptiPlex Homelab - Huvudinstallationsskript (Wizard)
set -e

# Byt till skriptets katalog
cd "$(dirname "$0")"

# Starta loggning
exec > >(tee -a /var/log/optiplex-setup.log) 2>&1

# Ladda bibliotek
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh

# ==========================================
# 1. Prereq Checks
# ==========================================
clear
msg_header "OptiPlex Homelab Installer"

if [ "$EUID" -ne 0 ]; then
    msg_err "Detta skript måste köras som root."
    exit 1
fi

if ! check_is_proxmox; then
    msg_err "Detta skript måste köras direkt på en Proxmox-nod."
    exit 1
fi

msg_ok "Körs som root på Proxmox"

# ==========================================
# 2. Konfiguration Phase
# ==========================================
msg_header "Konfiguration"

if load_config; then
    msg_ok "Hittade befintlig konfiguration (setup.env)"
else
    msg_info "Ingen setup.env hittades. Låt oss ställa in grunderna."
    
    NETWORK_PREFIX=$(ask_string "Nätverksprefix (t.ex. 192.168.1)" "192.168.1")
    GATEWAY=$(ask_string "Gateway IP" "${NETWORK_PREFIX}.1")
    CF_TUNNEL_TOKEN=$(ask_string "Cloudflare Tunnel Token (tryck Enter för att hoppa över)" "")
    CT_PASSWORD=$(ask_string "Standardlösenord för nya containers" "MySecurePassword123!" "true")
    
    STORAGE_POOL=$(find_storage_pool)
    if [ -z "$STORAGE_POOL" ]; then
        STORAGE_POOL="local-lvm"
    fi
    msg_info "Vald lagringspool för OS: $STORAGE_POOL"
    
    IP_HA="100"
    IP_CLOUDFLARED="101"
    IP_NPM="102"
    IP_FRIGATE="103"
    
    save_config
    msg_ok "Konfiguration sparad till setup.env"
fi

# ==========================================
# 3. Inventering och Planering (Resume-stöd)
# ==========================================
msg_header "Inventering av systemet"

# Status variabler
DO_HOST="y"
DO_HA="y"
DO_CF="y"
DO_NPM="y"
DO_FRIGATE="y"

# Kolla vad som redan finns och erbjud att köra ändå
if [ "$(get_state host_configured)" == "true" ]; then
    msg_skip "Proxmox Host är redan konfigurerad"
    DO_HOST="n"
else
    msg_info "Proxmox Host behöver konfigureras (repos, udev)"
fi

if check_id_exists $IP_HA; then
    if ask_yes_no "VM $IP_HA (Home Assistant) finns redan. Vill du köra HA-skriptet igen?" "N"; then
        DO_HA="y"
    else
        DO_HA="n"
    fi
else
    msg_info "VM $IP_HA (Home Assistant) saknas"
fi

if check_id_exists $IP_CLOUDFLARED; then
    if ask_yes_no "CT $IP_CLOUDFLARED (Cloudflared) finns redan. Vill du köra Cloudflare-skriptet igen?" "N"; then
        DO_CF="y"
    else
        DO_CF="n"
    fi
else
    msg_info "CT $IP_CLOUDFLARED (Cloudflared) saknas"
fi

if check_id_exists $IP_NPM; then
    if ask_yes_no "CT $IP_NPM (NPM) finns redan. Vill du köra NPM-skriptet igen?" "N"; then
        DO_NPM="y"
    else
        DO_NPM="n"
    fi
else
    msg_info "CT $IP_NPM (NPM) saknas"
fi

if check_id_exists $IP_FRIGATE; then
    if ask_yes_no "CT $IP_FRIGATE (Frigate) finns redan. Vill du köra Frigate-skriptet igen?" "N"; then
        DO_FRIGATE="y"
    else
        DO_FRIGATE="n"
    fi
else
    msg_info "CT $IP_FRIGATE (Frigate) saknas"
fi

echo ""
if ! ask_yes_no "Vill du fortsätta med vald installation?" "Y"; then
    msg_info "Avbryter installationen."
    exit 0
fi

# ==========================================
# 4. Execution Phase
# ==========================================

# 4.1 Storage (Disk)
if [ "$DO_FRIGATE" == "y" ]; then
    print_banner "Lagring" "Letar efter en dedikerad SSD för Frigate-inspelningar för att spara på OS-disken."
    bash modules/01-storage.sh
    source setup.env # Ladda om utifall STORAGE_POOL ändrades
fi

# 4.2 Proxmox Host
if [ "$DO_HOST" == "y" ]; then
    print_banner "Proxmox Host Konfiguration" "Fixar enterprise-repos, aktiverar TRIM, sätter udev-regler för iGPU och kollar BIOS-inställningar."
    bash modules/00-proxmox-host.sh
    set_state host_configured true
fi

# Hämta template om vi behöver LXC
if [ "$DO_CF" == "y" ] || [ "$DO_NPM" == "y" ] || [ "$DO_FRIGATE" == "y" ]; then
    TEMPLATE_PATH=$(get_debian_template)
fi

# 4.3 Home Assistant
if [ "$DO_HA" == "y" ]; then
    print_banner "Home Assistant (VM $IP_HA)" "Laddar ner HAOS och skapar en UEFI-baserad virtuell maskin för smarta hem-styrning."
    bash modules/02-ha-vm.sh
    # Validering
    msg_info "Väntar på att HA ska svara på port 8123..."
    for i in {1..10}; do
        if nc -z -w 2 "${NETWORK_PREFIX}.${IP_HA}" 8123 2>/dev/null; then
            msg_ok "HA är uppe och svarar!"
            break
        fi
        sleep 3
    done
fi

# 4.4 Cloudflared
if [ "$DO_CF" == "y" ]; then
    print_banner "Cloudflared (CT $IP_CLOUDFLARED)" "Skapar en krypterad tunnel till Cloudflare. Inga portar behöver öppnas i din router."
    bash modules/03-cloudflared.sh "$TEMPLATE_PATH"
fi

# 4.5 NPM
if [ "$DO_NPM" == "y" ]; then
    print_banner "Nginx Proxy Manager (CT $IP_NPM)" "Reverse proxy med snyggt GUI för att dirigera trafik till HA och Frigate internt."
    bash modules/04-npm.sh "$TEMPLATE_PATH"
    # Validering
    msg_info "Väntar på att NPM ska svara på port 81..."
    for i in {1..10}; do
        if nc -z -w 2 "${NETWORK_PREFIX}.${IP_NPM}" 81 2>/dev/null; then
            msg_ok "NPM är uppe och svarar!"
            break
        fi
        sleep 3
    done
fi

# 4.6 Frigate
if [ "$DO_FRIGATE" == "y" ]; then
    print_banner "Frigate NVR (CT $IP_FRIGATE)" "AI-videoövervakning med hårdvaruacceleration (iGPU passthrough) och Docker."
    bash modules/05-frigate.sh "$TEMPLATE_PATH"
fi

# 4.7 Axis Kameror
if [ "$DO_FRIGATE" == "y" ] || [ "$(get_state host_configured)" == "true" ]; then
    print_banner "Axis Kameror" "Skannar nätverket efter kameror och skapar Frigate-config automatiskt."
    bash modules/06-axis-cameras.sh
fi

# 4.8 Cloudflare DNS & Routing
if [ "$DO_CF" == "y" ] || [ "$DO_NPM" == "y" ] || [ "$(get_state host_configured)" == "true" ]; then
    print_banner "Cloudflare DNS & Routing" "Sätter automatiskt upp domäner och tunnel-routing via Cloudflare API."
    bash modules/07-cloudflare-dns.sh
fi

# 4.9 NPM Auto-Config
if [ "$DO_NPM" == "y" ] || [ "$(get_state host_configured)" == "true" ]; then
    print_banner "NPM Auto-Config" "Sätter upp proxy-regler i NPM automatiskt."
    bash modules/08-npm-config.sh
fi

# ==========================================
# 5. Summary
# ==========================================
clear
msg_header "Installation Slutförd!"

echo -e "${CYAN}┌─────────────┬──────────────────────────┬──────────────────────────┐${NC}"
echo -e "${CYAN}│${NC} ${BOLD}Tjänst${NC}      ${CYAN}│${NC} ${BOLD}Lokal IP / URL${NC}           ${CYAN}│${NC} ${BOLD}Status${NC}                   ${CYAN}│${NC}"
echo -e "${CYAN}├─────────────┼──────────────────────────┼──────────────────────────┤${NC}"
echo -e "${CYAN}│${NC} HAOS        ${CYAN}│${NC} http://${NETWORK_PREFIX}.${IP_HA}:8123   ${CYAN}│${NC} $(check_id_exists $IP_HA && echo -e "${GREEN}Installerad${NC}        " || echo -e "${YELLOW}Hoppades över${NC}      ") ${CYAN}│${NC}"
echo -e "${CYAN}│${NC} NPM Admin   ${CYAN}│${NC} http://${NETWORK_PREFIX}.${IP_NPM}:81      ${CYAN}│${NC} $(check_id_exists $IP_NPM && echo -e "${GREEN}Installerad${NC}        " || echo -e "${YELLOW}Hoppades över${NC}      ") ${CYAN}│${NC}"
echo -e "${CYAN}│${NC} Frigate     ${CYAN}│${NC} http://${NETWORK_PREFIX}.${IP_FRIGATE}:5000  ${CYAN}│${NC} $(check_id_exists $IP_FRIGATE && echo -e "${GREEN}Installerad${NC}        " || echo -e "${YELLOW}Hoppades över${NC}      ") ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────┴──────────────────────────┴──────────────────────────┘${NC}"

echo -e "\n${BOLD}Nästa steg:${NC}"
if [ -z "$CF_TUNNEL_TOKEN" ] && check_id_exists $IP_CLOUDFLARED; then
    echo -e "1. ${RED}Viktigt:${NC} Du angav ingen Cloudflare Token. Logga in på Cloudflare,"
    echo -e "   skapa en tunnel, och kör sedan detta i Proxmox-shell:"
    echo -e "   ${YELLOW}pct exec $IP_CLOUDFLARED -- cloudflared service install <DIN_TOKEN>${NC}"
fi
echo -e "2. Gå till NPM Admin (Lösenord: admin@example.com / changeme) och sätt upp dina domäner."
echo -e "3. Återställ din Home Assistant backup."
echo -e "\n${BLUE}Tack för att du använder OptiPlex Homelab Automation!${NC}"
echo -e "${YELLOW}Logg sparad i /var/log/optiplex-setup.log${NC}\n"
