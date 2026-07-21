#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh

msg_header "Cloudflare DNS Auto-Setup"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Denna modul kan automatiskt skapa DNS-poster i Cloudflare.     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} (t.ex. ha.din-domän.se och frigate.din-domän.se)               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} För att detta ska fungera behöver du en API Token från         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} Cloudflare med behörigheten: ${YELLOW}Zone -> DNS -> Edit${NC}               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} Skapa en här: https://dash.cloudflare.com/profile/api-tokens   ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if ! ask_yes_no "Vill du sätta upp DNS-poster automatiskt nu?" "N"; then
    msg_skip "Hoppar över Cloudflare DNS."
    exit 0
fi

CF_API_TOKEN=$(ask_string "Cloudflare API Token" "" "true")
if [ -z "$CF_API_TOKEN" ]; then
    msg_warn "Ingen token angiven. Avbryter."
    exit 0
fi

DOMAIN=$(ask_string "Din domän (t.ex. paasovaara.se)" "")
if [ -z "$DOMAIN" ]; then
    msg_warn "Ingen domän angiven. Avbryter."
    exit 0
fi

# Hämta Zone ID
msg_info "Hämtar Zone ID för $DOMAIN..."
ZONE_RES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RES" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)

if [ -z "$ZONE_ID" ]; then
    msg_err "Kunde inte hitta Zone ID för $DOMAIN. Är API-nyckeln korrekt?"
    exit 1
fi

msg_ok "Hittade Zone ID: $ZONE_ID"

# Vi behöver tunnelns UUID för att skapa en CNAME till <UUID>.cfargotunnel.com
msg_info "Letar efter Tunnel UUID i CT $IP_CLOUDFLARED..."
if pct status $IP_CLOUDFLARED &>/dev/null; then
    # Detta är lite knepigt att hämta ut om vi bara installerat via token, 
    # cloudflared sparar cert/credentials i /etc/cloudflared eller ~/.cloudflared.
    # För enkelhetens skull frågar vi användaren om de har sitt UUID, annars kan vi inte göra CNAMEs enkelt.
    TUNNEL_UUID=$(ask_string "Ditt Tunnel UUID (hittas i Cloudflare Zero Trust Dashboard)" "")
    
    if [ -n "$TUNNEL_UUID" ]; then
        TARGET="${TUNNEL_UUID}.cfargotunnel.com"
        
        for sub in "ha" "frigate"; do
            msg_info "Skapar CNAME för ${sub}.${DOMAIN} -> $TARGET..."
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                 -H "Authorization: Bearer $CF_API_TOKEN" \
                 -H "Content-Type: application/json" \
                 --data "{\"type\":\"CNAME\",\"name\":\"${sub}.${DOMAIN}\",\"content\":\"$TARGET\",\"ttl\":1,\"proxied\":true}" > /dev/null
            msg_ok "Skapade ${sub}.${DOMAIN}"
        done
    else
        msg_warn "Utan Tunnel UUID kan vi inte skapa DNS-posterna automatiskt."
    fi
else
    msg_warn "Cloudflared (CT $IP_CLOUDFLARED) är inte igång."
fi
