#!/usr/bin/env bash
set -e

source setup.env

echo "Laddar ner senaste Home Assistant OS..."
URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest | grep "browser_download_url.*haos_ova-.*\.qcow2.xz" | cut -d '"' -f 4)
wget -O haos.qcow2.xz "$URL"
xz -d -v haos.qcow2.xz

echo "Skapar VM $IP_HA (Home Assistant)..."
qm create $IP_HA \
    --name homeassistant \
    --cores 2 \
    --memory 4096 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --bios ovmf \
    --efidisk0 ${STORAGE_POOL}:0,efitype=4m,pre-enrolled-keys=1 \
    --machine q35 \
    --agent 1

echo "Importerar HAOS disk..."
qm importdisk $IP_HA haos.qcow2 $STORAGE_POOL
qm set $IP_HA --scsihw virtio-scsi-pci --scsi0 ${STORAGE_POOL}:vm-${IP_HA}-disk-1
qm set $IP_HA --boot c --bootdisk scsi0

# Ändra storlek på disken till 32GB
qm resize $IP_HA scsi0 32G

echo "Startar Home Assistant..."
qm start $IP_HA

echo "Städar upp..."
rm haos.qcow2

echo "Home Assistant-installation klar! Vänta några minuter för att det ska starta upp helt."
