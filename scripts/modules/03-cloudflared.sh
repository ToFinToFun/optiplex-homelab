#!/usr/bin/env bash
source setup.env
source lib/ui.sh
TEMPLATE_PATH=$1

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_CLOUDFLARED}"

msg_info "Skapar LXC-container ${IP_CLOUDFLARED}..."

if ! pct create "${IP_CLOUDFLARED}" "${TEMPLATE_PATH}" \
    --hostname cloudflared \
    --cores 1 \
    --memory 512 \
    --swap 0 \
    --net0 "name=eth0,bridge=vmbr0,ip=${CT_IP}/${CIDR},gw=${GATEWAY}" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:8" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_CLOUDFLARED}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

pct start "${IP_CLOUDFLARED}"
sleep 5

msg_info "Installerar Cloudflared-demonen..."
pct exec "${IP_CLOUDFLARED}" -- bash -c "apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq curl > /dev/null 2>&1"
pct exec "${IP_CLOUDFLARED}" -- bash -c "curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
pct exec "${IP_CLOUDFLARED}" -- bash -c "dpkg -i cloudflared.deb > /dev/null 2>&1"

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    msg_info "Konfigurerar tunnel med angiven token..."
    pct exec "${IP_CLOUDFLARED}" -- bash -c "cloudflared service install ${CF_TUNNEL_TOKEN}" > /dev/null 2>&1
    msg_ok "Cloudflare Tunnel installerad och startad!"
else
    echo ""
    msg_warn "Ingen Cloudflare Tunnel-token angiven."
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Utan token fungerar inte extern åtkomst.${NC}"
    echo -e ""
    echo -e "  Så här skapar du en token:"
    echo -e "  1. Gå till https://one.dash.cloudflare.com → Networks → Tunnels"
    echo -e "  2. Skapa en ny tunnel (Cloudflared)"
    echo -e "  3. Kopiera token-strängen"
    echo -e "  4. Kör sedan:"
    echo -e "     ${GREEN}pct exec ${IP_CLOUDFLARED} -- cloudflared service install <TOKEN>${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    msg_ok "Cloudflared installerat (tunnel ej konfigurerad — se instruktioner ovan)."
fi
