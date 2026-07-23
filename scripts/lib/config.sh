#!/usr/bin/env bash

# Config and State Management

ENV_FILE="setup.env"
STATE_FILE=".install_state"

load_config() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        return 0
    fi
    return 1
}

save_config() {
    cat > "$ENV_FILE" << EOF
# OptiPlex Homelab - Automation Config
# Genererad av setup.sh — redigera inte manuellt om du inte vet vad du gör.
NODE_HOSTNAME="${NODE_HOSTNAME:-homelab}"
NETWORK_PREFIX="${NETWORK_PREFIX}"
NETWORK_CIDR="${NETWORK_CIDR:-24}"
GATEWAY="${GATEWAY}"
IP_HA="${IP_HA:-100}"
IP_CLOUDFLARED="${IP_CLOUDFLARED:-101}"
IP_NPM="${IP_NPM:-102}"
IP_FRIGATE="${IP_FRIGATE:-103}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN}"
STORAGE_POOL="${STORAGE_POOL:-$(find_storage_pool)}"

# Gemensamt lösenord (används för CT root, NPM admin, MQTT, RTSP)
SHARED_PASSWORD="${SHARED_PASSWORD}"

# Tjänsteanvändare (samma överallt)
SERVICE_USER="${SERVICE_USER:-frigate}"

# NPM admin-email
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"

# DHCP eller statisk IP för containers
USE_DHCP="${USE_DHCP:-false}"

# AdGuard Home
IP_ADGUARD="${IP_ADGUARD:-104}"
ADGUARD_UPSTREAM="${ADGUARD_UPSTREAM:-cloudflare}"
CF_DOMAIN="${CF_DOMAIN}"

# Tillägg (valfria)
IP_SAMBA="${IP_SAMBA:-105}"
IP_IMMICH="${IP_IMMICH:-106}"
IP_NUT="${IP_NUT:-107}"
IMMICH_RAM="${IMMICH_RAM:-4096}"
IMMICH_DISK="${IMMICH_DISK:-50}"
IMMICH_CORES="${IMMICH_CORES:-2}"

# Remote Desktop (Guacamole + Desktop)
IP_GUACAMOLE="${IP_GUACAMOLE:-108}"
IP_DESKTOP="${IP_DESKTOP:-109}"
EOF
}

set_state() {
    local key="$1"
    local value="$2"
    
    # Skapa fil om den inte finns
    if [ ! -f "$STATE_FILE" ]; then
        echo "{}" > "$STATE_FILE"
    fi
    
    # Uppdatera JSON med python (finns alltid i Proxmox)
    python3 -c "
import json, sys
try:
    with open('$STATE_FILE', 'r') as f: data = json.load(f)
except:
    data = {}
data['$key'] = '$value'
with open('$STATE_FILE', 'w') as f: json.dump(data, f)
"
}

get_state() {
    local key="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return
    fi
    
    python3 -c "
import json, sys
try:
    with open('$STATE_FILE', 'r') as f: data = json.load(f)
    print(data.get('$key', ''))
except:
    print('')
"
}
