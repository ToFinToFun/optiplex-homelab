#!/usr/bin/env bash
set -e

source setup.env
TEMPLATE_PATH=$1

if [ -z "$TEMPLATE_PATH" ]; then
    echo "Fel: Måste ange sökväg till LXC-template."
    exit 1
fi

echo "Skapar CT $IP_NPM (Nginx Proxy Manager)..."
pct create $IP_NPM $TEMPLATE_PATH \
    --hostname npm \
    --cores 1 \
    --memory 1024 \
    --swap 0 \
    --net0 name=eth0,bridge=vmbr0,ip=${NETWORK_PREFIX}.${IP_NPM}/24,gw=${GATEWAY} \
    --storage $STORAGE_POOL \
    --rootfs ${STORAGE_POOL}:8 \
    --password "$CT_PASSWORD" \
    --unprivileged 1 \
    --features nesting=1

pct start $IP_NPM
echo "Väntar på att CT $IP_NPM ska starta..."
sleep 5

echo "Uppdaterar och installerar Docker..."
pct exec $IP_NPM -- bash -c "apt-get update && apt-get upgrade -y"
pct exec $IP_NPM -- bash -c "apt-get install -y curl ca-certificates gnupg"
pct exec $IP_NPM -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $IP_NPM -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
pct exec $IP_NPM -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec $IP_NPM -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec $IP_NPM -- bash -c "apt-get update"
pct exec $IP_NPM -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

echo "Kopierar docker-compose.yml..."
pct exec $IP_NPM -- bash -c "mkdir -p /opt/npm"
pct push $IP_NPM ../configs/docker-compose-npm.yml /opt/npm/docker-compose.yml

echo "Startar NPM..."
pct exec $IP_NPM -- bash -c "cd /opt/npm && docker compose up -d"

echo "NPM-installation klar!"
