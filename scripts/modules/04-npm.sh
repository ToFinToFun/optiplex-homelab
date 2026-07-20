#!/usr/bin/env bash
set -e
source setup.env
source lib/ui.sh
TEMPLATE_PATH=$1

msg_info "Skapar LXC-container $IP_NPM..."
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
    --features nesting=1 > /dev/null

pct start $IP_NPM
sleep 5

msg_info "Installerar Docker i containern..."
pct exec $IP_NPM -- bash -c "apt-get update > /dev/null && apt-get install -y curl ca-certificates gnupg > /dev/null"
pct exec $IP_NPM -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $IP_NPM -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
pct exec $IP_NPM -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec $IP_NPM -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec $IP_NPM -- bash -c "apt-get update > /dev/null"
pct exec $IP_NPM -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null"

msg_info "Konfigurerar Nginx Proxy Manager..."
pct exec $IP_NPM -- bash -c "mkdir -p /opt/npm"

# Skapa docker-compose fil direkt istället för att pusha från config-mappen (mer robust)
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
pct push $IP_NPM /tmp/npm-compose.yml /opt/npm/docker-compose.yml
rm /tmp/npm-compose.yml

msg_info "Startar NPM via Docker Compose..."
pct exec $IP_NPM -- bash -c "cd /opt/npm && docker compose up -d" > /dev/null

msg_ok "Nginx Proxy Manager är igång!"
