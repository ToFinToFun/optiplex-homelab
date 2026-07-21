#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — Doctor (Diagnostikverktyg)
# ============================================================
# Kör detta för att kontrollera att allt fungerar korrekt.
# Användning: bash tools/doctor.sh
# ============================================================

cd "$(dirname "$0")/.."
source lib/ui.sh

# Ladda config om den finns
if [ -f setup.env ]; then
    source setup.env
fi

clear
echo -e "${BOLD}${BLUE}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║     OptiPlex Homelab — Doctor 🩺              ║"
echo "  ╠═══════════════════════════════════════════════╣"
echo "  ║  Kontrollerar systemets hälsa...              ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

ISSUES=0
WARNINGS=0

# ============================================================
# 1. SYSTEM
# ============================================================
msg_header "System"

# Proxmox version
if command -v pveversion &>/dev/null; then
    PVE_VER=$(pveversion --verbose 2>/dev/null | head -1)
    msg_ok "Proxmox: $PVE_VER"
else
    msg_err "Proxmox VE hittades inte!"
    ISSUES=$((ISSUES + 1))
fi

# Kernel
KERNEL=$(uname -r)
msg_ok "Kernel: $KERNEL"

# Uptime
UPTIME=$(uptime -p)
msg_ok "Uptime: $UPTIME"

# CPU
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "?")
msg_ok "CPU-användning: ${CPU_USAGE}%"

# RAM
RAM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
RAM_USED=$(free -h | awk '/^Mem:/{print $3}')
RAM_PCT=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
if [ "$RAM_PCT" -gt 90 ]; then
    msg_warn "RAM: ${RAM_USED}/${RAM_TOTAL} (${RAM_PCT}%) — HÖG ANVÄNDNING!"
    WARNINGS=$((WARNINGS + 1))
else
    msg_ok "RAM: ${RAM_USED}/${RAM_TOTAL} (${RAM_PCT}%)"
fi

# Disk
DISK_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
DISK_USED=$(df -h / | awk 'NR==2{print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
if [ "$DISK_PCT" -gt 85 ]; then
    msg_warn "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%) — NÄSTAN FULL!"
    WARNINGS=$((WARNINGS + 1))
elif [ "$DISK_PCT" -gt 70 ]; then
    msg_info "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)"
else
    msg_ok "Disk (root): ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)"
fi

# Frigate-storage disk (om den finns)
if mountpoint -q /media/frigate 2>/dev/null || pvesm status 2>/dev/null | grep -q "frigate-storage"; then
    if mountpoint -q /media/frigate 2>/dev/null; then
        FRIG_PCT=$(df /media/frigate | awk 'NR==2{print $5}' | tr -d '%')
        FRIG_USED=$(df -h /media/frigate | awk 'NR==2{print $3}')
        FRIG_TOTAL=$(df -h /media/frigate | awk 'NR==2{print $2}')
        if [ "$FRIG_PCT" -gt 85 ]; then
            msg_warn "Disk (Frigate): ${FRIG_USED}/${FRIG_TOTAL} (${FRIG_PCT}%) — NÄSTAN FULL!"
            WARNINGS=$((WARNINGS + 1))
        else
            msg_ok "Disk (Frigate): ${FRIG_USED}/${FRIG_TOTAL} (${FRIG_PCT}%)"
        fi
    fi
fi

# Temperatur
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    if (( $(echo "$TEMP > 80" | bc -l 2>/dev/null || echo 0) )); then
        msg_warn "CPU-temperatur: ${TEMP}°C — HÖG!"
        WARNINGS=$((WARNINGS + 1))
    else
        msg_ok "CPU-temperatur: ${TEMP}°C"
    fi
fi

# ============================================================
# 2. iGPU
# ============================================================
msg_header "Intel iGPU"

if [ -e /dev/dri/renderD128 ]; then
    msg_ok "/dev/dri/renderD128 finns"
else
    msg_err "/dev/dri/renderD128 saknas — iGPU passthrough fungerar inte!"
    msg_info "  Kör: bash setup.sh (BIOS-steget) och starta om"
    ISSUES=$((ISSUES + 1))
fi

if command -v vainfo &>/dev/null; then
    if vainfo 2>&1 | grep -q "Intel iHD driver"; then
        VAAPI_PROFILES=$(vainfo 2>&1 | grep -c "VAProfile" || echo "0")
        msg_ok "VAAPI fungerar (Intel iHD, ${VAAPI_PROFILES} profiler)"
    else
        msg_warn "vainfo körs men Intel iHD-drivrutin hittades inte"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    msg_info "vainfo inte installerat (installeras i Frigate-containern)"
fi

# VT-x / VT-d
if grep -c -E '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1; then
    msg_ok "VT-x (virtualisering) aktiverat"
else
    msg_err "VT-x INTE aktiverat — VMs fungerar inte!"
    ISSUES=$((ISSUES + 1))
fi

if dmesg 2>/dev/null | grep -i -q -e "DMAR" -e "IOMMU"; then
    msg_ok "VT-d / IOMMU aktiverat"
else
    msg_warn "VT-d / IOMMU verkar inte aktivt (behövs för PCI passthrough)"
    WARNINGS=$((WARNINGS + 1))
fi

# ============================================================
# 3. CONTAINERS & VMs
# ============================================================
msg_header "Containers & VMs"

# Funktion för att kolla status
check_ct_vm() {
    local id="$1"
    local name="$2"
    local type="$3"  # "ct" eller "vm"
    
    if [ "$type" == "vm" ]; then
        if qm status $id 2>/dev/null | grep -q "running"; then
            msg_ok "VM $id ($name): Körs"
            return 0
        elif qm status $id 2>/dev/null | grep -q "stopped"; then
            msg_warn "VM $id ($name): Stoppad"
            WARNINGS=$((WARNINGS + 1))
            return 1
        else
            msg_info "VM $id ($name): Finns inte"
            return 2
        fi
    else
        if pct status $id 2>/dev/null | grep -q "running"; then
            msg_ok "CT $id ($name): Körs"
            return 0
        elif pct status $id 2>/dev/null | grep -q "stopped"; then
            msg_warn "CT $id ($name): Stoppad"
            WARNINGS=$((WARNINGS + 1))
            return 1
        else
            msg_info "CT $id ($name): Finns inte"
            return 2
        fi
    fi
}

# Kolla alla tjänster
HA_ID="${IP_HA:-100}"
CF_ID="${IP_CLOUDFLARED:-101}"
NPM_ID="${IP_NPM:-102}"
FRIG_ID="${IP_FRIGATE:-103}"

check_ct_vm "$HA_ID" "Home Assistant" "vm"
check_ct_vm "$CF_ID" "Cloudflared" "ct"
check_ct_vm "$NPM_ID" "NPM" "ct"
check_ct_vm "$FRIG_ID" "Frigate" "ct"

# ============================================================
# 4. DOCKER (i Frigate-container)
# ============================================================
msg_header "Docker-tjänster"

if pct status $FRIG_ID 2>/dev/null | grep -q "running"; then
    # Kolla Docker i Frigate
    DOCKER_STATUS=$(pct exec $FRIG_ID -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "")
    if [ -n "$DOCKER_STATUS" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -q "Up"; then
                msg_ok "Docker: $line"
            else
                msg_warn "Docker: $line"
                WARNINGS=$((WARNINGS + 1))
            fi
        done <<< "$DOCKER_STATUS"
    else
        msg_warn "Kunde inte kontakta Docker i Frigate-containern"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

if pct status $NPM_ID 2>/dev/null | grep -q "running"; then
    DOCKER_STATUS=$(pct exec $NPM_ID -- docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "")
    if [ -n "$DOCKER_STATUS" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -q "Up"; then
                msg_ok "Docker (NPM): $line"
            else
                msg_warn "Docker (NPM): $line"
                WARNINGS=$((WARNINGS + 1))
            fi
        done <<< "$DOCKER_STATUS"
    fi
fi

# ============================================================
# 5. NÄTVERK & TUNNEL
# ============================================================
msg_header "Nätverk & Tunnel"

# Internet
if ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
    msg_ok "Internet: Ansluten"
else
    msg_err "Internet: INGEN ANSLUTNING!"
    ISSUES=$((ISSUES + 1))
fi

# DNS
if host google.com > /dev/null 2>&1; then
    msg_ok "DNS: Fungerar"
else
    msg_warn "DNS: Problem med namnupplösning"
    WARNINGS=$((WARNINGS + 1))
fi

# Cloudflare Tunnel
if pct status $CF_ID 2>/dev/null | grep -q "running"; then
    TUNNEL_STATUS=$(pct exec $CF_ID -- cloudflared tunnel info 2>/dev/null | head -5 || echo "")
    if pct exec $CF_ID -- pgrep -f cloudflared > /dev/null 2>&1; then
        msg_ok "Cloudflare Tunnel: Processen körs"
    else
        msg_warn "Cloudflare Tunnel: Processen körs INTE"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Tjänst-portar
check_port() {
    local host="$1"
    local port="$2"
    local name="$3"
    if nc -z -w 2 "$host" "$port" 2>/dev/null; then
        msg_ok "$name: Svarar på ${host}:${port}"
    else
        msg_warn "$name: Svarar INTE på ${host}:${port}"
        WARNINGS=$((WARNINGS + 1))
    fi
}

NW="${NETWORK_PREFIX:-192.168.1}"
check_port "${NW}.${HA_ID}" 8123 "Home Assistant"
check_port "${NW}.${FRIG_ID}" 5000 "Frigate"
check_port "${NW}.${NPM_ID}" 81 "NPM Admin"

# ============================================================
# 6. SAMMANFATTNING
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $ISSUES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ Allt ser bra ut! Inga problem hittades.${NC}"
elif [ $ISSUES -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}⚠ ${WARNINGS} varning(ar) — men inget kritiskt.${NC}"
else
    echo -e "  ${RED}${BOLD}✗ ${ISSUES} kritiskt problem — ${WARNINGS} varning(ar)${NC}"
    echo -e "  ${RED}  Åtgärda de röda problemen ovan.${NC}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
