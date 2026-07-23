#!/usr/bin/env bash
source lib/ui.sh
source lib/proxmox.sh
source lib/config.sh

# ============================================================
# Module 01 — Frigate Recording Storage
# Detekterar extra disk, väljer rätt filsystem baserat på disktyp,
# formaterar, mountar och registrerar i Proxmox.
#
# Filsystemsval:
#   SSD → ext4 (noatime, discard) + fstrim.timer
#   HDD → XFS  (noatime) — bäst för sekventiella stora filer
#
# Frigate hanterar retention/cleanup själv via frigate.yml config.
# ============================================================

msg_info "Letar efter extra lagringsdisk för Frigate-inspelningar..."

# ── Hitta oanvända diskar ─────────────────────────────────────
EXTRA_DISKS=$(find_extra_disks)

if [ -z "$EXTRA_DISKS" ]; then
    msg_warn "Hittade ingen extra disk."
    msg_info "Frigate kommer använda samma disk som Proxmox (local-lvm)."
    msg_info "Rekommendation: Lägg till en dedikerad disk för inspelningar."
    msg_info "  • HDD (billigare, mer kapacitet) — WD Purple eller Seagate SkyHawk rekommenderas"
    msg_info "  • SSD (snabbare, tystare) — Moderna SSD:er klarar 24/7-skrivning utan problem"
    exit 0
fi

# Konvertera till array
read -a DISK_ARRAY <<< "$EXTRA_DISKS"

# ── Diskval ───────────────────────────────────────────────────
if [ ${#DISK_ARRAY[@]} -eq 1 ]; then
    TARGET_DISK="${DISK_ARRAY[0]}"
    msg_info "Hittade oanvänd disk: $TARGET_DISK"
else
    msg_info "Hittade flera oanvända diskar:"
    for i in "${!DISK_ARRAY[@]}"; do
        local_size=$(lsblk -nd -o SIZE "${DISK_ARRAY[$i]}" 2>/dev/null | xargs)
        local_rota=$(lsblk -nd -o ROTA "${DISK_ARRAY[$i]}" 2>/dev/null | xargs)
        local_type="SSD"
        [ "$local_rota" == "1" ] && local_type="HDD"
        echo "  [$i] ${DISK_ARRAY[$i]} — ${local_size} (${local_type})"
    done
    
    if [ "$HEADLESS" == "true" ]; then
        # Headless: välj första disken automatiskt
        TARGET_DISK="${DISK_ARRAY[0]}"
        msg_info "(headless) Väljer automatiskt: $TARGET_DISK"
    else
        while true; do
            tty_printf "Vilken disk vill du använda för Frigate? (0-$((${#DISK_ARRAY[@]}-1)) eller Enter för att skippa): "
            tty_read disk_choice
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
fi

# ── Disktyp-detektering ───────────────────────────────────────
DISK_ROTATIONAL=$(lsblk -nd -o ROTA "$TARGET_DISK" 2>/dev/null | xargs)
DISK_SIZE=$(lsblk -nd -o SIZE "$TARGET_DISK" 2>/dev/null | xargs)
DISK_MODEL=$(lsblk -nd -o MODEL "$TARGET_DISK" 2>/dev/null | xargs)

if [ "$DISK_ROTATIONAL" == "1" ]; then
    DISK_TYPE="HDD"
    FS_TYPE="xfs"
    MOUNT_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k"
    FS_REASON="XFS — optimalt för HDD med sekventiella stora videofiler"
else
    DISK_TYPE="SSD"
    FS_TYPE="ext4"
    MOUNT_OPTS="noatime,nodiratime,discard"
    FS_REASON="ext4 med TRIM — optimalt för SSD med 24/7-skrivning"
fi

echo ""
msg_info "┌─────────────────────────────────────────────────────┐"
msg_info "│  Disk: $TARGET_DISK"
msg_info "│  Modell: ${DISK_MODEL:-Okänd}"
msg_info "│  Storlek: $DISK_SIZE"
msg_info "│  Typ: $DISK_TYPE"
msg_info "│  Filsystem: $FS_REASON"
msg_info "└─────────────────────────────────────────────────────┘"
echo ""

# ── SMART-hälsokontroll ───────────────────────────────────────
if command -v smartctl &>/dev/null; then
    msg_info "Kontrollerar diskhälsa (SMART)..."
    SMART_HEALTH=$(smartctl -H "$TARGET_DISK" 2>/dev/null | grep -i "overall-health\|SMART Health" | awk -F: '{print $2}' | xargs)
    
    if [ -n "$SMART_HEALTH" ]; then
        if echo "$SMART_HEALTH" | grep -qi "PASSED\|OK"; then
            msg_ok "SMART-status: $SMART_HEALTH"
        else
            msg_warn "SMART-status: $SMART_HEALTH"
            msg_warn "Disken visar tecken på problem! Överväg att byta den."
            if [ "$HEADLESS" != "true" ]; then
                if ! ask_yes_no "Vill du fortsätta ändå med denna disk?" "N"; then
                    msg_skip "Avbryter disk-konfiguration."
                    exit 0
                fi
            else
                msg_warn "(headless) Fortsätter trots SMART-varning — kontrollera disken manuellt!"
            fi
        fi
    else
        msg_info "Kunde inte läsa SMART-data (disken kanske inte stöder det)."
    fi
    
    # Visa TBW/wear för SSD
    if [ "$DISK_TYPE" == "SSD" ]; then
        WEAR_PCT=$(smartctl -A "$TARGET_DISK" 2>/dev/null | grep -i "Wear_Leveling\|Media_Wearout\|Percent_Lifetime" | awk '{print $NF}')
        if [ -n "$WEAR_PCT" ]; then
            msg_info "SSD-slitage: ${WEAR_PCT}% använt"
        fi
    fi
else
    msg_info "smartctl ej installerat — hoppar över SMART-kontroll."
    msg_info "  Installera med: apt install smartmontools"
fi

# ── Headless säkerhetskontroll ────────────────────────────────
# I headless-mode: formatera BARA om disken saknar filesystem-signatur
if [ "$HEADLESS" == "true" ]; then
    EXISTING_FS=$(wipefs -n "$TARGET_DISK" 2>/dev/null | grep -v "offset" | head -1)
    if [ -n "$EXISTING_FS" ]; then
        msg_warn "(headless) Disken $TARGET_DISK har redan ett filsystem/signatur!"
        msg_warn "  Hittade: $EXISTING_FS"
        msg_warn "  Formaterar INTE automatiskt — kör setup.sh interaktivt för att formatera."
        exit 0
    fi
    msg_info "(headless) Disken är tom — formaterar automatiskt."
fi

# ── Bekräfta formatering ──────────────────────────────────────
if [ "$HEADLESS" != "true" ]; then
    echo ""
    msg_warn "VARNING: All data på $TARGET_DISK kommer att raderas!"
    if ! ask_yes_no "Vill du formatera $TARGET_DISK ($DISK_SIZE $DISK_TYPE) som 'frigate-storage'?" "Y"; then
        msg_skip "Hoppar över disk-konfiguration."
        exit 0
    fi
fi

# ── Formatera disken ──────────────────────────────────────────
msg_info "Formaterar $TARGET_DISK med $FS_TYPE..."

# Rensa eventuella gamla signaturer
wipefs -a "$TARGET_DISK" > /dev/null 2>&1

if [ "$FS_TYPE" == "xfs" ]; then
    # XFS: optimerat för stora sekventiella filer
    # -f = force, -K = don't discard (HDD behöver inte det)
    mkfs.xfs -f -K "$TARGET_DISK" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Kunde inte formatera $TARGET_DISK med XFS!"
        exit 1
    fi
elif [ "$FS_TYPE" == "ext4" ]; then
    # ext4: med lazy_itable_init för snabbare formatering
    # -E discard = TRIM hela disken vid formatering (SSD)
    mkfs.ext4 -F -E discard "$TARGET_DISK" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Kunde inte formatera $TARGET_DISK med ext4!"
        exit 1
    fi
fi

msg_ok "$FS_TYPE-filsystem skapat på $TARGET_DISK"

# ── Mounta disken ─────────────────────────────────────────────
msg_info "Skapar mount-punkt och uppdaterar fstab..."
mkdir -p /mnt/frigate-storage

# Hämta UUID
UUID=$(blkid -s UUID -o value "$TARGET_DISK")

if [ -z "$UUID" ]; then
    msg_err "Kunde inte läsa UUID från $TARGET_DISK!"
    exit 1
fi

# Ta bort eventuell gammal fstab-entry för frigate-storage
sed -i '/frigate-storage/d' /etc/fstab

# Lägg till ny fstab-entry med rätt mount-options
echo "UUID=$UUID /mnt/frigate-storage $FS_TYPE $MOUNT_OPTS 0 2" >> /etc/fstab

mount -a
if [ $? -ne 0 ]; then
    msg_err "Kunde inte mounta $TARGET_DISK!"
    exit 1
fi

msg_ok "Disk monterad på /mnt/frigate-storage"

# ── SSD-specifikt: fstrim.timer ───────────────────────────────
if [ "$DISK_TYPE" == "SSD" ]; then
    msg_info "Aktiverar fstrim.timer för SSD-underhåll (veckovis TRIM)..."
    
    # fstrim.timer trimmar alla monterade diskar med discard-stöd
    # Den bör redan vara aktiv från module 00, men säkerställ
    systemctl enable fstrim.timer > /dev/null 2>&1
    systemctl start fstrim.timer > /dev/null 2>&1
    
    msg_ok "fstrim.timer aktiv — SSD trimmas automatiskt varje vecka"
fi

# ── Lägg till i Proxmox ───────────────────────────────────────
msg_info "Registrerar lagringen i Proxmox..."
if pvesm status | grep -q "frigate-storage"; then
    msg_info "frigate-storage finns redan i Proxmox — uppdaterar..."
    pvesm set frigate-storage --path /mnt/frigate-storage > /dev/null 2>&1
else
    pvesm add dir frigate-storage --path /mnt/frigate-storage --content images,rootdir > /dev/null 2>&1
fi

msg_ok "Proxmox storage 'frigate-storage' registrerat"

# ── Koppla till befintlig Frigate CT (om den redan finns) ──────
FRIGATE_ID="${IP_FRIGATE:-103}"
if pct status "$FRIGATE_ID" &>/dev/null; then
    msg_info "Frigate CT ($FRIGATE_ID) finns redan — kopplar lagringsdisken..."
    
    # Kolla om mountpoint redan är satt till frigate-storage
    if pct config "$FRIGATE_ID" 2>/dev/null | grep -q "mp0.*frigate-storage"; then
        msg_ok "frigate-storage är redan monterad i Frigate CT."
    else
        # Kolla om det finns befintliga inspelningar på CT:ns interna disk
        OLD_STORAGE_SIZE=""
        if pct exec "$FRIGATE_ID" -- test -d /opt/frigate/storage 2>/dev/null; then
            OLD_STORAGE_SIZE=$(pct exec "$FRIGATE_ID" -- du -sh /opt/frigate/storage 2>/dev/null | awk '{print $1}')
        fi
        
        if [ -n "$OLD_STORAGE_SIZE" ] && [ "$OLD_STORAGE_SIZE" != "0" ] && [ "$OLD_STORAGE_SIZE" != "4.0K" ]; then
            # Det finns befintliga inspelningar på OS-disken
            echo ""
            msg_info "┌─────────────────────────────────────────────────────┐"
            msg_info "│  Befintliga inspelningar hittade: ${OLD_STORAGE_SIZE}B"
            msg_info "│  Dessa ligger på OS-disken (tar upp plats)."
            msg_info "└─────────────────────────────────────────────────────┘"
            echo ""
            
            if [ "$HEADLESS" == "true" ]; then
                msg_info "(headless) Flyttar befintliga inspelningar till nya disken..."
                MIGRATE_ACTION="move"
            else
                tty_echo "  Vad vill du göra med befintliga inspelningar?"
                tty_echo ""
                tty_echo "    1) Flytta till nya disken (behåll allt, frigör OS-disk)"
                tty_echo "    2) Radera gamla inspelningar (frigör OS-disk, börja från noll)"
                tty_echo "    3) Låt ligga (nya inspelningar på ny disk, gamla kvar på OS-disk)"
                tty_echo ""
                tty_printf "  Val [1-3] (default: 1): "; tty_read migrate_choice
                case "${migrate_choice:-1}" in
                    1) MIGRATE_ACTION="move" ;;
                    2) MIGRATE_ACTION="delete" ;;
                    3) MIGRATE_ACTION="keep" ;;
                    *) MIGRATE_ACTION="move" ;;
                esac
            fi
            
            # Stoppa Frigate CT (krävs för alla migreringsalternativ)
            if pct status "$FRIGATE_ID" 2>/dev/null | grep -q "running"; then
                msg_info "Stoppar Frigate CT för säker disk-migration..."
                pct stop "$FRIGATE_ID" --timeout 30 2>/dev/null
                sleep 3
            fi
            
            # CT är nu stoppad — vi kan komma åt rootfs direkt
            ROOTFS_PATH="/var/lib/lxc/${FRIGATE_ID}/rootfs"
            OLD_DATA_PATH="${ROOTFS_PATH}/opt/frigate/storage"
            
            case "$MIGRATE_ACTION" in
                move)
                    msg_info "Flyttar inspelningar till nya disken (detta kan ta en stund)..."
                    if [ -d "$OLD_DATA_PATH" ] && [ "$(ls -A "$OLD_DATA_PATH" 2>/dev/null)" ]; then
                        msg_info "Kopierar ${OLD_STORAGE_SIZE}B till /mnt/frigate-storage/..."
                        mkdir -p /mnt/frigate-storage/storage
                        rsync -a --info=progress2 "${OLD_DATA_PATH}/" /mnt/frigate-storage/storage/
                        if [ $? -eq 0 ]; then
                            msg_ok "Data kopierad! Rensar gamla filer från OS-disken..."
                            rm -rf "${OLD_DATA_PATH:?}"/*
                            msg_ok "OS-disk frigjord: ~${OLD_STORAGE_SIZE}B återvunnet"
                        else
                            msg_warn "Kopiering misslyckades — behåller gamla filer på OS-disken."
                        fi
                    else
                        msg_info "Inga filer att flytta (katalogen är tom)."
                    fi
                    ;;
                delete)
                    msg_info "Raderar gamla inspelningar från OS-disken..."
                    if [ -d "$OLD_DATA_PATH" ]; then
                        rm -rf "${OLD_DATA_PATH:?}"/*
                        msg_ok "Gamla inspelningar raderade — ~${OLD_STORAGE_SIZE}B frigjort på OS-disken"
                    fi
                    ;;
                keep)
                    msg_info "Behåller gamla inspelningar på OS-disken."
                    msg_info "Nya inspelningar hamnar på den dedikerade disken."
                    msg_info "OBS: Gamla filer tar fortfarande plats. Frigör manuellt:"
                    msg_info "  rm -rf ${OLD_DATA_PATH}/*"
                    ;;
            esac
            
            # Sätt mountpoint och starta Frigate
            pct set "$FRIGATE_ID" -mp0 "frigate-storage:100,mp=/opt/frigate/storage,backup=0" 2>/dev/null
            msg_info "Startar Frigate CT..."
            pct start "$FRIGATE_ID" 2>/dev/null
            
            msg_ok "Frigate pekar nu på den dedikerade disken."
        else
            # Inga befintliga inspelningar — bara lägg till mountpoint
            # CT måste vara stoppad för att ändra mountpoints
            NEED_RESTART=false
            if pct status "$FRIGATE_ID" 2>/dev/null | grep -q "running"; then
                msg_info "Stoppar Frigate CT för att lägga till lagringsdisk..."
                pct stop "$FRIGATE_ID" --timeout 30 2>/dev/null
                sleep 3
                NEED_RESTART=true
            fi
            
            pct set "$FRIGATE_ID" -mp0 "frigate-storage:100,mp=/opt/frigate/storage,backup=0" 2>/dev/null
            msg_ok "frigate-storage monterad i Frigate CT på /opt/frigate/storage"
            
            if [ "$NEED_RESTART" == "true" ]; then
                pct start "$FRIGATE_ID" 2>/dev/null
                msg_ok "Frigate CT startad med ny lagringsdisk."
            else
                msg_info "Starta Frigate för att använda den nya disken: pct start $FRIGATE_ID"
            fi
        fi
    fi
else
    msg_info "Frigate CT finns inte ännu — disken kopplas automatiskt när Frigate installeras."
fi

# ── Sammanfattning ────────────────────────────────────────────
echo ""
msg_ok "┌─────────────────────────────────────────────────────┐"
msg_ok "│  Frigate-lagring konfigurerad!                       │"
msg_ok "│                                                      │"
msg_ok "│  Disk: $TARGET_DISK ($DISK_SIZE $DISK_TYPE)"
msg_ok "│  Filsystem: $FS_TYPE"
msg_ok "│  Mount: /mnt/frigate-storage"
msg_ok "│  Mount-options: $MOUNT_OPTS"
if [ "$DISK_TYPE" == "SSD" ]; then
msg_ok "│  TRIM: Aktivt (fstrim.timer, veckovis)"
else
msg_ok "│  TRIM: Ej tillämpligt (HDD)"
fi
msg_ok "│  Proxmox: frigate-storage (dir)"
msg_ok "│                                                      │"
msg_ok "│  Frigate hanterar retention/cleanup automatiskt      │"
msg_ok "│  via 'retain'-inställningen i frigate.yml.           │"
msg_ok "└─────────────────────────────────────────────────────┘"
echo ""
