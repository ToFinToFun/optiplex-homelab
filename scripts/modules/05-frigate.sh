#!/usr/bin/env bash
source setup.env
source lib/ui.sh
TEMPLATE_PATH=$1

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_FRIGATE}"

msg_info "Skapar LXC-container ${IP_FRIGATE}..."

# Skapa container — lösenord i variabel för att undvika shell-expansion-problem
if ! pct create "${IP_FRIGATE}" "${TEMPLATE_PATH}" \
    --hostname frigate \
    --cores 4 \
    --memory 4096 \
    --swap 0 \
    --net0 "name=eth0,bridge=vmbr0,ip=${CT_IP}/${CIDR},gw=${GATEWAY}" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:8" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_FRIGATE}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

# Om vi har en dedikerad frigate-storage pool, mounta den till containern
if pvesm status | grep -q "frigate-storage"; then
    msg_info "Hittade frigate-storage pool, mountar den för videoinspelningar..."
    pct set "${IP_FRIGATE}" -mp0 "frigate-storage:100,mp=/opt/frigate/storage,backup=0"
fi

# iGPU passthrough — kontrollera att hosten har /dev/dri INNAN vi konfigurerar
msg_info "Konfigurerar iGPU passthrough..."
IGPU_OK=false
if [ ! -e /dev/dri/renderD128 ]; then
    msg_err "/dev/dri/renderD128 finns INTE på Proxmox-hosten!"
    msg_info "Möjliga orsaker:"
    msg_info "  1. iGPU är avstängd i BIOS (slå på 'Multi-Monitor' eller 'iGPU Enabled')"
    msg_info "  2. i915-drivern är inte laddad (kör: modprobe i915)"
    msg_info "  3. Servern behöver startas om efter BIOS-ändring"
    msg_info ""
    msg_info "Kontrollera med: ls -la /dev/dri/ && lspci | grep VGA"
    msg_info "Frigate installeras ändå, men utan GPU-acceleration."
    msg_info "Kör scriptet igen efter reboot för att aktivera iGPU."
else
    msg_ok "/dev/dri/renderD128 hittad på hosten"
    IGPU_OK=true
    
    CONF_FILE="/etc/pve/lxc/${IP_FRIGATE}.conf"
    if [ -f "$CONF_FILE" ]; then
        # Ta bort eventuella gamla lxc.cgroup2/mount-rader först
        sed -i '/^lxc\.cgroup2\.devices\.allow/d' "$CONF_FILE"
        sed -i '/^lxc\.mount\.entry.*dri/d' "$CONF_FILE"
        
        # Lägg till iGPU-access
        cat >> "$CONF_FILE" << 'EOF'
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
        msg_ok "iGPU passthrough konfigurerat i ${CONF_FILE}"
    else
        msg_warn "Conf-fil ${CONF_FILE} hittades inte — iGPU-passthrough kunde inte konfigureras."
        IGPU_OK=false
    fi
fi

pct start "${IP_FRIGATE}"
sleep 5

msg_info "Installerar Docker och Intel drivrutiner..."
pct exec "${IP_FRIGATE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y -qq curl ca-certificates gnupg python3 > /dev/null 2>&1"

# Aktivera non-free och non-free-firmware repos (krävs för Intel VA-driver)
msg_info "Aktiverar non-free repos för Intel GPU-driver..."
pct exec "${IP_FRIGATE}" -- bash -c '
    # DEB822-format (Debian 13 default)
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        # Lägg till non-free och non-free-firmware om de saknas
        if ! grep -q "non-free" /etc/apt/sources.list.d/debian.sources; then
            sed -i "/^Components:/s/$/ non-free non-free-firmware/" /etc/apt/sources.list.d/debian.sources
        fi
        # Lägg till contrib om det saknas
        if ! grep -q "contrib" /etc/apt/sources.list.d/debian.sources; then
            sed -i "/^Components:/s/$/ contrib/" /etc/apt/sources.list.d/debian.sources
        fi
    fi
    # Legacy format (sources.list)
    if [ -f /etc/apt/sources.list ] && ! grep -q "non-free" /etc/apt/sources.list; then
        sed -i "s/main$/main contrib non-free non-free-firmware/" /etc/apt/sources.list
    fi
'
pct exec "${IP_FRIGATE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"

# Intel media driver (non-free) — krävs för HW-acceleration
if [ "$IGPU_OK" == "true" ]; then
    msg_info "Installerar Intel VA-driver (intel-media-va-driver-non-free)..."
    VA_OUTPUT=$(pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y intel-media-va-driver-non-free vainfo 2>&1")
    VA_EXIT=$?
    if [ $VA_EXIT -ne 0 ]; then
        msg_warn "Intel VA-driver kunde inte installeras:"
        echo "$VA_OUTPUT" | tail -5
        msg_info "Frigate körs ändå men utan HW-acceleration."
        msg_info "Felsök: pct exec ${IP_FRIGATE} -- apt-get install -y intel-media-va-driver-non-free"
    else
        msg_ok "Intel VA-driver installerad"
    fi
else
    msg_info "Hoppar över VA-driver (iGPU ej tillgänglig på hosten)."
fi

# Docker installation
pct exec "${IP_FRIGATE}" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec "${IP_FRIGATE}" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null"
pct exec "${IP_FRIGATE}" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec "${IP_FRIGATE}" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec "${IP_FRIGATE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1"

msg_info "Konfigurerar Frigate..."
pct exec "${IP_FRIGATE}" -- bash -c "mkdir -p /opt/frigate/config /opt/frigate/storage"

# Hitta senaste Frigate 0.18.x version via GitHub Releases API
msg_info "Söker senaste Frigate 0.18-version..."
FRIGATE_TAG=$(pct exec "${IP_FRIGATE}" -- bash -c '
    curl -fsSL "https://api.github.com/repos/blakeblackshear/frigate/releases?per_page=20" 2>/dev/null | \
    python3 -c "
import json,sys,re
releases = json.load(sys.stdin)
# Hitta senaste 0.18.x release (stabil eller beta)
for r in releases:
    tag = r.get(\"tag_name\",\"\").lstrip(\"v\")
    if tag.startswith(\"0.18.\"):
        print(tag)
        break
" 2>/dev/null
' 2>/dev/null)

# Fallback om dynamisk lookup misslyckas
if [ -z "$FRIGATE_TAG" ] || [ "$FRIGATE_TAG" == "" ]; then
    FRIGATE_TAG="0.18.0-beta1"
    msg_warn "Kunde inte hämta senaste tag — använder fallback: ${FRIGATE_TAG}"
else
    msg_ok "Senaste Frigate 0.18-version: ${FRIGATE_TAG}"
fi

# Verifiera att taggen faktiskt finns (pull-test)
msg_info "Verifierar att image finns: ghcr.io/blakeblackshear/frigate:${FRIGATE_TAG}..."
if ! pct exec "${IP_FRIGATE}" -- bash -c "docker pull ghcr.io/blakeblackshear/frigate:${FRIGATE_TAG} 2>&1 | tail -5"; then
    msg_err "Kunde inte ladda ner Frigate ${FRIGATE_TAG}!"
    msg_info "Försöker med 0.18.0-beta1 som fallback..."
    FRIGATE_TAG="0.18.0-beta1"
    if ! pct exec "${IP_FRIGATE}" -- bash -c "docker pull ghcr.io/blakeblackshear/frigate:${FRIGATE_TAG} 2>&1 | tail -5"; then
        msg_err "Kunde inte ladda ner Frigate alls. Kontrollera internetanslutning."
        return 1 2>/dev/null || exit 1
    fi
fi
msg_ok "Frigate ${FRIGATE_TAG} nedladdad"

cat > /tmp/frigate-compose.yml << EOF
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:${FRIGATE_TAG}
    shm_size: "128mb"
$(if [ "$IGPU_OK" == "true" ]; then echo '    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128'; fi)
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config
      - ./storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    environment:
      - FRIGATE_GEMINI_API_KEY=${FRIGATE_GEMINI_API_KEY:-}
    ports:
      - "8971:8971"
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF
pct push "${IP_FRIGATE}" /tmp/frigate-compose.yml /opt/frigate/docker-compose.yml
rm -f /tmp/frigate-compose.yml

if [ "$IGPU_OK" == "true" ]; then
cat > /tmp/frigate-config.yml << 'EOF'
mqtt:
  enabled: False

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
EOF
else
cat > /tmp/frigate-config.yml << 'EOF'
mqtt:
  enabled: False

detectors:
  cpu_0:
    type: cpu
    num_threads: 4

ffmpeg:
  hwaccel_args: []
EOF
msg_warn "Frigate körs med CPU-detektion (långsamt). Aktivera iGPU och kör scriptet igen."
fi

cat >> /tmp/frigate-config.yml << 'EOF'

record:
  enabled: true
  retain:
    days: 7
    mode: all

snapshots:
  enabled: true

# Generativ AI (valfritt) — avkommentera och lägg till din API-nyckel
# i docker-compose.yml (FRIGATE_GEMINI_API_KEY) för att aktivera.
# genai:
#   provider: gemini
#   api_key: "{FRIGATE_GEMINI_API_KEY}"
#   model: gemini-2.5-flash

cameras:
  dummy_camera:
    enabled: False
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:554/rtsp
          roles:
            - detect
EOF
pct push "${IP_FRIGATE}" /tmp/frigate-config.yml /opt/frigate/config/config.yml
rm -f /tmp/frigate-config.yml

msg_info "Startar Frigate via Docker Compose..."
pct exec "${IP_FRIGATE}" -- bash -c "cd /opt/frigate && docker compose up -d" 2>&1 | tail -3

# Verifiering: vänta på att Frigate faktiskt startar
msg_info "Väntar på att Frigate startar (kan ta 30-60 sek)..."
FRIGATE_READY=false
for i in $(seq 1 20); do
    if pct exec "${IP_FRIGATE}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/" 2>/dev/null | grep -q "200\|301\|302"; then
        FRIGATE_READY=true
        break
    fi
    # Kolla om containern överhuvudtaget kör
    if ! pct exec "${IP_FRIGATE}" -- bash -c "docker ps --filter name=frigate --format '{{.Status}}'" 2>/dev/null | grep -qi "up"; then
        msg_warn "Frigate-container är inte igång. Kollar loggar..."
        pct exec "${IP_FRIGATE}" -- bash -c "docker logs frigate --tail 10" 2>&1 | head -10
        break
    fi
    sleep 3
done

if [ "$FRIGATE_READY" == "true" ]; then
    msg_ok "Frigate svarar på port 5000!"
else
    msg_warn "Frigate svarar inte ännu på port 5000 — kan behöva mer tid."
    msg_info "Felsök: pct exec ${IP_FRIGATE} -- docker logs frigate --tail 30"
fi

# iGPU-verifiering
if pct exec "${IP_FRIGATE}" -- vainfo 2>&1 | grep -qi "intel\|iHD"; then
    msg_ok "iGPU-passthrough fungerar (vainfo OK)"
else
    msg_warn "iGPU-passthrough verkar ha problem. Kolla BIOS (VT-d, ReBAR)."
fi
msg_ok "Frigate ${FRIGATE_TAG} installerat! UI: http://${CT_IP}:5000"
