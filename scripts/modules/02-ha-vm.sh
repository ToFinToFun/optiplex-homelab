#!/usr/bin/env bash
source setup.env
source lib/ui.sh

msg_info "Laddar ner senaste Home Assistant OS..."
URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest | grep "browser_download_url.*haos_ova-.*\.qcow2.xz" | cut -d '"' -f 4)

if [ -z "$URL" ]; then
    msg_err "Kunde inte hämta nedladdnings-URL från GitHub. Kontrollera internet."
    exit 1
fi

wget -q --show-progress -O haos.qcow2.xz "$URL"
if [ ! -f haos.qcow2.xz ] || [ ! -s haos.qcow2.xz ]; then
    msg_err "Nedladdningen misslyckades eller filen är tom."
    exit 1
fi

xz -d haos.qcow2.xz

msg_info "Skapar VM $IP_HA..."
qm create $IP_HA \
    --name homeassistant \
    --cores 2 \
    --memory 4096 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --bios ovmf \
    --efidisk0 ${STORAGE_POOL}:0,efitype=4m,pre-enrolled-keys=0 \
    --machine q35 \
    --agent 1 \
    --onboot 1

msg_info "Importerar HAOS disk till $STORAGE_POOL..."
qm importdisk $IP_HA haos.qcow2 $STORAGE_POOL > /dev/null
qm set $IP_HA --scsihw virtio-scsi-pci --scsi0 ${STORAGE_POOL}:vm-${IP_HA}-disk-1,discard=on,ssd=1,cache=writethrough > /dev/null
qm set $IP_HA --boot order=scsi0 > /dev/null

msg_info "Expanderar disken till 32GB..."
qm resize $IP_HA scsi0 32G > /dev/null

msg_info "Startar Home Assistant..."
qm start $IP_HA

msg_info "Städar upp tillfälliga filer..."
rm -f haos.qcow2

msg_ok "Home Assistant VM skapad och startad!"
