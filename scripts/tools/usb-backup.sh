#!/usr/bin/env bash

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/config.sh

msg_header "Proxmox USB Backup"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC} Detta skript tar en fullständig 'snapshot'-backup av dina      ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} containers och virtuella maskiner (HA, NPM, Cloudflared) och   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} sparar dem på ett inkopplat USB-minne.                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}Vad som sparas:${NC} Hela operativsystemet, configs, databaser.      ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} ${YELLOW}Vad som INTE sparas:${NC} Frigates videoinspelningar (för stort).  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC} Ett USB-minne på 16GB - 32GB är perfekt för detta.             ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

if [ "$EUID" -ne 0 ]; then
    msg_err "Måste köras som root."
    exit 1
fi

load_config || true
IP_HA="${IP_HA:-100}"
IP_CLOUDFLARED="${IP_CLOUDFLARED:-101}"
IP_NPM="${IP_NPM:-102}"
IP_FRIGATE="${IP_FRIGATE:-103}"
IP_ADGUARD="${IP_ADGUARD:-104}"
IP_GUACAMOLE="${IP_GUACAMOLE:-107}"
IP_DESKTOP="${IP_DESKTOP:-108}"
IP_SAMBA="${IP_SAMBA:-110}"
IP_IMMICH="${IP_IMMICH:-111}"
IP_NUT="${IP_NUT:-112}"

# 1. Hitta USB-enheter
msg_info "Letar efter USB-enheter..."
USB_DEVS=$(lsblk -d -o NAME,TRAN,SIZE | grep usb | awk '{print $1}')

if [ -z "$USB_DEVS" ]; then
    msg_err "Inga USB-enheter hittades. Sätt i ett USB-minne och försök igen."
    exit 1
fi

echo "Hittade följande USB-enheter:"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep usb

echo ""
TARGET_DEV=$(ask_string "Vilken enhet vill du använda? (t.ex. sdb)" "")
if [ -z "$TARGET_DEV" ] || [ ! -b "/dev/$TARGET_DEV" ]; then
    msg_err "Ogiltig enhet."
    exit 1
fi

# 2. Formatering (Valfritt)
if ask_yes_no "Vill du formatera /dev/$TARGET_DEV (RADERAR ALL DATA PÅ USB-MINNET!)?" "N"; then
    msg_info "Formaterar /dev/$TARGET_DEV med ext4..."
    mkfs.ext4 -F /dev/$TARGET_DEV > /dev/null
    msg_ok "Formatering klar."
fi

# 3. Montering
MNT_DIR="/mnt/usb-backup"
mkdir -p $MNT_DIR

# Försök montera första partitionen om den finns, annars hela disken
if [ -b "/dev/${TARGET_DEV}1" ]; then
    mount /dev/${TARGET_DEV}1 $MNT_DIR || { msg_err "Kunde inte montera partitionen."; exit 1; }
else
    mount /dev/$TARGET_DEV $MNT_DIR || { msg_err "Kunde inte montera enheten."; exit 1; }
fi

msg_ok "USB-minne monterat på $MNT_DIR"

# Kolla ledigt utrymme på USB-minnet
USB_FREE=$(df -BG $MNT_DIR | awk 'NR==2 {print $4}' | sed 's/G//')

# 4. Lägg till som Storage i Proxmox (om den inte redan finns)
if ! pvesm status | grep -q "usb-backup"; then
    msg_info "Lägger till USB-minnet som backup-lagring i Proxmox..."
    pvesm add dir usb-backup --path $MNT_DIR --content backup
fi

# 5. Hantera HA VM (storlek)
BACKUP_IDS=""

if qm status $IP_HA &>/dev/null; then
    # Kolla storleken på HA-disken
    HA_SIZE=$(pvesh get /nodes/localhost/qemu/$IP_HA/config --output-format json | grep -o '"scsi0":"[^"]*' | cut -d',' -f2 | grep -o 'size=[^"]*' | cut -d'=' -f2 || echo "32G")
    
    echo -e "\n${YELLOW}Home Assistant VM ($IP_HA) har en disk på $HA_SIZE.${NC}"
    echo -e "Eftersom det är en VM kan vi inte exkludera specifika filer, hela disken måste backas upp."
    echo -e "Ditt USB-minne har $USB_FREE GB ledigt."
    if ask_yes_no "Vill du inkludera Home Assistant i backupen? (Svara N om du hellre använder HA:s inbyggda Google Drive-backup)" "N"; then
        BACKUP_IDS="$BACKUP_IDS $IP_HA"
    else
        msg_info "Hoppar över Home Assistant."
    fi
fi

# 6. Hantera LXC (alla installerade containers)
for id in $IP_CLOUDFLARED $IP_NPM $IP_FRIGATE $IP_ADGUARD $IP_GUACAMOLE $IP_DESKTOP $IP_SAMBA $IP_IMMICH $IP_NUT; do
    if pct status $id &>/dev/null; then
        BACKUP_IDS="$BACKUP_IDS $id"
    fi
done

if [ -z "$BACKUP_IDS" ]; then
    msg_err "Inga containers eller VMs valdes för backup."
    pvesm remove usb-backup 2>/dev/null || true
    umount $MNT_DIR
    exit 1
fi

# Exkludera Frigates videolagring från backupen
if pct status $IP_FRIGATE &>/dev/null; then
    msg_info "Säkerställer att Frigate video-storage exkluderas från backup..."
    # Hitta vilken mpX som pekar på /opt/frigate/storage
    MP_LINE=$(grep "mp=/opt/frigate/storage" /etc/pve/lxc/${IP_FRIGATE}.conf || true)
    if [ -n "$MP_LINE" ]; then
        MP_KEY=$(echo "$MP_LINE" | cut -d':' -f1)
        if ! echo "$MP_LINE" | grep -q "backup=0"; then
            sed -i "s|^${MP_KEY}:.*|&,backup=0|" /etc/pve/lxc/${IP_FRIGATE}.conf
        fi
    else
        msg_warn "Hittade ingen mount point för /opt/frigate/storage i CT $IP_FRIGATE."
        msg_warn "Om video sparas direkt i rootfs kommer backupen bli mycket stor!"
    fi
fi

# 7. Kör Backup (vzdump)
msg_info "Startar backup-processen. Detta kan ta flera minuter beroende på USB-minnets hastighet..."

# Kör vzdump (snapshot mode för noll nertid, zstd komprimering)
vzdump $BACKUP_IDS --storage usb-backup --mode snapshot --compress zstd --notes-template "OptiPlex Homelab Backup {{guestname}}"

msg_info "Kopierar även setup.env..."
cp setup.env $MNT_DIR/dump/setup.env 2>/dev/null || true

# 8. Avslut
msg_info "Avmonterar USB-minnet..."
# Ta bort storage från Proxmox så den inte klagar när USB-minnet dras ur
pvesm remove usb-backup 2>/dev/null || true
umount $MNT_DIR

echo -e "\n${GREEN}✔ Backup slutförd!${NC}"
echo -e "Du kan nu dra ur USB-minnet och förvara det på en säker plats."
echo -e "Vid en krasch sätter du bara i det, monterar det, och klickar 'Restore' i Proxmox GUI."
