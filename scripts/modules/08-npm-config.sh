#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/proxmox.sh
source lib/network.sh

msg_header "Nginx Proxy Manager Auto-Config"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Denna modul konfigurerar automatiskt NPM att dirigera trafik   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} till Home Assistant och Frigate.                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}Cloudflare Tunnel hanterar TLS/HTTPS externt.${NC}                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}NPM ska INTE ha Force SSL eller egna certifikat.${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

# Resolve faktiska CT-ID:n (IP_* kan vara IP-octet, inte CT-ID)
NPM_CT=$(resolve_ct_id "npm" "$IP_NPM")
[ -z "$NPM_CT" ] && NPM_CT="$IP_NPM"
if ! pct status $NPM_CT &>/dev/null; then
    msg_skip "NPM (CT $NPM_CT) är inte installerad eller igång."
    exit 0
fi

if ! ask_yes_no "Vill du att skriptet automatiskt sätter upp proxy-reglerna i NPM?" "Y"; then
    msg_skip "Hoppar över NPM auto-config."
    exit 0
fi

DOMAIN=$(ask_string "Vilken är din basdomän? (t.ex. paasovaara.se)" "")
if [ -z "$DOMAIN" ]; then
    msg_warn "Ingen domän angiven. Avbryter."
    exit 0
fi

msg_info "Hämtar API-token från NPM..."
# Hämta faktisk NPM-IP från containern
NPM_IP=$(pct exec $NPM_CT -- hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$NPM_IP" ] && NPM_IP="${NETWORK_PREFIX}.${IP_NPM}"

# Försök logga in med gemensamt lösenord (om det redan bytts av setup.sh)
# Fallback till default-credentials
NPM_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
NPM_PASS="${SHARED_PASSWORD:-changeme}"

TOKEN_RES=$(curl -s -X POST "http://${NPM_IP}:81/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\": \"${NPM_EMAIL}\", \"secret\": \"${NPM_PASS}\"}")

TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)

# Fallback: försök med default om gemensamt lösenord inte fungerade
if [ -z "$TOKEN" ] && [ "$NPM_PASS" != "changeme" ]; then
    TOKEN_RES=$(curl -s -X POST "http://${NPM_IP}:81/api/tokens" \
        -H "Content-Type: application/json" \
        -d '{"identity": "admin@example.com", "secret": "changeme"}')
    TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
fi

if [ -z "$TOKEN" ]; then
    msg_warn "Kunde inte logga in i NPM. Lösenordet har kanske bytts manuellt."
    msg_info "Lägg in proxy hosts manuellt i NPM GUI:t (http://${NPM_IP}:81)."
    exit 0
fi

# Funktion för att skapa proxy host
create_proxy_host() {
    local sub=$1
    local forward_ip=$2
    local forward_port=$3
    local websockets=$4

    msg_info "Skapar proxy för ${sub}.${DOMAIN} -> ${forward_ip}:${forward_port}..."
    
    curl -s -X POST "http://${NPM_IP}:81/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\": [\"${sub}.${DOMAIN}\"],
            \"forward_scheme\": \"http\",
            \"forward_host\": \"${forward_ip}\",
            \"forward_port\": ${forward_port},
            \"access_list_id\": \"0\",
            \"certificate_id\": \"0\",
            \"meta\": {
                \"letsencrypt_agree\": false,
                \"dns_challenge\": false
            },
            \"advanced_config\": \"\",
            \"locations\": [],
            \"block_exploits\": true,
            \"caching_enabled\": false,
            \"allow_websocket_upgrade\": ${websockets},
            \"http2_support\": true,
            \"hsts_enabled\": false,
            \"hsts_subdomains\": false,
            \"ssl_forced\": false
        }" > /dev/null
        
    msg_ok "Skapade ${sub}.${DOMAIN}"
}

# Upptäck faktiska IP:er (hanterar både DHCP och manuellt ändrade IP:er)
_get_actual_ip() {
    local hostname="$1"
    local config_id="$2"
    local ct_id
    ct_id=$(resolve_ct_id "$hostname" "$config_id")
    if [ -n "$ct_id" ] && pct status "$ct_id" 2>/dev/null | grep -q "running"; then
        local ip
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            echo "$ip"
            return
        fi
    fi
    # Fallback till konfigurerad IP
    echo "${NETWORK_PREFIX}.${config_id}"
}

# HA (VM — använd qm guest agent eller fallback)
HA_ACTUAL_IP=""
HA_VM_ID=$(resolve_vm_id "ha" "$IP_HA")
if [ -n "$HA_VM_ID" ] && qm status "$HA_VM_ID" 2>/dev/null | grep -q "running"; then
    HA_ACTUAL_IP=$(qm guest cmd "$HA_VM_ID" network-get-interfaces 2>/dev/null | \
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
fi
[ -z "$HA_ACTUAL_IP" ] && HA_ACTUAL_IP="${NETWORK_PREFIX}.${IP_HA}"

if [ -n "$HA_VM_ID" ]; then
    create_proxy_host "ha" "$HA_ACTUAL_IP" 8123 true
fi

# Frigate
FRIG_CT=$(resolve_ct_id "frigate" "$IP_FRIGATE")
FRIG_ACTUAL_IP=$(_get_actual_ip "frigate" "$IP_FRIGATE")
if [ -n "$FRIG_CT" ]; then
    create_proxy_host "frigate" "$FRIG_ACTUAL_IP" 5000 true
fi

# Guacamole (om installerad)
GUAC_CT=$(resolve_ct_id "guacamole" "${IP_GUACAMOLE:-}")
if [ -n "$GUAC_CT" ]; then
    GUAC_ACTUAL_IP=$(_get_actual_ip "guacamole" "$IP_GUACAMOLE")
    create_proxy_host "rdp" "$GUAC_ACTUAL_IP" 8080 true
fi

msg_ok "NPM-konfiguration slutförd!"
msg_info "WebSockets är aktiverat för alla tjänster (krävs för Frigate live-video)."
