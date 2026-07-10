#!/bin/bash
# Proxmox VE 9 Post-Install Script
# Kör detta i Proxmox Shell efter installation.
#
# Vad skriptet gör:
# 1. Inaktiverar Enterprise-repos (kräver betald licens)
# 2. Aktiverar gratis No-Subscription repo
# 3. Uppdaterar systemet
# 4. Aktiverar veckovis TRIM (förlänger SSD-livslängd)
# 5. Installerar udev-regel för iGPU-åtkomst

set -e

echo "=== Proxmox Post-Install ==="
echo ""

# 1. Inaktivera Enterprise-repos
echo "[1/5] Inaktiverar Enterprise-repos..."
cat > /etc/apt/sources.list.d/pve-enterprise.sources << 'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: no
EOF

cat > /etc/apt/sources.list.d/ceph.sources << 'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: no
EOF

# 2. Aktivera No-Subscription repo
echo "[2/5] Aktiverar No-Subscription repo..."
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# 3. Uppdatera systemet
echo "[3/5] Uppdaterar systemet (kan ta några minuter)..."
apt update && apt upgrade -y

# 4. Aktivera TRIM
echo "[4/5] Aktiverar veckovis TRIM för SSD..."
systemctl enable fstrim.timer
systemctl start fstrim.timer

# 5. Installera udev-regel för iGPU
echo "[5/5] Installerar udev-regel för iGPU (renderD128)..."
cat > /etc/udev/rules.d/99-igpu-permissions.rules << 'EOF'
KERNEL=="renderD128", SUBSYSTEM=="drm", MODE="0666"
EOF
udevadm control --reload-rules
udevadm trigger

echo ""
echo "=== Klart! ==="
echo "Proxmox är nu konfigurerat med gratis repos, TRIM och iGPU-åtkomst."
echo ""
echo "Nästa steg:"
echo "  - Starta om servern om en ny kernel installerades: reboot"
echo "  - Reservera en statisk IP i din router för denna maskin"
echo "  - Fortsätt med nästa guide i docs/"
