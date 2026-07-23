#!/bin/bash
# ============================================================================
# Modul 12: NUT — UPS-övervakning (Network UPS Tools)
# ============================================================================
# Skapar en LXC-container med NUT för UPS-hantering.
# Konfigurerar:
#   - Auto-detect USB UPS (APC, CyberPower, Eaton m.fl.)
#   - NUT server (netserver mode) — tillgänglig för HA och andra klienter
#   - Graceful shutdown vid låg batteri
#   - USB passthrough från Proxmox-host till container
# ============================================================================
# TILLÄGG — Installeras INTE automatiskt, bara vid explicit val.
# Krav: USB-ansluten UPS
# ============================================================================

source setup.env
source lib/ui.sh
source lib/network.sh
TEMPLATE_PATH=$1

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_NUT}"

# --- Detektera UPS på host ---
msg_info "Söker efter USB UPS-enheter på Proxmox-host..."

UPS_DEVICE=""
UPS_VENDOR=""
UPS_PRODUCT=""

# Sök efter vanliga UPS-tillverkare via lsusb
while IFS= read -r line; do
    if echo "$line" | grep -qi "ups\|apc\|cyberpower\|eaton\|tripp.lite\|liebert\|powercom"; then
        UPS_DEVICE="$line"
        UPS_VENDOR=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}')
        UPS_PRODUCT=$(echo "$line" | grep -oP 'ID [0-9a-f]{4}:\K[0-9a-f]{4}')
        break
    fi
done < <(lsusb 2>/dev/null)

if [ -z "$UPS_DEVICE" ]; then
    msg_warn "Ingen USB UPS hittades automatiskt."
    echo ""
    echo "  Anslutna USB-enheter:"
    lsusb 2>/dev/null | head -20
    echo ""
    msg_info "Om din UPS finns i listan ovan men inte detekterades,"
    msg_info "kan du konfigurera NUT manuellt efter installation."
    echo ""

    # Fråga om de vill fortsätta ändå
    if [ "${HEADLESS:-false}" == "true" ]; then
        msg_warn "Headless-mode: Hoppar över NUT (ingen UPS detekterad)"
        return 0 2>/dev/null || exit 0
    fi

    read -rp "  Fortsätta installationen ändå? [y/N] " CONTINUE_NUT
    if [[ ! "$CONTINUE_NUT" =~ ^[Yy]$ ]]; then
        msg_info "Hoppar över NUT-installation."
        return 0 2>/dev/null || exit 0
    fi
else
    msg_ok "UPS hittad: $UPS_DEVICE"
fi

# --- Hitta USB bus/device för passthrough ---
USB_BUS=""
USB_DEV=""
if [ -n "$UPS_VENDOR" ] && [ -n "$UPS_PRODUCT" ]; then
    USB_PATH=$(lsusb | grep "${UPS_VENDOR}:${UPS_PRODUCT}" | grep -oP 'Bus \K\d+')
    USB_DEV_NUM=$(lsusb | grep "${UPS_VENDOR}:${UPS_PRODUCT}" | grep -oP 'Device \K\d+')
    if [ -n "$USB_PATH" ] && [ -n "$USB_DEV_NUM" ]; then
        USB_BUS="$USB_PATH"
        USB_DEV="$USB_DEV_NUM"
    fi
fi

# Bestäm nätverksparameter (DHCP eller statisk)
NET0_PARAM=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")

msg_info "Skapar LXC-container ${IP_NUT} (NUT UPS)..."

# NUT behöver privilegierad container för USB-åtkomst
if ! pct create "${IP_NUT}" "${TEMPLATE_PATH}" \
    --hostname nut \
    --cores 1 \
    --memory 128 \
    --swap 0 \
    --net0 "$NET0_PARAM" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:2" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_NUT}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

# --- USB Passthrough ---
if [ -n "$USB_BUS" ] && [ -n "$USB_DEV" ]; then
    msg_info "Konfigurerar USB passthrough (Bus ${USB_BUS}, Device ${USB_DEV})..."
    # Lägg till USB-device i container-config
    cat >> "/etc/pve/lxc/${IP_NUT}.conf" << USBCONF

# USB UPS passthrough
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
USBCONF
else
    msg_warn "Kunde inte bestämma USB-sökväg. Manuell konfiguration krävs."
    msg_info "Lägg till i /etc/pve/lxc/${IP_NUT}.conf:"
    echo "  lxc.cgroup2.devices.allow: c 189:* rwm"
    echo "  lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir"
fi

pct start "${IP_NUT}"
sleep 5

# Upptäck faktisk IP (viktigt vid DHCP)
ACTUAL_IP=$(discover_ct_ip "${IP_NUT}" "$CT_IP" 30)
if [ "${USE_DHCP:-false}" == "true" ] && [ -n "$ACTUAL_IP" ]; then
    msg_info "Container fick IP: ${ACTUAL_IP}"
    msg_warn "Lås denna IP i din router för att den ska vara permanent."
fi
NUT_IP="${ACTUAL_IP:-$CT_IP}"

# --- Installera NUT ---
msg_info "Installerar NUT (Network UPS Tools)..."
pct exec "${IP_NUT}" -- bash -c "
    apt-get update -qq
    apt-get install -y -qq nut nut-client >/dev/null 2>&1
" || { msg_err "NUT-installation misslyckades"; return 1 2>/dev/null || exit 1; }

# --- Konfigurera NUT ---
msg_info "Konfigurerar NUT..."

# nut.conf — netserver mode (tillgänglig för HA och andra)
pct exec "${IP_NUT}" -- bash -c "
    echo 'MODE=netserver' > /etc/nut/nut.conf
"

# ups.conf — auto-detect eller generisk usbhid-ups
NUT_DRIVER="usbhid-ups"
pct exec "${IP_NUT}" -- bash -c "cat > /etc/nut/ups.conf << 'UPSCONF'
[ups]
    driver = ${NUT_DRIVER}
    port = auto
    desc = \"UPS (auto-detected)\"
    pollinterval = 15
UPSCONF"

# upsd.conf — lyssna på alla interface
pct exec "${IP_NUT}" -- bash -c "cat > /etc/nut/upsd.conf << 'UPSDCONF'
LISTEN 0.0.0.0 3493
UPSDCONF"

# upsd.users — admin + monitor-användare
NUT_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
pct exec "${IP_NUT}" -- bash -c "cat > /etc/nut/upsd.users << USERSCONF
[admin]
    password = ${NUT_PASS}
    actions = SET
    instcmds = ALL

[monitor]
    password = ${NUT_PASS}
    upsmon master
USERSCONF"

# upsmon.conf — monitor + shutdown
pct exec "${IP_NUT}" -- bash -c "cat > /etc/nut/upsmon.conf << MONCONF
MONITOR ups@localhost 1 monitor ${NUT_PASS} master
SHUTDOWNCMD \"/sbin/shutdown -h +0\"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5
MONCONF"

# Rätt behörigheter
pct exec "${IP_NUT}" -- bash -c "
    chown root:nut /etc/nut/*.conf /etc/nut/upsd.users
    chmod 640 /etc/nut/*.conf /etc/nut/upsd.users
"

# --- Starta NUT ---
pct exec "${IP_NUT}" -- bash -c "
    systemctl restart nut-server 2>/dev/null
    systemctl restart nut-monitor 2>/dev/null
    systemctl enable nut-server nut-monitor 2>/dev/null
"

# --- Verifiera ---
sleep 3
NUT_STATUS=""
NUT_STATUS=$(pct exec "${IP_NUT}" -- upsc ups@localhost 2>/dev/null | head -5)

if [ -n "$NUT_STATUS" ]; then
    msg_ok "NUT är igång och kommunicerar med UPS!"
    echo ""
    echo "  UPS-status:"
    pct exec "${IP_NUT}" -- upsc ups@localhost 2>/dev/null | grep -E "^(battery|ups\.|device)" | head -10 | sed 's/^/    /'
else
    msg_warn "NUT startade men kunde inte kommunicera med UPS."
    msg_info "Detta kan bero på att USB passthrough behöver en omstart."
    msg_info "Prova: pct stop ${IP_NUT} && pct start ${IP_NUT}"
    msg_info "Sedan: pct exec ${IP_NUT} -- upsc ups@localhost"
fi

# --- Visa information ---
echo ""
msg_info "═══════════════════════════════════════════════════════════════"
msg_ok  "NUT UPS-övervakning installerad!"
msg_info "═══════════════════════════════════════════════════════════════"
echo ""
echo "  NUT Server:  ${NUT_IP}:3493"
echo "  UPS-namn:    ups"
echo "  Användare:   monitor"
echo "  Lösenord:    ${NUT_PASS}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ HOME ASSISTANT INTEGRATION:                             │"
echo "  │                                                         │"
echo "  │ 1. Inställningar → Enheter & Tjänster → Lägg till      │"
echo "  │ 2. Sök 'Network UPS Tools (NUT)'                       │"
echo "  │ 3. Host: ${NUT_IP}                                     │"
echo "  │    Port: 3493                                           │"
echo "  │    Användare: monitor                                   │"
echo "  │    Lösenord: ${NUT_PASS}                                │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  Kommandon:"
echo "    Status:    pct exec ${IP_NUT} -- upsc ups@localhost"
echo "    Batteritid: pct exec ${IP_NUT} -- upsc ups@localhost battery.runtime"
echo ""
msg_info "Tips: Om UPS inte detekteras, starta om containern efter"
msg_info "      att du verifierat USB passthrough i /etc/pve/lxc/${IP_NUT}.conf"
echo ""
