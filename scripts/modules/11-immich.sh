#!/bin/bash
# ============================================================================
# Modul 11: Immich — Self-hosted foto/video-backup (ersätter Google Photos)
# ============================================================================
# Skapar en LXC-container med Docker och Immich.
# Konfigurerar:
#   - Docker CE + Docker Compose
#   - Immich (server, machine-learning, Redis, PostgreSQL)
#   - Valfri extern åtkomst via Cloudflare Tunnel + NPM
# ============================================================================
# TILLÄGG — Installeras INTE automatiskt, bara vid explicit val.
# Krav: Minst 4GB RAM (6GB rekommenderat), 2+ CPU-kärnor, 50GB+ disk
# ============================================================================

source setup.env
source lib/ui.sh
source lib/network.sh
TEMPLATE_PATH=$1

# Säkerställ defaults
IP_IMMICH="${IP_IMMICH:-110}"
STORAGE_POOL="${STORAGE_POOL:-local-lvm}"

# Pre-flight check
preflight_check_network || { return 1 2>/dev/null || exit 1; }

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_IMMICH}"

# --- Resurskontroll ---
IMMICH_RAM="${IMMICH_RAM:-4096}"
IMMICH_DISK="${IMMICH_DISK:-50}"
IMMICH_CORES="${IMMICH_CORES:-2}"

# Bestäm nätverksparameter (DHCP eller statisk)
NET0_PARAM=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")

msg_info "Skapar LXC-container ${IP_IMMICH} (Immich)..."
msg_info "Resurser: ${IMMICH_CORES} kärnor, ${IMMICH_RAM}MB RAM, ${IMMICH_DISK}GB disk"

if ! pct create "${IP_IMMICH}" "${TEMPLATE_PATH}" \
    --hostname immich \
    --cores "${IMMICH_CORES}" \
    --memory "${IMMICH_RAM}" \
    --swap 512 \
    --net0 "$NET0_PARAM" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:${IMMICH_DISK}" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_IMMICH}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

pct start "${IP_IMMICH}"
sleep 5

# Upptäck faktisk IP (viktigt vid DHCP)
ACTUAL_IP=$(discover_ct_ip "${IP_IMMICH}" "$CT_IP" 30)
if [ "${USE_DHCP:-false}" == "true" ] && [ -n "$ACTUAL_IP" ]; then
    msg_info "Container fick IP: ${ACTUAL_IP}"
    msg_warn "Lås denna IP i din router för att den ska vara permanent."
fi
IMMICH_IP="${ACTUAL_IP:-$CT_IP}"

# --- Installera Docker CE ---
msg_info "Installerar Docker CE..."
pct exec "${IP_IMMICH}" -- bash -c "
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable' > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
" || { msg_err "Docker-installation misslyckades"; return 1 2>/dev/null || exit 1; }

# --- Installera Immich ---
msg_info "Laddar ner Immich docker-compose..."
pct exec "${IP_IMMICH}" -- bash -c "
    mkdir -p /opt/immich
    cd /opt/immich
    curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
    curl -fsSL -o .env https://github.com/immich-app/immich/releases/latest/download/example.env
"

# --- Konfigurera .env ---
IMMICH_DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
TIMEZONE="${TZ:-Europe/Stockholm}"

msg_info "Konfigurerar Immich..."
pct exec "${IP_IMMICH}" -- bash -c "
    cd /opt/immich
    sed -i 's|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/opt/immich/library|' .env
    sed -i 's|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/opt/immich/postgres|' .env
    sed -i 's|DB_PASSWORD=.*|DB_PASSWORD=${IMMICH_DB_PASS}|' .env
    sed -i 's|# TZ=.*|TZ=${TIMEZONE}|' .env
    sed -i 's|^TZ=Etc/UTC|TZ=${TIMEZONE}|' .env

    mkdir -p /opt/immich/library
    mkdir -p /opt/immich/postgres
"

# --- Starta Immich ---
msg_info "Startar Immich (detta kan ta 2-5 minuter vid första start)..."
pct exec "${IP_IMMICH}" -- bash -c "
    cd /opt/immich
    docker compose up -d
"

# --- Vänta på att Immich svarar ---
msg_info "Väntar på att Immich startar..."
IMMICH_READY=false
for i in $(seq 1 60); do
    if pct exec "${IP_IMMICH}" -- curl -sf http://localhost:2283/api/server/ping >/dev/null 2>&1; then
        IMMICH_READY=true
        break
    fi
    sleep 5
done

if [ "$IMMICH_READY" == "true" ]; then
    msg_ok "Immich är igång!"
else
    msg_warn "Immich svarar inte ännu — kan ta ytterligare tid vid första start."
    msg_info "Kontrollera med: pct exec ${IP_IMMICH} -- docker compose -f /opt/immich/docker-compose.yml logs"
fi

# --- Skapa upgrade-script ---
pct exec "${IP_IMMICH}" -- bash -c "cat > /opt/immich/upgrade.sh << 'UPGRADE'
#!/bin/bash
cd /opt/immich
docker compose pull
docker compose up -d
docker image prune -f
echo 'Immich uppdaterad!'
UPGRADE
chmod +x /opt/immich/upgrade.sh"

# --- Visa information ---
echo ""
msg_info "═══════════════════════════════════════════════════════════════"
msg_ok  "Immich installerad!"
msg_info "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Web-UI:    http://${IMMICH_IP}:2283"
echo "  Port:      2283"
echo ""
echo "  Första gången: Skapa admin-konto via web-UI"
echo "  Mobilapp:  Sök 'Immich' i App Store / Google Play"
echo "             Server URL: http://${IMMICH_IP}:2283"
echo ""
echo "  Uppgradera: pct exec ${IP_IMMICH} -- /opt/immich/upgrade.sh"
echo "  Loggar:     pct exec ${IP_IMMICH} -- docker compose -f /opt/immich/docker-compose.yml logs"
echo ""
echo "  Diskutrymme: ${IMMICH_DISK}GB (utöka vid behov med 'pct resize')"
echo ""

# --- Extern åtkomst (om Cloudflare + NPM finns) ---
if [ -n "${CF_DOMAIN}" ]; then
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │ EXTERN ÅTKOMST (valfritt):                              │"
    echo "  │                                                         │"
    echo "  │ 1. Skapa CNAME: photos.${CF_DOMAIN} → tunnel           │"
    echo "  │ 2. Lägg till i Cloudflare Tunnel ingress                │"
    echo "  │ 3. Skapa NPM proxy host:                                │"
    echo "  │    photos.${CF_DOMAIN} → http://${IMMICH_IP}:2283       │"
    echo "  │    (Aktivera WebSockets!)                                │"
    echo "  │                                                         │"
    echo "  │ Mobilapp server URL: https://photos.${CF_DOMAIN}        │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
fi

msg_info "Tips: Immich kräver minst 4GB RAM. Om ML är långsamt,"
msg_info "      överväg att öka till 6-8GB: pct set ${IP_IMMICH} -memory 8192"
echo ""
