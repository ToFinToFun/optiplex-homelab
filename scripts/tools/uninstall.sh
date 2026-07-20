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

msg_warn "Detta kommer att PERMANENT RADERA följande containers/VMs:"
check_id_exists $IP_HA && echo " - VM $IP_HA (Home Assistant)"
check_id_exists $IP_CLOUDFLARED && echo " - CT $IP_CLOUDFLARED (Cloudflared)"
check_id_exists $IP_NPM && echo " - CT $IP_NPM (NPM)"
check_id_exists $IP_FRIGATE && echo " - CT $IP_FRIGATE (Frigate)"

echo ""
if ! ask_yes_no "Är du HELT SÄKER på att du vill ta bort dessa?" "N"; then
    msg_info "Avbryter."
    exit 0
fi

for id in $IP_HA $IP_CLOUDFLARED $IP_NPM $IP_FRIGATE; do
    if check_id_exists $id; then
        msg_info "Stoppar och tar bort ID $id..."
        if qm status $id &>/dev/null; then
            qm stop $id >/dev/null 2>&1 || true
            qm destroy $id --destroy-unreferenced-disks 1 --purge 1 >/dev/null
        else
            pct stop $id >/dev/null 2>&1 || true
            pct destroy $id >/dev/null
        fi
        msg_ok "ID $id borttaget."
    fi
done

rm -f .install_state
msg_ok "Avinstallation klar. Du kan nu köra setup.sh igen."
