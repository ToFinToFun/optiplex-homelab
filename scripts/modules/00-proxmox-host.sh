#!/usr/bin/env bash
set -e
source lib/ui.sh

msg_info "Konfigurerar Proxmox Repositories..."
# Ta bort enterprise repo
rm -f /etc/apt/sources.list.d/pve-enterprise.list
# Lägg till no-subscription repo om det saknas
if ! grep -q "pve-no-subscription" /etc/apt/sources.list; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list
fi
# Fixa ceph repo
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    sed -i 's/enterprise/no-subscription/g' /etc/apt/sources.list.d/ceph.list
fi

msg_info "Uppdaterar systemet (detta kan ta en stund)..."
apt-get update > /dev/null
# apt-get dist-upgrade -y > /dev/null

msg_info "Aktiverar fstrim (SSD-optimering)..."
systemctl enable fstrim.timer
systemctl start fstrim.timer

msg_info "Sätter upp udev-regler för iGPU..."
cat > /etc/udev/rules.d/99-igpu-permissions.rules << 'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD128", GROUP="video", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger

msg_info "Utför BIOS-sanity check..."
# Kolla VT-x
if egrep -c '(vmx|svm)' /proc/cpuinfo > /dev/null; then
    msg_ok "VT-x (Virtualisering) är aktiverat"
else
    msg_err "VT-x saknas! Du måste aktivera Intel Virtualization i BIOS."
fi

# Kolla VT-d / IOMMU
if dmesg | grep -i -e dmar -e iommu > /dev/null; then
    msg_ok "VT-d (IOMMU) är aktiverat"
else
    msg_warn "VT-d verkar saknas. Om Frigate-passthrough misslyckas, kolla 'VT for Direct I/O' och stäng av 'DMA Protection' i BIOS."
fi

# Kolla iGPU
if [ -e /dev/dri/renderD128 ]; then
    msg_ok "Intel iGPU hittades (/dev/dri/renderD128)"
else
    msg_warn "Hittade ingen iGPU. Kolla BIOS eller kör en reboot om systemet är nyligen uppdaterat."
fi

msg_ok "Proxmox Host-konfiguration klar!"
