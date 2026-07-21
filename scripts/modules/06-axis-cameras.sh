#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh

msg_header "Axis Kameror & Frigate Config"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Denna modul skannar nätverket efter Axis-kameror och ger dig   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} exakta instruktioner för hur du ska konfigurera dem, innan     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} den skapar en färdig Frigate-config åt dig.                    ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if ! ask_yes_no "Vill du skanna nätverket efter Axis-kameror nu?" "Y"; then
    msg_skip "Hoppar över kamera-konfiguration."
    exit 0
fi

# Kolla om nmap finns, annars installera
if ! command -v nmap &> /dev/null; then
    msg_info "Installerar nmap för nätverksskanning..."
    apt-get update > /dev/null && apt-get install -y nmap > /dev/null
fi

msg_info "Skannar nätverket (${NETWORK_PREFIX}.0/24) efter Axis-enheter..."
# Axis MAC-adresser börjar oftast med 00:40:8C eller AC:CC:8E
# Vi gör en snabb ping-scan och kollar MAC-adresser
SCAN_RES=$(nmap -sn ${NETWORK_PREFIX}.0/24 | grep -B 2 -i -E "Axis|00:40:8C|AC:CC:8E" || true)

FOUND_CAMS=()
if [ -n "$SCAN_RES" ]; then
    # Extrahera IP-adresser från nmap output
    while read -r line; do
        if [[ $line == *"Nmap scan report for"* ]]; then
            ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
            if [ -n "$ip" ]; then
                FOUND_CAMS+=("$ip")
            fi
        fi
    done <<< "$SCAN_RES"
fi

if [ ${#FOUND_CAMS[@]} -eq 0 ]; then
    msg_warn "Hittade inga Axis-kameror automatiskt."
    if ask_yes_no "Vill du mata in IP-adresser manuellt?" "Y"; then
        MANUAL_IPS=$(ask_string "Ange IP-adresser separerade med mellanslag" "")
        for ip in $MANUAL_IPS; do
            FOUND_CAMS+=("$ip")
        done
    else
        exit 0
    fi
else
    msg_ok "Hittade ${#FOUND_CAMS[@]} kameror: ${FOUND_CAMS[*]}"
    if ! ask_yes_no "Vill du konfigurera dessa för Frigate?" "Y"; then
        exit 0
    fi
fi

CAM_PASSWORD=$(ask_string "Vilket lösenord vill du använda för Frigate-användaren på kamerorna?" "$CT_PASSWORD" "true")

echo -e "\n${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}VIKTIGT: GÖR DETTA PÅ VARJE KAMERA INNAN DU FORTSÄTTER${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "Logga in på varje kameras webbgränssnitt och gör följande:"
echo -e "\n1. ${BOLD}Skapa Användare:${NC}"
echo -e "   Gå till System -> Users. Skapa en Viewer/Operator-användare:"
echo -e "   - Användarnamn: ${GREEN}frigate${NC}"
echo -e "   - Lösenord: ${GREEN}$CAM_PASSWORD${NC}"
echo -e "\n2. ${BOLD}Skapa Stream-profiler:${NC}"
echo -e "   Gå till Video -> Stream profiles. Skapa två nya profiler:"
echo -e "   Profil 1 (för inspelning):"
echo -e "   - Namn: ${GREEN}main${NC}"
echo -e "   - Upplösning: Max (t.ex. 1920x1080)"
echo -e "   - Framerate: ${GREEN}15 fps${NC}"
echo -e "   - Komprimering: H.264 (Zipstream: Off/Low)"
echo -e "   Profil 2 (för detektering):"
echo -e "   - Namn: ${GREEN}detect${NC}"
echo -e "   - Upplösning: Låg (t.ex. 640x480 eller 800x600)"
echo -e "   - Framerate: ${GREEN}5 fps${NC}"
echo -e "   - Komprimering: H.264"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}\n"

ask_string "Tryck Enter när du har gjort detta på kamerorna..." ""

# Generera config
msg_info "Genererar Frigate config.yml..."
FRIGATE_CONFIG_TMP="/tmp/frigate_cameras.yml"
echo "cameras:" > $FRIGATE_CONFIG_TMP

for ip in "${FOUND_CAMS[@]}"; do
    CAM_NAME="kamera_${ip//./_}"
    CAM_NAME=$(ask_string "Namn för kamera på IP $ip (inga mellanslag)" "$CAM_NAME")
    
    cat >> $FRIGATE_CONFIG_TMP << EOF
  ${CAM_NAME}:
    ffmpeg:
      inputs:
        - path: rtsp://frigate:${CAM_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=main
          roles:
            - record
        - path: rtsp://frigate:${CAM_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=detect
          roles:
            - detect
    detect:
      width: 640
      height: 480
      fps: 5
EOF
    msg_ok "Genererade config för $CAM_NAME"
done

if pct status $IP_FRIGATE &>/dev/null; then
    msg_info "Pushar ny konfiguration till Frigate (CT $IP_FRIGATE)..."
    
    # Ladda ner befintlig config
    pct pull $IP_FRIGATE /opt/frigate/config/config.yml /tmp/frigate_base.yml 2>/dev/null || echo "mqtt: {enabled: False}" > /tmp/frigate_base.yml
    
    # Rensa gamla 'cameras:' sektionen
    sed -i '/^cameras:/,$d' /tmp/frigate_base.yml
    
    # Slå ihop
    cat /tmp/frigate_base.yml $FRIGATE_CONFIG_TMP > /tmp/frigate_final.yml
    
    pct push $IP_FRIGATE /tmp/frigate_final.yml /opt/frigate/config/config.yml
    
    msg_info "Startar om Frigate för att tillämpa kamerorna..."
    pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose restart" > /dev/null
    msg_ok "Frigate omstartad med nya kameror!"
else
    msg_warn "Frigate-containern (CT $IP_FRIGATE) verkar inte vara igång."
    msg_info "Konfigurationen har sparats i /tmp/frigate_cameras.yml"
fi

rm -f $FRIGATE_CONFIG_TMP /tmp/frigate_base.yml /tmp/frigate_final.yml
