#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Uppgradera Proxmox VE 8 → 9
# ============================================================
# Uppgraderar din Proxmox-installation från version 8 (Bookworm)
# till version 9 (Trixie) via in-place upgrade.
#
# Användning (direkt via curl, kräver inga förinstallerade verktyg):
#   bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/tools/upgrade-proxmox.sh)
#
# Eller om repot redan är klonat:
#   cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh
#
# Baserat på officiell guide:
#   https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
# ============================================================

# Färger
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logfil
LOG="/var/log/proxmox-upgrade.log"
exec > >(tee -a "$LOG") 2>&1

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║       Proxmox VE 8 → 9 Uppgradering                         ║"
echo "║                                                              ║"
echo "║  Detta skript uppgraderar din Proxmox-installation från      ║"
echo "║  version 8 (Debian Bookworm) till version 9 (Debian Trixie). ║"
echo "║                                                              ║"
echo "║  Uppgraderingen tar ca 15-30 minuter och kräver en reboot.   ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# Kontroller
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[FEL]${NC} Måste köras som root."
    exit 1
fi

if ! command -v pveversion &> /dev/null; then
    echo -e "${RED}[FEL]${NC} Detta är inte en Proxmox-nod."
    exit 1
fi

CURRENT_VERSION=$(pveversion 2>/dev/null)
echo -e "${BOLD}Nuvarande version:${NC} $CURRENT_VERSION"
echo ""

# Kolla om redan på 9.x
if echo "$CURRENT_VERSION" | grep -q "pve-manager/9"; then
    echo -e "${GREEN}[OK]${NC} Du kör redan Proxmox VE 9! Ingen uppgradering behövs."
    exit 0
fi

# Kolla om på 8.x
if ! echo "$CURRENT_VERSION" | grep -q "pve-manager/8"; then
    echo -e "${RED}[FEL]${NC} Detta skript stödjer bara uppgradering från Proxmox VE 8.x"
    echo -e "      Din version: $CURRENT_VERSION"
    exit 1
fi

# ============================================================
# Förklaring
# ============================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Vad händer under uppgraderingen?${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. Vi stoppar alla VMs och containers (säkrast)"
echo -e "  2. Vi uppdaterar Proxmox 8 till senaste 8.4.x"
echo -e "  3. Vi kör ${BOLD}pve8to9${NC} — ett verktyg som kollar att allt är redo"
echo -e "  4. Vi fixar eventuella kända problem automatiskt"
echo -e "  5. Vi byter paketrepos från Bookworm → Trixie"
echo -e "  6. Vi kör den stora uppgraderingen (apt dist-upgrade)"
echo -e "  7. Vi startar om servern med ny kernel"
echo -e "  8. Dina VMs/containers startas igen automatiskt efter reboot"
echo ""
echo -e "  ${GREEN}Dina VMs och containers påverkas INTE${NC} — de finns kvar"
echo -e "  efter uppgraderingen precis som innan."
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ============================================================
# Bekräftelse
# ============================================================
echo -ne "${BOLD}Vill du starta uppgraderingen? [j/N]: ${NC}" > /dev/tty
read CONFIRM < /dev/tty
if [[ ! "$CONFIRM" =~ ^[jJyY]$ ]]; then
    echo -e "\n${YELLOW}[AVBRUTEN]${NC} Uppgraderingen avbröts. Inget har ändrats."
    exit 0
fi

# ============================================================
# Steg 1: Stoppa alla VMs och containers
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 1/7: Stoppa VMs och containers${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} Under uppgraderingen uppdateras systembibliotek"
echo -e "    och kernel. Körande VMs/containers kan bli instabila om"
echo -e "    deras underliggande system ändras under drift."
echo ""

# Hitta körande VMs och containers
RUNNING_CTS=$(pct list 2>/dev/null | awk '/running/{print $1}')
RUNNING_VMS=$(qm list 2>/dev/null | awk '/running/{print $1}')

if [ -z "$RUNNING_CTS" ] && [ -z "$RUNNING_VMS" ]; then
    echo -e "  ${GREEN}[OK]${NC} Inga körande VMs eller containers hittades."
else
    echo -e "  Följande är igång och bör stoppas:"
    echo ""
    for CT in $RUNNING_CTS; do
        CT_NAME=$(pct config "$CT" 2>/dev/null | grep "^hostname" | awk '{print $2}')
        echo -e "    • CT $CT ($CT_NAME)"
    done
    for VM in $RUNNING_VMS; do
        VM_NAME=$(qm config "$VM" 2>/dev/null | grep "^name" | awk '{print $2}')
        echo -e "    • VM $VM ($VM_NAME)"
    done
    echo ""
    echo -ne "${BOLD}Vill du stoppa alla dessa nu? [J/n]: ${NC}" > /dev/tty
    read STOP_ANSWER < /dev/tty
    if [[ ! "$STOP_ANSWER" =~ ^[nN]$ ]]; then
        for CT in $RUNNING_CTS; do
            echo -e "  ${CYAN}→${NC} Stoppar CT $CT..."
            pct shutdown "$CT" --timeout 30 2>/dev/null || pct stop "$CT" 2>/dev/null
        done
        for VM in $RUNNING_VMS; do
            echo -e "  ${CYAN}→${NC} Stoppar VM $VM..."
            qm shutdown "$VM" --timeout 60 2>/dev/null || qm stop "$VM" 2>/dev/null
        done
        echo -e "\n  ${GREEN}[OK]${NC} Alla VMs/containers stoppade."
        # Spara vilka som var igång för att starta dem igen efter reboot
        echo "$RUNNING_CTS $RUNNING_VMS" > /tmp/upgrade-was-running.txt
    else
        echo -e "\n  ${YELLOW}[VARNING]${NC} Fortsätter med körande VMs/containers."
        echo -e "  Det rekommenderas starkt att stoppa dem manuellt."
    fi
fi

# ============================================================
# Steg 2: Uppdatera till senaste Proxmox 8.4.x
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 2/7: Uppdatera till senaste Proxmox 8.4.x${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} Proxmox kräver att du är på senaste 8.4.x innan"
echo -e "    du kan uppgradera till 9. Verktyget pve8to9 finns bara i"
echo -e "    de senaste 8.4-paketen."
echo ""

# Ta bort enterprise-repo om det finns
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    echo -e "  ${CYAN}→${NC} Tog bort enterprise-repo (kräver betald licens)"
fi

# Ta bort ceph enterprise-repo om det finns
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    if grep -q "enterprise" /etc/apt/sources.list.d/ceph.list 2>/dev/null; then
        rm -f /etc/apt/sources.list.d/ceph.list
        echo -e "  ${CYAN}→${NC} Tog bort ceph enterprise-repo"
    fi
fi

# Lägg till no-subscription om det saknas
if ! grep -q "pve-no-subscription" /etc/apt/sources.list 2>/dev/null && \
   ! find /etc/apt/sources.list.d/ -name "*.list" -exec grep -l "pve-no-subscription" {} \; 2>/dev/null | grep -q .; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list
    echo -e "  ${CYAN}→${NC} La till pve-no-subscription repo"
fi

echo -e "  ${CYAN}→${NC} Uppdaterar paketlistor..."
apt-get update -qq 2>&1 | grep -v "^$" || true

echo -e "  ${CYAN}→${NC} Uppgraderar alla 8.4-paket (behåller befintliga configs)..."
if ! apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" 2>&1 | tail -5; then
    echo -e "  ${RED}[FEL]${NC} apt dist-upgrade misslyckades."
    echo -e "        Kolla loggen: $LOG"
    echo -ne "${BOLD}Vill du fortsätta ändå? [j/N]: ${NC}" > /dev/tty
    read CONT < /dev/tty
    [[ ! "$CONT" =~ ^[jJyY]$ ]] && exit 1
fi

echo -e "\n  ${GREEN}[OK]${NC} Proxmox 8 uppdaterad: $(pveversion 2>/dev/null)"

# ============================================================
# Steg 3: Kör pve8to9 checklist
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 3/7: Kör pve8to9 — kontrollerar att allt är redo${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} pve8to9 är Proxmox officiella verktyg som kollar"
echo -e "    efter potentiella problem INNAN uppgraderingen. Det kan"
echo -e "    hitta saker som: gamla kernel-versioner, felaktiga repos,"
echo -e "    containers med gammal config, etc."
echo ""

if ! command -v pve8to9 &> /dev/null; then
    echo -e "  ${YELLOW}[VARNING]${NC} pve8to9 hittades inte. Installerar..."
    apt-get install -y proxmox-ve > /dev/null 2>&1
fi

echo -e "  ${CYAN}→${NC} Kör pve8to9 --full..."
echo ""
pve8to9 --full 2>&1 | tee /tmp/pve8to9-output.txt
echo ""

# Kolla om det finns FAILURES
if grep -q "FAILURES" /tmp/pve8to9-output.txt; then
    echo -e "  ${RED}[VARNING]${NC} pve8to9 hittade problem som bör åtgärdas!"
    echo -e "        Läs utskriften ovan noggrant."
    echo ""
    echo -ne "${BOLD}Vill du fortsätta trots varningarna? [j/N]: ${NC}" > /dev/tty
    read CONT < /dev/tty
    [[ ! "$CONT" =~ ^[jJyY]$ ]] && { echo -e "\n${YELLOW}[AVBRUTEN]${NC} Fixa problemen och kör skriptet igen."; exit 1; }
elif grep -qi "WARN" /tmp/pve8to9-output.txt; then
    echo -e "  ${YELLOW}[INFO]${NC} pve8to9 hade varningar (ej kritiska)."
    echo -ne "${BOLD}Fortsätta? [J/n]: ${NC}" > /dev/tty
    read CONT < /dev/tty
    [[ "$CONT" =~ ^[nN]$ ]] && exit 0
else
    echo -e "  ${GREEN}[OK]${NC} Inga problem hittades!"
fi

# ============================================================
# Steg 4: Fixa kända problem automatiskt
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 4/7: Fixar kända problem automatiskt${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

FIXES_APPLIED=0

# Fix: LVM autoactivation (vanligaste pve8to9-varningen)
# Proxmox 9 kräver att guest volumes inte autoaktiveras
if grep -q "lvm_checks" /tmp/pve8to9-output.txt 2>/dev/null || \
   lvs --noheadings -o lv_name,lv_attr 2>/dev/null | grep -q "V"; then
    echo -e "  > ${BOLD}LVM autoactivation${NC}"
    echo -e "    Proxmox 9 kräver att VM/CT-diskar inte aktiveras automatiskt"
    echo -e "    vid boot. Vi sätter auto_activation_volume_list korrekt."
    echo ""
    if ! grep -q "auto_activation_volume_list" /etc/lvm/lvm.conf 2>/dev/null; then
        # Lägg till i global_filter-sektionen
        sed -i '/^[[:space:]]*# auto_activation_volume_list/a\\tauto_activation_volume_list = ["pve"]' /etc/lvm/lvm.conf 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${CYAN}→${NC} La till auto_activation_volume_list = [\"pve\"] i lvm.conf"
            FIXES_APPLIED=$((FIXES_APPLIED + 1))
        fi
    else
        echo -e "  ${GREEN}[OK]${NC} auto_activation_volume_list redan konfigurerad."
    fi
    echo ""
fi

# Fix: Uppdatera initramfs (behövs efter LVM-ändring)
if [ $FIXES_APPLIED -gt 0 ]; then
    echo -e "  ${CYAN}→${NC} Uppdaterar initramfs..."
    update-initramfs -u -k all > /dev/null 2>&1
    echo -e "  ${GREEN}[OK]${NC} initramfs uppdaterad."
fi

if [ $FIXES_APPLIED -eq 0 ]; then
    echo -e "  ${GREEN}[OK]${NC} Inga kända problem att fixa — allt ser bra ut!"
fi

# ============================================================
# Steg 5: Byt repos till Trixie
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 5/7: Byt paketrepos från Bookworm → Trixie${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} Proxmox 8 använder Debian 12 (Bookworm)."
echo -e "    Proxmox 9 använder Debian 13 (Trixie). Vi måste peka"
echo -e "    pakethanteraren till de nya repos innan vi uppgraderar."
echo ""

# Byt bookworm → trixie i alla relevanta filer
echo -e "  ${CYAN}→${NC} Uppdaterar /etc/apt/sources.list..."
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list

# Ta bort gamla .list-filer och skapa nya .sources-filer (deb822-format)
echo -e "  ${CYAN}→${NC} Skapar Proxmox VE 9 no-subscription repo (deb822-format)..."
cat > /etc/apt/sources.list.d/proxmox.sources << EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Ta bort gamla .list-filer som nu ersatts
rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null
rm -f /etc/apt/sources.list.d/pve-install-repo.list 2>/dev/null
rm -f /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null

# Ta bort eventuella gamla bookworm-rader som pekar på proxmox
sed -i '/download.proxmox.com.*bookworm/d' /etc/apt/sources.list 2>/dev/null
sed -i '/download.proxmox.com.*trixie/d' /etc/apt/sources.list 2>/dev/null

# Hantera ceph om det finns
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    echo -e "  ${CYAN}→${NC} Uppdaterar Ceph-repo..."
    sed -i 's/bookworm/trixie/g' /etc/apt/sources.list.d/ceph.list
fi

echo -e "  ${CYAN}→${NC} Uppdaterar paketlistor med nya repos..."
if ! apt-get update 2>&1 | tail -3; then
    echo -e "  ${RED}[FEL]${NC} apt update misslyckades med nya repos."
    echo -e "        Kontrollera /etc/apt/sources.list och sources.list.d/"
    echo -ne "${BOLD}Vill du fortsätta ändå? [j/N]: ${NC}" > /dev/tty
    read CONT < /dev/tty
    [[ ! "$CONT" =~ ^[jJyY]$ ]] && exit 1
fi

echo -e "\n  ${GREEN}[OK]${NC} Repos uppdaterade till Trixie."

# ============================================================
# Steg 6: Kör dist-upgrade (den stora uppgraderingen)
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 6/7: Uppgradera till Proxmox VE 9 (dist-upgrade)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} Nu laddar vi ner och installerar alla nya paket."
echo -e "    Detta är själva uppgraderingen. Det kan ta 10-20 minuter"
echo -e "    beroende på internetanslutning."
echo ""
echo -e "  ${GREEN}[AUTO]${NC} Konfigurationsfiler behålls automatiskt — du behöver"
echo -e "  inte svara på några frågor under uppgraderingen."
echo ""

echo -ne "${BOLD}Starta uppgraderingen nu? [j/N]: ${NC}" > /dev/tty
read CONFIRM < /dev/tty
if [[ ! "$CONFIRM" =~ ^[jJyY]$ ]]; then
    echo -e "\n${YELLOW}[AVBRUTEN]${NC} Repos är redan bytta till Trixie."
    echo -e "  Kör ${GREEN}apt dist-upgrade${NC} manuellt när du är redo."
    exit 0
fi

echo -e "\n  ${CYAN}→${NC} Kör apt dist-upgrade... (detta tar en stund)\n"
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"

if [ $? -ne 0 ]; then
    echo -e "\n  ${RED}[FEL]${NC} dist-upgrade rapporterade fel."
    echo -e "        Kolla loggen: $LOG"
    echo -e "        Kör ${GREEN}apt dist-upgrade -y${NC} igen manuellt om det behövs."
    echo -e "        Starta INTE om förrän uppgraderingen är klar!"
    exit 1
fi

echo -e "\n  ${GREEN}[OK]${NC} Uppgradering klar!"

# ============================================================
# Steg 7: Reboot
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Steg 7/7: Starta om med ny kernel${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  > ${BOLD}Varför?${NC} Proxmox 9 använder en ny Linux-kernel (6.14)."
echo -e "    Servern måste startas om för att använda den nya kerneln."
echo ""
echo -e "  ${BOLD}Efter omstarten:${NC}"
echo -e "  • Logga in på Proxmox web UI (samma IP som innan)"
echo -e "  • Gör en hard refresh i webbläsaren (Ctrl+Shift+R)"
echo -e "  • Verifiera med: ${GREEN}pveversion${NC}"
echo ""

# Sätt VMs/CTs att starta vid boot (om de var igång innan)
if [ -f /tmp/upgrade-was-running.txt ]; then
    echo -e "  ${GREEN}[AUTO]${NC} Dina VMs/containers som var igång innan uppgraderingen"
    echo -e "  kommer att startas automatiskt efter reboot (via onboot-flagga)."
    echo ""
    for ID in $(cat /tmp/upgrade-was-running.txt); do
        if pct config "$ID" &>/dev/null; then
            pct set "$ID" -onboot 1 2>/dev/null
        elif qm config "$ID" &>/dev/null; then
            qm set "$ID" -onboot 1 2>/dev/null
        fi
    done
fi

echo -ne "${BOLD}Starta om nu? [J/n]: ${NC}" > /dev/tty
read REBOOT < /dev/tty
if [[ "$REBOOT" =~ ^[nN]$ ]]; then
    echo -e "\n  ${YELLOW}[INFO]${NC} Starta om manuellt när du är redo:"
    echo -e "        ${GREEN}reboot${NC}"
    echo ""
    echo -e "  ${GREEN}[KLAR]${NC} Uppgraderingen är installerad. Reboot krävs."
else
    echo -e "\n  ${CYAN}→${NC} Startar om om 5 sekunder...\n"
    sleep 5
    reboot
fi
