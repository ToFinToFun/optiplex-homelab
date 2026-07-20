#!/usr/bin/env bash
set -e

source setup.env
TEMPLATE_PATH=$1

if [ -z "$TEMPLATE_PATH" ]; then
    echo "Fel: Måste ange sökväg till LXC-template."
    exit 1
fi

echo "Skapar CT $IP_FRIGATE (Frigate)..."
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
    --features nesting=1

echo "Konfigurerar iGPU passthrough..."
# Låter containern använda Intel iGPU (renderD128)
pct set $IP_FRIGATE -lxc.cgroup2.devices.allow "c 226:0 rwm"
pct set $IP_FRIGATE -lxc.cgroup2.devices.allow "c 226:128 rwm"
pct set $IP_FRIGATE -lxc.mount.entry "/dev/dri/card0 dev/dri/card0 none bind,optional,create=file"
pct set $IP_FRIGATE -lxc.mount.entry "/dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file"

pct start $IP_FRIGATE
echo "Väntar på att CT $IP_FRIGATE ska starta..."
sleep 5

echo "Uppdaterar och installerar Docker + Intel-drivrutiner..."
pct exec $IP_FRIGATE -- bash -c "apt-get update && apt-get upgrade -y"
pct exec $IP_FRIGATE -- bash -c "apt-get install -y curl ca-certificates gnupg intel-media-va-driver-non-free vainfo"
pct exec $IP_FRIGATE -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $IP_FRIGATE -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
pct exec $IP_FRIGATE -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec $IP_FRIGATE -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec $IP_FRIGATE -- bash -c "apt-get update"
pct exec $IP_FRIGATE -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

echo "Kopierar docker-compose.yml och config.yml..."
pct exec $IP_FRIGATE -- bash -c "mkdir -p /opt/frigate/config"
pct push $IP_FRIGATE ../configs/docker-compose-frigate.yml /opt/frigate/docker-compose.yml
pct push $IP_FRIGATE ../configs/frigate-config.example.yml /opt/frigate/config/config.yml

echo "Startar Frigate..."
pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose up -d"

echo "Frigate-installation klar!"
