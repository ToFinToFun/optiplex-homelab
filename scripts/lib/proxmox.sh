#!/usr/bin/env bash

# Proxmox Helpers

check_is_proxmox() {
    if ! command -v pct &> /dev/null || ! command -v qm &> /dev/null; then
        return 1
    fi
    return 0
}

check_id_exists() {
    local id=$1
    if pct status $id &>/dev/null || qm status $id &>/dev/null; then
        return 0 # Finns
    else
        return 1 # Finns inte
    fi
}

# Hitta CT-ID via hostname (robust — fungerar oavsett vilket ID som användes)
# Returnerar CT-ID om hittat, tom sträng om inte
find_ct_by_hostname() {
    local hostname="$1"
    # pct list: VMID | Status | Lock | Name
    pct list 2>/dev/null | awk -v h="$hostname" '$NF == h {print $1; exit}'
}

# Hitta VM-ID via namn
find_vm_by_name() {
    local name="$1"
    qm list 2>/dev/null | awk -v n="$name" '$2 == n {print $1; exit}'
}

# Resolve CT-ID: försök hostname-lookup först, fallback till config-variabel
# Användning: FRIGATE_ID=$(resolve_ct_id "frigate" "$IP_FRIGATE")
resolve_ct_id() {
    local hostname="$1"
    local fallback_id="$2"
    local found_id
    
    found_id=$(find_ct_by_hostname "$hostname")
    if [ -n "$found_id" ]; then
        echo "$found_id"
    elif [ -n "$fallback_id" ] && check_id_exists "$fallback_id" 2>/dev/null; then
        echo "$fallback_id"
    else
        echo ""
    fi
}

# Resolve VM-ID: försök namn-lookup först, fallback till config-variabel
resolve_vm_id() {
    local name="$1"
    local fallback_id="$2"
    local found_id
    
    found_id=$(find_vm_by_name "$name")
    if [ -n "$found_id" ]; then
        echo "$found_id"
    elif [ -n "$fallback_id" ] && check_id_exists "$fallback_id" 2>/dev/null; then
        echo "$fallback_id"
    else
        echo ""
    fi
}

get_debian_template() {
    # Uppdatera pveam cache om den är äldre än 7 dagar eller saknas
    if [ $(find /var/lib/pve-manager/apl-available/ -mtime +7 2>/dev/null | wc -l) -gt 0 ] || \
       [ ! -f /var/lib/pve-manager/apl-available/pveam-download.proxmox.com ]; then
        pveam update > /dev/null 2>&1
    fi
    
    local storage="local" # Default storage for templates
    
    # Försök Debian 13 (Trixie) först (Proxmox 9), sedan Debian 12 (Bookworm)
    local template=""
    template=$(pveam available -section system | grep "debian-13-standard" | awk '{print $2}' | sort -V | tail -n 1)
    if [ -z "$template" ]; then
        template=$(pveam available -section system | grep "debian-12-standard" | awk '{print $2}' | sort -V | tail -n 1)
    fi
    
    if [ -z "$template" ]; then
        msg_err "Ingen Debian LXC-template hittades i Proxmox repos!"
        msg_info "Kör manuellt: pveam update && pveam available -section system | grep debian"
        echo ""
        return
    fi
    
    local template_name=$(basename "$template")
    
    # Ladda ner om den inte redan finns
    if [ ! -f "/var/lib/vz/template/cache/$template_name" ]; then
        msg_info "Laddar ner ${template_name} (tar en minut)..."
        if ! pveam download $storage "$template" > /dev/null 2>&1; then
            msg_err "Nedladdning av template misslyckades!"
            msg_info "Kontrollera internet: ping download.proxmox.com"
            echo ""
            return
        fi
    fi
    
    # Verifiera att filen faktiskt finns och inte är tom
    if [ ! -s "/var/lib/vz/template/cache/$template_name" ]; then
        msg_err "Template-filen är tom eller korrupt: $template_name"
        rm -f "/var/lib/vz/template/cache/$template_name"
        echo ""
        return
    fi
    
    msg_ok "Template: $template_name"
    echo "${storage}:vztmpl/${template_name}"
}

find_storage_pool() {
    # Letar efter bästa storage poolen för CT/VM
    if pvesm status | grep -q "local-zfs"; then
        echo "local-zfs"
    elif pvesm status | grep -q "local-lvm"; then
        echo "local-lvm"
    else
        echo "local"
    fi
}

find_extra_disks() {
    # Letar efter diskar som inte används av Proxmox root/LVM
    local extra_disks=""
    for disk in $(lsblk -nd --output NAME,TYPE | grep disk | awk '{print $1}'); do
        if ! lsblk -n /dev/$disk | grep -q "part\|lvm"; then
            extra_disks="$extra_disks /dev/$disk"
        fi
    done
    echo "$extra_disks"
}

# ============================================================
# BIOS & Hårdvarustatus — visar ✓/✗ för kritiska inställningar
# Returnerar antal problem via BIOS_ISSUES (global)
# ============================================================
show_bios_status() {
    tty_echo ""
    tty_echo "  ${BOLD}── BIOS & Hårdvarustatus ──${NC}"
    tty_echo ""

    BIOS_ISSUES=0

    # VT-x
    if grep -c -E '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1; then
        tty_echo "  ${GREEN}✓${NC} VT-x (Virtualisering) — aktiverat"
    else
        tty_echo "  ${RED}✗${NC} VT-x (Virtualisering) — EJ aktiverat"
        BIOS_ISSUES=$((BIOS_ISSUES + 1))
    fi

    # VT-d / IOMMU
    if dmesg 2>/dev/null | grep -i -q -e "DMAR" -e "IOMMU"; then
        tty_echo "  ${GREEN}✓${NC} VT-d (IOMMU/Passthrough) — aktiverat"
    else
        tty_echo "  ${RED}✗${NC} VT-d (IOMMU/Passthrough) — EJ aktiverat"
        BIOS_ISSUES=$((BIOS_ISSUES + 1))
    fi

    # iGPU
    if [ -e /dev/dri/renderD128 ]; then
        local VAAPI_INFO=""
        if command -v vainfo &>/dev/null; then
            VAAPI_INFO=$(vainfo 2>/dev/null | grep "vainfo: Driver" | head -1 | sed 's/.*: //')
        fi
        tty_echo "  ${GREEN}✓${NC} Intel iGPU — hittad (/dev/dri/renderD128) ${VAAPI_INFO:+[$VAAPI_INFO]}"
    else
        tty_echo "  ${RED}✗${NC} Intel iGPU — EJ hittad"
        BIOS_ISSUES=$((BIOS_ISSUES + 1))
    fi

    # WoL
    local PRIMARY_NIC_CHECK
    PRIMARY_NIC_CHECK=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    if [ -n "$PRIMARY_NIC_CHECK" ] && command -v ethtool &>/dev/null; then
        local WOL_CHECK
        WOL_CHECK=$(ethtool "$PRIMARY_NIC_CHECK" 2>/dev/null | grep "Wake-on:" | tail -1 | awk '{print $2}')
        if echo "$WOL_CHECK" | grep -q "g"; then
            tty_echo "  ${GREEN}✓${NC} Wake-on-LAN — aktiverat ($PRIMARY_NIC_CHECK)"
        else
            tty_echo "  ${YELLOW}⚠${NC} Wake-on-LAN — EJ aktiverat"
        fi
    fi

    # TRIM
    if systemctl is-active fstrim.timer &>/dev/null; then
        tty_echo "  ${GREEN}✓${NC} SSD TRIM — aktiverat (veckovis)"
    else
        tty_echo "  ${YELLOW}⚠${NC} SSD TRIM — ej aktiverat"
    fi

    tty_echo ""

    if [ $BIOS_ISSUES -eq 0 ]; then
        msg_ok "Alla kritiska BIOS-inställningar verifierade!"
    else
        msg_warn "$BIOS_ISSUES kritisk(a) inställning(ar) saknas — kan fixas i steg 1 (Proxmox Host)."
    fi
}
