#!/usr/bin/env bash
set -e
source lib/ui.sh
source lib/proxmox.sh

msg_info "Letar efter extra lagringsdisk för Frigate..."

EXTRA_DISK=$(find_extra_disk)

if [ -z "$EXTRA_DISK" ]; then
    msg_warn "Hittade ingen extra disk. Frigate kommer använda samma disk som Proxmox (local-lvm)."
    msg_warn "Detta kan slita på din OS-disk snabbare."
    exit 0
fi

msg_info "Hittade oanvänd disk: $EXTRA_DISK"

if ask_yes_no "Vill du formatera $EXTRA_DISK och sätta upp den som 'frigate-storage'?" "Y"; then
    msg_info "Formaterar $EXTRA_DISK med ext4..."
    mkfs.ext4 -F $EXTRA_DISK > /dev/null
    
    msg_info "Skapar mount-punkt och uppdaterar fstab..."
    mkdir -p /mnt/frigate-storage
    
    # Hämta UUID
    UUID=$(blkid -s UUID -o value $EXTRA_DISK)
    
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID /mnt/frigate-storage ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
    
    mount -a
    
    msg_info "Lägger till lagringen i Proxmox..."
    if ! pvesm status | grep -q "frigate-storage"; then
        pvesm add dir frigate-storage --path /mnt/frigate-storage --content images,rootdir,vztmpl,backup,iso
    fi
    
    msg_ok "Lagring konfigurerad! $EXTRA_DISK är nu monterad på /mnt/frigate-storage."
    
    # Spara i config att vi ska använda denna pool
    sed -i 's/STORAGE_POOL=.*/STORAGE_POOL="frigate-storage"/g' setup.env
else
    msg_skip "Hoppar över disk-konfiguration."
fi
