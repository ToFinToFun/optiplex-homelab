#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/proxmox.sh

msg_header "Nginx Proxy Manager Auto-Config"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Denna modul konfigurerar automatiskt NPM att dirigera trafik   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} till Home Assistant och Frigate.                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}Cloudflare Tunnel hanterar TLS/HTTPS externt.${NC}                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}NPM ska INTE ha Force SSL eller egna certifikat.${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if ! pct status $IP_NPM &>/dev/null; then
    msg_skip "NPM (CT $IP_NPM) är inte installerad eller igång."
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
NPM_IP="${NETWORK_PREFIX}.${IP_NPM}"

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

# HA
if check_id_exists $IP_HA; then
    create_proxy_host "ha" "${NETWORK_PREFIX}.${IP_HA}" 8123 true
fi

# Frigate
if check_id_exists $IP_FRIGATE; then
    create_proxy_host "frigate" "${NETWORK_PREFIX}.${IP_FRIGATE}" 5000 true
fi

msg_ok "NPM-konfiguration slutförd!"
