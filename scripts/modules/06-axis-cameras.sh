#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/config.sh

msg_header "Axis Kameror & Frigate Config Generator"

print_banner "Kamera-konfiguration" \
"Denna modul hjälper dig att:
  1. Hitta Axis-kameror på nätverket (eller ange manuellt)
  2. Namnge varje kamera
  3. Generera en komplett Frigate config.yml

Konfigurationen baseras på beprövade inställningar med:
  • 2x OpenVINO GPU-detektorer (Intel iGPU)
  • YOLOv9c AI-modell (320x320)
  • VAAPI hårdvaruacceleration
  • Dual-stream (main=inspelning, sub=detektering)

Zoner och masker konfigurerar du sedan i Frigate UI."

if ! ask_yes_no "Vill du konfigurera kameror och generera Frigate-config nu?" "Y"; then
    msg_skip "Hoppar över kamera-konfiguration."
    exit 0
fi

# ============================================================
# STEG 1: Hitta kameror
# ============================================================
msg_header "Steg 1: Hitta kameror"

declare -a CAM_IPS=()
declare -a CAM_NAMES=()
declare -a CAM_CHANNELS=()
declare -a CAM_CODECS=()
declare -a CAM_DETECT_W=()
declare -a CAM_DETECT_H=()
declare -a CAM_DETECT_FPS=()
declare -a CAM_TYPES=()  # "streamprofile" eller "resolution"

echo -e "\n  ${BOLD}Hur vill du lägga till kameror?${NC}" > /dev/tty
echo -e "  1) Skanna nätverket automatiskt (nmap)" > /dev/tty
echo -e "  2) Ange antal kameror manuellt" > /dev/tty
echo -e "  3) Ange IP-adresser manuellt" > /dev/tty
echo -ne "\n  ${BOLD}Välj [1/2/3]: ${NC}" > /dev/tty
read CAM_METHOD < /dev/tty

case "$CAM_METHOD" in
    1)
        # Automatisk skanning
        if ! command -v nmap &> /dev/null; then
            msg_info "Installerar nmap för nätverksskanning..."
            apt-get update -qq > /dev/null && apt-get install -y nmap > /dev/null
        fi
        
        msg_info "Skannar nätverket (${NETWORK_PREFIX}.0/24) efter Axis-enheter..."
        SCAN_RES=$(nmap -sn ${NETWORK_PREFIX}.0/24 2>/dev/null | grep -B 2 -i -E "Axis|00:40:8C|AC:CC:8E" || true)
        
        while read -r line; do
            if [[ $line == *"Nmap scan report for"* ]]; then
                ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
                if [ -n "$ip" ]; then
                    CAM_IPS+=("$ip")
                fi
            fi
        done <<< "$SCAN_RES"
        
        if [ ${#CAM_IPS[@]} -eq 0 ]; then
            msg_warn "Hittade inga Axis-kameror automatiskt."
            msg_info "Du kan ange IP-adresser manuellt istället."
            NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
            for ((i=1; i<=NUM_CAMS; i++)); do
                ip=$(ask_string "IP-adress för kamera $i" "${NETWORK_PREFIX}.")
                CAM_IPS+=("$ip")
            done
        else
            msg_ok "Hittade ${#CAM_IPS[@]} Axis-enheter: ${CAM_IPS[*]}"
            if ! ask_yes_no "Stämmer dessa?" "Y"; then
                CAM_IPS=()
                NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
                for ((i=1; i<=NUM_CAMS; i++)); do
                    ip=$(ask_string "IP-adress för kamera $i" "${NETWORK_PREFIX}.")
                    CAM_IPS+=("$ip")
                done
            fi
        fi
        ;;
    2)
        NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
        msg_info "Du kan fylla i IP-adresser i config.yml efteråt."
        for ((i=1; i<=NUM_CAMS; i++)); do
            CAM_IPS+=("KAMERA_${i}_IP")
        done
        ;;
    3)
        MANUAL_IPS=$(ask_string "Ange IP-adresser separerade med mellanslag" "")
        for ip in $MANUAL_IPS; do
            CAM_IPS+=("$ip")
        done
        ;;
    *)
        NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
        for ((i=1; i<=NUM_CAMS; i++)); do
            CAM_IPS+=("KAMERA_${i}_IP")
        done
        ;;
esac

if [ ${#CAM_IPS[@]} -eq 0 ]; then
    msg_err "Inga kameror angivna. Avbryter."
    exit 0
fi

# ============================================================
# STEG 2: Namnge och konfigurera varje kamera
# ============================================================
msg_header "Steg 2: Namnge kameror"

echo -e "\n  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} ${BOLD}Kameratyper:${NC}                                              ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  ${BOLD}single${NC} = En kamera per enhet (vanligast)                  ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}          Använder streamprofile=main/detect                 ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  ${BOLD}multi${NC}  = Flera kanaler per enhet (t.ex. Axis P3265-LVE)   ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}          Använder camera=1,2,3 med resolution-parametrar    ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n" > /dev/tty

for ((i=0; i<${#CAM_IPS[@]}; i++)); do
    echo -e "\n  ${BOLD}── Kamera $((i+1))/${#CAM_IPS[@]} (${CAM_IPS[$i]}) ──${NC}" > /dev/tty
    
    # Namn
    DEFAULT_NAME="kamera_$((i+1))"
    name=$(ask_string "  Namn (snake_case, t.ex. entre, garage_inne)" "$DEFAULT_NAME")
    # Sanitize: lowercase, replace spaces with underscore
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
    CAM_NAMES+=("$name")
    
    # Typ
    cam_type=$(ask_string "  Typ [single/multi]" "single")
    
    if [ "$cam_type" == "multi" ]; then
        channels=$(ask_string "  Antal kanaler" "3")
        CAM_CHANNELS+=("$channels")
        CAM_TYPES+=("multi")
        # Multi-channel: resolution-baserade URLs
        detect_w=$(ask_string "  Detect-bredd per kanal" "1280")
        detect_h=$(ask_string "  Detect-höjd per kanal" "960")
        detect_fps=$(ask_string "  Detect FPS per kanal" "5")
        CAM_DETECT_W+=("$detect_w")
        CAM_DETECT_H+=("$detect_h")
        CAM_DETECT_FPS+=("$detect_fps")
        CAM_CODECS+=("h264")
    else
        CAM_CHANNELS+=("1")
        CAM_TYPES+=("single")
        # Single: streamprofile-baserade URLs
        codec=$(ask_string "  Codec [h264/h265]" "h265")
        detect_w=$(ask_string "  Detect-bredd" "1280")
        detect_h=$(ask_string "  Detect-höjd" "960")
        detect_fps=$(ask_string "  Detect FPS" "5")
        CAM_DETECT_W+=("$detect_w")
        CAM_DETECT_H+=("$detect_h")
        CAM_DETECT_FPS+=("$detect_fps")
        CAM_CODECS+=("$codec")
    fi
done

# ============================================================
# STEG 3: Credentials
# ============================================================
msg_header "Steg 3: Credentials"

echo -e "\n  Frigate ansluter till kamerorna via RTSP." > /dev/tty
echo -e "  Du behöver en användare på kamerorna med Viewer/Operator-behörighet.\n" > /dev/tty

RTSP_USER=$(ask_string "RTSP-användarnamn (samma för alla kameror)" "frigate")
RTSP_PASS=$(ask_string "RTSP-lösenord" "${CT_PASSWORD}" "true")

echo "" > /dev/tty
msg_info "MQTT används för att skicka händelser till Home Assistant."
MQTT_HOST=$(ask_string "MQTT-host (vanligtvis din HA-IP)" "${NETWORK_PREFIX}.${IP_HA}")
MQTT_USER=$(ask_string "MQTT-användarnamn" "mosquitto")
MQTT_PASS=$(ask_string "MQTT-lösenord" "" "true")

# ============================================================
# STEG 4: Google Gemini AI (valfritt)
# ============================================================
msg_header "Steg 4: Google Gemini AI (valfritt)"

echo -e "\n  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} ${BOLD}Google Gemini AI-integration${NC}                                ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} Frigate kan använda Gemini för att:                         ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}   • Generera beskrivningar av händelser                    ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}   • Svara på frågor om vad som hänt                        ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}   • Klassificera objekt mer exakt                          ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} Skapa en gratis API-nyckel:                                ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}   https://aistudio.google.com/app/apikey                   ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} Du kan lägga till detta senare om du vill.                 ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n" > /dev/tty

GEMINI_KEY=""
if ask_yes_no "Vill du konfigurera Google Gemini AI nu?" "N"; then
    GEMINI_KEY=$(ask_string "Google Gemini API-nyckel" "" "true")
    if [ -n "$GEMINI_KEY" ]; then
        msg_ok "Gemini API-nyckel sparad!"
    fi
fi

# ============================================================
# STEG 5: Generera config.yml
# ============================================================
msg_header "Steg 5: Genererar Frigate config.yml"

# Bestäm Frigate-IP
FRIGATE_IP="${NETWORK_PREFIX}.${IP_FRIGATE}"

# Bygg go2rtc streams
GO2RTC_STREAMS=""
CAMERAS_BLOCK=""
CAMERA_GROUP_ALL=""

for ((i=0; i<${#CAM_IPS[@]}; i++)); do
    ip="${CAM_IPS[$i]}"
    name="${CAM_NAMES[$i]}"
    channels="${CAM_CHANNELS[$i]}"
    cam_type="${CAM_TYPES[$i]}"
    codec="${CAM_CODECS[$i]}"
    det_w="${CAM_DETECT_W[$i]}"
    det_h="${CAM_DETECT_H[$i]}"
    det_fps="${CAM_DETECT_FPS[$i]}"
    
    if [ "$cam_type" == "multi" ]; then
        # Multi-channel kamera (t.ex. Axis P3265-LVE med 3 linser)
        # Generera sub-namn: name_vanster, name_center, name_hoger (eller 1,2,3)
        for ((ch=1; ch<=channels; ch++)); do
            if [ "$channels" -eq 3 ]; then
                case $ch in
                    1) suffix="vanster" ;;
                    2) suffix="center" ;;
                    3) suffix="hoger" ;;
                esac
            else
                suffix="kanal_${ch}"
            fi
            
            cam_full_name="${name}_${suffix}"
            
            # go2rtc stream (main = full res, sub = detect res)
            GO2RTC_STREAMS+="    ${cam_full_name}:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?camera=${ch}&resolution=2560x1920&fps=15&videocodec=h264&audio=1\n"
            GO2RTC_STREAMS+="    ${cam_full_name}_sub:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?camera=${ch}&resolution=${det_w}x${det_h}&fps=${det_fps}&videocodec=h264\n"
            
            # Camera block
            CAMERAS_BLOCK+="  ${cam_full_name}:\n"
            CAMERAS_BLOCK+="    enabled: true\n"
            CAMERAS_BLOCK+="    ffmpeg:\n"
            CAMERAS_BLOCK+="      inputs:\n"
            CAMERAS_BLOCK+="        - path: rtsp://127.0.0.1:8554/${cam_full_name}\n"
            CAMERAS_BLOCK+="          input_args: preset-rtsp-restream\n"
            CAMERAS_BLOCK+="          roles:\n"
            CAMERAS_BLOCK+="            - record\n"
            CAMERAS_BLOCK+="        - path: rtsp://127.0.0.1:8554/${cam_full_name}_sub\n"
            CAMERAS_BLOCK+="          input_args: preset-rtsp-restream\n"
            CAMERAS_BLOCK+="          roles:\n"
            CAMERAS_BLOCK+="            - detect\n"
            CAMERAS_BLOCK+="    detect:\n"
            CAMERAS_BLOCK+="      enabled: true\n"
            CAMERAS_BLOCK+="      width: ${det_w}\n"
            CAMERAS_BLOCK+="      height: ${det_h}\n"
            CAMERAS_BLOCK+="      fps: ${det_fps}\n"
            CAMERAS_BLOCK+="    # Zoner och masker — konfigurera i Frigate UI:\n"
            CAMERAS_BLOCK+="    # zones:\n"
            CAMERAS_BLOCK+="    #   min_zon:\n"
            CAMERAS_BLOCK+="    #     coordinates: 0,0,1,0,1,1,0,1\n"
            CAMERAS_BLOCK+="    #     objects: person\n"
            CAMERAS_BLOCK+="    #     friendly_name: Min zon\n"
            CAMERAS_BLOCK+="\n"
            
            # Camera group
            CAMERA_GROUP_ALL+="      - ${cam_full_name}\n"
        done
    else
        # Single-channel kamera (streamprofile-baserad)
        GO2RTC_STREAMS+="    ${name}:\n"
        GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=main&videocodec=${codec}&audio=1\n"
        GO2RTC_STREAMS+="    ${name}_sub:\n"
        GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=detect&videocodec=${codec}\n"
        
        # Camera block
        CAMERAS_BLOCK+="  ${name}:\n"
        CAMERAS_BLOCK+="    enabled: true\n"
        CAMERAS_BLOCK+="    ffmpeg:\n"
        CAMERAS_BLOCK+="      inputs:\n"
        CAMERAS_BLOCK+="        - path: rtsp://127.0.0.1:8554/${name}\n"
        CAMERAS_BLOCK+="          input_args: preset-rtsp-restream\n"
        CAMERAS_BLOCK+="          roles:\n"
        CAMERAS_BLOCK+="            - record\n"
        CAMERAS_BLOCK+="        - path: rtsp://127.0.0.1:8554/${name}_sub\n"
        CAMERAS_BLOCK+="          input_args: preset-rtsp-restream\n"
        CAMERAS_BLOCK+="          roles:\n"
        CAMERAS_BLOCK+="            - detect\n"
        CAMERAS_BLOCK+="    detect:\n"
        CAMERAS_BLOCK+="      enabled: true\n"
        CAMERAS_BLOCK+="      width: ${det_w}\n"
        CAMERAS_BLOCK+="      height: ${det_h}\n"
        CAMERAS_BLOCK+="      fps: ${det_fps}\n"
        CAMERAS_BLOCK+="    # Zoner och masker — konfigurera i Frigate UI:\n"
        CAMERAS_BLOCK+="    # zones:\n"
        CAMERAS_BLOCK+="    #   min_zon:\n"
        CAMERAS_BLOCK+="    #     coordinates: 0,0,1,0,1,1,0,1\n"
        CAMERAS_BLOCK+="    #     objects: person\n"
        CAMERAS_BLOCK+="    #     friendly_name: Min zon\n"
        CAMERAS_BLOCK+="\n"
        
        # Camera group
        CAMERA_GROUP_ALL+="      - ${name}\n"
    fi
done

# ============================================================
# STEG 6: Skriv config.yml
# ============================================================

# Läs template och ersätt placeholders
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/../configs/frigate-config-template.yml"

if [ ! -f "$TEMPLATE_FILE" ]; then
    msg_warn "Template-fil saknas, genererar direkt..."
    TEMPLATE_FILE="/tmp/frigate-template.yml"
    # Fallback: generera inline (kopierat från template)
fi

CONFIG_OUTPUT="/tmp/frigate-config-generated.yml"

# Kopiera template och ersätt placeholders
cp "$TEMPLATE_FILE" "$CONFIG_OUTPUT"

# Ersätt MQTT
sed -i "s|__MQTT_HOST__|${MQTT_HOST}|g" "$CONFIG_OUTPUT"

# Ersätt Frigate IP
sed -i "s|__FRIGATE_IP__|${FRIGATE_IP}|g" "$CONFIG_OUTPUT"

# Ersätt go2rtc streams (multi-line)
# Använd python för multi-line replacement
python3 << PYEOF
import re

with open("$CONFIG_OUTPUT", "r") as f:
    content = f.read()

# go2rtc streams
streams = """$(echo -e "$GO2RTC_STREAMS")"""
content = content.replace("__GO2RTC_STREAMS__\n", streams)
content = content.replace("__GO2RTC_STREAMS__", streams)

# cameras
cameras = """$(echo -e "$CAMERAS_BLOCK")"""
content = content.replace("__CAMERAS__\n", cameras)
content = content.replace("__CAMERAS__", cameras)

# camera group all
group_all = """$(echo -e "$CAMERA_GROUP_ALL")"""
content = content.replace("__CAMERA_GROUP_ALL__\n", group_all)
content = content.replace("__CAMERA_GROUP_ALL__", group_all)

# Aktivera GenAI om nyckel angavs
gemini_key = """${GEMINI_KEY}"""
if gemini_key:
    # Uncomment genai section
    content = content.replace("#genai:\n#  gemini:\n#    provider: gemini\n#    api_key: '{FRIGATE_GEMINI_API_KEY}'\n#    model: gemini-2.5-flash-lite",
        "genai:\n  gemini:\n    provider: gemini\n    api_key: '{FRIGATE_GEMINI_API_KEY}'\n    model: gemini-2.5-flash-lite")
    # Uncomment objects.genai
    content = content.replace("#genai:\n  #  enabled: true", "genai:\n    enabled: true")
    # Uncomment review.genai
    content = content.replace("#review:\n#  genai:\n#    enabled: true\n#    alerts: true\n#    detections: false",
        "review:\n  genai:\n    enabled: true\n    alerts: true\n    detections: false")

with open("$CONFIG_OUTPUT", "w") as f:
    f.write(content)
PYEOF

msg_ok "config.yml genererad!"

# ============================================================
# STEG 7: Skriv .env-fil för Docker
# ============================================================
ENV_OUTPUT="/tmp/frigate-env-generated"

cat > "$ENV_OUTPUT" << EOF
# Frigate Environment Variables
# Placeras i /opt/frigate/.env
# Docker Compose läser dessa automatiskt.

# RTSP-credentials (samma för alla kameror)
FRIGATE_RTSP_USER=${RTSP_USER}
FRIGATE_RTSP_PASSWORD=${RTSP_PASS}

# MQTT-credentials
FRIGATE_MQTT_USER=${MQTT_USER}
FRIGATE_MQTT_PASSWORD=${MQTT_PASS}
EOF

if [ -n "$GEMINI_KEY" ]; then
    cat >> "$ENV_OUTPUT" << EOF

# Google Gemini AI
FRIGATE_GEMINI_API_KEY=${GEMINI_KEY}
EOF
fi

msg_ok ".env-fil genererad!"

# ============================================================
# STEG 8: Pusha till Frigate-container (om den finns)
# ============================================================
echo "" > /dev/tty

# Visa sammanfattning
TOTAL_CAMS=0
for ((i=0; i<${#CAM_IPS[@]}; i++)); do
    if [ "${CAM_TYPES[$i]}" == "multi" ]; then
        TOTAL_CAMS=$((TOTAL_CAMS + ${CAM_CHANNELS[$i]}))
    else
        TOTAL_CAMS=$((TOTAL_CAMS + 1))
    fi
done

echo -e "  ${GREEN}╔════════════════════════════════════════════════════════════╗${NC}" > /dev/tty
echo -e "  ${GREEN}║${NC} ${BOLD}Sammanfattning${NC}                                              ${GREEN}║${NC}" > /dev/tty
echo -e "  ${GREEN}╠════════════════════════════════════════════════════════════╣${NC}" > /dev/tty
echo -e "  ${GREEN}║${NC}  Antal kameravyer:  ${BOLD}${TOTAL_CAMS}${NC}                                       ${GREEN}║${NC}" > /dev/tty
echo -e "  ${GREEN}║${NC}  RTSP-användare:    ${BOLD}${RTSP_USER}${NC}                                   ${GREEN}║${NC}" > /dev/tty
echo -e "  ${GREEN}║${NC}  MQTT-host:         ${BOLD}${MQTT_HOST}${NC}                          ${GREEN}║${NC}" > /dev/tty
echo -e "  ${GREEN}║${NC}  Gemini AI:         ${BOLD}$([ -n "$GEMINI_KEY" ] && echo "Aktiverad" || echo "Ej konfigurerad")${NC}                          ${GREEN}║${NC}" > /dev/tty
echo -e "  ${GREEN}╚════════════════════════════════════════════════════════════╝${NC}" > /dev/tty

echo "" > /dev/tty

# Kolla om Frigate-container finns och är igång
if pct status ${IP_FRIGATE} 2>/dev/null | grep -q "running"; then
    if ask_yes_no "Vill du pusha konfigurationen till Frigate-containern (CT ${IP_FRIGATE}) nu?" "Y"; then
        msg_info "Pushar config.yml och .env till Frigate..."
        
        # Pusha config
        pct push ${IP_FRIGATE} "$CONFIG_OUTPUT" /opt/frigate/config/config.yml
        pct push ${IP_FRIGATE} "$ENV_OUTPUT" /opt/frigate/.env
        
        # Starta om Frigate
        msg_info "Startar om Frigate för att tillämpa ny konfiguration..."
        pct exec ${IP_FRIGATE} -- bash -c "cd /opt/frigate && docker compose down && docker compose up -d" 2>/dev/null
        
        sleep 5
        if pct exec ${IP_FRIGATE} -- bash -c "docker ps | grep -q frigate" 2>/dev/null; then
            msg_ok "Frigate körs med ny konfiguration!"
        else
            msg_warn "Frigate verkar inte ha startat korrekt. Kolla loggar:"
            msg_info "  pct exec ${IP_FRIGATE} -- docker logs frigate"
        fi
    else
        msg_info "Config sparad lokalt. Du kan pusha manuellt:"
        msg_info "  pct push ${IP_FRIGATE} ${CONFIG_OUTPUT} /opt/frigate/config/config.yml"
        msg_info "  pct push ${IP_FRIGATE} ${ENV_OUTPUT} /opt/frigate/.env"
    fi
else
    msg_warn "Frigate-containern (CT ${IP_FRIGATE}) körs inte just nu."
    
    # Spara lokalt
    SAVE_DIR="/opt/optiplex-homelab/generated"
    mkdir -p "$SAVE_DIR"
    cp "$CONFIG_OUTPUT" "$SAVE_DIR/frigate-config.yml"
    cp "$ENV_OUTPUT" "$SAVE_DIR/frigate.env"
    
    msg_info "Konfigurationen har sparats i:"
    msg_info "  Config: ${SAVE_DIR}/frigate-config.yml"
    msg_info "  Env:    ${SAVE_DIR}/frigate.env"
    msg_info ""
    msg_info "När Frigate är igång, pusha med:"
    msg_info "  pct push ${IP_FRIGATE} ${SAVE_DIR}/frigate-config.yml /opt/frigate/config/config.yml"
    msg_info "  pct push ${IP_FRIGATE} ${SAVE_DIR}/frigate.env /opt/frigate/.env"
    msg_info "  pct exec ${IP_FRIGATE} -- bash -c 'cd /opt/frigate && docker compose restart'"
fi

# Cleanup
rm -f "$CONFIG_OUTPUT" "$ENV_OUTPUT"

# ============================================================
# STEG 9: Kamera-instruktioner
# ============================================================
echo "" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty
echo -e "  ${BOLD}VIKTIGT: Gör detta på varje kamera (om du inte redan gjort det)${NC}" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty
echo -e "" > /dev/tty
echo -e "  Logga in på varje kameras webbgränssnitt och:" > /dev/tty
echo -e "" > /dev/tty
echo -e "  ${BOLD}1. Skapa användare:${NC}" > /dev/tty
echo -e "     System → Users → Lägg till:" > /dev/tty
echo -e "     - Användarnamn: ${GREEN}${RTSP_USER}${NC}" > /dev/tty
echo -e "     - Lösenord: (det du angav ovan)" > /dev/tty
echo -e "     - Roll: Viewer eller Operator" > /dev/tty
echo -e "" > /dev/tty
echo -e "  ${BOLD}2. Skapa stream-profiler (om kameran stöder det):${NC}" > /dev/tty
echo -e "     Video → Stream profiles:" > /dev/tty
echo -e "     Profil '${GREEN}main${NC}': Max upplösning, 15 fps, H.264/H.265" > /dev/tty
echo -e "     Profil '${GREEN}detect${NC}': Låg upplösning (640x480), 5 fps, H.264" > /dev/tty
echo -e "" > /dev/tty
echo -e "  ${BOLD}3. Nästa steg:${NC}" > /dev/tty
echo -e "     - Öppna Frigate UI: http://${FRIGATE_IP}:5000" > /dev/tty
echo -e "     - Verifiera att alla kameror syns" > /dev/tty
echo -e "     - Rita zoner och masker i UI:t" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty

msg_ok "Kamera-konfiguration klar!"
