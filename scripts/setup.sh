#!/usr/bin/env bash

# OptiPlex Homelab - Huvudinstallationsskript (Wizard)
# ============================================================
# Användning:
#   bash setup.sh              — Normal installation
#   bash setup.sh --dry-run    — Visa vad som SKULLE hända (ingen ändring)
# ============================================================

# Byt till skriptets katalog
cd "$(dirname "$0")"

# Flaggor
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            export DRY_RUN
            ;;
    esac
done

# Starta loggning (inte i dry-run)
if [ "$DRY_RUN" != "true" ]; then
    exec > >(tee -a /var/log/optiplex-setup.log) 2>&1
fi

# Ladda bibliotek
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh
source lib/network.sh

# Totalt antal steg (för progressbar)
TOTAL_STEPS=9
CURRENT_STEP=0

# ==========================================
# 1. Prereq Checks
# ==========================================
clear

if [ "$DRY_RUN" == "true" ]; then
    echo -e "${YELLOW}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║         🏜️  DRY-RUN MODE — INGET ÄNDRAS              ║"
    echo "  ║   Visar vad som SKULLE hända vid en riktig körning   ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
fi

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
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Konfiguration"
msg_header "Konfiguration"

if load_config; then
    msg_ok "Hittade befintlig konfiguration (setup.env)"
else
    msg_info "Ingen setup.env hittades. Låt oss ställa in grunderna."
    
    # Automatisk nätverksdetektering
    echo -e "\n  ${BOLD}Nätverksdetektering...${NC}" > /dev/tty
    if confirm_network; then
        msg_ok "Nätverksinställningar bekräftade"
    else
        # Manuell inmatning
        NETWORK_PREFIX=$(ask_string "Nätverksprefix (t.ex. 192.168.1)" "192.168.1")
        GATEWAY=$(ask_string "Gateway IP" "${NETWORK_PREFIX}.1")
    fi
    
    NODE_HOSTNAME=$(ask_string "Namn på din server (hostname)" "homelab")
    CF_TUNNEL_TOKEN=$(ask_string "Cloudflare Tunnel Token (tryck Enter för att hoppa över)" "")
    CT_PASSWORD=$(ask_string "Standardlösenord för nya containers" "MySecurePassword123!" "true")
    
    STORAGE_POOL=$(find_storage_pool)
    if [ -z "$STORAGE_POOL" ]; then
        STORAGE_POOL="local-lvm"
    fi
    msg_info "Vald lagringspool för OS: $STORAGE_POOL"
    
    IP_HA=$(ask_string "VM ID för Home Assistant (även sista delen av IP)" "100")
    IP_CLOUDFLARED=$(ask_string "CT ID för Cloudflared" "101")
    IP_NPM=$(ask_string "CT ID för NPM" "102")
    IP_FRIGATE=$(ask_string "CT ID för Frigate" "103")
    
    if [ "$DRY_RUN" != "true" ]; then
        save_config
        msg_ok "Konfiguration sparad till setup.env"
    else
        msg_dry "Skulle spara konfiguration till setup.env"
    fi
fi

# ==========================================
# 3. Inventering och Planering (Resume-stöd)
# ==========================================
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Inventering"
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

# Variabler för moduler som inte har egna IDs
DO_CAMERAS="y"
DO_CF_DNS="y"
DO_NPM_CONF="y"

if [ "$(get_state cameras_configured)" == "true" ]; then
    if ask_yes_no "Axis Kameror är redan konfigurerade. Vill du köra kamera-skriptet igen?" "N"; then
        DO_CAMERAS="y"
    else
        DO_CAMERAS="n"
    fi
fi

if [ "$(get_state cfdns_configured)" == "true" ]; then
    if ask_yes_no "Cloudflare DNS är redan konfigurerat. Vill du köra DNS-skriptet igen?" "N"; then
        DO_CF_DNS="y"
    else
        DO_CF_DNS="n"
    fi
fi

if [ "$(get_state npm_configured)" == "true" ]; then
    if ask_yes_no "NPM Auto-Config är redan körd. Vill du köra den igen?" "N"; then
        DO_NPM_CONF="y"
    else
        DO_NPM_CONF="n"
    fi
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
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Lagring"
if [ "$DO_FRIGATE" == "y" ]; then
    print_banner "Lagring" "Letar efter en dedikerad SSD för Frigate-inspelningar för att spara på OS-disken."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle söka efter extra diskar och formatera för Frigate"
    else
        bash modules/01-storage.sh
        source setup.env # Ladda om utifall STORAGE_POOL ändrades
    fi
fi

# 4.2 Proxmox Host
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Proxmox Host"
if [ "$DO_HOST" == "y" ]; then
    print_banner "Proxmox Host Konfiguration" "Fixar enterprise-repos, aktiverar TRIM, sätter udev-regler för iGPU och kollar BIOS-inställningar."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle konfigurera repos, TRIM, udev, BIOS"
    else
        bash modules/00-proxmox-host.sh
        set_state host_configured true
    fi
fi

# Hämta template om vi behöver LXC
if [ "$DO_CF" == "y" ] || [ "$DO_NPM" == "y" ] || [ "$DO_FRIGATE" == "y" ]; then
    if [ "$DRY_RUN" != "true" ]; then
        TEMPLATE_PATH=$(get_debian_template)
    else
        msg_dry "Skulle ladda ner Debian LXC-template"
        TEMPLATE_PATH="/var/lib/vz/template/cache/debian-12-standard_12.x_amd64.tar.zst"
    fi
fi

# 4.3 Home Assistant
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Home Assistant"
if [ "$DO_HA" == "y" ]; then
    print_banner "Home Assistant (VM $IP_HA)" "Laddar ner HAOS och skapar en UEFI-baserad virtuell maskin för smarta hem-styrning."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa VM $IP_HA med HAOS"
    else
        if ! bash modules/02-ha-vm.sh; then
            msg_err "Ett fel uppstod under installationen av Home Assistant."
            if ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then exit 1; fi
        else
            msg_info "Väntar på att HA ska starta (tar en stund)..."
            msg_info "Observera: HAOS använder DHCP by default. Om din router inte ger den IP .${IP_HA}"
            msg_info "så kommer detta test att misslyckas, men HA fungerar ändå på den IP den fick."
            for i in {1..15}; do
                if nc -z -w 2 "${NETWORK_PREFIX}.${IP_HA}" 8123 2>/dev/null; then
                    msg_ok "HA är uppe och svarar på ${NETWORK_PREFIX}.${IP_HA}:8123!"
                    break
                fi
                sleep 5
            done
        fi
    fi
fi

# 4.4 Cloudflared
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Cloudflare Tunnel"
if [ "$DO_CF" == "y" ]; then
    print_banner "Cloudflared (CT $IP_CLOUDFLARED)" "Skapar en krypterad tunnel till Cloudflare. Inga portar behöver öppnas i din router."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa CT $IP_CLOUDFLARED med cloudflared"
    else
        if ! bash modules/03-cloudflared.sh "$TEMPLATE_PATH"; then
            msg_err "Ett fel uppstod under installationen av Cloudflared."
            if ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then exit 1; fi
        fi
    fi
fi

# 4.5 NPM
if [ "$DO_NPM" == "y" ]; then
    print_banner "Nginx Proxy Manager (CT $IP_NPM)" "Reverse proxy med snyggt GUI för att dirigera trafik till HA och Frigate internt."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa CT $IP_NPM med NPM + Docker"
    else
        if ! bash modules/04-npm.sh "$TEMPLATE_PATH"; then
            msg_err "Ett fel uppstod under installationen av NPM."
            if ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then exit 1; fi
        else
            msg_info "Väntar på att NPM ska svara på port 81..."
            for i in {1..10}; do
                if nc -z -w 2 "${NETWORK_PREFIX}.${IP_NPM}" 81 2>/dev/null; then
                    msg_ok "NPM är uppe och svarar!"
                    break
                fi
                sleep 3
            done
        fi
    fi
fi

# 4.6 Frigate
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Frigate NVR"
if [ "$DO_FRIGATE" == "y" ]; then
    print_banner "Frigate NVR (CT $IP_FRIGATE)" "AI-videoövervakning med hårdvaruacceleration (iGPU passthrough) och Docker."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa CT $IP_FRIGATE med Frigate 0.18 + Docker + iGPU"
    else
        if ! bash modules/05-frigate.sh "$TEMPLATE_PATH"; then
            msg_err "Ett fel uppstod under installationen av Frigate."
            if ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then exit 1; fi
        else
            msg_info "Väntar på att Frigate ska svara på port 5000..."
            for i in {1..10}; do
                if nc -z -w 2 "${NETWORK_PREFIX}.${IP_FRIGATE}" 5000 2>/dev/null; then
                    msg_ok "Frigate är uppe och svarar!"
                    break
                fi
                sleep 3
            done
        fi
    fi
fi

# 4.7 Axis Kameror & Frigate Config
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Kameror & Config"
if [ "$DO_CAMERAS" == "y" ]; then
    print_banner "Axis Kameror & Frigate Config" "Skannar nätverket efter kameror och genererar en komplett Frigate-konfiguration."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skanna nätverk, fråga kameranamn, generera config.yml"
    else
        if ! bash modules/06-axis-cameras.sh; then
            msg_err "Kamerakonfigurationen avslutades med fel."
        else
            set_state cameras_configured true
        fi
    fi
fi

# 4.8 Cloudflare DNS & Routing
if [ "$DO_CF_DNS" == "y" ]; then
    print_banner "Cloudflare DNS & Routing" "Sätter automatiskt upp domäner och tunnel-routing via Cloudflare API."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa CNAME-records och tunnel-routes i Cloudflare"
    else
        if ! bash modules/07-cloudflare-dns.sh; then
            msg_err "Cloudflare DNS/Routing avslutades med fel."
        else
            set_state cfdns_configured true
        fi
    fi
fi

# 4.9 NPM Auto-Config
if [ "$DO_NPM_CONF" == "y" ]; then
    print_banner "NPM Auto-Config" "Sätter upp proxy-regler i NPM automatiskt."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa proxy hosts i NPM via API"
    else
        if ! bash modules/08-npm-config.sh; then
            msg_err "NPM Auto-Config avslutades med fel."
        else
            set_state npm_configured true
        fi
    fi
fi

# ==========================================
# 5. Summary
# ==========================================
CURRENT_STEP=$TOTAL_STEPS
show_progress $CURRENT_STEP $TOTAL_STEPS "Klart!"

clear
echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║           ✓ Installation Slutförd!                        ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$DRY_RUN" == "true" ]; then
    echo -e "  ${YELLOW}${BOLD}(DRY-RUN — inget ändrades)${NC}\n"
fi

echo -e "${BOLD}Server:${NC} ${NODE_HOSTNAME:-$(hostname)} ($(hostname -I | awk '{print $1}'))"
echo ""

echo -e "${CYAN}┌─────────────┬──────────────────────────────────┬──────────────────┐${NC}"
echo -e "${CYAN}│${NC} ${BOLD}Tjänst${NC}      ${CYAN}│${NC} ${BOLD}Lokal URL${NC}                         ${CYAN}│${NC} ${BOLD}Status${NC}           ${CYAN}│${NC}"
echo -e "${CYAN}├─────────────┼──────────────────────────────────┼──────────────────┤${NC}"
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "Proxmox" "https://$(hostname -I | awk '{print $1}'):8006" "Denna maskin"
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "HAOS" "http://${NETWORK_PREFIX}.${IP_HA}:8123" "$(check_id_exists $IP_HA 2>/dev/null && echo 'Installerad' || echo 'Hoppades över')"
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "NPM Admin" "http://${NETWORK_PREFIX}.${IP_NPM}:81" "$(check_id_exists $IP_NPM 2>/dev/null && echo 'Installerad' || echo 'Hoppades över')"
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "Frigate" "http://${NETWORK_PREFIX}.${IP_FRIGATE}:5000" "$(check_id_exists $IP_FRIGATE 2>/dev/null && echo 'Installerad' || echo 'Hoppades över')"
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "Cloudflared" "(ingen UI — tunnel)" "$(check_id_exists $IP_CLOUDFLARED 2>/dev/null && echo 'Installerad' || echo 'Hoppades över')"
echo -e "${CYAN}└─────────────┴──────────────────────────────────┴──────────────────┘${NC}"

# Wake-on-LAN info
MAC_ADDRESS=$(get_state mac_address)
PRIMARY_NIC=$(get_state primary_nic)
if [ -n "$MAC_ADDRESS" ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Fjärrstart (Wake-on-LAN)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Din servers MAC-adress: ${GREEN}${MAC_ADDRESS}${NC}"
    echo -e "  Nätverkskort: ${PRIMARY_NIC}"
    echo ""
    echo -e "  ${BOLD}Starta servern från en annan dator i samma nätverk:${NC}"
    echo ""
    echo -e "    Linux/Mac:  ${YELLOW}wakeonlan ${MAC_ADDRESS}${NC}"
    echo -e "    Windows:    ${YELLOW}wolcmd ${MAC_ADDRESS//:/} $(hostname -I | awk '{print $1}') 255.255.255.0${NC}"
    echo -e "    Telefon:    Sök efter 'Wake on LAN' i App Store/Play Store"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Nästa steg:${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

STEP=1
if [ -z "$CF_TUNNEL_TOKEN" ] && check_id_exists $IP_CLOUDFLARED 2>/dev/null; then
    echo -e "  ${STEP}. ${RED}Cloudflare Token saknas.${NC} Följ docs/10-cloudflare-api-setup.md"
    echo -e "     och kör sedan:"
    echo -e "     ${YELLOW}pct exec $IP_CLOUDFLARED -- cloudflared service install <DIN_TOKEN>${NC}"
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_NPM 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}NPM Admin:${NC} Logga in på http://${NETWORK_PREFIX}.${IP_NPM}:81"
    echo -e "     Standardinloggning: admin@example.com / changeme"
    echo -e "     Byt lösenord direkt!"
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_HA 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}Home Assistant:${NC} Gå till http://${NETWORK_PREFIX}.${IP_HA}:8123"
    echo -e "     Återställ din backup eller skapa nytt konto."
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_FRIGATE 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}Frigate:${NC} Gå till http://${NETWORK_PREFIX}.${IP_FRIGATE}:5000"
    echo -e "     Rita zoner och masker i UI:t för varje kamera."
    STEP=$((STEP + 1))
fi

echo ""
echo -e "  ${BOLD}Användbara kommandon:${NC}"
echo -e "    Hälsokontroll: ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/doctor.sh${NC}"
echo -e "    Systemstatus:  ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/status.sh${NC}"
echo -e "    Uppdatera:     ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/update.sh${NC}"
echo -e "    USB-backup:    ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/usb-backup.sh${NC}"
echo -e "    Kör om wizard:  ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
echo -e "    Dry-run:       ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh --dry-run${NC}"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Tack för att du använder OptiPlex Homelab Automation!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Logg sparad i: /var/log/optiplex-setup.log"
echo ""
