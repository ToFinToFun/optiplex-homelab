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
    --features nesting=1 2>&1; then
    msg_error "Kunde inte skapa container ${IP_FRIGATE}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

# Om vi har en dedikerad frigate-storage pool, mounta den till containern
if pvesm status | grep -q "frigate-storage"; then
    msg_info "Hittade frigate-storage pool, mountar den för videoinspelningar..."
    pct set "${IP_FRIGATE}" -mp0 "frigate-storage:100,mp=/opt/frigate/storage,backup=0"
fi

# iGPU passthrough — skrivs direkt till conf-filen (pct set stöder inte lxc.* options)
msg_info "Konfigurerar iGPU passthrough..."
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
fi

pct start "${IP_FRIGATE}"
sleep 5

msg_info "Installerar Docker och Intel drivrutiner..."
pct exec "${IP_FRIGATE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y -qq curl ca-certificates gnupg > /dev/null 2>&1"

# Intel media driver — kan saknas i vissa repos, ej kritiskt
pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y -qq intel-media-va-driver-non-free vainfo > /dev/null 2>&1" || \
    msg_warn "Intel VA-driver kunde inte installeras (kan läggas till manuellt senare)"

# Docker installation
pct exec "${IP_FRIGATE}" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec "${IP_FRIGATE}" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null"
pct exec "${IP_FRIGATE}" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec "${IP_FRIGATE}" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec "${IP_FRIGATE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_FRIGATE}" -- bash -c "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1"

msg_info "Konfigurerar Frigate..."
pct exec "${IP_FRIGATE}" -- bash -c "mkdir -p /opt/frigate/config /opt/frigate/storage"

# Välj version
if ask_yes_no "Vill du använda Frigate 0.18.0 (rekommenderas, senaste stabila)? Svara 'n' för äldre 0.17.2." "Y"; then
    FRIGATE_TAG="0.18.0"
else
    FRIGATE_TAG="0.17.2"
fi

cat > /tmp/frigate-compose.yml << EOF
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:${FRIGATE_TAG}
    shm_size: "128mb"
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config
      - ./storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "8971:8971"
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF
pct push "${IP_FRIGATE}" /tmp/frigate-compose.yml /opt/frigate/docker-compose.yml
rm -f /tmp/frigate-compose.yml

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

record:
  enabled: true
  retain:
    days: 7
    mode: all

snapshots:
  enabled: true

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
pct exec "${IP_FRIGATE}" -- bash -c "cd /opt/frigate && docker compose up -d" > /dev/null 2>&1

# Verifiering
if pct exec "${IP_FRIGATE}" -- vainfo 2>&1 | grep -qi "intel\|iHD"; then
    msg_ok "iGPU-passthrough fungerar (vainfo OK)"
else
    msg_warn "iGPU-passthrough verkar ha problem. Kolla BIOS (VT-d, ReBAR)."
fi

msg_ok "Frigate installerat och igång! Du kan nu konfigurera via UI på port 5000."
