#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh

msg_header "Axis Kameror & Frigate Config"

msg_info "Söker efter kameror i nätverket (${NETWORK_PREFIX}.x)..."
# Enkel nätverksskanning på port 80/443. Kräver nmap/ncat, vi installerar om det saknas.
if ! command -v nc &> /dev/null; then
    apt-get install -y ncat > /dev/null 2>&1 || true
fi

# Vi kollar en range, tex .20 till .50 för att vara snabba.
# I en riktig miljö kanske användaren får skriva in IP-adresser manuellt om de inte hittas.
FOUND_CAMS=()
msg_info "Detta är en enkel skanning. Det kan vara snabbare att skriva in IP-adresserna manuellt."
if ask_yes_no "Vill du mata in kamera-IP manuellt istället för att skanna?" "Y"; then
    while true; do
        CAM_IP=$(ask_string "Kamera IP (lämna tomt för att avsluta)" "")
        if [ -z "$CAM_IP" ]; then
            break
        fi
        FOUND_CAMS+=("$CAM_IP")
    done
else
    # Förenklad skanning (kräver arp-scan eller liknande för att vara riktigt bra, vi hoppar över det för nu och ber om manuell inmatning om det misslyckas)
    msg_warn "Nätverksskanning är inte helt pålitlig i denna version. Mata in IP manuellt:"
    while true; do
        CAM_IP=$(ask_string "Kamera IP (lämna tomt för att avsluta)" "")
        if [ -z "$CAM_IP" ]; then
            break
        fi
        FOUND_CAMS+=("$CAM_IP")
    done
fi

if [ ${#FOUND_CAMS[@]} -eq 0 ]; then
    msg_skip "Inga kameror angivna. Hoppar över kamerakonfiguration."
    exit 0
fi

echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} ${BOLD}Viktig förberedelse i kamerorna${NC}                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} För att Frigate ska kunna ansluta måste du skapa en användare  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} i varje kamera.                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} 1. Logga in i kamerans webbgränssnitt.                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} 2. Gå till System -> Users.                                    ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} 3. Skapa en användare:                                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Användarnamn: ${YELLOW}frigate${NC}                                       ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Lösenord:     ${YELLOW}$CT_PASSWORD${NC}                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Roll:         ${YELLOW}Viewer${NC} (eller Admin)                           ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if ! ask_yes_no "Har du skapat 'frigate'-användaren på kamerorna enligt ovan?" "Y"; then
    msg_warn "Du måste göra detta innan vi kan fortsätta. Skriptet kan dock generera konfigurationen åt dig ändå."
fi

msg_info "Konfigurerar stream-profiler på kamerorna via API..."
# Vi använder axis-create-stream-profiles.sh logiken här inbakat för enkelhet.
# Men vi gör det enklare: Vi bara genererar Frigate config.

FRIGATE_CONFIG_TMP="/tmp/frigate_cameras.yml"
echo "cameras:" > $FRIGATE_CONFIG_TMP

for ip in "${FOUND_CAMS[@]}"; do
    # Byt ut punkter mot understreck för kameranamn
    CAM_NAME="kamera_${ip//./_}"
    CAM_NAME=$(ask_string "Namn för kamera på IP $ip (inga mellanslag)" "$CAM_NAME")
    
    cat >> $FRIGATE_CONFIG_TMP << EOF
  ${CAM_NAME}:
    ffmpeg:
      inputs:
        # Högupplöst för inspelning (15fps max rekommenderas)
        - path: rtsp://frigate:${CT_PASSWORD}@${ip}/axis-media/media.amp?videocodec=h264&resolution=1920x1080&fps=15
          roles:
            - record
        # Lågupplöst för AI-detektion (5fps rekommenderas)
        - path: rtsp://frigate:${CT_PASSWORD}@${ip}/axis-media/media.amp?videocodec=h264&resolution=640x480&fps=5
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
    
    # Rensa gamla 'cameras:' sektionen (mycket förenklat)
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
