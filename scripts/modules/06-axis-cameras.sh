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
msg_info "Genererar komplett Frigate config.yml..."
FRIGATE_CONFIG_TMP="/tmp/frigate_cameras.yml"

# Skapa den kompletta mallen
cat << EOF > $FRIGATE_CONFIG_TMP
# ==========================================
# Frigate Huvudkonfiguration
# ==========================================

mqtt:
  enabled: true
  host: ${NETWORK_PREFIX}.${IP_HA}
  user: mqtt_user
  password: mqtt_password

# Aktivera OpenVINO för iGPU
detectors:
  ov_0:
    type: openvino
    device: GPU

model:
  model_type: yolo-generic
  input_tensor: nchw
  input_dtype: float
  labelmap_path: /config/model_cache/coco-80.txt
  path: /config/model_cache/yolov9c_openvino.xml
  width: 320
  height: 320

ffmpeg:
  hwaccel_args: preset-vaapi

# Objekt att spåra
objects:
  track:
    - person
    - bicycle
    - car
    - cat
    - dog
  filters:
    person:
      min_score: 0.5
      threshold: 0.7

# Generella inspelningsinställningar
record:
  enabled: true
  alerts:
    pre_capture: 5
    post_capture: 5
    retain:
      days: 30
      mode: active_objects
  detections:
    pre_capture: 5
    post_capture: 5
    retain:
      days: 7
      mode: active_objects

snapshots:
  enabled: true
  retain:
    default: 30

ui:
  time_format: 24hour

go2rtc:
  streams:
EOF

# Lägg till go2rtc streams
for ip in "${FOUND_CAMS[@]}"; do
    CAM_NAME="kamera_${ip//./_}"
    # Vi sätter default namn till ip:n men låter användaren ändra
    # För att inte bomba användaren med prompts, sätter vi namnet automatiskt
    # om de inte kör wizarden interaktivt. Här frågar vi bara en gång.
    cat << EOF >> $FRIGATE_CONFIG_TMP
    ${CAM_NAME}:
      - rtsp://frigate:${CAM_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=main&videocodec=h264
    ${CAM_NAME}_sub:
      - rtsp://frigate:${CAM_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=detect&videocodec=h264
EOF
done

# Lägg till kamerorna
cat << EOF >> $FRIGATE_CONFIG_TMP

cameras:
EOF

for ip in "${FOUND_CAMS[@]}"; do
    CAM_NAME="kamera_${ip//./_}"
    cat << EOF >> $FRIGATE_CONFIG_TMP
  ${CAM_NAME}:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/${CAM_NAME}
          input_args: preset-rtsp-restream
          roles:
            - record
        - path: rtsp://127.0.0.1:8554/${CAM_NAME}_sub
          input_args: preset-rtsp-restream
          roles:
            - detect
    detect:
      enabled: true
      width: 640
      height: 480
      fps: 5
EOF
done

msg_ok "Komplett config genererad!"

if pct status $IP_FRIGATE &>/dev/null; then
    msg_info "Pushar ny konfiguration till Frigate (CT $IP_FRIGATE)..."
    
    pct push $IP_FRIGATE $FRIGATE_CONFIG_TMP /opt/frigate/config/config.yml
    
    msg_info "Startar om Frigate för att tillämpa inställningarna..."
    pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose restart" > /dev/null
    msg_ok "Frigate omstartad med komplett config!"
else
    msg_warn "Frigate-containern (CT $IP_FRIGATE) verkar inte vara igång."
    msg_info "Konfigurationen har sparats i /tmp/frigate_cameras.yml"
fi

rm -f $FRIGATE_CONFIG_TMP
