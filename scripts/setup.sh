#!/usr/bin/env bash

# OptiPlex Homelab - Huvudinstallationsskript (Wizard)
# ============================================================
# Användning:
#   bash setup.sh              — Normal installation (interaktiv wizard)
#   bash setup.sh --headless   — Installera allt utan frågor ("gå iväg-knappen")
#   bash setup.sh --dry-run    — Visa vad som SKULLE hända (ingen ändring)
#
# Headless-mode:
#   Installerar ALL infrastruktur med defaults från setup.env.
#   Kräver att setup.env redan finns (kör wizarden interaktivt först).
#   Hoppar över: kameror, Cloudflare DNS, NPM-regler (kräver manuell input).
#   Kör om med 'bash setup.sh' för att konfigurera dessa efterhand.
# ============================================================

# Byt till skriptets katalog
cd "$(dirname "$0")"

# Flaggor
DRY_RUN=false
HEADLESS=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            export DRY_RUN
            ;;
        --headless)
            HEADLESS=true
            export HEADLESS
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
source lib/rollback.sh

# ==========================================
# PREFLIGHT: Verifiera att alla funktioner finns
# ==========================================
PREFLIGHT_OK=true
for fn in msg_info msg_ok msg_warn msg_err msg_skip show_progress ask_yes_no ask_string \
          load_config save_config get_state set_state \
          check_is_proxmox check_id_exists get_debian_template find_storage_pool \
          resolve_ct_id resolve_vm_id find_ct_by_hostname find_vm_by_name \
          detect_network confirm_network \
          rollback_register rollback_offer rollback_clear; do
    if ! type "$fn" &>/dev/null; then
        echo "FATAL: Funktion '$fn' saknas! Kontrollera att lib/-filerna är kompletta."
        PREFLIGHT_OK=false
    fi
done
if [ "$PREFLIGHT_OK" != "true" ]; then
    echo "Avbryter — lib-filer är korrupta eller saknas."
    exit 1
fi

# ==========================================
# TRAP: Fånga Ctrl+C och erbjud cleanup
# ==========================================
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ "$DRY_RUN" != "true" ]; then
        echo ""
        echo -e "${RED}${BOLD}  ⚠ Installationen avbröts (signal/fel)!${NC}"
        echo ""
        if [ -f "/tmp/.optiplex_rollback_stack" ] && [ -s "/tmp/.optiplex_rollback_stack" ]; then
            echo -e "  Följande resurser skapades innan avbrottet:"
            cat /tmp/.optiplex_rollback_stack | while IFS=: read -r type id name; do
                echo -e "    ${YELLOW}${type} ${id} (${name})${NC}"
            done
            echo ""
            if [ "$HEADLESS" == "true" ]; then
                # Headless: behåll resurser (säkrare än att radera)
                answer="n"
            else
                echo -ne "  ${BOLD}Vill du ta bort dem? [y/N]: ${NC}"
                tty_read -t 10 answer 2>/dev/null || answer="n"
            fi
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                while [ -s "/tmp/.optiplex_rollback_stack" ]; do
                    rollback_last
                done
            else
                echo -e "  OK. Resurserna finns kvar. Ta bort manuellt med:"
                echo -e "    ${YELLOW}pct destroy <ID> --purge${NC}  (containers)"
                echo -e "    ${YELLOW}qm destroy <ID> --purge${NC}   (VMs)"
            fi
        fi
        echo ""
        echo -e "  Logg: /var/log/optiplex-setup.log"
        echo -e "  Kör om: ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
        echo ""
    fi
    # Rensa temp-filer
    rm -f /tmp/frigate-config-generated.yml /tmp/frigate-env-generated 2>/dev/null
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

# Totalt antal steg (för progressbar)
TOTAL_STEPS=10
CURRENT_STEP=0

# ==========================================
# 1. Prereq Checks
# ==========================================
clear

if [ "$DRY_RUN" == "true" ]; then
    echo -e "${YELLOW}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║         DRY-RUN MODE — INGET ÄNDRAS                  ║"
    echo "  ║   Visar vad som SKULLE hända vid en riktig körning   ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
fi

if [ "$HEADLESS" == "true" ]; then
    echo -e "${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║     HEADLESS MODE — Installerar allt automatiskt     ║"
    echo "  ║   Inga frågor ställs — defaults från setup.env används  ║"
    echo "  ║   Kör 'bash setup.sh' igen för kameror/DNS/NPM-regler ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
    # Headless kräver att setup.env redan finns (lösenord måste vara satt)
    if [ ! -f setup.env ]; then
        msg_err "Headless-mode kräver att setup.env redan finns!"
        msg_info "Kör först: bash setup.sh (interaktivt) för att sätta lösenord och nätverk."
        msg_info "Sen kan du köra: bash setup.sh --headless"
        exit 1
    fi
    
    # Ladda config för validering
    source setup.env
    
    # ── Pre-flight checks ──────────────────────────────────────
    echo -e "  ${BOLD}Pre-flight checks:${NC}"
    HEADLESS_ABORT=false
    
    # 1. Lösenord måste finnas
    if [ -z "${SHARED_PASSWORD:-$CT_PASSWORD}" ]; then
        echo -e "    ${RED}✗${NC} SHARED_PASSWORD saknas i setup.env!"
        HEADLESS_ABORT=true
    else
        echo -e "    ${GREEN}✓${NC} Lösenord konfigurerat"
    fi
    
    # 2. Nätverk måste finnas
    if [ -z "$NETWORK_PREFIX" ] || [ -z "$GATEWAY" ]; then
        echo -e "    ${RED}✗${NC} NETWORK_PREFIX eller GATEWAY saknas i setup.env!"
        HEADLESS_ABORT=true
    else
        echo -e "    ${GREEN}✓${NC} Nätverk: ${NETWORK_PREFIX}.0/24 (GW: ${GATEWAY})"
    fi
    
    # 3. Kolla om BIOS-reboot behövs (varning, inte stopp)
    HEADLESS_NEEDS_REBOOT=false
    if [ "$(get_state needs_reboot 2>/dev/null)" == "true" ]; then
        echo -e "    ${YELLOW}⚠${NC} Reboot krävs (BIOS-ändringar väntar) — Frigate kan inte installeras utan iGPU"
        HEADLESS_NEEDS_REBOOT=true
    elif [ ! -e /dev/dri/renderD128 ] 2>/dev/null; then
        echo -e "    ${YELLOW}⚠${NC} iGPU ej tillgänglig — Frigate hoppas över (kräver reboot efter BIOS-fix)"
        HEADLESS_NEEDS_REBOOT=true
    else
        echo -e "    ${GREEN}✓${NC} iGPU tillgänglig (Frigate kan installeras)"
    fi
    
    # 4. Tunnel-token (info, inte stopp)
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        echo -e "    ${YELLOW}⚠${NC} CF_TUNNEL_TOKEN saknas — Cloudflared installeras men tunneln aktiveras inte"
    else
        echo -e "    ${GREEN}✓${NC} Cloudflare Tunnel-token finns"
    fi
    
    echo ""
    
    if [ "$HEADLESS_ABORT" == "true" ]; then
        msg_err "Pre-flight misslyckades! Fixa setup.env och försök igen."
        msg_info "Kör: bash setup.sh (interaktivt) för att konfigurera."
        exit 1
    fi
    
    msg_ok "Pre-flight OK — startar headless-installation..."
    echo ""
    sleep 2
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
# 1b. BIOS & Hårdvarustatus (visas ALLTID först)
# ==========================================
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "BIOS & Hårdvara"
msg_header "BIOS & Hårdvarustatus"

show_bios_status

# Erbjud BIOS-konfiguration direkt om problem hittades OCH host inte är konfigurerad
if [ $BIOS_ISSUES -gt 0 ] && [ "$(get_state host_configured)" != "true" ]; then
    tty_echo ""
    if ask_yes_no "Vill du konfigurera Proxmox Host nu (BIOS, repos, TRIM, udev)?" "Y"; then
        if [ "$DRY_RUN" == "true" ]; then
            msg_dry "Skulle konfigurera repos, TRIM, udev, BIOS"
        else
            bash modules/00-proxmox-host.sh
            set_state host_configured true
            
            # Om BIOS ändrades behövs reboot — erbjud det
            if [ "$(get_state needs_reboot)" == "true" ]; then
                tty_echo ""
                msg_warn "BIOS-ändringar kräver omstart för att träda i kraft."
                if [ "$HEADLESS" == "true" ]; then
                    msg_info "(headless) Reboot skjuts upp — fortsätter installationen."
                elif ask_yes_no "Vill du starta om nu? (Kör setup.sh igen efter omstart)" "Y"; then
                    msg_info "Startar om om 5 sekunder..."
                    msg_info "Efter omstart, kör: cd /opt/optiplex-homelab/scripts && bash setup.sh"
                    sleep 5
                    reboot
                fi
            fi
        fi
    fi
elif [ $BIOS_ISSUES -eq 0 ]; then
    msg_ok "Hårdvaran är redo — fortsätter med konfiguration."
fi

# ==========================================
# 2. Konfiguration Phase
# ==========================================
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Konfiguration"
msg_header "Konfiguration"

if load_config; then
    msg_ok "Hittade befintlig konfiguration (setup.env)"
    
    # ══════════════════════════════════════════════════════════
    # CHECKLISTA: Vad saknas / vad kan aktiveras?
    # ══════════════════════════════════════════════════════════
    MISSING_COUNT=0
    
    # Kolla vad som saknas
    [ -z "$CF_TUNNEL_TOKEN" ] && MISSING_COUNT=$((MISSING_COUNT + 1))
    [ "$(get_state cfdns_configured)" != "true" ] && MISSING_COUNT=$((MISSING_COUNT + 1))
    
    if [ $MISSING_COUNT -gt 0 ]; then
        tty_echo ""
        tty_echo "  ${YELLOW}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
        tty_echo "  ${YELLOW}${BOLD}║${NC} ${BOLD}Saker som fortfarande behöver konfigureras:${NC}              ${YELLOW}${BOLD}║${NC}"
        tty_echo "  ${YELLOW}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
        tty_echo ""
        
        # 1. Tunnel Token
        if [ -z "$CF_TUNNEL_TOKEN" ]; then
            tty_echo "  ${RED}✗${NC} ${BOLD}Cloudflare Tunnel Token${NC} — krävs för extern åtkomst"
            tty_echo "    ${DIM}Utan denna fungerar INTE ha.dindomän.se, frigate.dindomän.se etc.${NC}"
            tty_echo "    ${CYAN}Skapa:${NC} https://one.dash.cloudflare.com → Networks → Tunnels"
            tty_echo "    ${CYAN}Steg:${NC}  Create Tunnel → Döp den → Kopiera token (börjar med eyJh...)"
            tty_echo ""
        fi
        
        # 2. Cloudflare DNS (API token + domän + tunnel UUID)
        if [ "$(get_state cfdns_configured)" != "true" ]; then
            tty_echo "  ${RED}✗${NC} ${BOLD}Cloudflare DNS & Zero Trust${NC} — krävs för automatisk DNS-routing"
            tty_echo "    ${DIM}Skapar DNS-poster (ha.domän.se → tunnel) och Zero Trust-skydd.${NC}"
            tty_echo "    ${CYAN}Du behöver:${NC}"
            tty_echo "      1. Din domän (t.ex. dindomän.se — måste vara Active i Cloudflare)"
            tty_echo "      2. Tunnel UUID (synlig i Zero Trust → Tunnels → din tunnel)"
            tty_echo "      3. API Token med behörigheter:"
            tty_echo "         ${DIM}Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit + Account:Access:Edit${NC}"
            tty_echo "    ${CYAN}Skapa API Token:${NC} https://dash.cloudflare.com/profile/api-tokens"
            tty_echo "    ${CYAN}Fullständig guide:${NC} docs/10-cloudflare-api-setup.md"
            tty_echo ""
        fi
        
        # Google AI API Key (valfritt — för Frigate 0.18+ generativ AI)
        tty_echo "  ${CYAN}○${NC} ${BOLD}Google Gemini API Key${NC} — valfritt (generativ AI i Frigate 0.18+)"
        tty_echo "    ${DIM}Ger: AI-beskrivningar av händelser, semantic search, sammanfattningar.${NC}"
        tty_echo "    ${DIM}Frigate fungerar utan detta — du kan lägga till det när som helst.${NC}"
        tty_echo "    ${CYAN}Skapa nyckel:${NC} https://aistudio.google.com/api-keys"
        tty_echo "    ${CYAN}Steg:${NC}  Accept ToS → Get API Key → Create API key → Kopiera"
        tty_echo "    ${CYAN}Lägg till:${NC} docker-compose.yml → environment → FRIGATE_GEMINI_API_KEY=<nyckel>"
        tty_echo "    ${CYAN}config.yml:${NC}"
        tty_echo "      ${DIM}genai:${NC}"
        tty_echo "      ${DIM}  provider: gemini${NC}"
        tty_echo "      ${DIM}  api_key: \"{FRIGATE_GEMINI_API_KEY}\"${NC}"
        tty_echo "      ${DIM}  model: gemini-2.5-flash${NC}"
        tty_echo ""
        
        tty_echo "  ${DIM}────────────────────────────────────────────────────────────${NC}"
        tty_echo "  ${DIM}Tips: Du kan hoppa över allt nu och aktivera senare genom att${NC}"
        tty_echo "  ${DIM}köra wizarden igen: cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
        tty_echo ""
    fi
    
    # Erbjud att lägga till tunnel-token om den saknas
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        if ask_yes_no "Har du en Cloudflare Tunnel-token att lägga till nu?" "N"; then
            CF_TUNNEL_TOKEN=$(ask_string "Cloudflare Tunnel Token (börjar med eyJh...)" "")
            if [ -n "$CF_TUNNEL_TOKEN" ]; then
                save_config
                chmod 600 setup.env 2>/dev/null
                msg_ok "Tunnel-token sparad!"
            fi
        fi
    fi

    # Vid omkörning: erbjud att byta lösenord
    if [ -n "$SHARED_PASSWORD" ]; then
        if ! ask_yes_no "Behålla befintligt gemensamt lösenord?" "Y"; then
            SHARED_PASSWORD=$(ask_string "Nytt gemensamt lösenord" "" "true")
            while [ -z "$SHARED_PASSWORD" ]; do
                msg_warn "Lösenord kan inte vara tomt."
                SHARED_PASSWORD=$(ask_string "Nytt gemensamt lösenord" "" "true")
            done
            CT_PASSWORD="$SHARED_PASSWORD"
            save_config
            chmod 600 setup.env 2>/dev/null
            msg_ok "Lösenord uppdaterat."
        fi
    fi
    CT_PASSWORD="${SHARED_PASSWORD:-$CT_PASSWORD}"
else
    msg_info "Ingen setup.env hittades. Låt oss ställa in grunderna."
    
    # Automatisk nätverksdetektering
    tty_echo "\n  ${BOLD}Nätverksdetektering...${NC}"
    if confirm_network; then
        msg_ok "Nätverksinställningar bekräftade"
    else
        # Manuell inmatning
        NETWORK_PREFIX=$(ask_string "Nätverksprefix (t.ex. 192.168.1)" "192.168.1")
        GATEWAY=$(ask_string "Gateway IP" "${NETWORK_PREFIX}.1")
    fi
    
    NODE_HOSTNAME=$(ask_string "Namn på din server (hostname)" "homelab")
    
    # Tunnel token med tydlig varning
    tty_echo ""
    tty_echo "  ${CYAN}Cloudflare Tunnel Token ger säker extern åtkomst utan port forwarding.${NC}"
    tty_echo "  ${CYAN}Utan token fungerar INTE extern åtkomst (ha.dindomän.se etc).${NC}"
    tty_echo "  ${CYAN}Du kan lägga till den senare — se docs/04-cloudflare-tunnel.md${NC}"
    tty_echo ""
    CF_TUNNEL_TOKEN=$(ask_string "Cloudflare Tunnel Token (Enter = hoppa över)" "")
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        msg_warn "Ingen tunnel-token angiven. Extern åtkomst konfigureras senare."
        msg_info "Se: docs/04-cloudflare-tunnel.md och docs/10-cloudflare-api-setup.md"
    fi
    
    # Gemensamt lösenord — används överallt (CT root, NPM admin, MQTT, kamera RTSP)
    tty_echo ""
    tty_echo "  ${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    tty_echo "  ${CYAN}║${NC} ${BOLD}Gemensamt lösenord${NC}                                        ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC} Samma lösenord används för:                                ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}   • Alla containers (root-lösenord)                       ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}   • NPM admin-konto                                      ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}   • MQTT-användare (Frigate → HA)                          ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}   • Kamera RTSP-användare                                 ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC} ${DIM}Du kan byta individuella lösenord senare.${NC}                  ${CYAN}║${NC}"
    tty_echo "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    tty_echo ""
    SHARED_PASSWORD=$(ask_string "Välj ett gemensamt lösenord" "" "true")
    while [ -z "$SHARED_PASSWORD" ]; do
        msg_warn "Lösenord kan inte vara tomt."
        SHARED_PASSWORD=$(ask_string "Välj ett gemensamt lösenord" "" "true")
    done
    
    # Tjänsteanvändare (för RTSP + MQTT)
    tty_echo ""
    tty_echo "  ${CYAN}Tjänsteanvändare — skapas på kameror och i HA (Mosquitto).${NC}"
    tty_echo "  ${CYAN}Samma användarnamn används för RTSP och MQTT.${NC}"
    SERVICE_USER=$(ask_string "Tjänsteanvändarnamn" "frigate")
    
    # Bakkompatibilitet — CT_PASSWORD pekar på SHARED_PASSWORD
    CT_PASSWORD="$SHARED_PASSWORD"
    
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
        chmod 600 setup.env 2>/dev/null
        msg_ok "Konfiguration sparad till setup.env (skyddad: chmod 600)"
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

# Status variabler — default: installera det som saknas
DO_HOST="y"
DO_HA="y"
DO_CF="y"
DO_NPM="y"
DO_FRIGATE="y"
DO_CAMERAS="y"
DO_CF_DNS="y"
DO_NPM_CONF="y"
DO_RDP="n"

# Inventera vad som redan är klart
STATUS_HOST="saknas"
STATUS_HA="saknas"
STATUS_CF="saknas"
STATUS_NPM="saknas"
STATUS_FRIGATE="saknas"
STATUS_CAMERAS="saknas"
STATUS_CFDNS="saknas"
STATUS_NPMCONF="saknas"
STATUS_RDP="saknas"

[ "$(get_state host_configured)" == "true" ] && STATUS_HOST="klar"
[ -n "$(resolve_vm_id "ha" "$IP_HA")" ] && STATUS_HA="installerad"
[ -n "$(resolve_ct_id "cloudflared" "$IP_CLOUDFLARED")" ] && STATUS_CF="installerad"
[ -n "$(resolve_ct_id "npm" "$IP_NPM")" ] && STATUS_NPM="installerad"
[ -n "$(resolve_ct_id "frigate" "$IP_FRIGATE")" ] && STATUS_FRIGATE="installerad"
[ "$(get_state cameras_configured)" == "true" ] && STATUS_CAMERAS="klar"
[ "$(get_state cfdns_configured)" == "true" ] && STATUS_CFDNS="klar"
[ "$(get_state npm_configured)" == "true" ] && STATUS_NPMCONF="klar"
([ -n "$(resolve_ct_id "guacamole" "${IP_GUACAMOLE:-107}")" ] || [ -n "$(resolve_ct_id "desktop" "${IP_DESKTOP:-108}")" ]) && STATUS_RDP="installerad"

# Räkna hur många som är klara
DONE_COUNT=0
[ "$STATUS_HOST" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_HA" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_CF" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_NPM" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_FRIGATE" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_CAMERAS" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_CFDNS" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_NPMCONF" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))
[ "$STATUS_RDP" != "saknas" ] && DONE_COUNT=$((DONE_COUNT + 1))

# Om ALLT saknas — första körningen, kör allt utan meny
if [ "$HEADLESS" == "true" ]; then
    # Headless: kör allt som saknas, inklusive RDP, men hoppa över interaktiva moduler
    msg_info "Headless-mode: installerar all infrastruktur som saknas."
    [ "$STATUS_HOST" != "saknas" ] && DO_HOST="n"
    [ "$STATUS_HA" != "saknas" ] && DO_HA="n"
    [ "$STATUS_CF" != "saknas" ] && DO_CF="n"
    [ "$STATUS_NPM" != "saknas" ] && DO_NPM="n"
    [ "$STATUS_FRIGATE" != "saknas" ] && DO_FRIGATE="n"
    [ "$STATUS_RDP" != "saknas" ] && DO_RDP="n" || DO_RDP="y"
    DO_CAMERAS="n"
    DO_CF_DNS="n"
    DO_NPM_CONF="n"
    msg_info "Hoppar över: Kameror, Cloudflare DNS, NPM-regler (kräver manuell input)."
    msg_info "Kör 'bash setup.sh' interaktivt efterhand för att konfigurera dessa."
else
    # ===== HUVUDMENY =====
    status_icon() {
        if [ "$1" == "saknas" ]; then
            echo -e "${RED}✗${NC}"
        else
            echo -e "${GREEN}✓${NC}"
        fi
    }

    tty_echo ""
    tty_echo "  ${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    tty_echo "  ${CYAN}║${NC}  ${BOLD}OptiPlex Homelab Setup${NC}                                ${CYAN}║${NC}"
    tty_echo "  ${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    tty_echo "  ${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}  ${BOLD}Vad vill du göra?${NC}                                    ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    if [ $DONE_COUNT -eq 0 ]; then
    tty_echo "  ${CYAN}║${NC}  ${GREEN}1)${NC} Första installation (installera allt)              ${CYAN}║${NC}"
    else
    tty_echo "  ${CYAN}║${NC}  ${GREEN}1)${NC} Installera det som saknas                          ${CYAN}║${NC}"
    fi
    tty_echo "  ${CYAN}║${NC}  ${YELLOW}2)${NC} Laga / Uppgradera befintligt                       ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}  ${BLUE}3)${NC} Konfigurera (kameror, DNS, regler)                 ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}  ${MAGENTA}4)${NC} Avancerat (välj enskilda steg)                     ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}  ${RED}Q)${NC} Avsluta                                             ${CYAN}║${NC}"
    tty_echo "  ${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    tty_echo "  ${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    tty_echo ""
    tty_printf "  ${BOLD}Välj [1-4/Q] (default: 1): ${NC}"
    tty_read TOP_CHOICE

    case "${TOP_CHOICE:-1}" in
        1)
            # ===== INSTALLERA (det som saknas) =====
            if [ $DONE_COUNT -eq 0 ]; then
                msg_info "Första installationen — alla steg körs."
            else
                [ "$STATUS_HOST" != "saknas" ] && DO_HOST="n"
                [ "$STATUS_HA" != "saknas" ] && DO_HA="n"
                [ "$STATUS_CF" != "saknas" ] && DO_CF="n"
                [ "$STATUS_NPM" != "saknas" ] && DO_NPM="n"
                [ "$STATUS_FRIGATE" != "saknas" ] && DO_FRIGATE="n"
                [ "$STATUS_CAMERAS" != "saknas" ] && DO_CAMERAS="n"
                [ "$STATUS_CFDNS" != "saknas" ] && DO_CF_DNS="n"
                [ "$STATUS_NPMCONF" != "saknas" ] && DO_NPM_CONF="n"
                [ "$STATUS_RDP" != "saknas" ] && DO_RDP="n"
                msg_info "Kör bara steg som saknas."
            fi
            ;;
        2)
            # ===== LAGA / UPPGRADERA =====
            tty_echo ""
            tty_echo "  ${BOLD}Laga / Uppgradera:${NC}"
            tty_echo ""
            tty_printf "  $(status_icon $STATUS_FRIGATE) Frigate     %-16s\n" "($STATUS_FRIGATE)"
            tty_printf "  $(status_icon $STATUS_NPM) NPM         %-16s\n" "($STATUS_NPM)"
            tty_printf "  $(status_icon $STATUS_CF) Cloudflared %-16s\n" "($STATUS_CF)"
            tty_printf "  $(status_icon $STATUS_HA) Home Assist %-16s\n" "($STATUS_HA)"
            tty_printf "  $(status_icon $STATUS_RDP) Remote Desk %-16s\n" "($STATUS_RDP)"
            tty_echo ""
            msg_info "Söker efter uppgraderingar och problem..."
            tty_echo ""

            # Sätt alla till n, aktivera bara upgrade-paths
            DO_HOST="n"; DO_HA="n"; DO_CF="n"; DO_NPM="n"
            DO_CAMERAS="n"; DO_CF_DNS="n"; DO_NPM_CONF="n"; DO_RDP="n"

            # Frigate: erbjud upgrade om den finns
            if [ "$STATUS_FRIGATE" != "saknas" ]; then
                DO_FRIGATE="upgrade"
            else
                DO_FRIGATE="n"
                msg_info "Frigate är inte installerad — välj '1' för att installera."
            fi
            ;;
        3)
            # ===== KONFIGURERA =====
            tty_echo ""
            tty_echo "  ${BOLD}Konfigurera:${NC}"
            tty_echo ""
            tty_printf "  $(status_icon $STATUS_CAMERAS) Kameror & Frigate-config  %-12s\n" "($STATUS_CAMERAS)"
            tty_printf "  $(status_icon $STATUS_CFDNS) Cloudflare DNS-routing   %-12s\n" "($STATUS_CFDNS)"
            tty_printf "  $(status_icon $STATUS_NPMCONF) NPM Proxy-regler         %-12s\n" "($STATUS_NPMCONF)"
            tty_echo ""

            # Sätt alla till n, aktivera bara config-steg
            DO_HOST="n"; DO_HA="n"; DO_CF="n"; DO_NPM="n"
            DO_FRIGATE="n"; DO_RDP="n"
            DO_CAMERAS="y"; DO_CF_DNS="y"; DO_NPM_CONF="y"
            msg_info "Kör konfigurationssteg (kameror, DNS, NPM-regler)."
            ;;
        4)
            # ===== AVANCERAT (befintlig detaljerad meny) =====
            tty_echo ""
            tty_echo "  ${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
            tty_echo "  ${CYAN}║${NC} ${BOLD}Avancerat — välj enskilda steg${NC}                       ${CYAN}║${NC}"
            tty_echo "  ${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
            tty_printf "  ${CYAN}║${NC}  1. $(status_icon $STATUS_HOST) Proxmox Host         %-16s ${CYAN}║${NC}\n" "($STATUS_HOST)"
            tty_printf "  ${CYAN}║${NC}  2. $(status_icon $STATUS_HA) Home Assistant       %-16s ${CYAN}║${NC}\n" "($STATUS_HA)"
            tty_printf "  ${CYAN}║${NC}  3. $(status_icon $STATUS_CF) Cloudflared          %-16s ${CYAN}║${NC}\n" "($STATUS_CF)"
            tty_printf "  ${CYAN}║${NC}  4. $(status_icon $STATUS_NPM) NPM                  %-16s ${CYAN}║${NC}\n" "($STATUS_NPM)"
            tty_printf "  ${CYAN}║${NC}  5. $(status_icon $STATUS_FRIGATE) Frigate              %-16s ${CYAN}║${NC}\n" "($STATUS_FRIGATE)"
            tty_printf "  ${CYAN}║${NC}  6. $(status_icon $STATUS_CAMERAS) Kameror & Config     %-16s ${CYAN}║${NC}\n" "($STATUS_CAMERAS)"
            tty_printf "  ${CYAN}║${NC}  7. $(status_icon $STATUS_CFDNS) Cloudflare DNS       %-16s ${CYAN}║${NC}\n" "($STATUS_CFDNS)"
            tty_printf "  ${CYAN}║${NC}  8. $(status_icon $STATUS_NPMCONF) NPM Auto-Config      %-16s ${CYAN}║${NC}\n" "($STATUS_NPMCONF)"
            tty_printf "  ${CYAN}║${NC}  9. $(status_icon $STATUS_RDP) Remote Desktop      %-16s ${CYAN}║${NC}\n" "($STATUS_RDP)"
            tty_echo "  ${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
            tty_echo "  ${CYAN}║${NC}                                                        ${CYAN}║${NC}"
            tty_echo "  ${CYAN}║${NC}  ${BOLD}A${NC} = Kör ALLT                                         ${CYAN}║${NC}"
            tty_echo "  ${CYAN}║${NC}  ${BOLD}1-9${NC} = Välj specifika steg (t.ex. ${GREEN}6,9${NC})               ${CYAN}║${NC}"
            tty_echo "  ${CYAN}║${NC}  ${BOLD}Q${NC} = Avsluta                                            ${CYAN}║${NC}"
            tty_echo "  ${CYAN}║${NC}                                                        ${CYAN}║${NC}"
            tty_echo "  ${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
            tty_echo ""
            tty_printf "  ${BOLD}Välj [A/1-9/Q]: ${NC}"
            tty_read MENU_CHOICE

            case "${MENU_CHOICE^^}" in
                Q|q)
                    msg_info "Avslutar."
                    exit 0
                    ;;
                A|a)
                    msg_info "Kör alla steg (befintliga containers skrivs INTE över)."
                    ;;
                *)
                    # Specifika steg
                    DO_HOST="n"; DO_HA="n"; DO_CF="n"; DO_NPM="n"
                    DO_FRIGATE="n"; DO_CAMERAS="n"; DO_CF_DNS="n"; DO_NPM_CONF="n"; DO_RDP="n"
                    SELECTED=$(echo "$MENU_CHOICE" | tr ',' ' ' | tr -s ' ')
                    for sel in $SELECTED; do
                        case "$sel" in
                            1) DO_HOST="y" ;;
                            2) DO_HA="y" ;;
                            3) DO_CF="y" ;;
                            4) DO_NPM="y" ;;
                            5) DO_FRIGATE="y" ;;
                            6) DO_CAMERAS="y" ;;
                            7) DO_CF_DNS="y" ;;
                            8) DO_NPM_CONF="y" ;;
                            9) DO_RDP="y" ;;
                            *) msg_warn "Okänt val: $sel (ignoreras)" ;;
                        esac
                    done
                    msg_info "Kör valda steg: ${MENU_CHOICE}"
                    ;;
            esac
            ;;
        Q|q)
            msg_info "Avslutar."
            exit 0
            ;;
        *)
            msg_warn "Okänt val: ${TOP_CHOICE}. Avslutar."
            exit 1
            ;;
    esac
fi

# Säkerhetskontroll: Om CT/VM redan finns och DO_*=y, fråga om de vill ÅTERSKAPA
# (skyddar mot att av misstag radera en fungerande container)
HA_FOUND=$(resolve_vm_id "ha" "$IP_HA")
if [ "$DO_HA" == "y" ] && [ -n "$HA_FOUND" ]; then
    msg_warn "VM ${HA_FOUND} (Home Assistant) finns redan och körs."
    if ! ask_yes_no "Vill du RADERA och återskapa den? (ALL DATA FÖRSVINNER)" "N"; then
        DO_HA="n"
        msg_skip "Behåller befintlig HA-VM."
    fi
fi
CF_FOUND=$(resolve_ct_id "cloudflared" "$IP_CLOUDFLARED")
if [ "$DO_CF" == "y" ] && [ -n "$CF_FOUND" ]; then
    msg_warn "CT ${CF_FOUND} (Cloudflared) finns redan."
    if ! ask_yes_no "Vill du RADERA och återskapa den?" "N"; then
        DO_CF="n"
        msg_skip "Behåller befintlig Cloudflared-container."
    fi
fi
NPM_FOUND=$(resolve_ct_id "npm" "$IP_NPM")
if [ "$DO_NPM" == "y" ] && [ -n "$NPM_FOUND" ]; then
    msg_warn "CT ${NPM_FOUND} (NPM) finns redan."
    if ! ask_yes_no "Vill du RADERA och återskapa den?" "N"; then
        DO_NPM="n"
        msg_skip "Behåller befintlig NPM-container."
    fi
fi
FRIGATE_FOUND=$(resolve_ct_id "frigate" "$IP_FRIGATE")
if [ "$DO_FRIGATE" == "y" ] && [ -n "$FRIGATE_FOUND" ]; then
    msg_warn "CT ${FRIGATE_FOUND} (Frigate) finns redan."
    if [ "$HEADLESS" == "true" ]; then
        # Headless: uppgradera/fixa automatiskt, radera aldrig
        DO_FRIGATE="upgrade"
        msg_info "(headless) Uppgraderar/fixar befintlig Frigate..."
    else
        tty_echo ""
        tty_echo "  ${BOLD}Vad vill du göra?${NC}"
        tty_echo "  1) Uppgradera/fixa (uppdatera image, behåll config & inspelningar)"
        tty_echo "  2) Radera och återskapa från scratch"
        tty_echo "  3) Hoppa över (behåll som det är)"
        tty_echo ""
        tty_printf "  ${BOLD}Välj [1/2/3] (default: 1): ${NC}"
        tty_read FRIGATE_CHOICE
        case "${FRIGATE_CHOICE:-1}" in
            1) DO_FRIGATE="upgrade" ;;
            2) DO_FRIGATE="y" ;;
            *) DO_FRIGATE="n"; msg_skip "Behåller befintlig Frigate-container." ;;
        esac
    fi
fi

# Aktivera tunnel på befintlig Cloudflared-container om token nu finns men tunnel inte är aktiv
CF_CT=$(resolve_ct_id "cloudflared" "$IP_CLOUDFLARED")
if [ "$DO_CF" == "n" ] && [ -n "$CF_TUNNEL_TOKEN" ] && [ -n "$CF_CT" ]; then
    # Kolla om cloudflared service redan kör
    CF_RUNNING=$(pct exec $CF_CT -- systemctl is-active cloudflared 2>/dev/null || echo "inactive")
    if [ "$CF_RUNNING" != "active" ]; then
        tty_echo ""
        msg_info "Cloudflared-containern (CT ${CF_CT}) finns men tunneln är inte aktiv."
        if ask_yes_no "Vill du aktivera Cloudflare Tunnel med din token nu?" "Y"; then
            msg_info "Installerar tunnel-token i CT ${CF_CT}..."
            pct exec ${CF_CT} -- bash -c "cloudflared service install ${CF_TUNNEL_TOKEN}" > /dev/null 2>&1
            if pct exec ${CF_CT} -- systemctl is-active cloudflared &>/dev/null; then
                msg_ok "Cloudflare Tunnel aktiverad och kör!"
            else
                msg_warn "Tunnel-tjänsten startade inte. Kontrollera token och kör:"
                tty_echo "  ${YELLOW}pct exec ${CF_CT} -- cloudflared service install <TOKEN>${NC}"
            fi
        fi
    fi
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
if [ "$DO_HOST" == "y" ] && [ "$(get_state host_configured)" != "true" ]; then
    print_banner "Proxmox Host Konfiguration" "Verifierar BIOS, fixar repos, aktiverar TRIM, sätter udev-regler för iGPU."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle konfigurera repos, TRIM, udev, BIOS"
    else
        bash modules/00-proxmox-host.sh
        set_state host_configured true
        
        # Erbjud Proxmox-uppdatering
        tty_echo ""
        if ask_yes_no "Vill du kolla efter Proxmox-uppdateringar?" "N"; then
            bash tools/upgrade-proxmox.sh
        fi
    fi
elif [ "$(get_state host_configured)" == "true" ]; then
    msg_ok "Proxmox Host redan konfigurerad (BIOS, repos, TRIM, udev) — hoppar över"
fi

# Hämta template om vi behöver LXC
if [ "$DO_CF" == "y" ] || [ "$DO_NPM" == "y" ] || [ "$DO_FRIGATE" == "y" ] || [ "$DO_RDP" == "y" ]; then
    if [ "$DRY_RUN" != "true" ]; then
        TEMPLATE_PATH=$(get_debian_template)
        if [ -z "$TEMPLATE_PATH" ]; then
            msg_err "Kunde inte hämta Debian LXC-template. Kontrollera internet och repos."
            msg_info "Försök manuellt: pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst"
            if ! ask_yes_no "Vill du fortsätta ändå (hoppar över container-skapning)?" "N"; then
                exit 1
            fi
            DO_CF="n"; DO_NPM="n"; DO_FRIGATE="n"; DO_RDP="n"
        fi
    else
        msg_dry "Skulle ladda ner Debian LXC-template"
        TEMPLATE_PATH="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
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
        rollback_register "vm" "$IP_HA" "Home Assistant"
        if ! bash modules/02-ha-vm.sh; then
            msg_err "Ett fel uppstod under installationen av Home Assistant."
            rollback_offer "$IP_HA" "Home Assistant"
            if [ "$HEADLESS" == "true" ]; then
                msg_warn "(headless) Felet loggas, fortsätter med nästa steg..."
            elif ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then
                exit 1
            fi
        else
            rollback_clear  # Lyckades — inget att ångra
            wait_for_service "${NETWORK_PREFIX}.${IP_HA}" 8123 "Home Assistant" 180
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
        rollback_register "ct" "$IP_CLOUDFLARED" "Cloudflared"
        if ! bash modules/03-cloudflared.sh "$TEMPLATE_PATH"; then
            msg_err "Ett fel uppstod under installationen av Cloudflared."
            rollback_offer "$IP_CLOUDFLARED" "Cloudflared"
            if [ "$HEADLESS" == "true" ]; then
                msg_warn "(headless) Felet loggas, fortsätter med nästa steg..."
            elif ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then
                exit 1
            fi
        else
            rollback_clear
        fi
    fi
fi

# 4.5 NPM
if [ "$DO_NPM" == "y" ]; then
    print_banner "Nginx Proxy Manager (CT $IP_NPM)" \
"Reverse proxy som dirigerar trafik internt (HTTP).
Cloudflare Tunnel hanterar all extern TLS/HTTPS — NPM behöver INTE SSL-certifikat.
Ingen 'Force SSL' ska aktiveras i NPM (orsakar redirect-loop)."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa CT $IP_NPM med NPM + Docker"
    else
        rollback_register "ct" "$IP_NPM" "NPM"
        if ! bash modules/04-npm.sh "$TEMPLATE_PATH"; then
            msg_err "Ett fel uppstod under installationen av NPM."
            rollback_offer "$IP_NPM" "NPM"
            if [ "$HEADLESS" == "true" ]; then
                msg_warn "(headless) Felet loggas, fortsätter med nästa steg..."
            elif ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then
                exit 1
            fi
        else
            rollback_clear
            wait_for_service "${NETWORK_PREFIX}.${IP_NPM}" 81 "NPM" 60
            
            # Auto-byt NPM admin-lösenord från default till SHARED_PASSWORD
            if [ -n "$SHARED_PASSWORD" ]; then
                msg_info "Byter NPM admin-lösenord från default..."
                sleep 3  # Ge NPM tid att vara helt redo
                NPM_IP="${NETWORK_PREFIX}.${IP_NPM}"
                # Logga in med default-credentials
                TOKEN_RES=$(curl -s --max-time 10 -X POST "http://${NPM_IP}:81/api/tokens" \
                    -H "Content-Type: application/json" \
                    -d '{"identity": "admin@example.com", "secret": "changeme"}' 2>/dev/null)
                NPM_TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
                
                if [ -n "$NPM_TOKEN" ]; then
                    # Byt lösenord
                    CHANGE_RES=$(curl -s --max-time 10 -X PUT "http://${NPM_IP}:81/api/users/1" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: Bearer $NPM_TOKEN" \
                        -d "{\"name\": \"Administrator\", \"nickname\": \"Admin\", \"email\": \"${NPM_ADMIN_EMAIL:-admin@example.com}\"}" 2>/dev/null)
                    
                    # Byt lösenord separat
                    curl -s --max-time 10 -X PUT "http://${NPM_IP}:81/api/users/1/auth" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: Bearer $NPM_TOKEN" \
                        -d "{\"type\": \"password\", \"current\": \"changeme\", \"secret\": \"${SHARED_PASSWORD}\"}" > /dev/null 2>&1
                    
                    if [ $? -eq 0 ]; then
                        msg_ok "NPM admin-lösenord bytt! Login: ${NPM_ADMIN_EMAIL:-admin@example.com} / (ditt gemensamma lösenord)"
                    else
                        msg_warn "Kunde inte byta NPM-lösenord automatiskt. Byt manuellt i UI:t."
                    fi
                else
                    msg_warn "Kunde inte logga in i NPM (kanske redan bytt). Kontrollera manuellt."
                fi
            fi
        fi
    fi
fi

# 4.6 Frigate
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Frigate NVR"
if [ "$DO_FRIGATE" == "y" ]; then
    print_banner "Frigate NVR (CT $IP_FRIGATE)" "AI-videoövervakning med hårdvaruacceleration (iGPU passthrough) och Docker."
    
    # Kolla iGPU — varna om den saknas (reboot behövs)
    if [ ! -e /dev/dri/renderD128 ]; then
        msg_warn "iGPU (/dev/dri/renderD128) hittades INTE på hosten!"
        msg_info "Frigate behöver iGPU för AI-detektering och VAAPI."
        if [ "$(get_state needs_reboot)" == "true" ]; then
            msg_info "Du konfigurerade BIOS tidigare men har inte startat om ännu."
            msg_info "Starta om först, kör sedan setup.sh igen."
        else
            msg_info "Om du just konfigurerade BIOS krävs en omstart först."
        fi
        if ! ask_yes_no "Vill du installera Frigate ändå (utan iGPU)?" "N"; then
            msg_skip "Hoppar över Frigate. Starta om och kör wizarden igen."
            DO_FRIGATE="n"
        fi
    fi
    
    if [ "$DO_FRIGATE" == "y" ]; then
        if [ "$DRY_RUN" == "true" ]; then
            msg_dry "Skulle skapa CT $IP_FRIGATE med Frigate 0.18 + Docker + iGPU"
        else
            rollback_register "ct" "$IP_FRIGATE" "Frigate"
            if ! bash modules/05-frigate.sh "$TEMPLATE_PATH"; then
                msg_err "Ett fel uppstod under installationen av Frigate."
                rollback_offer "$IP_FRIGATE" "Frigate"
                if [ "$HEADLESS" == "true" ]; then
                    msg_warn "(headless) Felet loggas, fortsätter med nästa steg..."
                elif ! ask_yes_no "Vill du fortsätta med nästa steg ändå?" "N"; then
                    exit 1
                fi
            else
                rollback_clear
                wait_for_service "${NETWORK_PREFIX}.${IP_FRIGATE}" 5000 "Frigate" 90
            fi
        fi
    fi
fi

# ── Frigate Upgrade/Fix (om CT redan finns) ──────────────────
if [ "$DO_FRIGATE" == "upgrade" ]; then
    print_banner "Frigate Uppgradering" "Uppdaterar Frigate-image till senaste 0.18.x — behåller config och inspelningar."
    
    # Hitta Frigate CT via hostname (robust — fungerar även om ID ändrats)
    FRIGATE_CT=$(resolve_ct_id "frigate" "$IP_FRIGATE")
    if [ -z "$FRIGATE_CT" ]; then
        msg_err "Kunde inte hitta Frigate-container (varken via hostname 'frigate' eller ID ${IP_FRIGATE})!"
        msg_info "Kontrollera: pct list"
    else
    [ "$FRIGATE_CT" != "$IP_FRIGATE" ] && msg_info "Frigate hittad via hostname på CT ${FRIGATE_CT} (config säger ${IP_FRIGATE})"
    CT_IP=$(pct exec "${FRIGATE_CT}" -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$CT_IP" ] && CT_IP="${NETWORK_PREFIX}.${IP_FRIGATE}"
    
    # Hitta senaste version (samma logik som i module 05)
    msg_info "Söker senaste Frigate 0.18-version..."
    NEW_TAG=$(pct exec "${FRIGATE_CT}" -- bash -c '
        curl -fsSL "https://api.github.com/repos/blakeblackshear/frigate/releases?per_page=20" 2>/dev/null | \
        python3 -c "
import json,sys
releases = json.load(sys.stdin)
for r in releases:
    tag = r.get(\"tag_name\",\"\").lstrip(\"v\")
    if tag.startswith(\"0.18.\"):
        print(tag)
        break
" 2>/dev/null
    ' 2>/dev/null)
    
    [ -z "$NEW_TAG" ] && NEW_TAG="0.18.0-beta1"
    
    # Kolla nuvarande version
    CURRENT_TAG=$(pct exec "${FRIGATE_CT}" -- bash -c \
        "grep -oP 'image:.*frigate:\K[^\"]+' /opt/frigate/docker-compose.yml 2>/dev/null || echo 'okänd'" 2>/dev/null)
    
    msg_info "Nuvarande: ${CURRENT_TAG:-okänd}"
    msg_info "Senaste:   ${NEW_TAG}"
    
    if [ "$CURRENT_TAG" == "$NEW_TAG" ]; then
        msg_ok "Frigate kör redan senaste versionen (${NEW_TAG})!"
        # Kolla ändå om den är igång
        if ! pct exec "${FRIGATE_CT}" -- bash -c "docker ps --filter name=frigate --format '{{.Status}}'" 2>/dev/null | grep -qi "up"; then
            msg_warn "Frigate-containern kör inte! Startar..."
            pct exec "${FRIGATE_CT}" -- bash -c "cd /opt/frigate && docker compose up -d" 2>&1 | tail -3
        fi
    else
        msg_info "Uppdaterar docker-compose.yml till ${NEW_TAG}..."
        pct exec "${FRIGATE_CT}" -- bash -c "
            cd /opt/frigate
            # Byt image-tag i docker-compose.yml
            sed -i \"s|image: ghcr.io/blakeblackshear/frigate:.*|image: ghcr.io/blakeblackshear/frigate:${NEW_TAG}|\" docker-compose.yml
            # Pull + restart
            echo '  Laddar ner ny image...'
            docker compose pull 2>&1 | tail -3
            echo '  Startar om Frigate...'
            docker compose up -d 2>&1 | tail -3
        "
    fi
    
    # Verifiering: vänta på att Frigate svarar
    msg_info "Väntar på att Frigate startar..."
    FRIGATE_UP=false
    for i in $(seq 1 20); do
        if pct exec "${FRIGATE_CT}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/" 2>/dev/null | grep -q "200\|301\|302"; then
            FRIGATE_UP=true
            break
        fi
        sleep 3
    done
    
    if [ "$FRIGATE_UP" == "true" ]; then
        msg_ok "Frigate ${NEW_TAG} kör och svarar på http://${CT_IP}:5000"
    else
        msg_warn "Frigate svarar inte ännu. Felsök:"
        msg_info "  pct exec ${FRIGATE_CT} -- docker logs frigate --tail 30"
        pct exec "${FRIGATE_CT}" -- bash -c "docker logs frigate --tail 5" 2>&1 | head -5
    fi
    fi  # end: else (CT found)
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
    print_banner "NPM Auto-Config" \
"Sätter upp proxy-regler i NPM automatiskt.
OBS: Alla proxy hosts använder HTTP internt (scheme: http).
Cloudflare Tunnel hanterar TLS externt — NPM ska INTE ha Force SSL."
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

# 4.10 Remote Desktop (Guacamole + Desktop)
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Remote Desktop"
if [ "$DO_RDP" == "y" ]; then
    print_banner "Remote Desktop" "Guacamole (webb-RDP proxy) och/eller Linux Desktop med xrdp."
    if [ "$DRY_RUN" == "true" ]; then
        msg_dry "Skulle skapa Guacamole CT och/eller Desktop CT med xrdp"
    else
        if ! bash modules/09-remote-desktop.sh "$TEMPLATE_PATH"; then
            msg_err "Remote Desktop-installationen avslutades med fel."
        else
            set_state rdp_configured true
        fi
    fi
fi

# ==========================================
# 5. Brandväggsverifiering
# ==========================================
if [ "$DRY_RUN" != "true" ]; then
    msg_header "Brandväggsverifiering"
    
    # Kolla att Proxmox-brandväggen inte blockerar intern trafik
    PVE_FW_ENABLED=$(cat /etc/pve/firewall/cluster.fw 2>/dev/null | grep -i "enable:" | awk '{print $2}')
    if [ "$PVE_FW_ENABLED" == "1" ]; then
        msg_warn "Proxmox-brandväggen är AKTIVERAD på klusternivå."
        msg_info "Se till att följande portar är tillåtna mellan containers:"
        msg_info "  • 8123 (HA), 5000/8554/8555 (Frigate), 80/81/443 (NPM)"
        msg_info "  • 1883 (MQTT), 8971 (Frigate auth)"
        msg_info "Alternativt: Inaktivera Proxmox-brandväggen (Unifi hanterar nätverkssäkerhet)."
    else
        msg_ok "Proxmox-brandvägg: Inaktiverad (bra — Unifi/router hanterar säkerhet)"
    fi
    
    # Kolla iptables/nftables i hosten
    if nft list ruleset 2>/dev/null | grep -q "drop\|reject" && ! nft list ruleset 2>/dev/null | grep -q "pve-fw"; then
        msg_warn "nftables-regler hittades som kan blockera trafik. Kontrollera med: nft list ruleset"
    fi
    
    # Kolla att containers inte har brandvägg aktiverad per-CT
    for ct_id in $IP_CLOUDFLARED $IP_NPM $IP_FRIGATE; do
        if [ -f "/etc/pve/firewall/${ct_id}.fw" ]; then
            CT_FW=$(grep -i "enable:" "/etc/pve/firewall/${ct_id}.fw" 2>/dev/null | awk '{print $2}')
            if [ "$CT_FW" == "1" ]; then
                msg_warn "CT ${ct_id} har egen brandvägg aktiverad. Detta kan blockera trafik."
                msg_info "  Inaktivera: Datacenter → CT ${ct_id} → Firewall → Options → Enable: No"
            fi
        fi
    done
fi

# ==========================================
# 6. Summary
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
printf "${CYAN}│${NC} %-11s ${CYAN}│${NC} %-32s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "Guacamole" "http://${NETWORK_PREFIX}.${IP_GUACAMOLE:-107}:8080" "$(check_id_exists ${IP_GUACAMOLE:-107} 2>/dev/null && echo 'Installerad' || echo 'Hoppades över')"
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
echo -e "${BOLD}Nästa steg (VIKTIGT):${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

STEP=1

# MQTT-varning — alltid relevant om Frigate är installerat
if check_id_exists $IP_FRIGATE 2>/dev/null; then
    echo -e "  ${STEP}. ${YELLOW}${BOLD}MQTT (Frigate → Home Assistant):${NC}"
    echo -e "     Frigate använder MQTT för att skicka händelser till HA."
    echo -e "     MQTT-brokern (Mosquitto) körs som add-on i Home Assistant."
    echo -e ""
    echo -e "     ${BOLD}Gör detta i HA:${NC}"
    echo -e "       a) Inställningar → Add-ons → Sök 'Mosquitto broker' → Installera"
    echo -e "       b) Inställningar → Personer → Användare → Lägg till:"
    echo -e "          Användarnamn: ${GREEN}${SERVICE_USER:-frigate}${NC}"
    echo -e "          Lösenord: ${GREEN}(ditt gemensamma lösenord)${NC}"
    echo -e "       c) Starta Mosquitto add-on"
    echo -e ""
    echo -e "     ${DIM}Om MQTT inte konfigureras: Frigate fungerar lokalt men HA${NC}"
    echo -e "     ${DIM}får inga notiser/händelser. Konfigurera när HA är klar.${NC}"
    echo ""
    STEP=$((STEP + 1))
fi

if [ -z "$CF_TUNNEL_TOKEN" ] && check_id_exists $IP_CLOUDFLARED 2>/dev/null; then
    echo -e "  ${STEP}. ${RED}${BOLD}Cloudflare Tunnel Token saknas!${NC}"
    echo -e "     Utan token fungerar INTE extern åtkomst (ha.dindomän.se)."
    echo -e ""
    echo -e "     ${BOLD}Så här fixar du det:${NC}"
    echo -e "     a) Skapa tunnel: https://one.dash.cloudflare.com → Networks → Tunnels"
    echo -e "     b) Kopiera token-strängen"
    echo -e "     c) Kör wizarden igen: ${GREEN}cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
    echo -e "        (Du får frågan om token direkt vid start)"
    echo -e ""
    echo -e "     ${DIM}Eller manuellt: pct exec $IP_CLOUDFLARED -- cloudflared service install <TOKEN>${NC}"
    echo -e "     ${DIM}Mer info: docs/10-cloudflare-api-setup.md${NC}"
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_NPM 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}NPM Admin:${NC} Logga in på http://${NETWORK_PREFIX}.${IP_NPM}:81"
    if [ -n "$SHARED_PASSWORD" ]; then
        echo -e "     Login: ${GREEN}${NPM_ADMIN_EMAIL:-admin@example.com}${NC} / (ditt gemensamma lösenord)"
    else
        echo -e "     Standardinloggning: admin@example.com / changeme"
        echo -e "     Byt lösenord direkt!"
    fi
    echo -e "     ${YELLOW}OBS: Aktivera INTE 'Force SSL' — Cloudflare hanterar HTTPS externt.${NC}"
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_HA 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}Home Assistant:${NC} Gå till http://${NETWORK_PREFIX}.${IP_HA}:8123"
    echo -e "     Återställ din backup eller skapa nytt konto."
    echo -e "     Installera Mosquitto add-on (se steg 1 ovan)."
    STEP=$((STEP + 1))
fi

if check_id_exists $IP_FRIGATE 2>/dev/null; then
    echo -e "  ${STEP}. ${BOLD}Frigate:${NC} Gå till http://${NETWORK_PREFIX}.${IP_FRIGATE}:5000"
    echo -e "     Rita zoner och masker i UI:t för varje kamera."
    echo -e "     Verifiera att alla kameror syns och att AI-detektering fungerar."
    STEP=$((STEP + 1))
fi

echo ""
echo -e "  ${BOLD}Användbara kommandon:${NC}"
echo -e "    Hälsokontroll: ${YELLOW}cd /opt/optiplex-homelab/scripts && sudo bash tools/doctor.sh${NC}"
echo -e "    Systemstatus:  ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/status.sh${NC}"
echo -e "    Uppdatera:     ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/update.sh${NC}"
echo -e "    USB-backup:    ${YELLOW}cd /opt/optiplex-homelab/scripts && bash tools/usb-backup.sh${NC}"
echo -e "    Kör om wizard:  ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
echo -e "    Headless:      ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh --headless${NC}"
echo -e "    Dry-run:       ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh --dry-run${NC}"

# ==========================================
# Generera TODO.md (manuella steg som kvarstår)
# ==========================================
if [ "$DRY_RUN" != "true" ]; then
    TODO_FILE="/opt/optiplex-homelab/TODO.md"
    cat > "$TODO_FILE" << 'TODOEOF'
# Manuella steg efter installation

Dessa steg kunde inte automatiseras och måste göras manuellt.
Bocka av med [x] när du är klar.

---

TODOEOF

    TODO_STEP=1

    # HA DHCP
    if check_id_exists $IP_HA 2>/dev/null; then
        cat >> "$TODO_FILE" << EOF
## ${TODO_STEP}. Home Assistant — Reservera IP i router

- [ ] Gå till din Unifi-router (eller annan DHCP-server)
- [ ] Reservera IP **${NETWORK_PREFIX}.${IP_HA}** för HA-VM:ens MAC-adress
- [ ] Alternativt: Konfigurera statisk IP i HA: Settings → System → Network

> HAOS använder DHCP som default. Utan reservation kan IP:n ändras vid omstart.

---

EOF
        TODO_STEP=$((TODO_STEP + 1))
    fi

    # Mosquitto
    if check_id_exists $IP_FRIGATE 2>/dev/null; then
        cat >> "$TODO_FILE" << EOF
## ${TODO_STEP}. MQTT (Mosquitto) i Home Assistant

- [ ] Öppna HA: http://${NETWORK_PREFIX}.${IP_HA}:8123
- [ ] Gå till: Inställningar → Add-ons → Sök "Mosquitto broker" → Installera
- [ ] Skapa MQTT-användare: Inställningar → Personer → Användare → Lägg till:
  - Användarnamn: **${SERVICE_USER:-frigate}**
  - Lösenord: **(ditt gemensamma lösenord)**
- [ ] Starta Mosquitto add-on
- [ ] Verifiera: Frigate-loggen ska visa "MQTT connected"

> Utan MQTT: Frigate fungerar lokalt men HA får inga notiser/händelser.

---

EOF
        TODO_STEP=$((TODO_STEP + 1))
    fi

    # Kameror
    if [ "$(get_state cameras_configured)" == "true" ]; then
        cat >> "$TODO_FILE" << EOF
## ${TODO_STEP}. Kameror — Skapa användare

Logga in på varje kameras webbgränssnitt:

- [ ] Skapa användare på alla kameror:
  - Användarnamn: **${SERVICE_USER:-frigate}**
  - Lösenord: **(ditt gemensamma lösenord)**
  - Roll: **Viewer** eller **Operator** (ej Admin)
- [ ] Skapa stream-profiler (Axis-kameror):
  - Profil **main**: Codec H.265, Max upplösning (2592×1944), 15 fps, Compression 30
  - Profil **detect**: Codec H.265, 1280×960 (4:3), 5 fps, Compression 30

> Utan detta kan Frigate inte ansluta till kamerorna.

---

EOF
        TODO_STEP=$((TODO_STEP + 1))
    fi

    # Cloudflare Tunnel
    if [ -z "$CF_TUNNEL_TOKEN" ] && check_id_exists $IP_CLOUDFLARED 2>/dev/null; then
        cat >> "$TODO_FILE" << EOF
## ${TODO_STEP}. Cloudflare Tunnel Token

- [ ] Skapa tunnel: Cloudflare Dashboard → Zero Trust → Networks → Tunnels
- [ ] Kopiera token
- [ ] Installera: \`pct exec ${IP_CLOUDFLARED} -- cloudflared service install <DIN_TOKEN>\`
- [ ] Verifiera: \`pct exec ${IP_CLOUDFLARED} -- systemctl status cloudflared\`

> Utan token fungerar INTE extern åtkomst (ha.dindomän.se etc).

---

EOF
        TODO_STEP=$((TODO_STEP + 1))
    fi

    # Frigate zoner
    if check_id_exists $IP_FRIGATE 2>/dev/null; then
        cat >> "$TODO_FILE" << EOF
## ${TODO_STEP}. Frigate — Zoner och masker

- [ ] Öppna Frigate: http://${NETWORK_PREFIX}.${IP_FRIGATE}:5000
- [ ] Verifiera att alla kameror syns och AI-detektering fungerar
- [ ] Rita zoner (områden där detektering ska ske) för varje kamera
- [ ] Rita masker (områden att ignorera, t.ex. träd, vägar)

---

EOF
        TODO_STEP=$((TODO_STEP + 1))
    fi

    # Avslutning
    cat >> "$TODO_FILE" << 'EOF'
## Tips

- Kör `sudo bash tools/doctor.sh` för att kontrollera systemets hälsa
- Kör `bash setup.sh` igen för att lägga till/ändra tjänster
- Alla credentials använder samma gemensamma lösenord (byt individuellt vid behov)
EOF

    msg_ok "TODO-lista sparad: ${TODO_FILE}"
    msg_info "  Öppna med: cat ${TODO_FILE}"
fi

# ==========================================
# Headless post-run sammanfattning
# ==========================================
if [ "$HEADLESS" == "true" ] && [ "$DRY_RUN" != "true" ]; then
    echo ""
    echo -e "${YELLOW}${BOLD}"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  DU MÅSTE GÖRA FÖLJANDE MANUELLT:                        │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    
    HSTEP=1
    
    # Reboot behövs?
    if [ "$(get_state needs_reboot)" == "true" ]; then
        echo -e "  ${RED}${BOLD}${HSTEP}. STARTA OM SERVERN${NC}"
        echo -e "     BIOS-ändringar kräver omstart för att träda i kraft."
        echo -e "     Utan omstart: iGPU saknas → Frigate kan inte använda AI-detektering."
        echo -e "     ${YELLOW}Kör: reboot${NC}"
        echo -e "     ${DIM}Efter omstart, kör: bash setup.sh --headless (för att installera Frigate)${NC}"
        echo ""
        HSTEP=$((HSTEP + 1))
    fi
    
    # Frigate hoppades över?
    if ! check_id_exists ${IP_FRIGATE} 2>/dev/null; then
        echo -e "  ${YELLOW}${BOLD}${HSTEP}. FRIGATE HOPPADES ÖVER${NC}"
        echo -e "     Trolig orsak: iGPU ej tillgänglig (reboot behövs först)."
        echo -e "     ${YELLOW}Kör efter reboot: bash setup.sh --headless${NC}"
        echo ""
        HSTEP=$((HSTEP + 1))
    fi
    
    # Kameror, DNS, NPM-regler
    echo -e "  ${BOLD}${HSTEP}. KONFIGURERA KAMEROR, DNS & NPM-REGLER${NC}"
    echo -e "     Dessa hoppades över i headless-mode (kräver manuell input)."
    echo -e "     ${YELLOW}Kör: bash setup.sh${NC}  (interaktivt, välj steg 6-8)"
    echo ""
    HSTEP=$((HSTEP + 1))
    
    # Tunnel-token
    if [ -z "$CF_TUNNEL_TOKEN" ] && check_id_exists $IP_CLOUDFLARED 2>/dev/null; then
        echo -e "  ${BOLD}${HSTEP}. LÄGG TILL CLOUDFLARE TUNNEL-TOKEN${NC}"
        echo -e "     Utan token fungerar INTE extern åtkomst."
        echo -e "     ${YELLOW}Kör: bash setup.sh${NC}  (du får frågan vid start)"
        echo ""
        HSTEP=$((HSTEP + 1))
    fi
    
    echo -e "  ${DIM}Allt ovan är också sparat i: /opt/optiplex-homelab/TODO.md${NC}"
    echo ""
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Tack för att du använder OptiPlex Homelab Automation!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Logg sparad i: /var/log/optiplex-setup.log"
echo ""
