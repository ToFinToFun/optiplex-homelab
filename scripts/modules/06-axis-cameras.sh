#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/config.sh

msg_header "Axis Kameror & Frigate Config Generator"

# ============================================================
# PRE-CHECK: Verifiera att Frigate-containern existerar
# ============================================================
FRIGATE_READY=false
FRIGATE_IP="${NETWORK_PREFIX}.${IP_FRIGATE}"

if pct status ${IP_FRIGATE} 2>/dev/null | grep -q "running"; then
    # Kolla att Docker finns i containern
    if pct exec ${IP_FRIGATE} -- docker --version &>/dev/null; then
        FRIGATE_READY=true
        msg_ok "Frigate-container (CT ${IP_FRIGATE}) körs med Docker"
    else
        msg_warn "Frigate-container körs men Docker saknas inuti!"
        msg_info "Config genereras och sparas lokalt. Pusha manuellt efter Docker-installation."
    fi
elif pct status ${IP_FRIGATE} &>/dev/null; then
    msg_warn "Frigate-container (CT ${IP_FRIGATE}) finns men är stoppad."
    msg_info "Config genereras och sparas lokalt. Starta containern och pusha sedan."
else
    msg_warn "Frigate-container (CT ${IP_FRIGATE}) finns INTE."
    msg_info "Config genereras och sparas lokalt. Kör modul 05 (Frigate) först."
fi

# ============================================================
# SKYDD MOT DUBBLA KÖRNINGAR
# ============================================================
EXISTING_CONFIG=""
if [ "$FRIGATE_READY" == "true" ]; then
    # Kolla om config redan finns i containern
    if pct exec ${IP_FRIGATE} -- test -f /opt/frigate/config/config.yml 2>/dev/null; then
        # Kolla om det är mer än dummy-config
        CAMERA_COUNT=$(pct exec ${IP_FRIGATE} -- grep -c "^  [a-z]" /opt/frigate/config/config.yml 2>/dev/null || echo "0")
        if [ "$CAMERA_COUNT" -gt 1 ]; then
            EXISTING_CONFIG="true"
        fi
    fi
fi

if [ -f "/opt/optiplex-homelab/generated/frigate-config.yml" ] || [ "$EXISTING_CONFIG" == "true" ]; then
    echo "" > /dev/tty
    msg_warn "En Frigate-konfiguration finns redan!"
    echo "" > /dev/tty
    echo -e "  ${BOLD}Vad vill du göra?${NC}" > /dev/tty
    echo -e "  1) Generera ny config från scratch (skriver över — zoner/masker försvinner!)" > /dev/tty
    echo -e "  2) Uppdatera credentials (RTSP/MQTT/Gemini — behåller kameror & zoner)" > /dev/tty
    echo -e "  3) Avbryt (behåll allt som det är)" > /dev/tty
    echo -ne "\n  ${BOLD}Välj [1/2/3]: ${NC}" > /dev/tty
    read OVERWRITE_CHOICE < /dev/tty
    
    case "$OVERWRITE_CHOICE" in
        1)
            # Backup befintlig config
            if [ "$FRIGATE_READY" == "true" ] && [ "$EXISTING_CONFIG" == "true" ]; then
                BACKUP_NAME="config.yml.backup.$(date +%Y%m%d_%H%M%S)"
                pct exec ${IP_FRIGATE} -- cp /opt/frigate/config/config.yml "/opt/frigate/config/${BACKUP_NAME}" 2>/dev/null
                msg_ok "Backup skapad: /opt/frigate/config/${BACKUP_NAME}"
            fi
            # Fortsätt med full regenerering nedan
            ;;
        2)
            # UPPDATERA CREDENTIALS ONLY
            msg_info "Uppdaterar credentials i befintlig config..."
            echo "" > /dev/tty
            echo -e "  ${CYAN}Ange nya credentials (Enter = behåll befintligt värde):${NC}" > /dev/tty
            echo "" > /dev/tty
            
            NEW_RTSP_USER=$(ask_string "RTSP-användarnamn" "${SERVICE_USER:-frigate}")
            NEW_RTSP_PASS=$(ask_string "RTSP-lösenord" "${SHARED_PASSWORD}" "true")
            NEW_MQTT_USER=$(ask_string "MQTT-användarnamn" "${SERVICE_USER:-frigate}")
            NEW_MQTT_PASS=$(ask_string "MQTT-lösenord" "${SHARED_PASSWORD}" "true")
            
            GEMINI_UPDATE=""
            if ask_yes_no "Uppdatera Google Gemini API-nyckel?" "N"; then
                GEMINI_UPDATE=$(ask_string "Ny Gemini API-nyckel" "" "true")
            fi
            
            # Skriv uppdaterad .env
            ENV_TARGET=""
            if [ "$FRIGATE_READY" == "true" ]; then
                ENV_TARGET="/tmp/frigate-env-update"
            else
                ENV_TARGET="/opt/optiplex-homelab/generated/frigate.env"
            fi
            
            cat > "$ENV_TARGET" << EOF
# Frigate Environment Variables (uppdaterad $(date +%Y-%m-%d))
FRIGATE_RTSP_USER=${NEW_RTSP_USER}
FRIGATE_RTSP_PASSWORD=${NEW_RTSP_PASS}
FRIGATE_MQTT_USER=${NEW_MQTT_USER}
FRIGATE_MQTT_PASSWORD=${NEW_MQTT_PASS}
EOF
            
            if [ -n "$GEMINI_UPDATE" ]; then
                echo "FRIGATE_GEMINI_API_KEY=${GEMINI_UPDATE}" >> "$ENV_TARGET"
            elif [ "$FRIGATE_READY" == "true" ]; then
                # Behåll befintlig Gemini-nyckel om den finns
                OLD_GEMINI=$(pct exec ${IP_FRIGATE} -- grep "FRIGATE_GEMINI_API_KEY" /opt/frigate/.env 2>/dev/null | cut -d= -f2)
                [ -n "$OLD_GEMINI" ] && echo "FRIGATE_GEMINI_API_KEY=${OLD_GEMINI}" >> "$ENV_TARGET"
            fi
            
            if [ "$FRIGATE_READY" == "true" ]; then
                pct push ${IP_FRIGATE} "$ENV_TARGET" /opt/frigate/.env
                rm -f "$ENV_TARGET"
                
                # Starta om Frigate för att läsa nya credentials
                msg_info "Startar om Frigate..."
                pct exec ${IP_FRIGATE} -- bash -c "cd /opt/frigate && docker compose down && docker compose up -d" 2>/dev/null
                sleep 5
                if pct exec ${IP_FRIGATE} -- bash -c "docker ps | grep -q frigate" 2>/dev/null; then
                    msg_ok "Frigate körs med uppdaterade credentials!"
                else
                    msg_warn "Frigate verkar inte ha startat. Kolla loggar:"
                    msg_info "  pct exec ${IP_FRIGATE} -- docker logs frigate --tail 20"
                fi
            else
                msg_ok "Credentials sparade lokalt: $ENV_TARGET"
                msg_info "Pusha till Frigate när containern är igång."
            fi
            
            msg_ok "Credentials uppdaterade!"
            exit 0
            ;;
        *)
            msg_skip "Behåller befintlig konfiguration."
            msg_info "Tips: Redigera config direkt i Frigate UI eller via:"
            msg_info "  pct exec ${IP_FRIGATE} -- nano /opt/frigate/config/config.yml"
            exit 0
            ;;
    esac
fi

# ============================================================
# BANNER
# ============================================================
print_banner "Kamera-konfiguration" \
"Denna modul hjälper dig att:
  1. Hitta kameror på nätverket (eller ange manuellt)
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
# STEG 1: Kameratyp
# ============================================================
msg_header "Steg 1: Kameratyp"

echo -e "\n  ${BOLD}Vilken typ av kameror har du?${NC}" > /dev/tty
echo -e "  1) Axis (rekommenderat — dual stream profiles)" > /dev/tty
echo -e "  2) Annat märke (Hikvision, Dahua, Reolink, etc.)" > /dev/tty
echo -e "  3) Blandat (Axis + andra)" > /dev/tty
echo -ne "\n  ${BOLD}Välj [1/2/3]: ${NC}" > /dev/tty
read CAM_BRAND < /dev/tty
CAM_BRAND="${CAM_BRAND:-1}"

if [ "$CAM_BRAND" == "2" ] || [ "$CAM_BRAND" == "3" ]; then
    echo "" > /dev/tty
    msg_info "För icke-Axis-kameror genereras generiska RTSP-URLs."
    msg_info "Du behöver fylla i rätt RTSP-path för ditt kameramärke i config.yml efteråt."
    echo -e "  ${DIM}Vanliga RTSP-paths:${NC}" > /dev/tty
    echo -e "  ${DIM}  Hikvision: /Streaming/Channels/101 (main), /Streaming/Channels/102 (sub)${NC}" > /dev/tty
    echo -e "  ${DIM}  Dahua:     /cam/realmonitor?channel=1&subtype=0 (main), subtype=1 (sub)${NC}" > /dev/tty
    echo -e "  ${DIM}  Reolink:   /h264Preview_01_main (main), /h264Preview_01_sub (sub)${NC}" > /dev/tty
    echo "" > /dev/tty
fi

# ============================================================
# STEG 2: Hitta kameror
# ============================================================
msg_header "Steg 2: Hitta kameror"

declare -a CAM_IPS=()
declare -a CAM_NAMES=()
declare -a CAM_CHANNELS=()
declare -a CAM_CODECS=()
declare -a CAM_DETECT_W=()
declare -a CAM_DETECT_H=()
declare -a CAM_DETECT_FPS=()
declare -a CAM_TYPES=()
declare -a CAM_BRANDS=()

echo -e "\n  ${BOLD}Hur vill du lägga till kameror?${NC}" > /dev/tty
echo -e "  1) Skanna nätverket automatiskt (nmap)" > /dev/tty
echo -e "  2) Ange antal kameror (fyll i IP senare i config)" > /dev/tty
echo -e "  3) Ange IP-adresser manuellt" > /dev/tty
echo -ne "\n  ${BOLD}Välj [1/2/3]: ${NC}" > /dev/tty
read CAM_METHOD < /dev/tty

case "$CAM_METHOD" in
    1)
        # Automatisk skanning — installera nmap om det saknas
        if ! command -v nmap &> /dev/null; then
            msg_info "nmap behövs för nätverksskanning. Installerar..."
            if apt-get update -qq > /dev/null 2>&1 && apt-get install -y nmap > /dev/null 2>&1; then
                msg_ok "nmap installerat"
            else
                msg_warn "Kunde inte installera nmap automatiskt."
                msg_info "Installera manuellt: apt install nmap"
                msg_info "Byter till manuell inmatning istället."
                CAM_METHOD="2"
            fi
        fi
        
        if [ "$CAM_METHOD" == "1" ]; then
            msg_info "Skannar nätverket (${NETWORK_PREFIX}.0/24)..."
            msg_info "Letar efter kameror (Axis MAC: 00:40:8C, AC:CC:8E)..."
            SCAN_RES=$(nmap -sn ${NETWORK_PREFIX}.0/24 2>/dev/null | grep -B 2 -i -E "Axis|00:40:8C|AC:CC:8E|camera|ipcam" || true)
            
            while read -r line; do
                if [[ $line == *"Nmap scan report for"* ]]; then
                    ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
                    if [ -n "$ip" ]; then
                        CAM_IPS+=("$ip")
                    fi
                fi
            done <<< "$SCAN_RES"
            
            if [ ${#CAM_IPS[@]} -eq 0 ]; then
                msg_warn "Hittade inga kameror automatiskt."
                msg_info "Möjliga orsaker: kamerorna är på annat VLAN, eller MAC-filter matchar inte."
                msg_info "Du kan ange IP-adresser manuellt istället."
                NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
                for ((i=1; i<=NUM_CAMS; i++)); do
                    ip=$(ask_string "IP-adress för kamera $i" "${NETWORK_PREFIX}.")
                    CAM_IPS+=("$ip")
                done
            else
                msg_ok "Hittade ${#CAM_IPS[@]} kameror: ${CAM_IPS[*]}"
                if ! ask_yes_no "Stämmer dessa?" "Y"; then
                    CAM_IPS=()
                    NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
                    for ((i=1; i<=NUM_CAMS; i++)); do
                        ip=$(ask_string "IP-adress för kamera $i" "${NETWORK_PREFIX}.")
                        CAM_IPS+=("$ip")
                    done
                fi
            fi
        fi
        ;;&  # Fall through to check if we switched to method 2
    2)
        if [ ${#CAM_IPS[@]} -eq 0 ]; then
            NUM_CAMS=$(ask_string "Hur många kameror har du?" "4")
            msg_info "IP-adresser sätts som placeholders — fyll i dem i config.yml efteråt."
            for ((i=1; i<=NUM_CAMS; i++)); do
                CAM_IPS+=("KAMERA_${i}_IP")
            done
        fi
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
# STEG 3: Namnge och konfigurera varje kamera
# ============================================================
msg_header "Steg 3: Namnge kameror"

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
    
    # Brand per kamera (om blandat)
    if [ "$CAM_BRAND" == "3" ]; then
        brand=$(ask_string "  Märke [axis/other]" "axis")
    elif [ "$CAM_BRAND" == "2" ]; then
        brand="other"
    else
        brand="axis"
    fi
    CAM_BRANDS+=("$brand")
    
    # Typ
    cam_type=$(ask_string "  Typ [single/multi]" "single")
    
    if [ "$cam_type" == "multi" ]; then
        channels=$(ask_string "  Antal kanaler" "3")
        CAM_CHANNELS+=("$channels")
        CAM_TYPES+=("multi")
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
# STEG 4: Credentials
# ============================================================
msg_header "Steg 4: Credentials"

echo -e "\n  Frigate ansluter till kamerorna via RTSP." > /dev/tty
echo -e "  Du behöver en användare på kamerorna med Viewer/Operator-behörighet.\n" > /dev/tty

RTSP_USER=$(ask_string "RTSP-användarnamn (samma för alla kameror)" "${SERVICE_USER:-frigate}")
RTSP_PASS=$(ask_string "RTSP-lösenord" "${SHARED_PASSWORD}" "true")

echo "" > /dev/tty
echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC} ${BOLD}MQTT — Frigate → Home Assistant${NC}                             ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  MQTT-brokern (Mosquitto) körs som add-on i HA.            ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  Om HA inte är klar ännu: ange credentials nu, konfigurera ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  Mosquitto i HA senare. Frigate startar ändå men loggar     ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}║${NC}  'MQTT connection failed' tills brokern är igång.           ${CYAN}║${NC}" > /dev/tty
echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}" > /dev/tty
echo "" > /dev/tty

MQTT_HOST=$(ask_string "MQTT-host (din HA-IP, Mosquitto körs där)" "${NETWORK_PREFIX}.${IP_HA}")
MQTT_USER=$(ask_string "MQTT-användarnamn (skapa denna i HA → Användare)" "${SERVICE_USER:-frigate}")
MQTT_PASS=$(ask_string "MQTT-lösenord (samma som du sätter i HA)" "${SHARED_PASSWORD}" "true")

# Testa MQTT-anslutning om möjligt
MQTT_STATUS="unknown"
if command -v nc &>/dev/null && [[ "$MQTT_HOST" != *"_IP"* ]]; then
    if nc -z -w 2 "$MQTT_HOST" 1883 2>/dev/null; then
        msg_ok "MQTT-broker svarar på ${MQTT_HOST}:1883"
        MQTT_STATUS="reachable"
    else
        msg_warn "MQTT-broker svarar INTE på ${MQTT_HOST}:1883"
        msg_info "Detta är normalt om HA/Mosquitto inte är installerat ännu."
        msg_info "Frigate startar ändå — MQTT ansluts när brokern är igång."
        MQTT_STATUS="unreachable"
    fi
fi

# ============================================================
# STEG 5: Google Gemini AI (valfritt)
# ============================================================
msg_header "Steg 5: Google Gemini AI (valfritt)"

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
# STEG 6: Generera config.yml
# ============================================================
msg_header "Steg 6: Genererar Frigate config.yml"

# Bygg go2rtc streams och camera blocks
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
    brand="${CAM_BRANDS[$i]}"
    
    if [ "$cam_type" == "multi" ]; then
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
            
            GO2RTC_STREAMS+="    ${cam_full_name}:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?camera=${ch}&resolution=2560x1920&fps=15&videocodec=h264&audio=1\n"
            GO2RTC_STREAMS+="    ${cam_full_name}_sub:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?camera=${ch}&resolution=${det_w}x${det_h}&fps=${det_fps}&videocodec=h264\n"
            
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
            CAMERAS_BLOCK+="    # Zoner och masker — konfigurera i Frigate UI\n"
            CAMERAS_BLOCK+="    # zones:\n"
            CAMERAS_BLOCK+="    #   min_zon:\n"
            CAMERAS_BLOCK+="    #     coordinates: 0,0,1,0,1,1,0,1\n"
            CAMERAS_BLOCK+="    #     objects:\n"
            CAMERAS_BLOCK+="    #       - person\n"
            CAMERAS_BLOCK+="\n"
            CAMERA_GROUP_ALL+="      - ${cam_full_name}\n"
        done
    else
        # Single-channel
        if [ "$brand" == "axis" ]; then
            # Axis: streamprofile-baserade URLs
            GO2RTC_STREAMS+="    ${name}:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=main&videocodec=${codec}&audio=1\n"
            GO2RTC_STREAMS+="    ${name}_sub:\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/axis-media/media.amp?streamprofile=detect&videocodec=${codec}\n"
        else
            # Generisk: placeholder-URLs som användaren fyller i
            GO2RTC_STREAMS+="    ${name}:  # BYT RTSP-PATH till rätt för ditt kameramärke\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/MAIN_STREAM_PATH\n"
            GO2RTC_STREAMS+="    ${name}_sub:  # BYT RTSP-PATH\n"
            GO2RTC_STREAMS+="      - rtsp://\${FRIGATE_RTSP_USER}:\${FRIGATE_RTSP_PASSWORD}@${ip}/SUB_STREAM_PATH\n"
        fi
        
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
        CAMERAS_BLOCK+="    # Zoner och masker — konfigurera i Frigate UI\n"
        CAMERAS_BLOCK+="    # zones:\n"
        CAMERAS_BLOCK+="    #   min_zon:\n"
        CAMERAS_BLOCK+="    #     coordinates: 0,0,1,0,1,1,0,1\n"
        CAMERAS_BLOCK+="    #     objects:\n"
        CAMERAS_BLOCK+="    #       - person\n"
        CAMERAS_BLOCK+="\n"
        CAMERA_GROUP_ALL+="      - ${name}\n"
    fi
done

# ============================================================
# STEG 7: Skriv config.yml från template
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/../configs/frigate-config-template.yml"

if [ ! -f "$TEMPLATE_FILE" ]; then
    msg_err "Template-fil saknas: $TEMPLATE_FILE"
    msg_info "Kontrollera att repot är komplett. Kör: git pull"
    exit 1
fi

CONFIG_OUTPUT="/tmp/frigate-config-generated.yml"
cp "$TEMPLATE_FILE" "$CONFIG_OUTPUT"

# Ersätt placeholders
sed -i "s|__MQTT_HOST__|${MQTT_HOST}|g" "$CONFIG_OUTPUT"
sed -i "s|__FRIGATE_IP__|${FRIGATE_IP}|g" "$CONFIG_OUTPUT"

# Multi-line replacement via python
python3 << PYEOF
import sys

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
if gemini_key.strip():
    content = content.replace("#genai:", "genai:")
    content = content.replace("#  gemini:", "  gemini:")
    content = content.replace("#    provider: gemini", "    provider: gemini")
    content = content.replace("#    api_key: '{FRIGATE_GEMINI_API_KEY}'", "    api_key: '{FRIGATE_GEMINI_API_KEY}'")
    content = content.replace("#    model: gemini-2.5-flash-lite", "    model: gemini-2.5-flash-lite")

# Lägg till MQTT-statuskommentar
mqtt_status = "$MQTT_STATUS"
if mqtt_status == "unreachable":
    mqtt_comment = "# OBS: MQTT-broker svarade inte vid konfiguration.\\n# Installera Mosquitto i HA och skapa användare '$MQTT_USER' med samma lösenord.\\n# Frigate loggar 'MQTT connection failed' tills brokern är igång.\\n"
    content = content.replace("mqtt:\\n", mqtt_comment + "mqtt:\\n", 1)

with open("$CONFIG_OUTPUT", "w") as f:
    f.write(content)
PYEOF

msg_ok "config.yml genererad!"

# ============================================================
# STEG 8: Skriv .env-fil
# ============================================================
ENV_OUTPUT="/tmp/frigate-env-generated"

cat > "$ENV_OUTPUT" << EOF
# Frigate Environment Variables
# Placeras i /opt/frigate/.env
# Docker Compose läser dessa automatiskt.
# ────────────────────────────────────────────

# RTSP-credentials (samma för alla kameror)
FRIGATE_RTSP_USER=${RTSP_USER}
FRIGATE_RTSP_PASSWORD=${RTSP_PASS}

# MQTT-credentials (Mosquitto i Home Assistant)
# Skapa denna användare i HA: Inställningar → Personer → Användare
FRIGATE_MQTT_USER=${MQTT_USER}
FRIGATE_MQTT_PASSWORD=${MQTT_PASS}
EOF

if [ -n "$GEMINI_KEY" ]; then
    cat >> "$ENV_OUTPUT" << EOF

# Google Gemini AI (genererar händelsebeskrivningar)
FRIGATE_GEMINI_API_KEY=${GEMINI_KEY}
EOF
fi

msg_ok ".env-fil genererad!"

# ============================================================
# STEG 9: Pusha till Frigate-container (om den är redo)
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
printf "  ${GREEN}║${NC}  Antal kameravyer:  ${BOLD}%-38s${NC} ${GREEN}║${NC}\n" "$TOTAL_CAMS" > /dev/tty
printf "  ${GREEN}║${NC}  RTSP-användare:    ${BOLD}%-38s${NC} ${GREEN}║${NC}\n" "$RTSP_USER" > /dev/tty
printf "  ${GREEN}║${NC}  MQTT-host:         ${BOLD}%-38s${NC} ${GREEN}║${NC}\n" "$MQTT_HOST" > /dev/tty
printf "  ${GREEN}║${NC}  MQTT-status:       ${BOLD}%-38s${NC} ${GREEN}║${NC}\n" "$([ "$MQTT_STATUS" == "reachable" ] && echo "Ansluten" || echo "Ej nåbar (konfigureras i HA)")" > /dev/tty
printf "  ${GREEN}║${NC}  Gemini AI:         ${BOLD}%-38s${NC} ${GREEN}║${NC}\n" "$([ -n "$GEMINI_KEY" ] && echo "Aktiverad" || echo "Ej konfigurerad")" > /dev/tty
echo -e "  ${GREEN}╚════════════════════════════════════════════════════════════╝${NC}" > /dev/tty

echo "" > /dev/tty

if [ "$FRIGATE_READY" == "true" ]; then
    if ask_yes_no "Vill du pusha konfigurationen till Frigate-containern (CT ${IP_FRIGATE}) nu?" "Y"; then
        msg_info "Pushar config.yml och .env till Frigate..."
        
        pct push ${IP_FRIGATE} "$CONFIG_OUTPUT" /opt/frigate/config/config.yml
        pct push ${IP_FRIGATE} "$ENV_OUTPUT" /opt/frigate/.env
        
        # Starta om Frigate
        msg_info "Startar om Frigate för att tillämpa ny konfiguration..."
        pct exec ${IP_FRIGATE} -- bash -c "cd /opt/frigate && docker compose down && docker compose up -d" 2>/dev/null
        
        sleep 5
        if pct exec ${IP_FRIGATE} -- bash -c "docker ps | grep -q frigate" 2>/dev/null; then
            msg_ok "Frigate körs med ny konfiguration!"
            
            # MQTT-status varning
            if [ "$MQTT_STATUS" == "unreachable" ]; then
                echo "" > /dev/tty
                msg_warn "MQTT-broker är inte nåbar ännu."
                msg_info "Frigate fungerar lokalt men skickar INTE händelser till HA."
                msg_info "Åtgärd: Installera Mosquitto add-on i HA och skapa användare '${MQTT_USER}'."
                msg_info "Frigate ansluter automatiskt när brokern startar."
            fi
        else
            msg_warn "Frigate verkar inte ha startat korrekt. Kolla loggar:"
            msg_info "  pct exec ${IP_FRIGATE} -- docker logs frigate --tail 50"
        fi
    else
        msg_info "Config sparad lokalt. Du kan pusha manuellt:"
        msg_info "  pct push ${IP_FRIGATE} ${CONFIG_OUTPUT} /opt/frigate/config/config.yml"
        msg_info "  pct push ${IP_FRIGATE} ${ENV_OUTPUT} /opt/frigate/.env"
    fi
else
    # Spara lokalt
    SAVE_DIR="/opt/optiplex-homelab/generated"
    mkdir -p "$SAVE_DIR"
    cp "$CONFIG_OUTPUT" "$SAVE_DIR/frigate-config.yml"
    cp "$ENV_OUTPUT" "$SAVE_DIR/frigate.env"
    
    msg_ok "Konfigurationen har sparats lokalt:"
    msg_info "  Config: ${SAVE_DIR}/frigate-config.yml"
    msg_info "  Env:    ${SAVE_DIR}/frigate.env"
    msg_info ""
    msg_info "När Frigate-containern är igång, pusha med:"
    msg_info "  pct push ${IP_FRIGATE} ${SAVE_DIR}/frigate-config.yml /opt/frigate/config/config.yml"
    msg_info "  pct push ${IP_FRIGATE} ${SAVE_DIR}/frigate.env /opt/frigate/.env"
    msg_info "  pct exec ${IP_FRIGATE} -- bash -c 'cd /opt/frigate && docker compose restart'"
fi

# Cleanup temp
rm -f "$CONFIG_OUTPUT" "$ENV_OUTPUT"

# ============================================================
# STEG 10: Instruktioner
# ============================================================
echo "" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty
echo -e "  ${BOLD}VIKTIGT: Gör detta på varje kamera (om du inte redan gjort det)${NC}" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty
echo -e "" > /dev/tty
echo -e "  Logga in på varje kameras webbgränssnitt och:" > /dev/tty
echo -e "" > /dev/tty
echo -e "  ${BOLD}1. Skapa RTSP-användare på varje kamera:${NC}" > /dev/tty
echo -e "     System → Users → Lägg till:" > /dev/tty
echo -e "     - Användarnamn: ${GREEN}${RTSP_USER}${NC}" > /dev/tty
echo -e "     - Lösenord: (det du angav som gemensamt lösenord)" > /dev/tty
echo -e "     - Roll: ${GREEN}Viewer${NC} (behöver bara läsa video)" > /dev/tty
echo -e "" > /dev/tty
echo -e "  ${BOLD}2. Skapa stream-profiler (Axis-kameror):${NC}" > /dev/tty
echo -e "     Video → Stream profiles:" > /dev/tty
echo -e "" > /dev/tty
echo -e "     Profil '${GREEN}main${NC}' (inspelning + livevy):" > /dev/tty
echo -e "       Codec: ${BOLD}H.265${NC}, Resolution: Max (t.ex. 2592×1944)" > /dev/tty
echo -e "       Frame rate: 15, Compression: 30" > /dev/tty
echo -e "" > /dev/tty
echo -e "     Profil '${GREEN}detect${NC}' (AI-detektering):" > /dev/tty
echo -e "       Codec: ${BOLD}H.265${NC}, Resolution: 1280×960 (4:3)" > /dev/tty
echo -e "       Frame rate: 5, Compression: 30" > /dev/tty
echo -e "" > /dev/tty

# Icke-Axis-varning
if [ "$CAM_BRAND" == "2" ] || [ "$CAM_BRAND" == "3" ]; then
    echo -e "  ${BOLD}3. Icke-Axis-kameror:${NC}" > /dev/tty
    echo -e "     Redigera config.yml och byt RTSP-path till rätt för ditt märke." > /dev/tty
    echo -e "     Sök efter 'MAIN_STREAM_PATH' och 'SUB_STREAM_PATH' i filen." > /dev/tty
    echo -e "" > /dev/tty
fi

echo -e "  ${BOLD}Nästa steg:${NC}" > /dev/tty
echo -e "     - Öppna Frigate UI: http://${FRIGATE_IP}:5000" > /dev/tty
echo -e "     - Verifiera att alla kameror syns" > /dev/tty
echo -e "     - Rita zoner och masker i UI:t" > /dev/tty
echo -e "  ${YELLOW}════════════════════════════════════════════════════════════════${NC}" > /dev/tty

msg_ok "Kamera-konfiguration klar!"
