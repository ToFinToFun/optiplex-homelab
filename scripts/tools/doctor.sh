#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Doctor (Diagnostikverktyg)
# ============================================================
# Kör detta för att kontrollera att allt fungerar korrekt.
# Användning: bash tools/doctor.sh
# ============================================================

cd "$(dirname "$0")/.."
source lib/ui.sh

# Ladda config om den finns
if [ -f setup.env ]; then
    source setup.env
fi

# ============================================================
# ROOT-CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}${BOLD}  Doctor måste köras som root (behöver access till pct/qm/docker).${NC}"
    echo -e "  Kör: ${YELLOW}sudo bash tools/doctor.sh${NC}"
    echo ""
    echo -e "  Alternativt (begränsad info utan root):"
    echo -e "  Fortsätter med begränsad diagnostik...\n"
    NO_ROOT=true
else
    NO_ROOT=false
fi

clear
echo -e "${BOLD}${BLUE}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║     OptiPlex Homelab — Doctor                 ║"
echo "  ╠═══════════════════════════════════════════════╣"
echo "  ║  Kontrollerar systemets hälsa...              ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

ISSUES=0
WARNINGS=0

# ============================================================
# 1. SYSTEM
# ============================================================
msg_header "System"

# Proxmox version
if command -v pveversion &>/dev/null; then
    PVE_VER=$(pveversion --verbose 2>/dev/null | head -1)
    msg_ok "Proxmox: $PVE_VER"
else
    msg_err "Proxmox VE hittades inte!"
    ISSUES=$((ISSUES + 1))
fi

# Kernel
KERNEL=$(uname -r)
msg_ok "Kernel: $KERNEL"

# Uptime
UPTIME=$(uptime -p)
msg_ok "Uptime: $UPTIME"

# CPU
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "?")
msg_ok "CPU-användning: ${CPU_USAGE}%"

# RAM
RAM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
RAM_USED=$(free -h | awk '/^Mem:/{print $3}')
RAM_PCT=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
if [ "$RAM_PCT" -gt 90 ]; then
    msg_warn "RAM: ${RAM_USED}/${RAM_TOTAL} (${RAM_PCT}%) — HÖG ANVÄNDNING!"
    WARNINGS=$((WARNINGS + 1))
else
    msg_ok "RAM: ${RAM_USED}/${RAM_TOTAL} (${RAM_PCT}%)"
fi

# Disk
DISK_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
DISK_USED=$(df -h / | awk 'NR==2{print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
if [ "$DISK_PCT" -gt 85 ]; then
    msg_warn "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%) — NÄSTAN FULL!"
    WARNINGS=$((WARNINGS + 1))
elif [ "$DISK_PCT" -gt 70 ]; then
    msg_info "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)"
else
    msg_ok "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)"
fi

# Frigate-storage disk (om den finns)
if mountpoint -q /media/frigate 2>/dev/null || pvesm status 2>/dev/null | grep -q "frigate-storage"; then
    if mountpoint -q /media/frigate 2>/dev/null; then
        FRIG_PCT=$(df /media/frigate | awk 'NR==2{print $5}' | tr -d '%')
        FRIG_USED=$(df -h /media/frigate | awk 'NR==2{print $3}')
        FRIG_TOTAL=$(df -h /media/frigate | awk 'NR==2{print $2}')
        if [ "$FRIG_PCT" -gt 85 ]; then
            msg_warn "Disk (Frigate): ${FRIG_USED}/${FRIG_TOTAL} (${FRIG_PCT}%) — NÄSTAN FULL!"
            WARNINGS=$((WARNINGS + 1))
        else
            msg_ok "Disk (Frigate): ${FRIG_USED}/${FRIG_TOTAL} (${FRIG_PCT}%)"
        fi
    fi
fi

# Temperatur
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    if (( $(echo "$TEMP > 80" | bc -l 2>/dev/null || echo 0) )); then
        msg_warn "CPU-temperatur: ${TEMP}°C — HÖG!"
        WARNINGS=$((WARNINGS + 1))
    else
        msg_ok "CPU-temperatur: ${TEMP}°C"
    fi
fi

# ============================================================
# 2. iGPU
# ============================================================
msg_header "Intel iGPU"

if [ -e /dev/dri/renderD128 ]; then
    msg_ok "/dev/dri/renderD128 finns"
else
    msg_err "/dev/dri/renderD128 saknas — iGPU passthrough fungerar inte!"
    msg_info "  Kör: bash setup.sh (BIOS-steget) och starta om"
    ISSUES=$((ISSUES + 1))
fi

if command -v vainfo &>/dev/null; then
    if vainfo 2>&1 | grep -q "Intel iHD driver"; then
        VAAPI_PROFILES=$(vainfo 2>&1 | grep -c "VAProfile" || echo "0")
        msg_ok "VAAPI fungerar (Intel iHD, ${VAAPI_PROFILES} profiler)"
    else
        msg_warn "vainfo körs men Intel iHD-drivrutin hittades inte"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    msg_info "vainfo inte installerat (installeras i Frigate-containern)"
fi

# VT-x / VT-d
if grep -c -E '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1; then
    msg_ok "VT-x (virtualisering) aktiverat"
else
    msg_err "VT-x INTE aktiverat — VMs fungerar inte!"
    ISSUES=$((ISSUES + 1))
fi

if dmesg 2>/dev/null | grep -i -q -e "DMAR" -e "IOMMU"; then
    msg_ok "VT-d / IOMMU aktiverat"
else
    msg_warn "VT-d / IOMMU verkar inte aktivt (behövs för PCI passthrough)"
    WARNINGS=$((WARNINGS + 1))
fi

# ============================================================
# 3. CONTAINERS & VMs
# ============================================================
msg_header "Containers & VMs"

if [ "$NO_ROOT" == "true" ]; then
    msg_info "Hoppar över (kräver root)"
else
    # Funktion för att kolla status
    check_ct_vm() {
        local id="$1"
        local name="$2"
        local type="$3"  # "ct" eller "vm"
        
        if [ "$type" == "vm" ]; then
            if qm status $id 2>/dev/null | grep -q "running"; then
                msg_ok "VM $id ($name): Körs"
                return 0
            elif qm status $id 2>/dev/null | grep -q "stopped"; then
                msg_warn "VM $id ($name): Stoppad"
                WARNINGS=$((WARNINGS + 1))
                return 1
            else
                msg_info "VM $id ($name): Finns inte"
                return 2
            fi
        else
            if pct status $id 2>/dev/null | grep -q "running"; then
                msg_ok "CT $id ($name): Körs"
                return 0
            elif pct status $id 2>/dev/null | grep -q "stopped"; then
                msg_warn "CT $id ($name): Stoppad"
                WARNINGS=$((WARNINGS + 1))
                return 1
            else
                msg_info "CT $id ($name): Finns inte"
                return 2
            fi
        fi
    }

    # Kolla alla tjänster
    HA_ID="${IP_HA:-100}"
    CF_ID="${IP_CLOUDFLARED:-101}"
    NPM_ID="${IP_NPM:-102}"
    FRIG_ID="${IP_FRIGATE:-103}"

    check_ct_vm "$HA_ID" "Home Assistant" "vm"
    check_ct_vm "$CF_ID" "Cloudflared" "ct"
    check_ct_vm "$NPM_ID" "NPM" "ct"
    check_ct_vm "$FRIG_ID" "Frigate" "ct"
    [ -n "${IP_ADGUARD:-}" ] && check_ct_vm "${IP_ADGUARD}" "AdGuard Home" "ct"
    [ -n "${IP_GUACAMOLE:-}" ] && check_ct_vm "${IP_GUACAMOLE}" "Guacamole" "ct"
    [ -n "${IP_DESKTOP:-}" ] && check_ct_vm "${IP_DESKTOP}" "Desktop" "ct"
    [ -n "${IP_SAMBA:-}" ] && check_ct_vm "${IP_SAMBA}" "Samba" "ct"
    [ -n "${IP_IMMICH:-}" ] && check_ct_vm "${IP_IMMICH}" "Immich" "ct"
    [ -n "${IP_NUT:-}" ] && check_ct_vm "${IP_NUT}" "NUT" "ct"
fi

# ============================================================
# 4. DOCKER (i Frigate-container)
# ============================================================
msg_header "Docker-tjänster"

if [ "$NO_ROOT" != "true" ]; then
    FRIG_ID="${IP_FRIGATE:-103}"
    NPM_ID="${IP_NPM:-102}"
    
    if pct status $FRIG_ID 2>/dev/null | grep -q "running"; then
        DOCKER_STATUS=$(pct exec $FRIG_ID -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "")
        if [ -n "$DOCKER_STATUS" ]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q "Up"; then
                    msg_ok "Docker (Frigate): $line"
                else
                    msg_warn "Docker (Frigate): $line"
                    WARNINGS=$((WARNINGS + 1))
                fi
            done <<< "$DOCKER_STATUS"
        else
            msg_warn "Kunde inte kontakta Docker i Frigate-containern"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    if pct status $NPM_ID 2>/dev/null | grep -q "running"; then
        DOCKER_STATUS=$(pct exec $NPM_ID -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "")
        if [ -n "$DOCKER_STATUS" ]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q "Up"; then
                    msg_ok "Docker (NPM): $line"
                else
                    msg_warn "Docker (NPM): $line"
                    WARNINGS=$((WARNINGS + 1))
                fi
            done <<< "$DOCKER_STATUS"
        fi
    fi

    # Immich Docker (om installerad)
    IMMICH_ID="${IP_IMMICH:-111}"
    if [ -n "${IP_IMMICH:-}" ] && pct status $IMMICH_ID 2>/dev/null | grep -q "running"; then
        DOCKER_STATUS=$(pct exec $IMMICH_ID -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "")
        if [ -n "$DOCKER_STATUS" ]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q "Up"; then
                    msg_ok "Docker (Immich): $line"
                else
                    msg_warn "Docker (Immich): $line"
                    WARNINGS=$((WARNINGS + 1))
                fi
            done <<< "$DOCKER_STATUS"
        fi
    fi
else
    msg_info "Hoppar över (kräver root)"
fi

# ============================================================
# 5. NÄTVERK & TUNNEL
# ============================================================
msg_header "Nätverk & Tunnel"

# Internet
if ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
    msg_ok "Internet: Ansluten"
else
    msg_err "Internet: INGEN ANSLUTNING!"
    ISSUES=$((ISSUES + 1))
fi

# DNS
if host google.com > /dev/null 2>&1; then
    msg_ok "DNS: Fungerar"
else
    msg_warn "DNS: Problem med namnupplösning"
    WARNINGS=$((WARNINGS + 1))
fi

# Cloudflare Tunnel
if [ "$NO_ROOT" != "true" ]; then
    CF_ID="${IP_CLOUDFLARED:-101}"
    if pct status $CF_ID 2>/dev/null | grep -q "running"; then
        if pct exec $CF_ID -- pgrep -f cloudflared > /dev/null 2>&1; then
            msg_ok "Cloudflare Tunnel: Processen körs"
        else
            msg_warn "Cloudflare Tunnel: Processen körs INTE"
            msg_info "  Kontrollera: pct exec $CF_ID -- systemctl status cloudflared"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
fi

# Tjänst-portar
check_port() {
    local host="$1"
    local port="$2"
    local name="$3"
    if nc -z -w 2 "$host" "$port" 2>/dev/null; then
        msg_ok "$name: Svarar på ${host}:${port}"
    else
        msg_warn "$name: Svarar INTE på ${host}:${port}"
        WARNINGS=$((WARNINGS + 1))
    fi
}

NW="${NETWORK_PREFIX:-192.168.1}"
HA_ID="${IP_HA:-100}"
FRIG_ID="${IP_FRIGATE:-103}"
NPM_ID="${IP_NPM:-102}"

# Upptäck faktiska IP:er (hanterar DHCP/manuellt bytt IP)
if [ "$NO_ROOT" != "true" ]; then
    HA_IP=$(qm agent $HA_ID network-get-interfaces 2>/dev/null | grep -oP '"ip-address"\s*:\s*"\K192[^"]+' | head -1)
    [ -z "$HA_IP" ] && HA_IP="${NW}.${HA_ID}"
    FRIG_IP=$(pct exec $FRIG_ID -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$FRIG_IP" ] && FRIG_IP="${NW}.${FRIG_ID}"
    NPM_IP_CHECK=$(pct exec $NPM_ID -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$NPM_IP_CHECK" ] && NPM_IP_CHECK="${NW}.${NPM_ID}"
else
    HA_IP="${NW}.${HA_ID}"
    FRIG_IP="${NW}.${FRIG_ID}"
    NPM_IP_CHECK="${NW}.${NPM_ID}"
fi

check_port "$HA_IP" 8123 "Home Assistant"
check_port "$FRIG_IP" 5000 "Frigate"
check_port "$NPM_IP_CHECK" 81 "NPM Admin"

# Tilläggstjänster (om installerade)
if [ -n "${IP_ADGUARD:-}" ]; then
    AGH_CHK_IP="${NW}.${IP_ADGUARD}"
    [ "$NO_ROOT" != "true" ] && pct status $IP_ADGUARD 2>/dev/null | grep -q running && \
        AGH_CHK_IP=$(pct exec $IP_ADGUARD -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$AGH_CHK_IP" ] && check_port "$AGH_CHK_IP" 53 "AdGuard DNS"
fi
if [ -n "${IP_SAMBA:-}" ]; then
    SMB_CHK_IP="${NW}.${IP_SAMBA}"
    [ "$NO_ROOT" != "true" ] && pct status $IP_SAMBA 2>/dev/null | grep -q running && \
        SMB_CHK_IP=$(pct exec $IP_SAMBA -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$SMB_CHK_IP" ] && check_port "$SMB_CHK_IP" 445 "Samba (SMB)"
fi
if [ -n "${IP_IMMICH:-}" ]; then
    IMM_CHK_IP="${NW}.${IP_IMMICH}"
    [ "$NO_ROOT" != "true" ] && pct status $IP_IMMICH 2>/dev/null | grep -q running && \
        IMM_CHK_IP=$(pct exec $IP_IMMICH -- hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$IMM_CHK_IP" ] && check_port "$IMM_CHK_IP" 2283 "Immich"
fi

# ============================================================
# 6. MQTT
# ============================================================
msg_header "MQTT (Frigate → Home Assistant)"

MQTT_HOST="$HA_IP"
if nc -z -w 2 "$MQTT_HOST" 1883 2>/dev/null; then
    msg_ok "MQTT-broker: Svarar på ${MQTT_HOST}:1883"
else
    msg_warn "MQTT-broker: Svarar INTE på ${MQTT_HOST}:1883"
    msg_info "  Frigate kan inte skicka händelser till Home Assistant."
    msg_info "  Åtgärd: Installera Mosquitto add-on i HA:"
    msg_info "    HA → Inställningar → Add-ons → Mosquitto broker → Installera"
    msg_info "    Skapa användare 'mqtt-user' i HA → Inställningar → Personer → Användare"
    WARNINGS=$((WARNINGS + 1))
fi

# ============================================================
# 7. BRANDVÄGG
# ============================================================
msg_header "Brandvägg"

# Proxmox-brandvägg
PVE_FW_ENABLED=$(cat /etc/pve/firewall/cluster.fw 2>/dev/null | grep -i "^enable:" | awk '{print $2}')
if [ "$PVE_FW_ENABLED" == "1" ]; then
    msg_warn "Proxmox-brandvägg: AKTIVERAD på klusternivå"
    msg_info "  Se till att intern trafik (8123, 5000, 80, 81, 443, 1883) är tillåten."
    msg_info "  Alternativt: Inaktivera (Datacenter → Firewall → Options → Enable: No)"
    WARNINGS=$((WARNINGS + 1))
else
    msg_ok "Proxmox-brandvägg: Inaktiverad (Unifi/router hanterar säkerhet)"
fi

# Per-container brandvägg
if [ "$NO_ROOT" != "true" ]; then
    for ct_id in ${IP_CLOUDFLARED:-101} ${IP_NPM:-102} ${IP_FRIGATE:-103}; do
        if [ -f "/etc/pve/firewall/${ct_id}.fw" ]; then
            CT_FW=$(grep -i "^enable:" "/etc/pve/firewall/${ct_id}.fw" 2>/dev/null | awk '{print $2}')
            if [ "$CT_FW" == "1" ]; then
                msg_warn "CT ${ct_id}: Egen brandvägg aktiverad (kan blockera trafik)"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    done
fi

# nftables-regler
if command -v nft &>/dev/null; then
    DROP_RULES=$(nft list ruleset 2>/dev/null | grep -c -E "drop|reject" || echo "0")
    if [ "$DROP_RULES" -gt 0 ]; then
        # Kolla om det är Proxmox-egna regler (pve-fw)
        if nft list ruleset 2>/dev/null | grep -q "pve-fw"; then
            msg_ok "nftables: Proxmox-hanterade regler (normalt)"
        else
            msg_warn "nftables: ${DROP_RULES} drop/reject-regler hittades"
            msg_info "  Kontrollera: nft list ruleset | grep -E 'drop|reject'"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        msg_ok "nftables: Inga blockerande regler"
    fi
fi

# ============================================================
# 8. ADGUARD HOME
# ============================================================
msg_header "AdGuard Home (DNS)"

if [ "$NO_ROOT" != "true" ]; then
    AGH_ID="${IP_ADGUARD:-104}"
    if pct status $AGH_ID 2>/dev/null | grep -q "running"; then
        AGH_IP=$(pct exec $AGH_ID -- hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$AGH_IP" ] && AGH_IP="${NETWORK_PREFIX:-192.168.1}.${AGH_ID}"
        msg_ok "AdGuard Home CT $AGH_ID kör (IP: $AGH_IP)"
        
        # Kontrollera att DNS svarar
        if pct exec $AGH_ID -- bash -c "nslookup cloudflare.com 127.0.0.1 2>/dev/null" | grep -q "Address"; then
            msg_ok "DNS-upplösning fungerar"
        else
            msg_err "DNS svarar INTE på port 53!"
            echo -e "    ${DIM}Kontrollera: pct exec $AGH_ID -- systemctl status AdGuardHome${NC}"
            ISSUES=$((ISSUES + 1))
        fi
        
        # Kontrollera att web-UI svarar
        AGH_HTTP=$(pct exec $AGH_ID -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)
        if [ "$AGH_HTTP" == "200" ] || [ "$AGH_HTTP" == "302" ]; then
            msg_ok "Web-UI svarar (HTTP $AGH_HTTP)"
        else
            msg_warn "Web-UI svarar inte (HTTP $AGH_HTTP)"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        # Kontrollera split-DNS rewrites
        if [ -n "${CF_DOMAIN}" ] && [ -n "${SHARED_PASSWORD}" ]; then
            REWRITE_COUNT=$(pct exec $AGH_ID -- curl -s -u "admin:${SHARED_PASSWORD}" \
                'http://127.0.0.1/control/rewrite/list' 2>/dev/null | grep -c '"domain"' || echo "0")
            if [ "${REWRITE_COUNT:-0}" -gt 0 ]; then
                msg_ok "Split-DNS: ${REWRITE_COUNT} rewrites konfigurerade för *.${CF_DOMAIN}"
            else
                msg_warn "Inga split-DNS rewrites hittades för ${CF_DOMAIN}"
                echo -e "    ${DIM}Kör modulen igen (steg 4) eller lägg till manuellt i AdGuard UI.${NC}"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    elif pct status $AGH_ID 2>/dev/null | grep -q "stopped"; then
        msg_warn "AdGuard Home CT $AGH_ID är stoppad"
        echo -e "    ${DIM}Starta: pct start $AGH_ID${NC}"
        WARNINGS=$((WARNINGS + 1))
    else
        msg_info "AdGuard Home är inte installerad (CT $AGH_ID finns inte)"
    fi
else
    msg_info "(kräver root för AdGuard-kontroll)"
fi

# ============================================================
# 9. NPM KONFIGURATION (SSL, WebSockets, IP-mismatch)
# ============================================================
msg_header "NPM Proxy-konfiguration"

if [ "$NO_ROOT" != "true" ]; then
    NPM_ID="${IP_NPM:-102}"
    if pct status $NPM_ID 2>/dev/null | grep -q "running"; then
        # Upptäck NPM:s faktiska IP
        NPM_IP=$(pct exec $NPM_ID -- hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$NPM_IP" ] && NPM_IP="${NW}.${NPM_ID}"
        
        # Försök logga in (gemensamt lösenord först, sedan default)
        NPM_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
        NPM_PASS="${SHARED_PASSWORD:-changeme}"
        TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
            -H "Content-Type: application/json" \
            -d "{\"identity\": \"${NPM_EMAIL}\", \"secret\": \"${NPM_PASS}\"}" 2>/dev/null)
        TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' 2>/dev/null | cut -d'"' -f4)
        
        if [ -z "$TOKEN" ] && [ "$NPM_PASS" != "changeme" ]; then
            TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
                -H "Content-Type: application/json" \
                -d '{"identity": "admin@example.com", "secret": "changeme"}' 2>/dev/null)
            TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' 2>/dev/null | cut -d'"' -f4)
        fi
        
        if [ -n "$TOKEN" ]; then
            HOSTS=$(curl -s --max-time 5 "http://${NPM_IP}:81/api/nginx/proxy-hosts" \
                -H "Authorization: Bearer $TOKEN" 2>/dev/null)
            
            # Force SSL-check
            FORCE_SSL_COUNT=$(echo "$HOSTS" | grep -o '"ssl_forced":1' | wc -l 2>/dev/null || echo "0")
            if [ "$FORCE_SSL_COUNT" -gt 0 ]; then
                msg_warn "NPM: ${FORCE_SSL_COUNT} proxy host(s) har 'Force SSL' aktiverat!"
                msg_info "  Detta orsakar redirect-loop med Cloudflare Tunnel."
                msg_info "  Åtgärd: NPM Admin → Proxy Hosts → Edit → SSL → Avmarkera 'Force SSL'"
                msg_info "  Eller kör: ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
                WARNINGS=$((WARNINGS + 1))
            else
                msg_ok "NPM: Ingen 'Force SSL' aktiv (korrekt med Cloudflare Tunnel)"
            fi
            
            # WebSocket-check för Frigate
            FRIGATE_NO_WS=$(echo "$HOSTS" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        domains = ','.join(h.get('domain_names', []))
        port = h.get('forward_port', 0)
        ws = h.get('allow_websocket_upgrade', 0)
        if port == 5000 or 'frigate' in domains.lower() or 'nvr' in domains.lower():
            if not ws:
                print(f'{domains}')
except: pass
" 2>/dev/null)
            
            if [ -n "$FRIGATE_NO_WS" ]; then
                msg_warn "NPM: Frigate-proxy (${FRIGATE_NO_WS}) saknar WebSockets!"
                msg_info "  Frigate kräver WebSockets för live-video. UI:t snurrar utan det."
                msg_info "  Åtgärd: NPM Admin → Proxy Hosts → Edit → Websockets Support: ON"
                msg_info "  Eller kör: ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
                WARNINGS=$((WARNINGS + 1))
            else
                msg_ok "NPM: WebSockets aktiverat för Frigate (krävs för live-video)"
            fi
            
            # IP-mismatch-check (snabb)
            FRIG_ID="${IP_FRIGATE:-103}"
            if pct status $FRIG_ID 2>/dev/null | grep -q "running"; then
                FRIG_ACTUAL=$(pct exec $FRIG_ID -- hostname -I 2>/dev/null | awk '{print $1}')
                if [ -n "$FRIG_ACTUAL" ]; then
                    NPM_FRIG_FWD=$(echo "$HOSTS" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        domains = ','.join(h.get('domain_names', []))
        port = h.get('forward_port', 0)
        if port == 5000 or 'frigate' in domains.lower():
            print(h.get('forward_host', ''))
            break
except: pass
" 2>/dev/null)
                    if [ -n "$NPM_FRIG_FWD" ] && [ "$NPM_FRIG_FWD" != "$FRIG_ACTUAL" ]; then
                        msg_warn "NPM pekar Frigate till ${NPM_FRIG_FWD} men Frigate har IP ${FRIG_ACTUAL}!"
                        msg_info "  Kör: ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
                        WARNINGS=$((WARNINGS + 1))
                    elif [ -n "$NPM_FRIG_FWD" ]; then
                        msg_ok "NPM → Frigate: IP matchar (${FRIG_ACTUAL})"
                    fi
                fi
            fi
        else
            msg_info "NPM: Kunde inte logga in (lösenord bytt manuellt)"
            msg_info "  Kontrollera manuellt: http://${NPM_IP}:81"
            msg_info "  Eller kör: ${YELLOW}sudo bash tools/ip-check.sh${NC}"
        fi
    fi
else
    msg_info "Hoppar över (kräver root)"
fi

# ============================================================
# 10. VERSIONSCHECK (GitHub API)
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}10. Tillgängliga uppdateringar${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Funktion: Hämta senaste version från GitHub
get_latest_version() {
    local repo="$1"
    local latest
    latest=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | sed 's/^v//')
    echo "$latest"
}

# Funktion: Hämta installerad version
get_installed_version() {
    local service="$1"
    local ctid="$2"
    case "$service" in
        frigate)
            if [ -n "$ctid" ] && pct status "$ctid" 2>/dev/null | grep -q running; then
                pct exec "$ctid" -- docker inspect frigate 2>/dev/null | grep -oP '"FRIGATE_VERSION=\K[^"]+' | head -1
            fi
            ;;
        immich)
            if [ -n "$ctid" ] && pct status "$ctid" 2>/dev/null | grep -q running; then
                # Hämta version från .env (IMMICH_VERSION=v1.x.x)
                pct exec "$ctid" -- grep 'IMMICH_VERSION' /opt/immich/.env 2>/dev/null | cut -d= -f2 | sed 's/^v//'
            fi
            ;;
        adguard)
            if [ -n "$ctid" ] && pct status "$ctid" 2>/dev/null | grep -q running; then
                pct exec "$ctid" -- /opt/AdGuardHome/AdGuardHome --version 2>/dev/null | grep -oP 'v\K[0-9.]+'
            fi
            ;;
        npm)
            if [ -n "$ctid" ] && pct status "$ctid" 2>/dev/null | grep -q running; then
                pct exec "$ctid" -- docker inspect nginx-proxy-manager 2>/dev/null | grep -oP '"com.github.jc21.version":\s*"\K[^"]+' | head -1
            fi
            ;;
    esac
}

UPDATES_AVAILABLE=0

# Frigate
if [ -n "${IP_FRIGATE}" ] && [ "$NO_ROOT" == "false" ]; then
    FRIG_LATEST=$(get_latest_version "blakeblackshear/frigate")
    FRIG_CURRENT=$(get_installed_version "frigate" "${IP_FRIGATE}")
    if [ -n "$FRIG_LATEST" ] && [ -n "$FRIG_CURRENT" ]; then
        if [ "$FRIG_LATEST" != "$FRIG_CURRENT" ]; then
            msg_warn "Frigate: ${FRIG_CURRENT} → ${FRIG_LATEST} (uppdatering tillgänglig)"
            msg_info "  Uppgradera via: bash setup.sh → Meny 2 (Laga/Uppgradera)"
            UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
        else
            msg_ok "Frigate: ${FRIG_CURRENT} (senaste)"
        fi
    elif [ -n "$FRIG_LATEST" ]; then
        msg_info "Frigate senaste: ${FRIG_LATEST} (installerad version okänd)"
    fi
fi

# Immich
if [ -n "${IP_IMMICH}" ] && [ "$NO_ROOT" == "false" ]; then
    IMMICH_LATEST=$(get_latest_version "immich-app/immich")
    IMMICH_CURRENT=$(get_installed_version "immich" "${IP_IMMICH}")
    if [ -n "$IMMICH_LATEST" ] && [ -n "$IMMICH_CURRENT" ]; then
        if [ "$IMMICH_LATEST" != "$IMMICH_CURRENT" ]; then
            msg_warn "Immich: ${IMMICH_CURRENT} → ${IMMICH_LATEST} (uppdatering tillgänglig)"
            msg_info "  Uppgradera: pct exec ${IP_IMMICH} -- /opt/immich/upgrade.sh"
            UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
        else
            msg_ok "Immich: ${IMMICH_CURRENT} (senaste)"
        fi
    elif [ -n "$IMMICH_LATEST" ]; then
        msg_info "Immich senaste: ${IMMICH_LATEST}"
    fi
fi

# AdGuard Home
if [ -n "${IP_ADGUARD}" ] && [ "$NO_ROOT" == "false" ]; then
    AGH_LATEST=$(get_latest_version "AdguardTeam/AdGuardHome")
    AGH_CURRENT=$(get_installed_version "adguard" "${IP_ADGUARD}")
    if [ -n "$AGH_LATEST" ] && [ -n "$AGH_CURRENT" ]; then
        if [ "$AGH_LATEST" != "$AGH_CURRENT" ]; then
            msg_warn "AdGuard Home: ${AGH_CURRENT} → ${AGH_LATEST} (uppdatering tillgänglig)"
            msg_info "  Uppgradera: pct exec ${IP_ADGUARD} -- /opt/AdGuardHome/AdGuardHome --update"
            UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
        else
            msg_ok "AdGuard Home: ${AGH_CURRENT} (senaste)"
        fi
    elif [ -n "$AGH_LATEST" ]; then
        msg_info "AdGuard Home senaste: ${AGH_LATEST}"
    fi
fi

# NPM
if [ -n "${IP_NPM}" ] && [ "$NO_ROOT" == "false" ]; then
    NPM_LATEST=$(get_latest_version "NginxProxyManager/nginx-proxy-manager")
    if [ -n "$NPM_LATEST" ]; then
        msg_info "NPM senaste release: ${NPM_LATEST}"
    fi
fi

if [ $UPDATES_AVAILABLE -eq 0 ]; then
    msg_ok "Alla tjänster är uppdaterade (eller version kunde ej kontrolleras)"
else
    msg_warn "${UPDATES_AVAILABLE} uppdatering(ar) tillgänglig(a)"
    WARNINGS=$((WARNINGS + UPDATES_AVAILABLE))
fi

# ============================================================
# 11. SAMMANFATTNING
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $ISSUES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ Allt ser bra ut! Inga problem hittades.${NC}"
elif [ $ISSUES -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}⚠ ${WARNINGS} varning(ar) — men inget kritiskt.${NC}"
else
    echo -e "  ${RED}${BOLD}✗ ${ISSUES} kritiskt problem — ${WARNINGS} varning(ar)${NC}"
    echo -e "  ${RED}  Åtgärda de röda problemen ovan.${NC}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
