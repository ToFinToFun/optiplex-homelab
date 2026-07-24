#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh

msg_header "OptiPlex Homelab - Avinstallation"

if [ "$EUID" -ne 0 ]; then
    msg_err "Detta skript måste köras som root."
    exit 1
fi

load_config || msg_warn "Ingen setup.env hittades. Använder standard-ID:n."

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

msg_warn "Detta kommer att PERMANENT RADERA följande containers/VMs:"
FOUND_ANY=false
check_id_exists $IP_HA && echo " - VM $IP_HA (Home Assistant)" && FOUND_ANY=true
check_id_exists $IP_CLOUDFLARED && echo " - CT $IP_CLOUDFLARED (Cloudflared)" && FOUND_ANY=true
check_id_exists $IP_NPM && echo " - CT $IP_NPM (NPM)" && FOUND_ANY=true
check_id_exists $IP_FRIGATE && echo " - CT $IP_FRIGATE (Frigate)" && FOUND_ANY=true
check_id_exists $IP_ADGUARD && echo " - CT $IP_ADGUARD (AdGuard Home)" && FOUND_ANY=true
check_id_exists $IP_GUACAMOLE && echo " - CT $IP_GUACAMOLE (Guacamole)" && FOUND_ANY=true
check_id_exists $IP_DESKTOP && echo " - CT $IP_DESKTOP (Linux Desktop)" && FOUND_ANY=true
check_id_exists $IP_SAMBA && echo " - CT $IP_SAMBA (Samba)" && FOUND_ANY=true
check_id_exists $IP_IMMICH && echo " - CT $IP_IMMICH (Immich)" && FOUND_ANY=true
check_id_exists $IP_NUT && echo " - CT $IP_NUT (NUT UPS)" && FOUND_ANY=true

if [ "$FOUND_ANY" != "true" ]; then
    msg_info "Inga installerade containers/VMs hittades. Inget att ta bort."
    exit 0
fi

echo ""
if ! ask_yes_no "Är du HELT SÄKER på att du vill ta bort dessa?" "N"; then
    msg_info "Avbryter."
    exit 0
fi

for id in $IP_HA $IP_CLOUDFLARED $IP_NPM $IP_FRIGATE $IP_ADGUARD $IP_GUACAMOLE $IP_DESKTOP $IP_SAMBA $IP_IMMICH $IP_NUT; do
    if check_id_exists $id; then
        msg_info "Stoppar och tar bort ID $id..."
        if qm status $id &>/dev/null; then
            qm stop $id >/dev/null 2>&1 || true
            sleep 2
            qm destroy $id --destroy-unreferenced-disks 1 --purge 1 >/dev/null
        else
            pct stop $id >/dev/null 2>&1 || true
            sleep 1
            pct destroy $id --purge >/dev/null
        fi
        msg_ok "ID $id borttaget."
    fi
done

rm -f .install_state
msg_ok "Avinstallation klar. Du kan nu köra setup.sh igen."
