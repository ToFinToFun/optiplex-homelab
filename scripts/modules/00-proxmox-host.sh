#!/usr/bin/env bash
source lib/ui.sh
source lib/config.sh
source lib/proxmox.sh

# ============================================================
# Proxmox Host Konfiguration
# ============================================================

# --- Repos ---
msg_info "Konfigurerar Proxmox Repositories..."

# Detektera codename
CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)
CODENAME="${CODENAME:-bookworm}"

# Ta bort enterprise repo
rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null

# Lägg till no-subscription repo om det saknas
if ! grep -q "pve-no-subscription" /etc/apt/sources.list 2>/dev/null && \
   ! find /etc/apt/sources.list.d/ -name "*.list" -name "*.sources" -exec grep -l "pve-no-subscription" {} \; 2>/dev/null | grep -q .; then
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" >> /etc/apt/sources.list
    msg_ok "La till pve-no-subscription repo"
fi

# Fixa ceph repo
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    sed -i 's/enterprise/no-subscription/g' /etc/apt/sources.list.d/ceph.list
fi

msg_info "Uppdaterar paketlistor..."
apt-get update -qq 2>&1 | grep -v "^$" || true

# ============================================================
# BIOS AUTO-KONFIGURATION (Dell Command Configure)
# ============================================================

# ============================================================
# BIOS VERIFIERING (använder delad funktion från lib/proxmox.sh)
# ============================================================
show_bios_status

# Beslut baserat på status
if [ $BIOS_ISSUES -eq 0 ]; then
    if [ "$(get_state bios_configured)" == "true" ]; then
        # Redan konfigurerat och allt fungerar
        if ask_yes_no "Vill du köra BIOS-konfiguration ändå (t.ex. ändra enskild inställning)?" "N"; then
            RUN_BIOS_CONFIG=true
        else
            RUN_BIOS_CONFIG=false
        fi
    else
        # Aldrig konfigurerat men allt fungerar (manuellt inställt)
        msg_info "BIOS verkar vara korrekt inställt (manuellt eller från fabrik)."
        if ask_yes_no "Vill du köra automatisk BIOS-optimering ändå?" "N"; then
            RUN_BIOS_CONFIG=true
        else
            RUN_BIOS_CONFIG=false
            set_state bios_configured true
        fi
    fi
else
    msg_warn "$BIOS_ISSUES kritisk(a) inställning(ar) saknas!"
    
    if [ "$(get_state bios_configured)" == "true" ] && [ "$(get_state needs_reboot)" == "true" ]; then
        msg_info "Du konfigurerade BIOS tidigare men har inte startat om ännu."
        if ask_yes_no "Vill du starta om nu?" "Y"; then
            msg_info "Startar om om 5 sekunder... Kör setup.sh igen efter omstart."
            sleep 5
            reboot
            exit 0
        fi
        RUN_BIOS_CONFIG=false
    else
        if ask_yes_no "Vill du köra automatisk BIOS-konfiguration för att fixa detta?" "Y"; then
            RUN_BIOS_CONFIG=true
        else
            RUN_BIOS_CONFIG=false
            msg_info "Se docs/01-bios-setup.md för manuell BIOS-guide."
        fi
    fi
fi

if [ "$RUN_BIOS_CONFIG" != "true" ]; then
    # Hoppa över BIOS-config, gå vidare till hostname etc.
    true
else
    echo "" > /dev/tty
    print_banner "BIOS-optimering (Dell Command Configure)" \
"Dell OptiPlex XE4 kan konfigureras direkt från Linux
utan att du behöver gå in i BIOS manuellt.

Detta ställer in ALLA inställningar optimalt:
  • Virtualisering (VT-x, VT-d) för VMs
  • iGPU Multi-Display för Frigate AI
  • Wake-on-LAN för fjärrstart
  • AC Recovery: Always On (startar efter strömavbrott)
  • Deep Sleep: Av (nätverkskortet alltid redo)
  • Secure Boot: Av (krävs för Proxmox)
  • Headless-drift (inga boot-stopp utan skärm)
  • DMA Protection: Av (krävs för GPU passthrough)"

    if ask_yes_no "Vill du optimera BIOS-inställningarna automatiskt?" "N"; then

    msg_info "Installerar Dell Command Configure..."
    
    # Kolla om cctk redan finns
    CCTK=""
    for path in /opt/dell/dcc/cctk /opt/dell/toolkit/bin/cctk; do
        if [ -x "$path" ]; then
            CCTK="$path"
            break
        fi
    done

    if [ -n "$CCTK" ]; then
        msg_ok "Dell Command Configure redan installerat ($CCTK)"
    else
        # Ladda ner och installera DCC 5.1.0 (senaste med Ubuntu 22.04/24.04-stöd)
        DCC_URL="https://dl.dell.com/FOLDER12705833M/1/command-configure_5.1.0-6.ubuntu22_amd64.tar.gz"
        DCC_TGZ="/tmp/dell-command-configure.tar.gz"
        DCC_DIR="/tmp/dell-command-configure"
        
        msg_info "Laddar ner Dell Command Configure 5.1.0..."
        # Dell CDN kräver User-Agent header
        if wget -q --user-agent="Mozilla/5.0 (X11; Linux x86_64)" -O "$DCC_TGZ" "$DCC_URL" 2>/dev/null; then
            msg_ok "Nedladdning klar (2.3 MB)"
            
            # Extrahera tar.gz och hitta .deb-filen
            rm -rf "$DCC_DIR"
            mkdir -p "$DCC_DIR"
            tar -xzf "$DCC_TGZ" -C "$DCC_DIR" 2>/dev/null
            
            # Hitta .deb-filer (srvadmin-hapi + command-configure)
            HAPI_DEB=$(find "$DCC_DIR" -name "srvadmin-hapi*" -name "*.deb" -type f | head -1)
            DCC_DEB=$(find "$DCC_DIR" -name "command-configure*" -name "*.deb" -type f | head -1)
            
            if [ -z "$HAPI_DEB" ] && [ -z "$DCC_DEB" ]; then
                msg_err "Kunde inte hitta .deb-filer i arkivet."
                msg_info "Du kan ställa in BIOS manuellt — se docs/01-bios-setup.md"
            else
                # Steg 1: Installera beroenden
                msg_info "Installerar beroenden (libsmbios, pciutils, openssl)..."
                apt-get install -y libsmbios-dev pciutils openssl > /dev/null 2>&1 || true
                
                # Steg 2: Installera srvadmin-hapi FÖRST (ger libdchbas.so.9)
                # Känt problem: postinst-scriptet kan misslyckas (instsvcdrv.service)
                # Lösning: skapa en dummy-postinst som workaround
                INSTALL_OK=true
                
                if [ -n "$HAPI_DEB" ]; then
                    msg_info "Installerar srvadmin-hapi (HAPI driver)..."
                    if ! dpkg -i "$HAPI_DEB" 2>&1 | tail -5; then
                        # Känd fix: postinst misslyckas p.g.a. instsvcdrv.service
                        # Skapa dummy-postinst och kör configure igen
                        msg_warn "HAPI postinst misslyckades (känt problem) — applicerar workaround..."
                        cat > /var/lib/dpkg/info/srvadmin-hapi.postinst << 'POSTINST'
#!/bin/bash
# Workaround: instsvcdrv.service not needed on Proxmox
/bin/true
POSTINST
                        chmod +x /var/lib/dpkg/info/srvadmin-hapi.postinst
                        dpkg --configure -a > /dev/null 2>&1
                        # Verifiera att filerna faktiskt installerades
                        if [ -f /opt/dell/srvadmin/lib64/libdchbas.so.9 ] || \
                           find /opt/dell -name "libdchbas.so*" 2>/dev/null | grep -q .; then
                            msg_ok "srvadmin-hapi installerat (med workaround)"
                        else
                            # Tvinga ominstallation
                            dpkg -i --force-confnew "$HAPI_DEB" > /dev/null 2>&1 || true
                            dpkg --configure -a > /dev/null 2>&1
                        fi
                    else
                        msg_ok "srvadmin-hapi installerat"
                    fi
                    apt-get install -f -y > /dev/null 2>&1 || true
                fi
                
                # Steg 3: Installera command-configure (cctk)
                if [ -n "$DCC_DEB" ]; then
                    msg_info "Installerar Dell Command Configure (cctk)..."
                    if dpkg -i "$DCC_DEB" > /dev/null 2>&1; then
                        msg_ok "Dell Command Configure installerat"
                    else
                        apt-get install -f -y > /dev/null 2>&1
                        if dpkg -i "$DCC_DEB" > /dev/null 2>&1; then
                            msg_ok "Dell Command Configure installerat (med fixade beroenden)"
                        else
                            msg_err "Kunde inte installera Dell Command Configure."
                            INSTALL_OK=false
                        fi
                    fi
                fi
                
                # Steg 4: Kör ldconfig så systemet hittar de nya biblioteken
                ldconfig 2>/dev/null || true
                
                # Steg 5: Verifiera att libdchbas.so hittas
                if [ "$INSTALL_OK" == "true" ]; then
                    MISSING_LIBS=$(ldd /opt/dell/dcc/cctk 2>/dev/null | grep "not found" || true)
                    if [ -n "$MISSING_LIBS" ]; then
                        msg_warn "Saknade bibliotek efter installation:"
                        echo "$MISSING_LIBS" | head -5
                        msg_info "Försöker fixa med LD_LIBRARY_PATH..."
                    fi
                else
                    msg_info "Du kan ställa in BIOS manuellt — se docs/01-bios-setup.md"
                fi
            fi
            
            # Städa upp
            rm -rf "$DCC_TGZ" "$DCC_DIR"
        else
            msg_err "Kunde inte ladda ner Dell Command Configure."
            msg_info "Kontrollera internetanslutningen eller ställ in BIOS manuellt."
            msg_info "Se docs/01-bios-setup.md för steg-för-steg-guide."
        fi
        
        # Hitta cctk efter installation
        for path in /opt/dell/dcc/cctk /opt/dell/toolkit/bin/cctk; do
            if [ -x "$path" ]; then
                CCTK="$path"
                break
            fi
        done
    fi
    
    if [ -n "$CCTK" ] && [ -x "$CCTK" ]; then
        # Säkerställ att systemet hittar DCC-biblioteken
        # 1. Skapa persistent ld.so.conf.d-fil (så ldconfig hittar dem)
        if [ -d /opt/dell/dcc ] && [ ! -f /etc/ld.so.conf.d/dell-dcc.conf ]; then
            echo "/opt/dell/dcc" > /etc/ld.so.conf.d/dell-dcc.conf
            # Lägg till srvadmin-lib64 om den finns
            [ -d /opt/dell/srvadmin/lib64 ] && echo "/opt/dell/srvadmin/lib64" >> /etc/ld.so.conf.d/dell-dcc.conf
            ldconfig 2>/dev/null || true
        fi
        
        # 2. Sätt LD_LIBRARY_PATH som fallback för denna session
        export LD_LIBRARY_PATH="/opt/dell/dcc:/opt/dell/srvadmin/lib64:${LD_LIBRARY_PATH:-}"
        
        # Snabbtest: kan cctk köras?
        if ! $CCTK --version &>/dev/null && ! $CCTK --help &>/dev/null; then
            msg_err "cctk kunde inte köras."
            # Visa diagnostik
            msg_info "Diagnostik:"
            ldd "$CCTK" 2>/dev/null | grep "not found" | while read -r line; do
                echo "    $line"
            done
            msg_info "Du kan ställa in BIOS manuellt — se docs/01-bios-setup.md"
            CCTK=""  # Avbryt BIOS-konfiguration
        else
            msg_ok "cctk verifierat — redo att konfigurera BIOS"
        fi
    fi
    
    if [ -n "$CCTK" ] && [ -x "$CCTK" ]; then
        msg_info "Konfigurerar BIOS (detta tar några sekunder)..."
        echo ""
        
        BIOS_ERRORS=0
        
        # Funktion för att sätta BIOS-inställning med feedback
        set_bios() {
            local setting="$1"
            local desc="$2"
            local result
            
            result=$($CCTK $setting 2>&1)
            if echo "$result" | grep -qi "success\|already\|read only"; then
                msg_ok "$desc"
            elif echo "$result" | grep -qi "not found\|unsupported\|invalid"; then
                msg_warn "$desc — inställningen stöds inte på denna modell (hoppar över)"
            else
                msg_err "$desc — misslyckades: $result"
                BIOS_ERRORS=$((BIOS_ERRORS + 1))
            fi
        }
        
        echo -e "  ${BOLD}── Storage ──${NC}"
        set_bios "--sataoperation=ahci" "SATA Operation → AHCI"
        
        echo -e "\n  ${BOLD}── Display ──${NC}"
        set_bios "--multidisplay=enable" "Multi-Display → Enabled"
        set_bios "--primarydisplay=auto" "Primary Display → Auto"
        set_bios "--fullscreenlogo=disable" "Full Screen Logo → Disabled"
        
        echo -e "\n  ${BOLD}── Nätverk ──${NC}"
        set_bios "--embnic1=enabledwpxe" "Integrated NIC → Enabled with PXE"
        set_bios "--uefinwstack=enable" "UEFI Network Stack → Enabled"
        
        echo -e "\n  ${BOLD}── Power Management ──${NC}"
        set_bios "--acpwrrecovery=on" "AC Recovery → Always On"
        set_bios "--blocksleep=enable" "Block Sleep → Enabled"
        set_bios "--deepsleepctrl=disable" "Deep Sleep Control → Disabled"
        set_bios "--wakeonlan=lanwlan" "Wake on LAN → LAN+WLAN"
        set_bios "--usbwake=enable" "USB Wake Support → Enabled"
        set_bios "--usbpowershare=disable" "USB PowerShare → Disabled"
        set_bios "--aspm=disable" "ASPM → Disabled"
        set_bios "--speedshift=enable" "Intel Speed Shift → Enabled"
        
        echo -e "\n  ${BOLD}── CPU & Prestanda ──${NC}"
        set_bios "--speedstep=enable" "Intel SpeedStep → Enabled"
        set_bios "--cstatesctrl=enable" "C-State Control → Enabled"
        set_bios "--turbomode=enable" "Turbo Mode → Enabled"
        set_bios "--logicproc=enable" "Hyper-Threading → Enabled"
        set_bios "--corecnt=all" "Active Cores → All"
        
        echo -e "\n  ${BOLD}── Virtualisering & PCIe ──${NC}"
        set_bios "--virtualization=enable" "Intel VT-x → Enabled"
        set_bios "--vtfordirectio=enable" "VT-d (IOMMU) → Enabled"
        set_bios "--trustexecution=disable" "Intel TXT → Disabled"
        set_bios "--resizablebarstate=enable" "PCIe Resizable BAR → Enabled"
        set_bios "--mmioabove4gb=enable" "MMIO Above 4GB → Enabled"
        
        echo -e "\n  ${BOLD}── DMA-skydd (av för passthrough) ──${NC}"
        set_bios "--prebootdma=disable" "Pre-Boot DMA Support → Disabled"
        set_bios "--kerneldma=disable" "Kernel DMA Protection → Disabled"
        
        echo -e "\n  ${BOLD}── Säkerhet ──${NC}"
        set_bios "--secureboot=disable" "Secure Boot → Disabled"
        set_bios "--tpmsecurity=enable" "TPM 2.0 → Enabled"
        set_bios "--inteltme=disable" "Intel TME → Disabled"
        set_bios "--chasintrusion=disable" "Chassis Intrusion → Disabled"
        set_bios "--smmmitig=disable" "SMM Security Mitigation → Disabled"
        
        echo -e "\n  ${BOLD}── Boot & Headless ──${NC}"
        set_bios "--warnerror=continue" "Warnings and Errors → Continue"
        set_bios "--fastboot=auto" "Fast Boot → Auto"
        set_bios "--extposttime=0s" "Extend BIOS POST Time → 0 seconds"
        
        echo -e "\n  ${BOLD}── Dell-tjänster (inaktivera) ──${NC}"
        set_bios "--biosconnect=disable" "BIOSConnect → Disabled"
        set_bios "--supportassist=disable" "SupportAssist OS Recovery → Disabled"
        set_bios "--fota=disable" "Firmware OTA → Disabled"
        set_bios "--absolute=disable" "Absolute/Computrace → Disabled"
        
        echo -e "\n  ${BOLD}── Update & Recovery ──${NC}"
        set_bios "--biosdowngrade=enable" "Allow BIOS Downgrade → Enabled"
        set_bios "--capsulefwupdate=enable" "Capsule Firmware Update → Enabled"
        
        echo ""
        if [ $BIOS_ERRORS -eq 0 ]; then
            msg_ok "Alla BIOS-inställningar konfigurerade!"
        else
            msg_warn "$BIOS_ERRORS inställning(ar) misslyckades — se ovan."
            msg_info "Dessa kan behöva ställas in manuellt i BIOS (F2 vid boot)."
        fi
        
        echo "" > /dev/tty
        echo -e "  ${YELLOW}OBS: BIOS-ändringarna träder i kraft vid nästa omstart.${NC}" > /dev/tty
        echo -e "  ${YELLOW}En reboot rekommenderas efter att hela installationen är klar.${NC}" > /dev/tty
        echo "" > /dev/tty
        
        set_state bios_configured true
        
        echo "" > /dev/tty
        echo -e "  ${GREEN}BIOS-inställningarna är sparade men kräver en omstart.${NC}" > /dev/tty
        echo "" > /dev/tty
        if ask_yes_no "Vill du starta om nu? (Kör setup.sh igen efter omstart)" "Y"; then
            msg_info "Startar om om 5 sekunder..."
            msg_info "Efter omstart, kör: cd /opt/optiplex-homelab/scripts && bash setup.sh"
            sleep 5
            reboot
            exit 0
        else
            set_state needs_reboot true
            msg_info "OK! Kom ihåg att starta om innan du installerar Frigate (iGPU behöver VT-d)."
        fi
    fi
    else
        msg_skip "BIOS-konfiguration hoppades över."
        msg_info "Du kan ställa in BIOS manuellt — se docs/01-bios-setup.md"
        msg_info "Eller kör detta skript igen senare och välj Ja."
    fi
fi

# --- Hostname ---
if [ -n "$NODE_HOSTNAME" ] && [ "$NODE_HOSTNAME" != "$(hostname)" ]; then
    CURRENT_HOSTNAME=$(hostname)
    msg_info "Nuvarande hostname: ${CURRENT_HOSTNAME}"
    msg_info "Önskat hostname: ${NODE_HOSTNAME}"
    
    echo -e "\n  > ${BOLD}Varför byta hostname?${NC}" > /dev/tty
    echo -e "    Hostnamet identifierar din server i nätverket och i Proxmox." > /dev/tty
    echo -e "    OBS: Att byta hostname på en Proxmox-nod som redan har VMs/CTs" > /dev/tty
    echo -e "    kan kräva extra steg. Det är enklast att göra det tidigt.\n" > /dev/tty
    
    if ask_yes_no "Vill du byta hostname till '${NODE_HOSTNAME}'?" "Y"; then
        hostnamectl set-hostname "$NODE_HOSTNAME"
        sed -i "s/${CURRENT_HOSTNAME}/${NODE_HOSTNAME}/g" /etc/hosts 2>/dev/null
        msg_ok "Hostname ändrat till: ${NODE_HOSTNAME}"
        msg_info "OBS: Fullständig effekt efter reboot. Proxmox GUI kan visa gammalt namn tills dess."
    fi
fi

# --- SSD-optimering ---
msg_info "Aktiverar fstrim (SSD-optimering)..."
systemctl enable fstrim.timer > /dev/null 2>&1
systemctl start fstrim.timer > /dev/null 2>&1
msg_ok "TRIM aktiverat (kör automatiskt varje vecka)"

# --- iGPU udev ---
msg_info "Sätter upp udev-regler för iGPU..."
cat > /etc/udev/rules.d/99-igpu-permissions.rules << 'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD128", GROUP="video", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger
msg_ok "iGPU-regler installerade"

# --- Nätverkskort Power Saving ---
msg_info "Kontrollerar nätverkskortets power saving..."

# Hitta primärt nätverkskort
PRIMARY_NIC=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
if [ -z "$PRIMARY_NIC" ]; then
    PRIMARY_NIC=$(ls /sys/class/net/ | grep -v "^lo$\|^vmbr\|^tap\|^fwbr" | head -1)
fi

if [ -n "$PRIMARY_NIC" ]; then
    # Installera ethtool om det saknas
    if ! command -v ethtool &>/dev/null; then
        apt-get install -y ethtool > /dev/null 2>&1
    fi
    
    # Kolla WoL-status
    WOL_STATUS=$(ethtool "$PRIMARY_NIC" 2>/dev/null | grep "Wake-on:" | tail -1 | awk '{print $2}')
    
    if echo "$WOL_STATUS" | grep -q "g"; then
        msg_ok "Wake-on-LAN är aktiverat på $PRIMARY_NIC"
    else
        msg_warn "Wake-on-LAN verkar inte vara aktiverat på $PRIMARY_NIC"
        msg_info "Aktiverar WoL..."
        ethtool -s "$PRIMARY_NIC" wol g 2>/dev/null
        
        # Gör det persistent via systemd
        cat > /etc/systemd/system/wol-${PRIMARY_NIC}.service << EOF
[Unit]
Description=Enable Wake-on-LAN for ${PRIMARY_NIC}
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s ${PRIMARY_NIC} wol g

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "wol-${PRIMARY_NIC}.service" > /dev/null 2>&1
        msg_ok "Wake-on-LAN aktiverat och persistent (överlever reboot)"
    fi
    
    # Kolla power saving (EEE - Energy Efficient Ethernet)
    EEE_STATUS=$(ethtool --show-eee "$PRIMARY_NIC" 2>/dev/null | grep "EEE status:" | awk '{print $3}')
    if [ "$EEE_STATUS" == "enabled" ]; then
        msg_warn "Energy Efficient Ethernet (EEE) är aktiverat — kan orsaka latens"
        msg_info "Stänger av EEE..."
        ethtool --set-eee "$PRIMARY_NIC" eee off 2>/dev/null
        msg_ok "EEE avstängt"
    else
        msg_ok "Nätverkskortet är inte i power saving mode"
    fi
    
    # Spara MAC-adress för WoL-sammanfattning
    MAC_ADDRESS=$(cat /sys/class/net/${PRIMARY_NIC}/address 2>/dev/null)
    if [ -n "$MAC_ADDRESS" ]; then
        set_state mac_address "$MAC_ADDRESS"
        set_state primary_nic "$PRIMARY_NIC"
    fi
else
    msg_warn "Kunde inte hitta primärt nätverkskort"
fi

# BIOS-verifiering sker nu i början av skriptet (rad 38-136).
# Ingen dubbel-check behövs här.

echo ""
msg_ok "Proxmox Host-konfiguration klar!"
