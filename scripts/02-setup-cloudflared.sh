#!/usr/bin/env bash
set -e

source setup.env
TEMPLATE_PATH=$1

if [ -z "$TEMPLATE_PATH" ]; then
    echo "Fel: Måste ange sökväg till LXC-template."
    exit 1
fi

echo "Skapar CT $IP_CLOUDFLARED (Cloudflared)..."
pct create $IP_CLOUDFLARED $TEMPLATE_PATH \
    --hostname cloudflared \
    --cores 1 \
    --memory 512 \
    --swap 0 \
    --net0 name=eth0,bridge=vmbr0,ip=${NETWORK_PREFIX}.${IP_CLOUDFLARED}/24,gw=${GATEWAY} \
    --storage $STORAGE_POOL \
    --rootfs ${STORAGE_POOL}:8 \
    --password "$CT_PASSWORD" \
    --unprivileged 1 \
    --features nesting=1

pct start $IP_CLOUDFLARED
echo "Väntar på att CT $IP_CLOUDFLARED ska starta..."
sleep 5

echo "Uppdaterar och installerar cloudflared..."
pct exec $IP_CLOUDFLARED -- bash -c "apt-get update && apt-get upgrade -y"
pct exec $IP_CLOUDFLARED -- bash -c "apt-get install -y curl"
pct exec $IP_CLOUDFLARED -- bash -c "curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
pct exec $IP_CLOUDFLARED -- bash -c "dpkg -i cloudflared.deb"

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "Konfigurerar Cloudflare Tunnel..."
    pct exec $IP_CLOUDFLARED -- bash -c "cloudflared service install $CF_TUNNEL_TOKEN"
else
    echo "Ingen CF_TUNNEL_TOKEN angiven, hoppar över tunnel-konfiguration."
fi

echo "Cloudflared-installation klar!"
