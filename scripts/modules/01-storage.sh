#!/usr/bin/env bash
source lib/ui.sh
source lib/proxmox.sh

msg_info "Letar efter extra lagringsdisk för Frigate..."

EXTRA_DISKS=$(find_extra_disks)

if [ -z "$EXTRA_DISKS" ]; then
    msg_warn "Hittade ingen extra disk. Frigate kommer använda samma disk som Proxmox (local-lvm)."
    msg_warn "Detta kan slita på din OS-disk snabbare."
    exit 0
fi

# Konvertera till array
read -a DISK_ARRAY <<< "$EXTRA_DISKS"

if [ ${#DISK_ARRAY[@]} -eq 1 ]; then
    TARGET_DISK="${DISK_ARRAY[0]}"
    msg_info "Hittade oanvänd disk: $TARGET_DISK"
else
    msg_info "Hittade flera oanvända diskar:"
    for i in "${!DISK_ARRAY[@]}"; do
        echo "[$i] ${DISK_ARRAY[$i]} ($(lsblk -nd -o SIZE ${DISK_ARRAY[$i]}))"
    done
    
    while true; do
        read -p "Vilken disk vill du använda för Frigate? (0-$((${#DISK_ARRAY[@]}-1)) eller tryck Enter för att skippa): " disk_choice
        if [ -z "$disk_choice" ]; then
            msg_skip "Hoppar över disk-konfiguration."
            exit 0
        fi
        if [[ "$disk_choice" =~ ^[0-9]+$ ]] && [ "$disk_choice" -ge 0 ] && [ "$disk_choice" -lt "${#DISK_ARRAY[@]}" ]; then
            TARGET_DISK="${DISK_ARRAY[$disk_choice]}"
            break
        else
            echo "Ogiltigt val, försök igen."
        fi
    done
fi

if ask_yes_no "Vill du formatera $TARGET_DISK och sätta upp den som 'frigate-storage'?" "Y"; then
    msg_info "Formaterar $TARGET_DISK med ext4..."
    mkfs.ext4 -F $TARGET_DISK > /dev/null
    
    msg_info "Skapar mount-punkt och uppdaterar fstab..."
    mkdir -p /mnt/frigate-storage
    
    # Hämta UUID
    UUID=$(blkid -s UUID -o value $TARGET_DISK)
    
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID /mnt/frigate-storage ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
    
    mount -a
    
    msg_info "Lägger till lagringen i Proxmox..."
    if ! pvesm status | grep -q "frigate-storage"; then
        pvesm add dir frigate-storage --path /mnt/frigate-storage --content images,rootdir,vztmpl,backup,iso
    fi
    
    msg_ok "Lagring konfigurerad! $TARGET_DISK är nu monterad på /mnt/frigate-storage."
    
    # Vi ändrar INTE STORAGE_POOL i setup.env eftersom den styr OS-diskarna (som ska ligga på snabb NVMe).
    # 05-frigate.sh kommer automatiskt hitta 'frigate-storage' och mounta den för videoinspelningar.
    msg_ok "Lagringspool frigate-storage är nu redo att användas för videoinspelningar!"
else
    msg_skip "Hoppar över disk-konfiguration."
fi
