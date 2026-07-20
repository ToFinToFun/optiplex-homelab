#!/usr/bin/env bash

# OptiPlex Homelab - Huvudinstallationsskript
# Detta skript upptäcker befintliga containers och erbjuder att installera de som saknas.

set -e

# Färger för utskrift
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}   OptiPlex Homelab - Automatisk Installation   ${NC}"
echo -e "${BLUE}==================================================${NC}"

# Kontrollera att vi körs på Proxmox (kräver root)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Fel: Detta skript måste köras som root på Proxmox-noden.${NC}"
  exit 1
fi

if ! command -v pct &> /dev/null; then
  echo -e "${RED}Fel: Detta skript måste köras direkt på en Proxmox-nod.${NC}"
  exit 1
fi

# Ladda miljövariabler om setup.env finns, annars fråga interaktivt
if [ -f "setup.env" ]; then
    echo -e "${GREEN}Laddar inställningar från setup.env...${NC}"
    source setup.env
else
    echo -e "${YELLOW}Ingen setup.env hittades. Vi ställer några frågor...${NC}"
    
    read -p "Nätverksprefix (t.ex. 192.168.1): " NETWORK_PREFIX
    read -p "Gateway IP (t.ex. 192.168.1.1): " GATEWAY
    read -p "Cloudflare Tunnel Token (lämna tomt för att hoppa över): " CF_TUNNEL_TOKEN
    read -s -p "Standardlösenord för nya containers: " CT_PASSWORD
    echo ""
    
    STORAGE_POOL="local-lvm"
    IP_HA="100"
    IP_CLOUDFLARED="101"
    IP_NPM="102"
    IP_FRIGATE="103"
    
    # Spara för framtida körningar
    cat > setup.env << EOF
NETWORK_PREFIX="$NETWORK_PREFIX"
GATEWAY="$GATEWAY"
IP_HA="$IP_HA"
IP_CLOUDFLARED="$IP_CLOUDFLARED"
IP_NPM="$IP_NPM"
IP_FRIGATE="$IP_FRIGATE"
CF_TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"
CT_PASSWORD="$CT_PASSWORD"
STORAGE_POOL="$STORAGE_POOL"
EOF
    echo -e "${GREEN}Inställningar sparade till setup.env${NC}"
fi

# Funktion för att kolla om ett ID redan finns
check_exists() {
    local id=$1
    if pct status $id &>/dev/null || qm status $id &>/dev/null; then
        return 0 # Finns
    else
        return 1 # Finns inte
    fi
}

echo -e "\n${BLUE}--- Inventering av systemet ---${NC}"

# 1. Home Assistant (VM)
if check_exists 100; then
    echo -e "${YELLOW}VM 100 (Home Assistant) finns redan. Hoppar över.${NC}"
    INSTALL_HA="n"
else
    read -p "Vill du installera Home Assistant (VM 100)? [J/n] " INSTALL_HA
    INSTALL_HA=${INSTALL_HA:-J}
fi

# 2. Cloudflared (LXC)
if check_exists 101; then
    echo -e "${YELLOW}CT 101 (Cloudflared) finns redan. Hoppar över.${NC}"
    INSTALL_CF="n"
else
    read -p "Vill du installera Cloudflared (CT 101)? [J/n] " INSTALL_CF
    INSTALL_CF=${INSTALL_CF:-J}
fi

# 3. NPM (LXC)
if check_exists 102; then
    echo -e "${YELLOW}CT 102 (Nginx Proxy Manager) finns redan. Hoppar över.${NC}"
    INSTALL_NPM="n"
else
    read -p "Vill du installera NPM (CT 102)? [J/n] " INSTALL_NPM
    INSTALL_NPM=${INSTALL_NPM:-J}
fi

# 4. Frigate (LXC)
if check_exists 103; then
    echo -e "${YELLOW}CT 103 (Frigate) finns redan. Hoppar över.${NC}"
    INSTALL_FRIGATE="n"
else
    read -p "Vill du installera Frigate (CT 103)? [J/n] " INSTALL_FRIGATE
    INSTALL_FRIGATE=${INSTALL_FRIGATE:-J}
fi

echo -e "\n${BLUE}--- Startar installation ---${NC}"

# Hämta Debian 12 template om vi ska installera LXC
if [[ "$INSTALL_CF" =~ ^[JjYy]$ ]] || [[ "$INSTALL_NPM" =~ ^[JjYy]$ ]] || [[ "$INSTALL_FRIGATE" =~ ^[JjYy]$ ]]; then
    echo -e "Kontrollerar Debian 12 LXC-template..."
    pveam update
    TEMPLATE=$(pveam available -section system | grep debian-12-standard | awk '{print $2}' | head -n 1)
    if [ ! -f "/var/lib/vz/template/cache/$(basename $TEMPLATE)" ]; then
        echo -e "Laddar ner $TEMPLATE..."
        pveam download local $TEMPLATE
    fi
    TEMPLATE_PATH="local:vztmpl/$(basename $TEMPLATE)"
fi

# Exekvera valda skript
if [[ "$INSTALL_HA" =~ ^[JjYy]$ ]]; then
    echo -e "\n${GREEN}Installerade Home Assistant...${NC}"
    bash ./01-setup-ha.sh
fi

if [[ "$INSTALL_CF" =~ ^[JjYy]$ ]]; then
    echo -e "\n${GREEN}Installerade Cloudflared...${NC}"
    bash ./02-setup-cloudflared.sh "$TEMPLATE_PATH"
fi

if [[ "$INSTALL_NPM" =~ ^[JjYy]$ ]]; then
    echo -e "\n${GREEN}Installerade Nginx Proxy Manager...${NC}"
    bash ./03-setup-npm.sh "$TEMPLATE_PATH"
fi

if [[ "$INSTALL_FRIGATE" =~ ^[JjYy]$ ]]; then
    echo -e "\n${GREEN}Installerade Frigate...${NC}"
    bash ./04-setup-frigate.sh "$TEMPLATE_PATH"
fi

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}   Installation slutförd!                       ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo -e "Nästa steg:"
echo -e "1. Konfigurera NPM via http://${NETWORK_PREFIX}.${IP_NPM}:81"
echo -e "2. Lägg till din Frigate config.yml i CT 103"
echo -e "3. Återställ din Home Assistant backup på http://${NETWORK_PREFIX}.${IP_HA}:8123"
