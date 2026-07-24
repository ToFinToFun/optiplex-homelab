#!/usr/bin/env bash
# Inget set -e — vi vill fortsätta även om en tjänst misslyckas med uppdatering

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
IP_ADGUARD="${IP_ADGUARD:-104}"
IP_GUACAMOLE="${IP_GUACAMOLE:-107}"
IP_SAMBA="${IP_SAMBA:-110}"
IP_IMMICH="${IP_IMMICH:-111}"
IP_NUT="${IP_NUT:-112}"

# Self-update (git pull)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$SCRIPT_DIR/.git" ]; then
    msg_info "Uppdaterar skript från GitHub..."
    cd "$SCRIPT_DIR"
    if git pull --quiet 2>/dev/null; then
        msg_ok "Skript uppdaterade."
    else
        msg_warn "Kunde inte uppdatera skript (kontrollera internet)."
    fi
    cd "$(dirname "$0")/.."
fi

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

# AdGuard Home
if check_id_exists $IP_ADGUARD; then
    msg_info "Uppdaterar AdGuard Home (CT $IP_ADGUARD)..."
    pct exec $IP_ADGUARD -- bash -c "apt-get update -qq >/dev/null && apt-get upgrade -y -qq >/dev/null" 2>&1 || true
    msg_ok "AdGuard Home uppdaterad."
fi

# NPM
if check_id_exists $IP_NPM; then
    msg_info "Uppdaterar NPM (CT $IP_NPM)..."
    if pct exec $IP_NPM -- bash -c "cd /opt/npm && docker compose pull && docker compose up -d" >/dev/null 2>&1; then
        msg_ok "NPM uppdaterad."
    else
        msg_warn "NPM-uppdatering misslyckades (kontrollera manuellt)."
    fi
fi

# Frigate
if check_id_exists $IP_FRIGATE; then
    msg_info "Uppdaterar Frigate (CT $IP_FRIGATE)..."
    if pct exec $IP_FRIGATE -- bash -c "cd /opt/frigate && docker compose pull && docker compose up -d" >/dev/null 2>&1; then
        msg_ok "Frigate uppdaterad."
    else
        msg_warn "Frigate-uppdatering misslyckades (kontrollera manuellt)."
    fi
fi

# Guacamole
if check_id_exists $IP_GUACAMOLE; then
    msg_info "Uppdaterar Guacamole (CT $IP_GUACAMOLE)..."
    if pct exec $IP_GUACAMOLE -- bash -c "cd /opt/guacamole && docker compose pull && docker compose up -d" >/dev/null 2>&1; then
        msg_ok "Guacamole uppdaterad."
    else
        msg_warn "Guacamole-uppdatering misslyckades (kontrollera manuellt)."
    fi
fi

# Immich
if check_id_exists $IP_IMMICH; then
    msg_info "Uppdaterar Immich (CT $IP_IMMICH)..."
    if pct exec $IP_IMMICH -- bash -c "cd /opt/immich && docker compose pull && docker compose up -d" >/dev/null 2>&1; then
        msg_ok "Immich uppdaterad."
    else
        msg_warn "Immich-uppdatering misslyckades (kontrollera manuellt)."
    fi
fi

# Samba (apt upgrade)
if check_id_exists $IP_SAMBA; then
    msg_info "Uppdaterar Samba (CT $IP_SAMBA)..."
    pct exec $IP_SAMBA -- bash -c "apt-get update -qq >/dev/null && apt-get upgrade -y -qq >/dev/null" 2>&1 || true
    msg_ok "Samba uppdaterad."
fi

# NUT (apt upgrade)
if check_id_exists $IP_NUT; then
    msg_info "Uppdaterar NUT (CT $IP_NUT)..."
    pct exec $IP_NUT -- bash -c "apt-get update -qq >/dev/null && apt-get upgrade -y -qq >/dev/null" 2>&1 || true
    msg_ok "NUT uppdaterad."
fi

# Docker prune (rensa gamla images)
msg_info "Rensar gamla Docker-images..."
for id in $IP_NPM $IP_FRIGATE $IP_GUACAMOLE $IP_IMMICH; do
    if check_id_exists $id; then
        pct exec $id -- bash -c "docker image prune -f" >/dev/null 2>&1 || true
    fi
done
msg_ok "Gamla images borttagna."

msg_ok "Alla tjänster är nu uppdaterade till senaste versionen!"
