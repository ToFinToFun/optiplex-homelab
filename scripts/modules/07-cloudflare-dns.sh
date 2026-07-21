#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh

msg_header "Cloudflare DNS, Zero Trust & Split-DNS"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Denna modul sätter upp:                                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  1. DNS-poster (CNAME) för ha.domän.se och frigate.domän.se     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  2. Tunnel Routing (Ingress) så tunneln vet vart trafik ska     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  3. Zero Trust Access (skyddar Frigate/NPM med e-post OTP)      ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  4. Split-DNS (undviker hairpin NAT vid lokal åtkomst)          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}API Token behöver:${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  - Zone -> DNS -> Edit                                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  - Account -> Cloudflare Tunnel -> Edit                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  - Account -> Access: Apps and Policies -> Edit                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} Skapa token: https://dash.cloudflare.com/profile/api-tokens     ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if ! ask_yes_no "Vill du sätta upp DNS och extern åtkomst nu?" "N"; then
    msg_skip "Hoppar över Cloudflare DNS/Zero Trust."
    echo -e "${YELLOW}Du kan köra detta steg senare genom att köra:${NC}"
    echo -e "  ${GREEN}cd /tmp/optiplex-homelab/scripts && bash modules/07-cloudflare-dns.sh${NC}\n"
    exit 0
fi

CF_API_TOKEN=$(ask_string "Cloudflare API Token" "" "true")
if [ -z "$CF_API_TOKEN" ]; then
    msg_warn "Ingen token angiven. Avbryter."
    exit 0
fi

DOMAIN=$(ask_string "Din domän (t.ex. example.se)" "")
if [ -z "$DOMAIN" ]; then
    msg_warn "Ingen domän angiven. Avbryter."
    exit 0
fi

# ==========================================
# STEG 1: DNS-poster
# ==========================================
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

TUNNEL_UUID=$(ask_string "Ditt Tunnel UUID (hittas i Cloudflare Zero Trust Dashboard -> Networks -> Tunnels)" "")

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

    # ==========================================
    # STEG 2: Tunnel Routing (Ingress)
    # ==========================================
    if ask_yes_no "Vill du sätta upp Tunnel Routing (Ingress) via API?" "Y"; then
        msg_info "Hämtar Account ID..."
        ACC_RES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
             -H "Authorization: Bearer $CF_API_TOKEN" \
             -H "Content-Type: application/json")
        ACC_ID=$(echo "$ACC_RES" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
        
        if [ -n "$ACC_ID" ]; then
            msg_info "Sätter upp ingress-regler för tunneln..."
            # Routing: allt via NPM (som hanterar SSL och proxy)
            curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACC_ID/cfd_tunnel/$TUNNEL_UUID/configurations" \
                 -H "Authorization: Bearer $CF_API_TOKEN" \
                 -H "Content-Type: application/json" \
                 --data "{
                   \"config\": {
                     \"ingress\": [
                       {\"hostname\": \"ha.${DOMAIN}\", \"service\": \"http://${NETWORK_PREFIX}.${IP_NPM}:80\"},
                       {\"hostname\": \"frigate.${DOMAIN}\", \"service\": \"http://${NETWORK_PREFIX}.${IP_NPM}:80\"},
                       {\"service\": \"http_status:404\"}
                     ]
                   }
                 }" > /dev/null
            msg_ok "Tunnel routing konfigurerad!"
        else
            msg_warn "Kunde inte hämta Account ID. Saknar API-nyckeln 'Account:Cloudflare Tunnel:Edit'?"
        fi
    fi

    # ==========================================
    # STEG 3: Zero Trust Access Policies
    # ==========================================
    echo -e "\n${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Zero Trust Access — Skydda dina tjänster${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "Home Assistant har sin egen inloggning, men Frigate och NPM"
    echo -e "har ${RED}ingen autentisering${NC} som standard. Utan Zero Trust kan vem"
    echo -e "som helst med URL:en komma åt dem."
    echo -e ""
    echo -e "Zero Trust Access lägger till en inloggningssida (e-post OTP)"
    echo -e "framför dessa tjänster. Bara godkända e-postadresser släpps igenom."
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}\n"

    if ask_yes_no "Vill du sätta upp Zero Trust Access för Frigate och NPM?" "Y"; then
        ACCESS_EMAIL=$(ask_string "Vilken e-postadress ska ha tillgång? (din e-post)" "")
        
        if [ -z "$ACCESS_EMAIL" ]; then
            msg_warn "Ingen e-post angiven. Hoppar över Zero Trust."
        else
            # Hämta Account ID om vi inte redan har det
            if [ -z "$ACC_ID" ]; then
                ACC_RES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
                     -H "Authorization: Bearer $CF_API_TOKEN" \
                     -H "Content-Type: application/json")
                ACC_ID=$(echo "$ACC_RES" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
            fi
            
            if [ -n "$ACC_ID" ]; then
                # Skapa Access Application för Frigate
                msg_info "Skapar Access Application för frigate.${DOMAIN}..."
                curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACC_ID/access/apps" \
                     -H "Authorization: Bearer $CF_API_TOKEN" \
                     -H "Content-Type: application/json" \
                     --data "{
                       \"name\": \"Frigate NVR\",
                       \"domain\": \"frigate.${DOMAIN}\",
                       \"type\": \"self_hosted\",
                       \"session_duration\": \"24h\",
                       \"auto_redirect_to_identity\": false,
                       \"policies\": [
                         {
                           \"name\": \"Tillåt ägare\",
                           \"decision\": \"allow\",
                           \"include\": [
                             {\"email\": {\"email\": \"${ACCESS_EMAIL}\"}}
                           ]
                         }
                       ]
                     }" > /dev/null
                msg_ok "Zero Trust Access skapad för frigate.${DOMAIN}"

                # Skapa Access Application för NPM (admin-panel)
                msg_info "Skapar Access Application för npm.${DOMAIN} (om du vill exponera den)..."
                # NPM behöver oftast inte exponeras externt, men om den gör det:
                if ask_yes_no "Vill du även exponera NPM externt (npm.${DOMAIN}) med Zero Trust?" "N"; then
                    # Skapa DNS-post för NPM
                    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                         -H "Authorization: Bearer $CF_API_TOKEN" \
                         -H "Content-Type: application/json" \
                         --data "{\"type\":\"CNAME\",\"name\":\"npm.${DOMAIN}\",\"content\":\"$TARGET\",\"ttl\":1,\"proxied\":true}" > /dev/null
                    
                    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACC_ID/access/apps" \
                         -H "Authorization: Bearer $CF_API_TOKEN" \
                         -H "Content-Type: application/json" \
                         --data "{
                           \"name\": \"NPM Admin\",
                           \"domain\": \"npm.${DOMAIN}\",
                           \"type\": \"self_hosted\",
                           \"session_duration\": \"24h\",
                           \"auto_redirect_to_identity\": false,
                           \"policies\": [
                             {
                               \"name\": \"Tillåt ägare\",
                               \"decision\": \"allow\",
                               \"include\": [
                                 {\"email\": {\"email\": \"${ACCESS_EMAIL}\"}}
                               ]
                             }
                           ]
                         }" > /dev/null
                    msg_ok "Zero Trust Access skapad för npm.${DOMAIN}"
                fi
                
                msg_ok "Zero Trust konfigurerat! Du loggar in med e-post OTP (${ACCESS_EMAIL})."
            else
                msg_warn "Kunde inte hämta Account ID. Konfigurera Zero Trust manuellt:"
                echo -e "  1. Gå till https://one.dash.cloudflare.com"
                echo -e "  2. Access -> Applications -> Add an Application"
                echo -e "  3. Self-hosted, domän: frigate.${DOMAIN}"
                echo -e "  4. Policy: Allow, Include: Email = ${ACCESS_EMAIL}"
            fi
        fi
    fi
else
    msg_warn "Utan Tunnel UUID kan vi inte skapa DNS-posterna automatiskt."
    echo -e "  Hitta ditt UUID: Cloudflare Dashboard -> Zero Trust -> Networks -> Tunnels"
fi

# ==========================================
# STEG 4: Split-DNS (Undvik Hairpin NAT)
# ==========================================
echo -e "\n${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Split-DNS — Undvik Hairpin NAT${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "När du sitter hemma och surfar till ha.${DOMAIN:-dindomän.se} skickas"
echo -e "trafiken ut till Cloudflare och tillbaka in igen (hairpin NAT)."
echo -e "Det är långsamt och fungerar inte med alla routrar."
echo -e ""
echo -e "${BOLD}Lösning:${NC} Peka domänerna direkt till NPM:s lokala IP när du"
echo -e "är hemma. Trafiken stannar då på ditt LAN."
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}\n"

echo -e "${BOLD}Alternativ 1: Unifi DNS Override (rekommenderat)${NC}"
echo -e "  1. Logga in i Unifi Network Controller"
echo -e "  2. Gå till Settings -> Networks -> DNS"
echo -e "  3. Lägg till 'Local DNS Records':"
echo -e "     - ha.${DOMAIN:-dindomän.se}      -> ${NETWORK_PREFIX}.${IP_NPM}"
echo -e "     - frigate.${DOMAIN:-dindomän.se}  -> ${NETWORK_PREFIX}.${IP_NPM}"
echo -e ""
echo -e "${BOLD}Alternativ 2: /etc/hosts på klienterna${NC}"
echo -e "  Lägg till i /etc/hosts (Mac/Linux) eller C:\\Windows\\System32\\drivers\\etc\\hosts:"
echo -e "     ${NETWORK_PREFIX}.${IP_NPM}  ha.${DOMAIN:-dindomän.se}"
echo -e "     ${NETWORK_PREFIX}.${IP_NPM}  frigate.${DOMAIN:-dindomän.se}"
echo -e ""
echo -e "${BOLD}Alternativ 3: AdGuard Home / Pi-hole DNS Rewrite${NC}"
echo -e "  Om du kör lokal DNS (AdGuard/Pi-hole), lägg till DNS Rewrites:"
echo -e "     ha.${DOMAIN:-dindomän.se}      -> ${NETWORK_PREFIX}.${IP_NPM}"
echo -e "     frigate.${DOMAIN:-dindomän.se}  -> ${NETWORK_PREFIX}.${IP_NPM}"
echo -e ""

echo -e "${GREEN}Varför NPM och inte direkt till tjänsten?${NC}"
echo -e "  NPM hanterar SSL-certifikat och routing. Genom att peka allt till NPM"
echo -e "  fungerar samma URL (ha.domän.se) identiskt oavsett om du är hemma eller borta."
echo -e "  NPM dirigerar sedan vidare till rätt tjänst (HA:8123, Frigate:5000).\n"

ask_string "Tryck Enter för att fortsätta..." ""
