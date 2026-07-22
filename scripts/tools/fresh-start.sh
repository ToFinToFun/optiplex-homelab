#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Fresh Start (ren omstart)
# ============================================================
# Tar bort ALLT (containers, VMs, state, config) och kör
# bootstrap på nytt utan cache.
#
# Användning:
#   bash tools/fresh-start.sh
#   ELLER (direkt one-liner):
#   bash <(curl -fsSL "https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/tools/fresh-start.sh?v=$(date +%s)")
# ============================================================

# Färger
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║       ⚠  FRESH START — RADERAR ALLT OCH BÖRJAR OM  ⚠       ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "  ${BOLD}Detta kommer att:${NC}"
echo -e "  ────────────────"
echo -e "  ${RED}1.${NC} Stoppa och RADERA alla skapade VMs och containers"
echo -e "  ${RED}2.${NC} Ta bort setup.env (lösenord, IP-konfiguration)"
echo -e "  ${RED}3.${NC} Ta bort .install_state (framsteg)"
echo -e "  ${RED}4.${NC} Ta bort hela /opt/optiplex-homelab (repot)"
echo -e "  ${RED}5.${NC} Klona repot på nytt och starta wizarden"
echo ""
echo -e "  ${YELLOW}ALL DATA I CONTAINERS FÖRSVINNER PERMANENT!${NC}"
echo -e "  ${YELLOW}(Home Assistant, Frigate-inspelningar, NPM-config, etc.)${NC}"
echo ""

# Root-check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[FEL]${NC} Måste köras som root."
    exit 1
fi

echo -ne "${BOLD}Är du HELT SÄKER? Skriv 'JA' för att fortsätta: ${NC}"
read CONFIRM < /dev/tty
if [ "$CONFIRM" != "JA" ]; then
    echo ""
    echo -e "  ${GREEN}[OK]${NC} Avbrutet. Inget har ändrats."
    exit 0
fi

echo ""
echo -e "${CYAN}── Steg 1: Stoppar och tar bort VMs/Containers ──${NC}"

INSTALL_DIR="/opt/optiplex-homelab"

# Försök ladda config för att veta vilka ID:n som användes
if [ -f "$INSTALL_DIR/scripts/setup.env" ]; then
    source "$INSTALL_DIR/scripts/setup.env" 2>/dev/null || true
fi

# Default-ID:n om config saknas
IP_HA="${IP_HA:-100}"
IP_CLOUDFLARED="${IP_CLOUDFLARED:-101}"
IP_NPM="${IP_NPM:-102}"
IP_FRIGATE="${IP_FRIGATE:-103}"

for id in $IP_HA $IP_CLOUDFLARED $IP_NPM $IP_FRIGATE; do
    if qm status $id &>/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Stoppar och tar bort VM $id..."
        qm stop $id >/dev/null 2>&1 || true
        sleep 2
        qm destroy $id --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} VM $id borttagen"
    elif pct status $id &>/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Stoppar och tar bort CT $id..."
        pct stop $id >/dev/null 2>&1 || true
        sleep 1
        pct destroy $id >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} CT $id borttagen"
    fi
done

echo ""
echo -e "${CYAN}── Steg 2: Rensar lokal data ──${NC}"

# Ta bort state och config
rm -f "$INSTALL_DIR/scripts/.install_state" 2>/dev/null
rm -f "$INSTALL_DIR/scripts/setup.env" 2>/dev/null
rm -f "$INSTALL_DIR/scripts/TODO.md" 2>/dev/null
rm -rf "$INSTALL_DIR/scripts/generated/" 2>/dev/null
echo -e "  ${GREEN}✓${NC} State, config och genererade filer borttagna"

# Ta bort loggen
rm -f /var/log/optiplex-setup.log 2>/dev/null
echo -e "  ${GREEN}✓${NC} Installationslogg borttagen"

echo ""
echo -e "${CYAN}── Steg 3: Tar bort repot ──${NC}"
rm -rf "$INSTALL_DIR"
echo -e "  ${GREEN}✓${NC} $INSTALL_DIR borttaget"

echo ""
echo -e "${CYAN}── Steg 4: Startar om från scratch ──${NC}"
echo ""
echo -e "  ${GREEN}[OK]${NC} Allt rensat! Startar bootstrap..."
echo ""
sleep 2

# Kör bootstrap utan cache (v= parameter bustar GitHub CDN-cache)
exec bash <(curl -fsSL "https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh?v=$(date +%s)")
