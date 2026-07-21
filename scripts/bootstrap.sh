#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Bootstrap
# ============================================================
# Detta skript körs direkt via curl på en färsk Proxmox-installation.
# Det installerar nödvändiga verktyg, klonar repot och startar wizarden.
#
# Användning:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh)
# ============================================================

# Inget set -e — vi hanterar fel explicit så skriptet aldrig dör tyst

# Färger
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║       OptiPlex Homelab — Bootstrap & Installer               ║"
echo "║                                                              ║"
echo "║  Detta skript förbereder din Proxmox-nod med nödvändiga      ║"
echo "║  verktyg och startar sedan installationswizarden.            ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# Steg 1: Kontrollera att vi kör som root på Proxmox
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[FEL]${NC} Detta skript måste köras som root."
    echo -e "      Kör: ${GREEN}sudo bash <(curl -fsSL ...)${NC}"
    exit 1
fi

if ! command -v pveversion &> /dev/null; then
    echo -e "${RED}[FEL]${NC} Detta verkar inte vara en Proxmox-nod (pveversion hittades inte)."
    echo -e "      Installera Proxmox VE först. Se docs/02-proxmox-install.md"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Kör som root på Proxmox $(pveversion 2>/dev/null || echo 'VE')"

# ============================================================
# Steg 2: Installera nödvändiga verktyg
# ============================================================
echo -e "\n${BOLD}Installerar nödvändiga verktyg...${NC}"
echo -e "${YELLOW}(Detta tar 1-2 minuter vid första körningen)${NC}\n"

# Lista över paket att installera
PACKAGES=(
    # Grundläggande verktyg
    "git"               # Versionhantering, hämta/uppdatera repot
    "curl"              # HTTP-anrop (finns oftast redan)
    "wget"              # Nedladdning av filer
    "unzip"             # Packa upp arkiv

    # Systemövervakning
    "htop"              # Interaktiv processövervakning
    "lm-sensors"        # Temperaturövervakning (sensors)
    "iotop"             # Disk I/O-övervakning
    "net-tools"         # ifconfig, netstat etc.
    "nmap"              # Nätverksskanning (hitta kameror)

    # Intel iGPU-verktyg
    "intel-gpu-tools"   # intel_gpu_top (övervaka GPU-last)
    "vainfo"            # Verifiera VAAPI/iGPU-stöd

    # Docker-förberedelser
    "ca-certificates"   # SSL-certifikat
    "gnupg"             # GPG-nycklar för Docker-repo
)

# Uppdatera paketlistan (ta bort enterprise-repo först om det finns)
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    echo -e "  ${CYAN}→${NC} Tog bort enterprise-repo (kräver licens)"
fi
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    sed -i 's/enterprise/no-subscription/g' /etc/apt/sources.list.d/ceph.list 2>/dev/null || true
fi

# Lägg till no-subscription repo om det saknas
if ! grep -q "pve-no-subscription" /etc/apt/sources.list 2>/dev/null; then
    # Detektera Proxmox-version för rätt codename
    CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME:-trixie} pve-no-subscription" >> /etc/apt/sources.list
    echo -e "  ${CYAN}→${NC} La till pve-no-subscription repo"
fi

echo -e "  ${CYAN}→${NC} Uppdaterar paketlistor..."
if ! apt-get update -qq > /dev/null 2>&1; then
    echo -e "  ${YELLOW}[VARNING]${NC} apt-get update hade varningar (fortsätter ändå)"
fi

# Installera paket (hoppa över de som redan finns)
INSTALLED=0
SKIPPED=0
FAILED=0

for pkg in "${PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        SKIPPED=$((SKIPPED + 1))
    else
        echo -e "  ${CYAN}→${NC} Installerar ${BOLD}$pkg${NC}..."
        if apt-get install -y -qq "$pkg" > /dev/null 2>&1; then
            INSTALLED=$((INSTALLED + 1))
        else
            echo -e "  ${YELLOW}[VARNING]${NC} Kunde inte installera $pkg (ej kritiskt)"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo -e "\n${GREEN}[OK]${NC} Verktyg klara: ${INSTALLED} installerade, ${SKIPPED} fanns redan, ${FAILED} misslyckades"

# ============================================================
# Steg 3: Klona eller uppdatera repot
# ============================================================
REPO_URL="https://github.com/ToFinToFun/optiplex-homelab.git"
INSTALL_DIR="/opt/optiplex-homelab"

echo -e "\n${BOLD}Hämtar installationsskript...${NC}"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "  ${CYAN}→${NC} Repot finns redan i $INSTALL_DIR. Uppdaterar..."
    cd "$INSTALL_DIR"
    git pull --quiet
    echo -e "  ${GREEN}[OK]${NC} Uppdaterat till senaste versionen."
else
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "  ${YELLOW}[INFO]${NC} $INSTALL_DIR finns men är inte ett git-repo. Tar bort och klonar om..."
        rm -rf "$INSTALL_DIR"
    fi
    echo -e "  ${CYAN}→${NC} Klonar repot till $INSTALL_DIR..."
    if ! git clone --quiet "$REPO_URL" "$INSTALL_DIR"; then
        echo -e "  ${RED}[FEL]${NC} Kunde inte klona repot. Kontrollera internetanslutningen."
        echo -e "        Testa: ${GREEN}ping -c 1 github.com${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}[OK]${NC} Repot klonat."
fi

# ============================================================
# Steg 4: Starta wizarden
# ============================================================
echo -e "\n${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Allt redo! Startar installationswizarden...${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}\n"

cd "$INSTALL_DIR/scripts"
chmod +x setup.sh modules/*.sh tools/*.sh lib/*.sh 2>/dev/null || true
exec bash setup.sh
