#!/usr/bin/env bash
source lib/ui.sh
source lib/config.sh

# ============================================================
# Proxmox Host Konfiguration
# ============================================================

# --- Repos ---
msg_info "Konfigurerar Proxmox Repositories..."

# Detektera codename
CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)
CODENAME="${CODENAME:-bookworm}"

# Ta bort enterprise repo
rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null

# Lägg till no-subscription repo om det saknas
if ! grep -q "pve-no-subscription" /etc/apt/sources.list 2>/dev/null && \
   ! find /etc/apt/sources.list.d/ -name "*.list" -name "*.sources" -exec grep -l "pve-no-subscription" {} \; 2>/dev/null | grep -q .; then
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" >> /etc/apt/sources.list
    msg_ok "La till pve-no-subscription repo"
fi

# Fixa ceph repo
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    sed -i 's/enterprise/no-subscription/g' /etc/apt/sources.list.d/ceph.list
fi

msg_info "Uppdaterar paketlistor..."
apt-get update -qq 2>&1 | grep -v "^$" || true

# --- Hostname ---
if [ -n "$NODE_HOSTNAME" ] && [ "$NODE_HOSTNAME" != "$(hostname)" ]; then
    CURRENT_HOSTNAME=$(hostname)
    msg_info "Nuvarande hostname: ${CURRENT_HOSTNAME}"
    msg_info "Önskat hostname: ${NODE_HOSTNAME}"
    
    echo -e "\n  > ${BOLD}Varför byta hostname?${NC}" > /dev/tty
    echo -e "    Hostnamet identifierar din server i nätverket och i Proxmox." > /dev/tty
    echo -e "    OBS: Att byta hostname på en Proxmox-nod som redan har VMs/CTs" > /dev/tty
    echo -e "    kan kräva extra steg. Det är enklast att göra det tidigt.\n" > /dev/tty
    
    if ask_yes_no "Vill du byta hostname till '${NODE_HOSTNAME}'?" "Y"; then
        # Byt hostname
        hostnamectl set-hostname "$NODE_HOSTNAME"
        sed -i "s/${CURRENT_HOSTNAME}/${NODE_HOSTNAME}/g" /etc/hosts 2>/dev/null
        msg_ok "Hostname ändrat till: ${NODE_HOSTNAME}"
        msg_info "OBS: Fullständig effekt efter reboot. Proxmox GUI kan visa gammalt namn tills dess."
    fi
fi

# --- SSD-optimering ---
msg_info "Aktiverar fstrim (SSD-optimering)..."
systemctl enable fstrim.timer > /dev/null 2>&1
systemctl start fstrim.timer > /dev/null 2>&1
msg_ok "TRIM aktiverat (kör automatiskt varje vecka)"

# --- iGPU udev ---
msg_info "Sätter upp udev-regler för iGPU..."
cat > /etc/udev/rules.d/99-igpu-permissions.rules << 'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD128", GROUP="video", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger
msg_ok "iGPU-regler installerade"

# --- Nätverkskort Power Saving ---
msg_info "Kontrollerar nätverkskortets power saving..."

# Hitta primärt nätverkskort
PRIMARY_NIC=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
if [ -z "$PRIMARY_NIC" ]; then
    PRIMARY_NIC=$(ls /sys/class/net/ | grep -v "^lo$\|^vmbr\|^tap\|^fwbr" | head -1)
fi

if [ -n "$PRIMARY_NIC" ]; then
    # Installera ethtool om det saknas
    if ! command -v ethtool &>/dev/null; then
        apt-get install -y ethtool > /dev/null 2>&1
    fi
    
    # Kolla WoL-status
    WOL_STATUS=$(ethtool "$PRIMARY_NIC" 2>/dev/null | grep "Wake-on:" | tail -1 | awk '{print $2}')
    
    if echo "$WOL_STATUS" | grep -q "g"; then
        msg_ok "Wake-on-LAN är aktiverat på $PRIMARY_NIC"
    else
        msg_warn "Wake-on-LAN verkar inte vara aktiverat på $PRIMARY_NIC"
        msg_info "Aktiverar WoL..."
        ethtool -s "$PRIMARY_NIC" wol g 2>/dev/null
        
        # Gör det persistent via systemd
        cat > /etc/systemd/system/wol-${PRIMARY_NIC}.service << EOF
[Unit]
Description=Enable Wake-on-LAN for ${PRIMARY_NIC}
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s ${PRIMARY_NIC} wol g

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "wol-${PRIMARY_NIC}.service" > /dev/null 2>&1
        msg_ok "Wake-on-LAN aktiverat och persistent (överlever reboot)"
    fi
    
    # Kolla power saving (EEE - Energy Efficient Ethernet)
    EEE_STATUS=$(ethtool --show-eee "$PRIMARY_NIC" 2>/dev/null | grep "EEE status:" | awk '{print $3}')
    if [ "$EEE_STATUS" == "enabled" ]; then
        msg_warn "Energy Efficient Ethernet (EEE) är aktiverat — kan orsaka latens"
        msg_info "Stänger av EEE..."
        ethtool --set-eee "$PRIMARY_NIC" eee off 2>/dev/null
        msg_ok "EEE avstängt"
    else
        msg_ok "Nätverkskortet är inte i power saving mode"
    fi
    
    # Spara MAC-adress för WoL-sammanfattning
    MAC_ADDRESS=$(cat /sys/class/net/${PRIMARY_NIC}/address 2>/dev/null)
    if [ -n "$MAC_ADDRESS" ]; then
        set_state mac_address "$MAC_ADDRESS"
        set_state primary_nic "$PRIMARY_NIC"
    fi
else
    msg_warn "Kunde inte hitta primärt nätverkskort"
fi

# --- BIOS Sanity Check ---
echo ""
msg_info "Utför BIOS-verifiering..."
echo ""
echo -e "  > ${BOLD}Dessa inställningar bör vara aktiva i BIOS:${NC}" > /dev/tty
echo -e "    • Intel Virtualization Technology (VT-x) — för VMs" > /dev/tty
echo -e "    • VT for Direct I/O (VT-d) — för iGPU passthrough" > /dev/tty
echo -e "    • Multi-Display / iGPU Memory — för Frigate AI" > /dev/tty
echo -e "    • Wake on LAN — för fjärrstart" > /dev/tty
echo -e "    • AC Recovery: Power On — startar automatiskt efter strömavbrott" > /dev/tty
echo -e "    • Deep Sleep: Disabled — nätverkskortet behåller ström" > /dev/tty
echo "" > /dev/tty

BIOS_OK=true

# Kolla VT-x
if grep -c -E '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1; then
    msg_ok "VT-x (Virtualisering) är aktiverat"
else
    msg_err "VT-x saknas! Aktivera 'Intel Virtualization Technology' i BIOS."
    BIOS_OK=false
fi

# Kolla VT-d / IOMMU
if dmesg 2>/dev/null | grep -i -q -e "DMAR" -e "IOMMU"; then
    msg_ok "VT-d (IOMMU) är aktiverat"
else
    msg_warn "VT-d verkar saknas. Aktivera 'VT for Direct I/O' i BIOS."
    msg_info "Tips: Stäng även av 'DMA Protection' (Pre-boot) om det finns."
    BIOS_OK=false
fi

# Kolla iGPU
if [ -e /dev/dri/renderD128 ]; then
    msg_ok "Intel iGPU hittades (/dev/dri/renderD128)"
    # Kolla vainfo om det finns
    if command -v vainfo &>/dev/null; then
        VAAPI_DRIVER=$(vainfo 2>/dev/null | grep "vainfo: Driver" | head -1)
        if [ -n "$VAAPI_DRIVER" ]; then
            msg_ok "VAAPI: $VAAPI_DRIVER"
        fi
    fi
else
    msg_warn "Hittade ingen iGPU. Kontrollera i BIOS:"
    msg_info "  • 'Multi-Display' ska vara ON"
    msg_info "  • 'Primary Display' ska vara 'Auto' (inte 'PCI')"
    BIOS_OK=false
fi

# Kolla om AC Recovery verkar vara satt (kan inte verifiera direkt, men vi kan kolla uptime)
UPTIME_SECONDS=$(cat /proc/uptime | cut -d. -f1)
if [ "$UPTIME_SECONDS" -lt 300 ]; then
    msg_info "Servern startades nyligen — bra! Om den startar automatiskt efter strömavbrott"
    msg_info "är 'AC Recovery: Power On' korrekt inställt i BIOS."
fi

if [ "$BIOS_OK" == "false" ]; then
    echo "" > /dev/tty
    msg_warn "Vissa BIOS-inställningar verkar saknas."
    msg_info "Se docs/01-bios-setup.md för komplett BIOS-guide."
    echo "" > /dev/tty
    if ! ask_yes_no "Vill du fortsätta ändå?" "Y"; then
        exit 1
    fi
fi

echo ""
msg_ok "Proxmox Host-konfiguration klar!"
