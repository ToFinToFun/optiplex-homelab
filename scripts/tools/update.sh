#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh

msg_header "OptiPlex Homelab - Uppdatering"

if [ "$EUID" -ne 0 ]; then
    msg_err "Detta skript måste köras som root."
    exit 1
fi

load_config || true
IP_CLOUDFLARED="${IP_CLOUDFLARED:-101}"
IP_NPM="${IP_NPM:-102}"
IP_FRIGATE="${IP_FRIGATE:-103}"

# Proxmox
msg_info "Uppdaterar Proxmox Host..."
apt-get update >/dev/null && apt-get upgrade -y >/dev/null
msg_ok "Proxmox uppdaterad."

# Cloudflared
if check_id_exists $IP_CLOUDFLARED; then
    msg_info "Uppdaterar Cloudflared (CT $IP_CLOUDFLARED)..."
    pct exec $IP_CLOUDFLARED -- bash -c "cloudflared update" >/dev/null 2>&1 || true
    msg_ok "Cloudflared uppdaterad."
fi

# NPM
if check_id_exists $IP_NPM; then
    msg_info "Uppdaterar NPM (CT $IP_NPM)..."
    pct exec $IP_NPM -- bash -c "cd /opt/npm && docker compose pull && docker compose up -d" >/dev/null 2>&1
    msg_ok "NPM uppdaterad."
fi

# Frigate
if check_id_exists $IP_FRIGATE; then
    msg_info "Uppdaterar Frigate (CT $IP_FRIGATE)..."
    pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose pull && docker compose up -d" >/dev/null 2>&1
    msg_ok "Frigate uppdaterad."
fi

msg_ok "Alla tjänster är nu uppdaterade till senaste versionen!"
