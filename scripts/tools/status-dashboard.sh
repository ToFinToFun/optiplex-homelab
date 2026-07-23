#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Service Dashboard
# ============================================================
# Visar alla tjänster samlat med:
#   - Intern adress (IP:port) + status (grön/röd)
#   - Extern adress (domän via HTTPS) + status (grön/röd)
#   - NPM-proxy konfigurerad? (grön/röd)
#   - Cloudflare Tunnel-status
#
# Användning: sudo bash tools/status-dashboard.sh [--json]
# ============================================================

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/proxmox.sh

# Ladda config
if [ -f setup.env ]; then
    source setup.env
fi

JSON_OUTPUT=false
[[ "$1" == "--json" ]] && JSON_OUTPUT=true

# ============================================================
# ROOT-CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}${BOLD}  Dashboard måste köras som root.${NC}"
    echo -e "  Kör: ${YELLOW}sudo bash tools/status-dashboard.sh${NC}"
    exit 1
fi

NW="${NETWORK_PREFIX:-192.168.0}"

# ============================================================
# HJÄLPFUNKTIONER
# ============================================================

# Upptäck faktisk IP för en CT
get_ct_ip() {
    local hostname="$1"
    local config_id="$2"
    local ct_id
    ct_id=$(resolve_ct_id "$hostname" "$config_id")
    [ -z "$ct_id" ] && return
    if pct status "$ct_id" 2>/dev/null | grep -q "running"; then
        local ip
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && echo "$ip" && return
        # Fallback: LXC config
        local conf="/etc/pve/lxc/${ct_id}.conf"
        [ -f "$conf" ] && grep "^net0:" "$conf" | grep -oP 'ip=\K[^/]+' | grep -v "dhcp" && return
    fi
}

# Upptäck faktisk IP för HA VM
get_ha_ip() {
    local vm_id
    vm_id=$(resolve_vm_id "ha" "${IP_HA:-100}")
    [ -z "$vm_id" ] && return
    if qm status "$vm_id" 2>/dev/null | grep -q "running"; then
        local ip
        ip=$(qm guest cmd "$vm_id" network-get-interfaces 2>/dev/null | \
            python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for iface in data:
        if iface.get('name') == 'lo': continue
        for addr in iface.get('ip-addresses', []):
            if addr.get('ip-address-type') == 'ipv4' and not addr['ip-address'].startswith('127.'):
                print(addr['ip-address'])
                sys.exit(0)
except: pass
" 2>/dev/null)
        [ -n "$ip" ] && echo "$ip" && return
    fi
}

# Kontrollera om en intern port svarar
check_internal() {
    local ip="$1"
    local port="$2"
    [ -z "$ip" ] && echo "no_ip" && return
    if nc -z -w 3 "$ip" "$port" 2>/dev/null; then
        echo "up"
    else
        echo "down"
    fi
}

# Kontrollera extern HTTPS-åtkomst
check_external() {
    local domain="$1"
    [ -z "$domain" ] && echo "not_configured" && return
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -L "https://${domain}" 2>/dev/null)
    case "$http_code" in
        200|301|302|303|401|403) echo "up" ;;
        000) echo "timeout" ;;
        *) echo "error_${http_code}" ;;
    esac
}

# Kontrollera om NPM har en proxy-regel för en domän/port
check_npm_proxy() {
    local target_port="$1"
    local target_keyword="$2"
    # Använder NPM_HOSTS_DATA (hämtas en gång)
    [ -z "$NPM_HOSTS_DATA" ] && echo "npm_unavailable" && return
    
    python3 -c "
import json, sys
try:
    hosts = json.loads('''${NPM_HOSTS_DATA}''')
    for h in hosts:
        domains = ','.join(h.get('domain_names', []))
        port = h.get('forward_port', 0)
        fwd = h.get('forward_host', '')
        ws = h.get('allow_websocket_upgrade', 0)
        enabled = h.get('enabled', 1)
        if port == ${target_port} or '${target_keyword}' in domains.lower():
            if enabled:
                print(f'configured|{domains}|{fwd}:{port}|ws={ws}')
            else:
                print(f'disabled|{domains}|{fwd}:{port}|ws={ws}')
            sys.exit(0)
    print('missing')
except Exception as e:
    print('parse_error')
" 2>/dev/null
}

# ============================================================
# DATAINSAMLING
# ============================================================

# Upptäck domän (från NPM-regler eller config)
DOMAIN=""

# Upptäck NPM IP och logga in
NPM_CT_ID=$(resolve_ct_id "npm" "${IP_NPM:-102}")
NPM_IP=$(get_ct_ip "npm" "${IP_NPM:-102}")
NPM_HOSTS_DATA=""

if [ -n "$NPM_IP" ] && nc -z -w 3 "$NPM_IP" 81 2>/dev/null; then
    NPM_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
    NPM_PASS="${SHARED_PASSWORD:-changeme}"
    
    TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\": \"${NPM_EMAIL}\", \"secret\": \"${NPM_PASS}\"}" 2>/dev/null)
    NPM_TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    
    if [ -z "$NPM_TOKEN" ] && [ "$NPM_PASS" != "changeme" ]; then
        TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
            -H "Content-Type: application/json" \
            -d '{"identity": "admin@example.com", "secret": "changeme"}' 2>/dev/null)
        NPM_TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    fi
    
    if [ -n "$NPM_TOKEN" ]; then
        NPM_HOSTS_DATA=$(curl -s --max-time 10 "http://${NPM_IP}:81/api/nginx/proxy-hosts" \
            -H "Authorization: Bearer $NPM_TOKEN" 2>/dev/null)
        
        # Extrahera domän från första proxy host
        DOMAIN=$(echo "$NPM_HOSTS_DATA" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        for d in h.get('domain_names', []):
            parts = d.split('.')
            if len(parts) >= 2:
                print('.'.join(parts[-2:]))
                sys.exit(0)
except: pass
" 2>/dev/null)
    fi
fi

# Proxmox host IP
PVE_IP=$(hostname -I | awk '{print $1}')

# Tjänst-IP:er
HA_IP=$(get_ha_ip)
CF_IP=$(get_ct_ip "cloudflared" "${IP_CLOUDFLARED:-101}")
AGH_IP=$(get_ct_ip "adguard" "${IP_ADGUARD:-104}")
FRIG_IP=$(get_ct_ip "frigate" "${IP_FRIGATE:-103}")
GUAC_IP=$(get_ct_ip "guacamole" "${IP_GUACAMOLE:-107}")
DESK_IP=$(get_ct_ip "desktop" "${IP_DESKTOP:-108}")
SAMBA_IP=$(get_ct_ip "samba" "${IP_SAMBA:-}")
IMMICH_IP=$(get_ct_ip "immich" "${IP_IMMICH:-}")
NUT_IP=$(get_ct_ip "nut" "${IP_NUT:-}")

# ============================================================
# STATUSCHECK
# ============================================================

# Intern status
PVE_INT=$(check_internal "$PVE_IP" 8006)
HA_INT=$(check_internal "$HA_IP" 8123)
NPM_INT=$(check_internal "$NPM_IP" 81)
AGH_INT=$(check_internal "$AGH_IP" 53)
AGH_WEB_INT=$(check_internal "$AGH_IP" 80)
FRIG_INT=$(check_internal "$FRIG_IP" 5000)
GUAC_INT=$(check_internal "$GUAC_IP" 8080)
SAMBA_INT=$(check_internal "$SAMBA_IP" 445)
IMMICH_INT=$(check_internal "$IMMICH_IP" 2283)
NUT_INT=$(check_internal "$NUT_IP" 3493)

# Cloudflared-status
CF_STATUS="down"
CF_CT_ID=$(resolve_ct_id "cloudflared" "${IP_CLOUDFLARED:-101}")
if [ -n "$CF_CT_ID" ] && pct status "$CF_CT_ID" 2>/dev/null | grep -q "running"; then
    if pct exec "$CF_CT_ID" -- systemctl is-active --quiet cloudflared 2>/dev/null; then
        if pct exec "$CF_CT_ID" -- journalctl -u cloudflared -n 30 --no-pager 2>/dev/null | grep -q "Registered tunnel connection\|Connection.*registered"; then
            CF_STATUS="connected"
        else
            CF_STATUS="running"
        fi
    fi
fi

# Extern status (bara om vi har domän OCH tunnel verkar vara uppe)
HA_EXT="not_configured"
FRIG_EXT="not_configured"
GUAC_EXT="not_configured"
PVE_EXT="not_configured"

if [ -n "$DOMAIN" ] && [ "$CF_STATUS" == "connected" ]; then
    # Kolla vilka subdomäner som finns i NPM
    HA_DOMAIN=$(echo "$NPM_HOSTS_DATA" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        for d in h.get('domain_names', []):
            if 'ha' in d.lower() or 'home' in d.lower():
                print(d); sys.exit(0)
        if h.get('forward_port') == 8123:
            for d in h.get('domain_names', []): print(d); sys.exit(0)
except: pass
" 2>/dev/null)

    FRIG_DOMAIN=$(echo "$NPM_HOSTS_DATA" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        for d in h.get('domain_names', []):
            if 'frigate' in d.lower() or 'nvr' in d.lower() or 'cam' in d.lower():
                print(d); sys.exit(0)
        if h.get('forward_port') == 5000:
            for d in h.get('domain_names', []): print(d); sys.exit(0)
except: pass
" 2>/dev/null)

    GUAC_DOMAIN=$(echo "$NPM_HOSTS_DATA" | python3 -c "
import json, sys
try:
    hosts = json.load(sys.stdin)
    for h in hosts:
        for d in h.get('domain_names', []):
            if 'guac' in d.lower() or 'rdp' in d.lower() or 'remote' in d.lower():
                print(d); sys.exit(0)
        if h.get('forward_port') == 8080:
            for d in h.get('domain_names', []): print(d); sys.exit(0)
except: pass
" 2>/dev/null)

    [ -n "$HA_DOMAIN" ] && HA_EXT=$(check_external "$HA_DOMAIN")
    [ -n "$FRIG_DOMAIN" ] && FRIG_EXT=$(check_external "$FRIG_DOMAIN")
    [ -n "$GUAC_DOMAIN" ] && GUAC_EXT=$(check_external "$GUAC_DOMAIN")
elif [ -n "$DOMAIN" ]; then
    # Tunnel inte connected — markera som "tunnel_down"
    HA_EXT="tunnel_down"
    FRIG_EXT="tunnel_down"
fi

# NPM-proxy status
HA_NPM=$(check_npm_proxy 8123 "ha")
FRIG_NPM=$(check_npm_proxy 5000 "frigate")
GUAC_NPM=$(check_npm_proxy 8080 "guac")

# ============================================================
# PRESENTATION
# ============================================================

# Statusikoner
icon() {
    case "$1" in
        up|connected|configured*) echo -e "${GREEN}●${NC}" ;;
        running) echo -e "${YELLOW}◐${NC}" ;;
        down|timeout|error_*|no_ip) echo -e "${RED}●${NC}" ;;
        not_configured|missing) echo -e "${CYAN}○${NC}" ;;
        npm_unavailable|parse_error) echo -e "${YELLOW}?${NC}" ;;
        disabled) echo -e "${YELLOW}●${NC}" ;;
        tunnel_down) echo -e "${RED}▼${NC}" ;;
        *) echo -e "${YELLOW}?${NC}" ;;
    esac
}

status_text() {
    case "$1" in
        up) echo "Fungerar" ;;
        connected) echo "Ansluten" ;;
        running) echo "Körs (ej verifierad)" ;;
        down) echo "Nere" ;;
        timeout) echo "Timeout" ;;
        no_ip) echo "Ingen IP" ;;
        not_configured) echo "Ej konfigurerad" ;;
        missing) echo "Saknas i NPM" ;;
        npm_unavailable) echo "NPM ej nåbar" ;;
        disabled) echo "Inaktiverad" ;;
        tunnel_down) echo "Tunnel nere" ;;
        error_*) echo "Fel (${1#error_})" ;;
        configured*) echo "Konfigurerad" ;;
        *) echo "$1" ;;
    esac
}

if [ "$JSON_OUTPUT" == "true" ]; then
    # JSON-output för programmatisk användning
    cat << JSONEOF
{
  "timestamp": "$(date -Iseconds)",
  "domain": "${DOMAIN:-null}",
  "services": [
    {
      "name": "Proxmox VE",
      "internal": {"ip": "${PVE_IP}", "port": 8006, "url": "https://${PVE_IP}:8006", "status": "${PVE_INT}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"}
    },
    {
      "name": "Home Assistant",
      "internal": {"ip": "${HA_IP:-unknown}", "port": 8123, "url": "http://${HA_IP:-unknown}:8123", "status": "${HA_INT}"},
      "external": {"url": "${HA_DOMAIN:+https://${HA_DOMAIN}}", "status": "${HA_EXT}"},
      "npm": {"status": "${HA_NPM}"}
    },
    {
      "name": "Frigate NVR",
      "internal": {"ip": "${FRIG_IP:-unknown}", "port": 5000, "url": "http://${FRIG_IP:-unknown}:5000", "status": "${FRIG_INT}"},
      "external": {"url": "${FRIG_DOMAIN:+https://${FRIG_DOMAIN}}", "status": "${FRIG_EXT}"},
      "npm": {"status": "${FRIG_NPM}"}
    },
    {
      "name": "AdGuard Home",
      "internal": {"ip": "${AGH_IP:-null}", "port": 53, "url": "http://${AGH_IP:-unknown}", "status": "${AGH_STATUS:-not_configured}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"},
      "dns": {"port": 53, "status": "${AGH_INT:-not_configured}"}
    },
    {
      "name": "NPM Admin",
      "internal": {"ip": "${NPM_IP:-unknown}", "port": 81, "url": "http://${NPM_IP:-unknown}:81", "status": "${NPM_INT}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"}
    },
    {
      "name": "Cloudflare Tunnel",
      "internal": {"ip": "${CF_IP:-unknown}", "port": null, "url": null, "status": "${CF_STATUS}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"}
    },
    {
      "name": "Guacamole (Remote Desktop)",
      "internal": {"ip": "${GUAC_IP:-null}", "port": 8080, "url": "${GUAC_IP:+http://${GUAC_IP}:8080}", "status": "${GUAC_INT:-not_configured}"},
      "external": {"url": "${GUAC_DOMAIN:+https://${GUAC_DOMAIN}}", "status": "${GUAC_EXT:-not_configured}"},
      "npm": {"status": "${GUAC_NPM:-not_configured}"}
    },
    {
      "name": "Samba",
      "internal": {"ip": "${SAMBA_IP:-null}", "port": 445, "url": "smb://${SAMBA_IP:-unknown}", "status": "${SAMBA_INT:-not_configured}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"}
    },
    {
      "name": "Immich",
      "internal": {"ip": "${IMMICH_IP:-null}", "port": 2283, "url": "http://${IMMICH_IP:-unknown}:2283", "status": "${IMMICH_INT:-not_configured}"},
      "external": {"url": "${CF_DOMAIN:+https://photos.${CF_DOMAIN}}", "status": "${IMMICH_EXT:-not_configured}"},
      "npm": {"status": "${IMMICH_NPM:-not_configured}"}
    },
    {
      "name": "NUT (UPS)",
      "internal": {"ip": "${NUT_IP:-null}", "port": 3493, "url": null, "status": "${NUT_INT:-not_configured}"},
      "external": {"url": null, "status": "not_applicable"},
      "npm": {"status": "not_applicable"}
    }
  ]
}
JSONEOF
    exit 0
fi

# Terminal-output
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔═══════════════════════════════════════════════════════════════════════════════╗"
echo "  ║                    OptiPlex Homelab — Service Dashboard                       ║"
echo "  ╚═══════════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${CYAN}Domän:${NC} ${DOMAIN:-${YELLOW}(ej upptäckt — NPM har inga proxy hosts?)${NC}}"
echo -e "  ${CYAN}Tunnel:${NC} $(icon $CF_STATUS) $(status_text $CF_STATUS)"
echo ""

# Tabell-header
echo -e "  ${BOLD}┌──────────────────────┬──────────────────────────────┬───────┬──────────────────────────────────┬───────┬──────────────┬───────┐${NC}"
echo -e "  ${BOLD}│ Tjänst               │ Intern adress                │ Status│ Extern adress (HTTPS)            │ Status│ NPM-proxy    │ Status│${NC}"
echo -e "  ${BOLD}├──────────────────────┼──────────────────────────────┼───────┼──────────────────────────────────┼───────┼──────────────┼───────┤${NC}"

# Rad-funktion
print_row() {
    local name="$1"
    local int_url="$2"
    local int_status="$3"
    local ext_url="$4"
    local ext_status="$5"
    local npm_info="$6"
    local npm_status="$7"
    
    local int_icon=$(icon "$int_status")
    local ext_icon=$(icon "$ext_status")
    local npm_icon=$(icon "$npm_status")
    
    printf "  │ %-20s │ %-28s │ %b     │ %-32s │ %b     │ %-12s │ %b     │\n" \
        "$name" "$int_url" "$int_icon" "$ext_url" "$ext_icon" "$npm_info" "$npm_icon"
}

# Proxmox
print_row "Proxmox VE" "https://${PVE_IP}:8006" "$PVE_INT" "—" "not_configured" "—" "not_configured"

# Home Assistant
HA_INT_URL="${HA_IP:+http://${HA_IP}:8123}"
[ -z "$HA_IP" ] && HA_INT_URL="(IP okänd)"
HA_EXT_URL="${HA_DOMAIN:+https://${HA_DOMAIN}}"
[ -z "$HA_EXT_URL" ] && HA_EXT_URL="—"
HA_NPM_SHORT=$(echo "$HA_NPM" | cut -d'|' -f1)
print_row "Home Assistant" "$HA_INT_URL" "$HA_INT" "$HA_EXT_URL" "$HA_EXT" "${HA_NPM_SHORT:-—}" "${HA_NPM_SHORT:-missing}"

# Frigate
FRIG_INT_URL="${FRIG_IP:+http://${FRIG_IP}:5000}"
[ -z "$FRIG_IP" ] && FRIG_INT_URL="(IP okänd)"
FRIG_EXT_URL="${FRIG_DOMAIN:+https://${FRIG_DOMAIN}}"
[ -z "$FRIG_EXT_URL" ] && FRIG_EXT_URL="—"
FRIG_NPM_SHORT=$(echo "$FRIG_NPM" | cut -d'|' -f1)
print_row "Frigate NVR" "$FRIG_INT_URL" "$FRIG_INT" "$FRIG_EXT_URL" "$FRIG_EXT" "${FRIG_NPM_SHORT:-—}" "${FRIG_NPM_SHORT:-missing}"

# AdGuard Home
AGH_INT_URL="${AGH_IP:+http://${AGH_IP} (DNS: :53)}"
[ -z "$AGH_IP" ] && AGH_INT_URL="(ej installerad)"
AGH_STATUS="down"
[ "$AGH_INT" == "up" ] && AGH_STATUS="up"
[ "$AGH_WEB_INT" == "up" ] && AGH_STATUS="up"
print_row "AdGuard Home" "$AGH_INT_URL" "$AGH_STATUS" "— (intern DNS)" "not_configured" "—" "not_configured"

# NPM Admin (bara intern)
NPM_INT_URL="${NPM_IP:+http://${NPM_IP}:81}"
[ -z "$NPM_IP" ] && NPM_INT_URL="(IP okänd)"
print_row "NPM Admin" "$NPM_INT_URL" "$NPM_INT" "— (bör ej exponeras)" "not_configured" "—" "not_configured"

# Cloudflare Tunnel
CF_INT_URL="${CF_IP:+CT ${CF_CT_ID} (${CF_IP})}"
[ -z "$CF_IP" ] && CF_INT_URL="(ej igång)"
print_row "Cloudflare Tunnel" "$CF_INT_URL" "$CF_STATUS" "— (infrastruktur)" "not_configured" "—" "not_configured"

# Guacamole (om installerad)
if [ -n "$GUAC_IP" ] || [ -n "${IP_GUACAMOLE}" ]; then
    GUAC_INT_URL="${GUAC_IP:+http://${GUAC_IP}:8080}"
    [ -z "$GUAC_IP" ] && GUAC_INT_URL="(ej igång)"
    GUAC_EXT_URL="${GUAC_DOMAIN:+https://${GUAC_DOMAIN}}"
    [ -z "$GUAC_EXT_URL" ] && GUAC_EXT_URL="—"
    GUAC_NPM_SHORT=$(echo "$GUAC_NPM" | cut -d'|' -f1)
    print_row "Remote Desktop" "$GUAC_INT_URL" "${GUAC_INT:-down}" "$GUAC_EXT_URL" "$GUAC_EXT" "${GUAC_NPM_SHORT:-—}" "${GUAC_NPM_SHORT:-missing}"
fi

# Tillägg (visas bara om installerade)
if [ -n "$SAMBA_IP" ]; then
    print_row "Samba" "//${SAMBA_IP}/share" "${SAMBA_INT:-down}" "— (intern)" "not_configured" "—" "not_configured"
fi
if [ -n "$IMMICH_IP" ]; then
    IMMICH_EXT_URL="${CF_DOMAIN:+https://photos.${CF_DOMAIN}}"
    [ -z "$IMMICH_EXT_URL" ] && IMMICH_EXT_URL="—"
    print_row "Immich" "http://${IMMICH_IP}:2283" "${IMMICH_INT:-down}" "$IMMICH_EXT_URL" "${IMMICH_EXT:-not_configured}" "—" "not_configured"
fi
if [ -n "$NUT_IP" ]; then
    print_row "NUT (UPS)" "http://${NUT_IP}:3493" "${NUT_INT:-down}" "— (intern)" "not_configured" "—" "not_configured"
fi

echo -e "  ${BOLD}└──────────────────────┴──────────────────────────────┴───────┴──────────────────────────────────┴───────┴──────────────┴───────┘${NC}"

# ============================================================
# LEGEND
# ============================================================
echo ""
echo -e "  ${BOLD}Förklaring:${NC}"
echo -e "    ${GREEN}●${NC} Fungerar/Konfigurerad    ${YELLOW}◐${NC} Körs men ej verifierad    ${RED}●${NC} Nere/Fel"
echo -e "    ${CYAN}○${NC} Ej konfigurerad/N/A      ${RED}▼${NC} Tunnel nere               ${YELLOW}?${NC} Okänd"

# ============================================================
# DETALJER & REKOMMENDATIONER
# ============================================================
echo ""
echo -e "  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}Detaljer & Rekommendationer:${NC}"
echo ""

# Intern åtkomst-info
echo -e "  ${BOLD}Intern åtkomst (LAN):${NC}"
echo -e "    Proxmox:        ${BOLD}https://${PVE_IP}:8006${NC}"
[ -n "$HA_IP" ] && echo -e "    Home Assistant:  ${BOLD}http://${HA_IP}:8123${NC}"
[ -n "$NPM_IP" ] && echo -e "    NPM Admin:      ${BOLD}http://${NPM_IP}:81${NC}"
[ -n "$FRIG_IP" ] && echo -e "    Frigate:        ${BOLD}http://${FRIG_IP}:5000${NC}"
[ -n "$AGH_IP" ] && echo -e "    AdGuard Home:   ${BOLD}http://${AGH_IP}${NC} (DNS: ${AGH_IP}:53)"
[ -n "$GUAC_IP" ] && echo -e "    Guacamole:      ${BOLD}http://${GUAC_IP}:8080${NC}"
[ -n "$SAMBA_IP" ] && echo -e "    Samba:          ${BOLD}//${SAMBA_IP}/share${NC} (SMB port 445)"
[ -n "$IMMICH_IP" ] && echo -e "    Immich:         ${BOLD}http://${IMMICH_IP}:2283${NC}"
[ -n "$NUT_IP" ] && echo -e "    NUT:            ${BOLD}http://${NUT_IP}:3493${NC} (UPS-status)"

# Extern åtkomst-info
if [ -n "$DOMAIN" ]; then
    echo ""
    echo -e "  ${BOLD}Extern åtkomst (via Cloudflare Tunnel → NPM):${NC}"
    [ -n "$HA_DOMAIN" ] && echo -e "    Home Assistant:  ${BOLD}https://${HA_DOMAIN}${NC}"
    [ -n "$FRIG_DOMAIN" ] && echo -e "    Frigate:        ${BOLD}https://${FRIG_DOMAIN}${NC}"
    [ -n "$GUAC_DOMAIN" ] && echo -e "    Remote Desktop: ${BOLD}https://${GUAC_DOMAIN}${NC}"
fi

# Varningar/rekommendationer
echo ""
RECS=0

if [ "$CF_STATUS" != "connected" ]; then
    echo -e "  ${YELLOW}⚠${NC} Cloudflare Tunnel är inte ansluten — extern åtkomst fungerar inte."
    echo -e "    Kontrollera: pct exec ${CF_CT_ID:-101} -- journalctl -u cloudflared -n 20"
    RECS=$((RECS + 1))
fi

if [ "$HA_INT" == "down" ] && [ -n "$HA_IP" ]; then
    echo -e "  ${YELLOW}⚠${NC} Home Assistant svarar inte internt. Kontrollera VM:en."
    RECS=$((RECS + 1))
fi

if [ "$FRIG_INT" == "down" ] && [ -n "$FRIG_IP" ]; then
    echo -e "  ${YELLOW}⚠${NC} Frigate svarar inte internt. Kontrollera Docker:"
    echo -e "    pct exec ${FRIG_ID:-103} -- docker logs frigate --tail 20"
    RECS=$((RECS + 1))
fi

if echo "$FRIG_NPM" | grep -q "missing"; then
    echo -e "  ${YELLOW}⚠${NC} Frigate saknar NPM-proxy — extern åtkomst fungerar inte."
    echo -e "    Kör: ${YELLOW}sudo bash setup.sh${NC} (välj NPM-config)"
    RECS=$((RECS + 1))
fi

if echo "$FRIG_NPM" | grep -q "ws=0"; then
    echo -e "  ${RED}✗${NC} Frigate-proxy saknar WebSockets — live-video fungerar inte!"
    echo -e "    Kör: ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
    RECS=$((RECS + 1))
fi

if echo "$HA_NPM" | grep -q "missing"; then
    echo -e "  ${YELLOW}⚠${NC} Home Assistant saknar NPM-proxy — extern åtkomst fungerar inte."
    echo -e "    Kör: ${YELLOW}sudo bash setup.sh${NC} (välj NPM-config)"
    RECS=$((RECS + 1))
fi

if [ "$AGH_STATUS" == "down" ] && [ -n "$AGH_IP" ]; then
    echo -e "  ${YELLOW}⚠${NC} AdGuard Home svarar inte. DNS-blockering och split-DNS inaktivt."
    echo -e "    Kontrollera: pct exec ${IP_ADGUARD:-104} -- systemctl status AdGuardHome"
    RECS=$((RECS + 1))
fi

if [ "$HA_EXT" == "tunnel_down" ] || [ "$FRIG_EXT" == "tunnel_down" ]; then
    echo -e "  ${YELLOW}⚠${NC} Tunnel nere — använd interna adresser tills vidare:"
    [ -n "$HA_IP" ] && echo -e "    HA:      http://${HA_IP}:8123"
    [ -n "$FRIG_IP" ] && echo -e "    Frigate: http://${FRIG_IP}:5000"
    RECS=$((RECS + 1))
fi

if [ $RECS -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} Inga problem upptäckta. Alla tjänster fungerar som förväntat."
fi

echo ""
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}Verktyg:${NC}"
echo -e "    Reparera IP/NPM:  ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
echo -e "    Full diagnostik:  ${YELLOW}sudo bash tools/doctor.sh${NC}"
echo -e "    JSON-output:      ${YELLOW}sudo bash tools/status-dashboard.sh --json${NC}"
echo ""
