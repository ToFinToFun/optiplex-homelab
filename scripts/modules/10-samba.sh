#!/bin/bash
# ============================================================================
# Modul 10: Samba — Nätverksdelad mapp (filserver)
# ============================================================================
# Skapar en LXC-container med Samba för enkel fildelning i LAN.
# Konfigurerar:
#   - En delad mapp (/srv/share) tillgänglig för alla i nätverket
#   - En service-användare för autentisering
#   - Grundläggande smb.conf (kan byggas vidare av användaren)
# ============================================================================
# TILLÄGG — Installeras INTE automatiskt, bara vid explicit val.
# ============================================================================

source setup.env
source lib/ui.sh
source lib/network.sh
TEMPLATE_PATH=$1

# Säkerställ defaults
IP_SAMBA="${IP_SAMBA:-109}"
STORAGE_POOL="${STORAGE_POOL:-local-lvm}"

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_SAMBA}"

# Bestäm nätverksparameter (DHCP eller statisk)
NET0_PARAM=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")

msg_info "Skapar LXC-container ${IP_SAMBA} (Samba filserver)..."

if ! pct create "${IP_SAMBA}" "${TEMPLATE_PATH}" \
    --hostname samba \
    --cores 1 \
    --memory 256 \
    --swap 0 \
    --net0 "$NET0_PARAM" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:8" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_SAMBA}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

pct start "${IP_SAMBA}"
sleep 5

# Upptäck faktisk IP (viktigt vid DHCP)
ACTUAL_IP=$(discover_ct_ip "${IP_SAMBA}" "$CT_IP" 30)
if [ "${USE_DHCP:-false}" == "true" ] && [ -n "$ACTUAL_IP" ]; then
    msg_info "Container fick IP: ${ACTUAL_IP}"
    msg_warn "Lås denna IP i din router för att den ska vara permanent."
fi
SAMBA_IP="${ACTUAL_IP:-$CT_IP}"

# --- Installera Samba ---
msg_info "Installerar Samba..."
pct exec "${IP_SAMBA}" -- bash -c "
    apt-get update -qq
    apt-get install -y -qq samba >/dev/null 2>&1
" || { msg_err "Samba-installation misslyckades"; return 1 2>/dev/null || exit 1; }

# --- Skapa delad mapp ---
msg_info "Konfigurerar delad mapp /srv/share..."
pct exec "${IP_SAMBA}" -- bash -c "
    mkdir -p /srv/share
    chmod 2775 /srv/share
    chown nobody:nogroup /srv/share
"

# --- Skapa Samba-konfiguration ---
SAMBA_USER="${SAMBA_USERNAME:-samba}"
SAMBA_PASS="${SHARED_PASSWORD:-$CT_PASSWORD}"

pct exec "${IP_SAMBA}" -- bash -c "cat > /etc/samba/smb.conf << 'SMBCONF'
[global]
   workgroup = WORKGROUP
   server string = OptiPlex Homelab Filserver
   security = user
   map to guest = Bad User
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   min protocol = SMB2

[share]
   comment = Delad mapp
   path = /srv/share
   browseable = yes
   read only = no
   writable = yes
   valid users = ${SAMBA_USER}
   create mask = 0664
   directory mask = 2775
   force group = nogroup
SMBCONF"

# --- Skapa service-användare ---
msg_info "Skapar Samba-användare '${SAMBA_USER}'..."
pct exec "${IP_SAMBA}" -- bash -c "
    useradd -M -s /usr/sbin/nologin '${SAMBA_USER}' 2>/dev/null || true
    echo -e '${SAMBA_PASS}\n${SAMBA_PASS}' | smbpasswd -a -s '${SAMBA_USER}'
    smbpasswd -e '${SAMBA_USER}'
"

# --- Starta om Samba ---
pct exec "${IP_SAMBA}" -- systemctl restart smbd nmbd
pct exec "${IP_SAMBA}" -- systemctl enable smbd nmbd

# --- Verifiera ---
sleep 2
if pct exec "${IP_SAMBA}" -- systemctl is-active --quiet smbd; then
    msg_ok "Samba filserver klar!"
else
    msg_err "Samba startade inte korrekt"
    return 1 2>/dev/null || exit 1
fi

# --- Visa information ---
echo ""
msg_info "═══════════════════════════════════════════════════════════════"
msg_ok  "Samba filserver installerad!"
msg_info "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Åtkomst från Windows:  \\\\${SAMBA_IP}\\share"
echo "  Åtkomst från Mac:      smb://${SAMBA_IP}/share"
echo "  Åtkomst från Linux:    smb://${SAMBA_IP}/share"
echo ""
echo "  Användare: ${SAMBA_USER}"
echo "  Lösenord:  (samma som CT-lösenord)"
echo ""
echo "  Delad mapp i containern: /srv/share"
echo ""
msg_info "Tips: Du kan lägga till fler shares genom att redigera"
msg_info "      /etc/samba/smb.conf i container ${IP_SAMBA}."
echo ""
