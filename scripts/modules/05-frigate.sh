#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh
TEMPLATE_PATH=$1

msg_info "Skapar LXC-container $IP_FRIGATE..."
pct create $IP_FRIGATE $TEMPLATE_PATH \
    --hostname frigate \
    --cores 4 \
    --memory 4096 \
    --swap 0 \
    --net0 name=eth0,bridge=vmbr0,ip=${NETWORK_PREFIX}.${IP_FRIGATE}/24,gw=${GATEWAY} \
    --storage $STORAGE_POOL \
    --rootfs ${STORAGE_POOL}:32 \
    --password "$CT_PASSWORD" \
    --unprivileged 0 \
    --features nesting=1 > /dev/null

msg_info "Konfigurerar iGPU passthrough..."
pct set $IP_FRIGATE -lxc.cgroup2.devices.allow "c 226:0 rwm" > /dev/null
pct set $IP_FRIGATE -lxc.cgroup2.devices.allow "c 226:128 rwm" > /dev/null
pct set $IP_FRIGATE -lxc.mount.entry "/dev/dri/card0 dev/dri/card0 none bind,optional,create=file" > /dev/null
pct set $IP_FRIGATE -lxc.mount.entry "/dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" > /dev/null

pct start $IP_FRIGATE
sleep 5

msg_info "Installerar Docker och Intel drivrutiner..."
pct exec $IP_FRIGATE -- bash -c "apt-get update > /dev/null && apt-get install -y curl ca-certificates gnupg intel-media-va-driver-non-free vainfo > /dev/null"
pct exec $IP_FRIGATE -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $IP_FRIGATE -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
pct exec $IP_FRIGATE -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec $IP_FRIGATE -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec $IP_FRIGATE -- bash -c "apt-get update > /dev/null"
pct exec $IP_FRIGATE -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null"

msg_info "Konfigurerar Frigate..."
pct exec $IP_FRIGATE -- bash -c "mkdir -p /opt/frigate/config /opt/frigate/storage"

# Välj version
if ask_yes_no "Vill du använda den senaste stabila versionen (0.17.2)? Svara 'n' för att använda 0.18-beta." "Y"; then
    FRIGATE_TAG="stable"
else
    FRIGATE_TAG="0.18.0-beta1"
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
pct push $IP_FRIGATE /tmp/frigate-compose.yml /opt/frigate/docker-compose.yml
rm /tmp/frigate-compose.yml

cat > /tmp/frigate-config.yml << 'EOF'
mqtt:
  enabled: False
cameras:
  dummy_camera:
    enabled: False
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:554/rtsp
          roles:
            - detect
EOF
pct push $IP_FRIGATE /tmp/frigate-config.yml /opt/frigate/config/config.yml
rm /tmp/frigate-config.yml

msg_info "Startar Frigate via Docker Compose..."
pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose up -d" > /dev/null

# Verifiering
if pct exec $IP_FRIGATE -- vainfo 2>&1 | grep -q "Intel iHD driver"; then
    msg_ok "iGPU-passthrough fungerar (vainfo OK)"
else
    msg_warn "iGPU-passthrough verkar ha problem. Kolla BIOS (VT-d, ReBAR)."
fi

msg_ok "Frigate installerat och igång! Du kan nu konfigurera via UI på port 5000."
