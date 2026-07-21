#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh

msg_header "OptiPlex Homelab - Health Check"

if [ "$EUID" -ne 0 ]; then
    msg_err "Detta skript måste köras som root."
    exit 1
fi

load_config || true
IP_HA="${IP_HA:-100}"
IP_CLOUDFLARED="${IP_CLOUDFLARED:-101}"
IP_NPM="${IP_NPM:-102}"
IP_FRIGATE="${IP_FRIGATE:-103}"

# 1. Proxmox Host
echo -e "${BOLD}Proxmox Host${NC}"
UPTIME=$(uptime -p | cut -d' ' -f2-)
echo "  Uptime: $UPTIME"
if ls /dev/dri/renderD128 &>/dev/null; then
    echo -e "  iGPU:   ${GREEN}Tillgänglig${NC}"
else
    echo -e "  iGPU:   ${RED}Saknas${NC}"
fi

# 2. Containers / VMs
echo -e "\n${BOLD}Tjänster${NC}"

check_service() {
    local id=$1
    local name=$2
    if check_id_exists $id; then
        if pct status $id 2>/dev/null | grep -q "running" || qm status $id 2>/dev/null | grep -q "running"; then
            echo -e "  $name (ID $id): ${GREEN}Running${NC}"
            return 0
        else
            echo -e "  $name (ID $id): ${RED}Stopped${NC}"
            return 1
        fi
    else
        echo -e "  $name (ID $id): ${YELLOW}Not Installed${NC}"
        return 2
    fi
}

check_service $IP_HA "Home Assistant"
check_service $IP_CLOUDFLARED "Cloudflared   "
check_service $IP_NPM "NPM           "
check_service $IP_FRIGATE "Frigate       "

# 3. Docker status i Frigate
echo -e "\n${BOLD}Frigate Docker Status${NC}"
if pct status $IP_FRIGATE 2>/dev/null | grep -q "running"; then
    FRIGATE_DOCKER=$(pct exec $IP_FRIGATE -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "Docker ej tillgänglig")
    if [ -z "$FRIGATE_DOCKER" ]; then
        echo -e "  ${RED}Inga containers körs${NC}"
    else
        echo "  $FRIGATE_DOCKER"
    fi
else
    echo "  CT ej igång"
fi

# 4. Lagring
echo -e "\n${BOLD}Lagring (Proxmox Root)${NC}"
df -h / | awk 'NR==2 {print "  Använt: " $5 " (" $3 " av " $2 ")"}'

if pvesm status | grep -q "frigate-storage"; then
    echo -e "\n${BOLD}Lagring (Frigate SSD)${NC}"
    df -h /mnt/frigate-storage 2>/dev/null | awk 'NR==2 {print "  Använt: " $5 " (" $3 " av " $2 ")"}' || echo "  Ej monterad"
fi

echo ""
