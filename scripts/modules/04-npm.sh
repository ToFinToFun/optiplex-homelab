#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/network.sh
TEMPLATE_PATH=$1

# Säkerställ defaults
IP_NPM="${IP_NPM:-102}"
STORAGE_POOL="${STORAGE_POOL:-local-lvm}"

# Pre-flight check
preflight_check_network || { return 1 2>/dev/null || exit 1; }

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_NPM}"

# Bestäm nätverksparameter (DHCP eller statisk)
NET0_PARAM=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")

msg_info "Skapar LXC-container ${IP_NPM}..."

if ! pct create "${IP_NPM}" "${TEMPLATE_PATH}" \
    --hostname npm \
    --cores 1 \
    --memory 1024 \
    --swap 0 \
    --net0 "$NET0_PARAM" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:8" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_NPM}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

pct start "${IP_NPM}"
sleep 5

# Upptäck faktisk IP (viktigt vid DHCP)
ACTUAL_IP=$(discover_ct_ip "${IP_NPM}" "$CT_IP" 30)
if [ "${USE_DHCP:-false}" == "true" ] && [ -n "$ACTUAL_IP" ]; then
    msg_info "Container fick IP: ${ACTUAL_IP}"
    msg_warn "Lås denna IP i din router för att den ska vara permanent."
    # Exportera för setup.sh (NPM login, wait_for_service)
    CT_IP="$ACTUAL_IP"
fi

msg_info "Installerar Docker i containern..."
pct exec "${IP_NPM}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_NPM}" -- bash -c "apt-get install -y -qq curl ca-certificates gnupg > /dev/null 2>&1"
pct exec "${IP_NPM}" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec "${IP_NPM}" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null"
pct exec "${IP_NPM}" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec "${IP_NPM}" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec "${IP_NPM}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
pct exec "${IP_NPM}" -- bash -c "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1"

msg_info "Konfigurerar Nginx Proxy Manager..."
pct exec "${IP_NPM}" -- bash -c "mkdir -p /opt/npm"

# Skapa docker-compose fil direkt
cat > /tmp/npm-compose.yml << 'EOF'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
pct push "${IP_NPM}" /tmp/npm-compose.yml /opt/npm/docker-compose.yml
rm -f /tmp/npm-compose.yml

msg_info "Startar NPM via Docker Compose..."
pct exec "${IP_NPM}" -- bash -c "cd /opt/npm && docker compose up -d" > /dev/null 2>&1

msg_ok "Nginx Proxy Manager är igång!"
