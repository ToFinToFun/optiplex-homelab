#!/usr/bin/env bash
source setup.env
source lib/ui.sh
TEMPLATE_PATH=$1

msg_info "Skapar LXC-container $IP_CLOUDFLARED..."
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
    --features nesting=1 > /dev/null

pct start $IP_CLOUDFLARED
sleep 5

msg_info "Installerar Cloudflared-demonen..."
pct exec $IP_CLOUDFLARED -- bash -c "apt-get update > /dev/null && apt-get install -y curl > /dev/null"
pct exec $IP_CLOUDFLARED -- bash -c "curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
pct exec $IP_CLOUDFLARED -- bash -c "dpkg -i cloudflared.deb > /dev/null"

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    msg_info "Konfigurerar tunnel med angiven token..."
    pct exec $IP_CLOUDFLARED -- bash -c "cloudflared service install $CF_TUNNEL_TOKEN" > /dev/null
    msg_ok "Cloudflare Tunnel installerad och startad!"
else
    echo ""
    msg_warn "Ingen Cloudflare Tunnel Token angiven!"
    msg_info "Utan token fungerar INTE extern åtkomst (ha.dindomän.se etc)."
    msg_info ""
    msg_info "Containern är redo. När du har din token, kör:"
    msg_info "  pct exec $IP_CLOUDFLARED -- cloudflared service install <DIN_TOKEN>"
    msg_info ""
    msg_info "Skapa en token: Cloudflare Dashboard → Zero Trust → Networks → Tunnels"
    msg_info "Se: docs/04-cloudflare-tunnel.md och docs/10-cloudflare-api-setup.md"
fi
