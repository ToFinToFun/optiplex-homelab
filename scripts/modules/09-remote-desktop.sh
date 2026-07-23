#!/usr/bin/env bash
source setup.env
source lib/ui.sh
source lib/proxmox.sh
source lib/rollback.sh
TEMPLATE_PATH=$1

# ============================================================
# Modul 09 — Remote Desktop (Guacamole + Linux Desktop)
# ============================================================
# Guacamole: Webb-baserad RDP/VNC/SSH-gateway (Docker i LXC)
# Desktop:   Debian 13 + XFCE4 + xrdp (LXC container)
# ============================================================

CIDR="${NETWORK_CIDR:-24}"

# ─── Undermeny ───────────────────────────────────────────────
INSTALL_GUAC="n"
INSTALL_DESKTOP="n"

if [ "$HEADLESS" == "true" ]; then
    # Headless: installera båda med defaults
    msg_info "(headless) Installerar båda: Guacamole + Linux Desktop"
    INSTALL_GUAC="y"
    INSTALL_DESKTOP="y"
else
    echo "" > /dev/tty
    echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════╗${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC} ${BOLD}Remote Desktop — Vad vill du installera?${NC}                ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════╣${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}  ${BOLD}1)${NC} Guacamole — RDP-proxy via webbläsaren               ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}     ${DIM}Anslut till alla maskiner via rdp.dindomän.se${NC}        ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}  ${BOLD}2)${NC} Linux Desktop — Lättvikts-skrivbord med RDP          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}     ${DIM}Debian 13 + XFCE4 + xrdp (anslut via Guacamole)${NC}     ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}  ${BOLD}3)${NC} Båda (rekommenderat)                                 ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}  ${BOLD}0)${NC} Tillbaka (hoppa över Remote Desktop)                 ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}║${NC}                                                          ${CYAN}║${NC}" > /dev/tty
    echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}" > /dev/tty
    echo "" > /dev/tty
    echo -ne "  ${BOLD}Välj [0/1/2/3]: ${NC}" > /dev/tty
    read RDP_CHOICE < /dev/tty

    case "$RDP_CHOICE" in
        0)
            msg_info "Hoppar över Remote Desktop."
            exit 0
            ;;
        1) INSTALL_GUAC="y" ;;
        2) INSTALL_DESKTOP="y" ;;
        3|"") INSTALL_GUAC="y"; INSTALL_DESKTOP="y" ;;
        *) INSTALL_GUAC="y"; INSTALL_DESKTOP="y" ;;
    esac
fi

# ─── Konfiguration ───────────────────────────────────────────
echo "" > /dev/tty

if [ "$INSTALL_GUAC" == "y" ]; then
    msg_header "Guacamole — Konfiguration"
    
    # CT ID och IP
    local_default_guac_id="${IP_GUACAMOLE:-107}"
    IP_GUACAMOLE=$(ask_string "CT ID för Guacamole (även sista delen av IP)" "$local_default_guac_id")
    GUAC_IP="${NETWORK_PREFIX}.${IP_GUACAMOLE}"
    
    if [ "$HEADLESS" == "true" ]; then
        # Headless: använd gemensamt lösenord från setup.env
        GUAC_ADMIN_USER="admin"
        GUAC_ADMIN_PASS="${SHARED_PASSWORD:-$CT_PASSWORD}"
        msg_info "(headless) Guacamole admin: ${GUAC_ADMIN_USER} / (gemensamt lösenord)"
    else
        echo -e "  ${DIM}Guacamole admin-konto (för inloggning i webbgränssnittet)${NC}" > /dev/tty
        GUAC_ADMIN_USER=$(ask_string "Guacamole admin-användarnamn" "admin")
        GUAC_ADMIN_PASS=""
        while [ -z "$GUAC_ADMIN_PASS" ]; do
            GUAC_ADMIN_PASS=$(ask_string "Guacamole admin-lösenord" "" "true")
        done
    fi
fi

if [ "$INSTALL_DESKTOP" == "y" ]; then
    msg_header "Linux Desktop — Konfiguration"
    
    # CT ID och IP
    local_default_desk_id="${IP_DESKTOP:-108}"
    IP_DESKTOP=$(ask_string "CT ID för Desktop (även sista delen av IP)" "$local_default_desk_id")
    DESKTOP_IP="${NETWORK_PREFIX}.${IP_DESKTOP}"
    
    if [ "$HEADLESS" == "true" ]; then
        # Headless: använd gemensamt lösenord från setup.env
        DESKTOP_USER="user"
        DESKTOP_PASS="${SHARED_PASSWORD:-$CT_PASSWORD}"
        DESKTOP_DISK="32"
        msg_info "(headless) Desktop: ${DESKTOP_USER} / (gemensamt lösenord) / ${DESKTOP_DISK}GB"
    else
        echo -e "  ${DIM}Desktop-användare (för RDP-inloggning)${NC}" > /dev/tty
        DESKTOP_USER=$(ask_string "Desktop-användarnamn" "user")
        DESKTOP_PASS=""
        while [ -z "$DESKTOP_PASS" ]; do
            DESKTOP_PASS=$(ask_string "Desktop-lösenord" "" "true")
        done
        
        DESKTOP_DISK=$(ask_string "Diskstorlek för Desktop (GB, minimum 16)" "32")
        # Validera minimum
        if [ "$DESKTOP_DISK" -lt 16 ] 2>/dev/null; then
            msg_warn "Minimum 16GB krävs. Sätter till 16GB."
            DESKTOP_DISK=16
        fi
    fi
fi

# ─── Installation: Guacamole ─────────────────────────────────
if [ "$INSTALL_GUAC" == "y" ]; then
    echo "" > /dev/tty
    msg_header "Installerar Guacamole (CT ${IP_GUACAMOLE})"
    echo -e "  ${DIM}Webb-baserad RDP/VNC/SSH-gateway — nås via rdp.dindomän.se${NC}" > /dev/tty
    echo "" > /dev/tty
    
    # Skapa container
    msg_info "Skapar LXC-container ${IP_GUACAMOLE}..."
    
    if ! pct create "${IP_GUACAMOLE}" "${TEMPLATE_PATH}" \
        --hostname guacamole \
        --cores 2 \
        --memory 1024 \
        --swap 0 \
        --net0 "name=eth0,bridge=vmbr0,ip=${GUAC_IP}/${CIDR},gw=${GATEWAY}" \
        --storage "${STORAGE_POOL}" \
        --rootfs "${STORAGE_POOL}:8" \
        --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 2>&1; then
        msg_err "Kunde inte skapa Guacamole-container."
        rollback_offer "${IP_GUACAMOLE}" "Guacamole"
        return 1 2>/dev/null || exit 1
    fi
    
    rollback_register "ct" "${IP_GUACAMOLE}" "guacamole"
    pct start "${IP_GUACAMOLE}"
    sleep 5
    
    # Installera Docker + python3 (python3 behövs för API JSON-parsing)
    msg_info "Installerar Docker + beroenden..."
    pct exec "${IP_GUACAMOLE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
    pct exec "${IP_GUACAMOLE}" -- bash -c "apt-get install -y -qq curl ca-certificates gnupg python3 > /dev/null 2>&1"
    pct exec "${IP_GUACAMOLE}" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "${IP_GUACAMOLE}" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null"
    pct exec "${IP_GUACAMOLE}" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
    pct exec "${IP_GUACAMOLE}" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    pct exec "${IP_GUACAMOLE}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
    pct exec "${IP_GUACAMOLE}" -- bash -c "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1"
    
    # Skapa Guacamole docker-compose
    msg_info "Konfigurerar Guacamole (Docker Compose)..."
    pct exec "${IP_GUACAMOLE}" -- bash -c "mkdir -p /opt/guacamole"
    
    # Generera databas-lösenord
    GUAC_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    
    cat > /tmp/guac-compose.yml << EOF
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
    networks:
      - guac-net

  postgres:
    image: postgres:16-alpine
    container_name: guac-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: guacamole_db
      POSTGRES_USER: guacamole_user
      POSTGRES_PASSWORD: ${GUAC_DB_PASS}
    volumes:
      - ./db-data:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d
    networks:
      - guac-net

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole
    restart: unless-stopped
    depends_on:
      - guacd
      - postgres
    environment:
      GUACD_HOSTNAME: guacd
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_DATABASE: guacamole_db
      POSTGRESQL_USER: guacamole_user
      POSTGRESQL_PASSWORD: ${GUAC_DB_PASS}
      WEBAPP_CONTEXT: ROOT
      REMOTE_IP_VALVE_ENABLED: "true"
    ports:
      - "8080:8080"
    networks:
      - guac-net

networks:
  guac-net:
    driver: bridge
EOF
    pct push "${IP_GUACAMOLE}" /tmp/guac-compose.yml /opt/guacamole/docker-compose.yml
    rm -f /tmp/guac-compose.yml
    
    # Generera databas-initieringsscript (standard schema)
    msg_info "Initierar Guacamole-databasen..."
    pct exec "${IP_GUACAMOLE}" -- bash -c "mkdir -p /opt/guacamole/initdb"
    pct exec "${IP_GUACAMOLE}" -- bash -c "docker pull guacamole/guacamole:latest > /dev/null 2>&1"
    pct exec "${IP_GUACAMOLE}" -- bash -c "docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --postgresql > /opt/guacamole/initdb/001-init.sql 2>/dev/null"
    
    # Starta Guacamole (använd default guacadmin/guacadmin, byter lösenord via API efteråt)
    msg_info "Startar Guacamole via Docker Compose..."
    pct exec "${IP_GUACAMOLE}" -- bash -c "cd /opt/guacamole && docker compose up -d" > /dev/null 2>&1
    
    # Vänta på att Guacamole startar (retry loop med progress)
    msg_info "Väntar på att Guacamole startar (kan ta 30-60 sekunder)..."
    guac_ready=0
    for i in $(seq 1 30); do
        if pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf http://localhost:8080/ > /dev/null 2>&1"; then
            guac_ready=1
            break
        fi
        # Visa progress var 5:e försök
        if [ $((i % 5)) -eq 0 ]; then
            echo -ne "  ${DIM}...väntar (${i}/30)${NC}\r" > /dev/tty
        fi
        sleep 3
    done
    echo "" > /dev/tty
    
    if [ "$guac_ready" -eq 1 ]; then
        msg_ok "Guacamole är igång! Webb-UI: http://${GUAC_IP}:8080"
        
        # ── Byt admin-lösenord via REST API (säkrare än SQL-hack) ──
        msg_info "Konfigurerar admin-konto via API..."
        
        # Hämta auth-token med default credentials (retry loop)
        GUAC_TOKEN=""
        for attempt in $(seq 1 10); do
            GUAC_TOKEN=$(pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/tokens' \
                -d 'username=guacadmin&password=guacadmin' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"authToken\",\"\"))' 2>/dev/null")
            if [ -n "$GUAC_TOKEN" ]; then
                break
            fi
            sleep 3
        done
        
        if [ -n "$GUAC_TOKEN" ]; then
            # Byt lösenord för guacadmin
            pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/users/guacadmin/password?token=${GUAC_TOKEN}' \
                -H 'Content-Type: application/json' \
                -X PUT \
                -d '{
                    \"oldPassword\": \"guacadmin\",
                    \"newPassword\": \"${GUAC_ADMIN_PASS}\"
                }' > /dev/null 2>&1"
            
            # Byt användarnamn om det inte är 'guacadmin'
            if [ "$GUAC_ADMIN_USER" != "guacadmin" ]; then
                # Skapa ny admin-användare
                pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/users?token=${GUAC_TOKEN}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        \"username\": \"${GUAC_ADMIN_USER}\",
                        \"password\": \"${GUAC_ADMIN_PASS}\",
                        \"attributes\": {
                            \"disabled\": \"\",
                            \"expired\": \"\",
                            \"access-window-start\": \"\",
                            \"access-window-end\": \"\",
                            \"valid-from\": \"\",
                            \"valid-until\": \"\",
                            \"timezone\": \"\"
                        }
                    }' > /dev/null 2>&1"
                
                # Ge nya användaren full admin-behörighet
                # Hämta ny token med uppdaterat lösenord
                GUAC_TOKEN2=$(pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/tokens' \
                    -d 'username=guacadmin&password=${GUAC_ADMIN_PASS}' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"authToken\",\"\"))' 2>/dev/null")
                
                if [ -n "$GUAC_TOKEN2" ]; then
                    # Ge systemrättigheter till nya admin
                    pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/users/${GUAC_ADMIN_USER}/permissions?token=${GUAC_TOKEN2}' \
                        -H 'Content-Type: application/json' \
                        -X PATCH \
                        -d '[
                            {\"op\":\"add\",\"path\":\"/systemPermissions\",\"value\":\"ADMINISTER\"},
                            {\"op\":\"add\",\"path\":\"/systemPermissions\",\"value\":\"CREATE_USER\"},
                            {\"op\":\"add\",\"path\":\"/systemPermissions\",\"value\":\"CREATE_CONNECTION\"},
                            {\"op\":\"add\",\"path\":\"/systemPermissions\",\"value\":\"CREATE_CONNECTION_GROUP\"},
                            {\"op\":\"add\",\"path\":\"/systemPermissions\",\"value\":\"CREATE_SHARING_PROFILE\"}
                        ]' > /dev/null 2>&1"
                    
                    # Ta bort guacadmin-kontot
                    pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/users/guacadmin?token=${GUAC_TOKEN2}' \
                        -X DELETE > /dev/null 2>&1"
                    
                    msg_ok "Admin-konto '${GUAC_ADMIN_USER}' skapat (guacadmin borttagen)"
                    GUAC_TOKEN="$GUAC_TOKEN2"
                else
                    msg_warn "Kunde inte byta användarnamn. Logga in som 'guacadmin' med ditt valda lösenord."
                fi
            else
                msg_ok "Admin-lösenord uppdaterat för 'guacadmin'"
                # Hämta ny token med nytt lösenord för API-konfiguration
                GUAC_TOKEN=$(pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/tokens' \
                    -d 'username=guacadmin&password=${GUAC_ADMIN_PASS}' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"authToken\",\"\"))' 2>/dev/null")
            fi
        else
            msg_warn "Kunde inte ansluta till Guacamole API. Byt lösenord manuellt vid första inloggning."
            msg_info "Standard-inloggning: guacadmin / guacadmin"
        fi
    else
        msg_warn "Guacamole startar fortfarande. Ge den 1-2 minuter."
        msg_info "Testa manuellt: http://${GUAC_IP}:8080"
        msg_info "Standard-inloggning: guacadmin / guacadmin"
        GUAC_TOKEN=""
    fi
fi

# ─── Installation: Linux Desktop ─────────────────────────────
if [ "$INSTALL_DESKTOP" == "y" ]; then
    echo "" > /dev/tty
    msg_header "Installerar Linux Desktop (CT ${IP_DESKTOP})"
    echo -e "  ${DIM}Debian 13 + XFCE4 + xrdp — lättvikts-skrivbord${NC}" > /dev/tty
    echo "" > /dev/tty
    
    # Skapa container (privileged för bättre desktop-stöd)
    msg_info "Skapar LXC-container ${IP_DESKTOP}..."
    
    if ! pct create "${IP_DESKTOP}" "${TEMPLATE_PATH}" \
        --hostname desktop \
        --cores 4 \
        --memory 4096 \
        --swap 512 \
        --net0 "name=eth0,bridge=vmbr0,ip=${DESKTOP_IP}/${CIDR},gw=${GATEWAY}" \
        --storage "${STORAGE_POOL}" \
        --rootfs "${STORAGE_POOL}:${DESKTOP_DISK}" \
        --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 2>&1; then
        msg_err "Kunde inte skapa Desktop-container."
        rollback_offer "${IP_DESKTOP}" "Desktop"
        return 1 2>/dev/null || exit 1
    fi
    
    rollback_register "ct" "${IP_DESKTOP}" "desktop"
    pct start "${IP_DESKTOP}"
    sleep 5
    
    # Installera XFCE + xrdp + openssh-server (med progress-feedback)
    msg_info "Installerar XFCE4 desktop-miljö (detta tar 3-5 minuter)..."
    pct exec "${IP_DESKTOP}" -- bash -c "apt-get update -qq > /dev/null 2>&1"
    
    # Kör installationen i bakgrunden och visa progress
    pct exec "${IP_DESKTOP}" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xfce4 xfce4-terminal xfce4-goodies \
        lightdm \
        xrdp \
        openssh-server \
        dbus-x11 \
        firefox-esr \
        > /tmp/xfce-install.log 2>&1 &
        INSTALL_PID=\$!
        while kill -0 \$INSTALL_PID 2>/dev/null; do
            PKGS_DONE=\$(grep -c '^Setting up ' /tmp/xfce-install.log 2>/dev/null || echo 0)
            echo \"PROGRESS:\${PKGS_DONE}\"
            sleep 10
        done
        wait \$INSTALL_PID
        echo \"DONE:\$?\"" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            PROGRESS:*)
                count="${line#PROGRESS:}"
                echo -ne "  ${DIM}...installerar paket (${count} klara)${NC}\r" > /dev/tty
                ;;
            DONE:0)
                echo "" > /dev/tty
                ;;
            DONE:*)
                echo "" > /dev/tty
                msg_warn "Paketinstallation returnerade felkod: ${line#DONE:}"
                ;;
        esac
    done
    
    # Verifiera att xrdp installerades korrekt
    if ! pct exec "${IP_DESKTOP}" -- bash -c "which xrdp > /dev/null 2>&1"; then
        msg_warn "xrdp verkar inte ha installerats korrekt. Försöker igen..."
        pct exec "${IP_DESKTOP}" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp openssh-server > /dev/null 2>&1"
    fi
    
    # Skapa användare
    msg_info "Skapar användare '${DESKTOP_USER}'..."
    pct exec "${IP_DESKTOP}" -- bash -c "useradd -m -s /bin/bash -G sudo,audio,video '${DESKTOP_USER}'"
    pct exec "${IP_DESKTOP}" -- bash -c "echo '${DESKTOP_USER}:${DESKTOP_PASS}' | chpasswd"
    
    # Konfigurera xrdp för XFCE
    msg_info "Konfigurerar xrdp för XFCE..."
    pct exec "${IP_DESKTOP}" -- bash -c "cat > /home/${DESKTOP_USER}/.xsession << 'XEOF'
#!/bin/bash
exec startxfce4
XEOF"
    pct exec "${IP_DESKTOP}" -- bash -c "chown ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}/.xsession"
    pct exec "${IP_DESKTOP}" -- bash -c "chmod +x /home/${DESKTOP_USER}/.xsession"
    
    # Aktivera och starta xrdp + sshd
    pct exec "${IP_DESKTOP}" -- bash -c "systemctl enable xrdp > /dev/null 2>&1"
    pct exec "${IP_DESKTOP}" -- bash -c "systemctl start xrdp > /dev/null 2>&1"
    pct exec "${IP_DESKTOP}" -- bash -c "systemctl enable ssh > /dev/null 2>&1"
    pct exec "${IP_DESKTOP}" -- bash -c "systemctl start ssh > /dev/null 2>&1"
    
    # Verifiera att xrdp och sshd lyssnar
    sleep 2
    xrdp_ok=0
    ssh_ok=0
    if pct exec "${IP_DESKTOP}" -- bash -c "ss -tlnp | grep -q ':3389'"; then
        xrdp_ok=1
    fi
    if pct exec "${IP_DESKTOP}" -- bash -c "ss -tlnp | grep -q ':22'"; then
        ssh_ok=1
    fi
    
    if [ "$xrdp_ok" -eq 1 ] && [ "$ssh_ok" -eq 1 ]; then
        msg_ok "Linux Desktop igång! xrdp (3389) + SSH (22) lyssnar."
    elif [ "$xrdp_ok" -eq 1 ]; then
        msg_ok "xrdp lyssnar på port 3389."
        msg_warn "SSH verkar inte lyssna ännu. Kan behöva en reboot."
    else
        msg_warn "xrdp/SSH verkar inte lyssna ännu. Kan behöva en reboot av containern."
        msg_info "Testa: pct reboot ${IP_DESKTOP}"
    fi
    
    msg_ok "Desktop-container klar! Anslut via RDP till ${DESKTOP_IP}:3389"
    echo -e "  ${DIM}Användare: ${DESKTOP_USER} / Lösenord: (det du angav)${NC}" > /dev/tty
fi

# ─── Auto-konfigurera Guacamole med Desktop-anslutning ────────
if [ "$INSTALL_GUAC" == "y" ] && [ -n "$GUAC_TOKEN" ]; then
    echo "" > /dev/tty
    msg_info "Konfigurerar Guacamole-anslutningar..."
    
    # Hämta giltig token (retry om den gamla har gått ut)
    _guac_api_token() {
        local token=""
        for attempt in $(seq 1 10); do
            token=$(pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/tokens' \
                -d 'username=${GUAC_ADMIN_USER}&password=${GUAC_ADMIN_PASS}' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"authToken\",\"\"))' 2>/dev/null")
            if [ -n "$token" ]; then
                echo "$token"
                return 0
            fi
            sleep 3
        done
        return 1
    }
    
    GUAC_TOKEN=$(_guac_api_token)
    
    if [ -n "$GUAC_TOKEN" ]; then
        # ── Desktop-anslutningar (RDP + SSH) ──
        if [ "$INSTALL_DESKTOP" == "y" ]; then
            # RDP till Desktop med clipboard + filöverföring
            pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/connections?token=${GUAC_TOKEN}' \
                -H 'Content-Type: application/json' \
                -d '{
                    \"name\": \"Linux Desktop (RDP)\",
                    \"protocol\": \"rdp\",
                    \"parentIdentifier\": \"ROOT\",
                    \"parameters\": {
                        \"hostname\": \"${DESKTOP_IP}\",
                        \"port\": \"3389\",
                        \"username\": \"${DESKTOP_USER}\",
                        \"password\": \"${DESKTOP_PASS}\",
                        \"ignore-cert\": \"true\",
                        \"resize-method\": \"display-update\",
                        \"enable-drive\": \"true\",
                        \"drive-name\": \"Shared\",
                        \"drive-path\": \"/shared\",
                        \"create-drive-path\": \"true\",
                        \"disable-copy\": \"false\",
                        \"disable-paste\": \"false\",
                        \"enable-wallpaper\": \"false\",
                        \"enable-font-smoothing\": \"true\",
                        \"color-depth\": \"32\"
                    },
                    \"attributes\": {
                        \"max-connections\": \"2\",
                        \"max-connections-per-user\": \"2\"
                    }
                }' > /dev/null 2>&1"
            msg_ok "RDP-anslutning 'Linux Desktop (RDP)' skapad"
            echo -e "  ${DIM}Clipboard: aktiverat | Filöverföring: aktiverat (drive 'Shared')${NC}" > /dev/tty
            
            # SSH till Desktop
            pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/connections?token=${GUAC_TOKEN}' \
                -H 'Content-Type: application/json' \
                -d '{
                    \"name\": \"Linux Desktop (SSH)\",
                    \"protocol\": \"ssh\",
                    \"parentIdentifier\": \"ROOT\",
                    \"parameters\": {
                        \"hostname\": \"${DESKTOP_IP}\",
                        \"port\": \"22\",
                        \"username\": \"${DESKTOP_USER}\",
                        \"password\": \"${DESKTOP_PASS}\",
                        \"color-scheme\": \"green-black\",
                        \"font-size\": \"14\",
                        \"enable-sftp\": \"true\",
                        \"sftp-root-directory\": \"/home/${DESKTOP_USER}\"
                    },
                    \"attributes\": {}
                }' > /dev/null 2>&1"
            msg_ok "SSH-anslutning 'Linux Desktop (SSH)' skapad"
        fi
        
        # ── SSH till Proxmox-noden (alltid) ──
        NODE_IP=$(hostname -I | awk '{print $1}')
        pct exec "${IP_GUACAMOLE}" -- bash -c "curl -sf 'http://localhost:8080/api/session/data/postgresql/connections?token=${GUAC_TOKEN}' \
            -H 'Content-Type: application/json' \
            -d '{
                \"name\": \"Proxmox (${NODE_HOSTNAME:-$(hostname)})\",
                \"protocol\": \"ssh\",
                \"parentIdentifier\": \"ROOT\",
                \"parameters\": {
                    \"hostname\": \"${NODE_IP}\",
                    \"port\": \"22\",
                    \"username\": \"root\",
                    \"color-scheme\": \"green-black\",
                    \"font-size\": \"14\",
                    \"enable-sftp\": \"true\",
                    \"sftp-root-directory\": \"/root\"
                },
                \"attributes\": {}
            }' > /dev/null 2>&1"
        msg_ok "SSH-anslutning 'Proxmox (${NODE_HOSTNAME:-$(hostname)})' skapad"
    else
        msg_warn "Kunde inte auto-konfigurera Guacamole (API ej redo)."
        echo -e "  ${DIM}Lägg till anslutningar manuellt i Guacamole UI:${NC}" > /dev/tty
        echo -e "  ${DIM}  Settings → Connections → New Connection${NC}" > /dev/tty
    fi
fi

# ─── Sammanfattning och NPM/Cloudflare-instruktioner ──────────
echo "" > /dev/tty
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" > /dev/tty
echo -e "  ${BOLD}Remote Desktop — Klart!${NC}" > /dev/tty
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" > /dev/tty
echo "" > /dev/tty

if [ "$INSTALL_GUAC" == "y" ]; then
    echo -e "  ${BOLD}Guacamole:${NC}" > /dev/tty
    echo -e "    Lokal URL:    http://${GUAC_IP}:8080" > /dev/tty
    echo -e "    Användare:    ${GUAC_ADMIN_USER}" > /dev/tty
    echo -e "    Lösenord:     (det du angav)" > /dev/tty
    echo "" > /dev/tty
    echo -e "  ${BOLD}Funktioner som är aktiverade:${NC}" > /dev/tty
    echo -e "    ✓ Clipboard (kopiera/klistra mellan lokal dator och remote)" > /dev/tty
    echo -e "    ✓ Filöverföring (ladda upp/ner via drive 'Shared')" > /dev/tty
    echo -e "    ✓ PostgreSQL-autentisering (hantera användare via GUI)" > /dev/tty
    echo -e "    ✓ Dynamisk upplösning (anpassar sig till webbläsarfönstret)" > /dev/tty
    echo "" > /dev/tty
    echo -e "  ${BOLD}Lägga till fler anslutningar:${NC}" > /dev/tty
    echo -e "    1. Logga in på Guacamole (http://${GUAC_IP}:8080)" > /dev/tty
    echo -e "    2. Klicka ditt användarnamn (övre högra hörnet) → Settings" > /dev/tty
    echo -e "    3. Connections → New Connection" > /dev/tty
    echo -e "    4. Välj protokoll (RDP/VNC/SSH), ange IP + credentials" > /dev/tty
    echo -e "    5. Under Parameters → aktivera 'Enable drive' för filöverföring" > /dev/tty
    echo -e "    ${DIM}Du kan ansluta till vilken maskin som helst på nätverket!${NC}" > /dev/tty
    echo "" > /dev/tty
fi

if [ "$INSTALL_DESKTOP" == "y" ]; then
    echo -e "  ${BOLD}Linux Desktop:${NC}" > /dev/tty
    echo -e "    RDP-adress:   ${DESKTOP_IP}:3389" > /dev/tty
    echo -e "    SSH-adress:   ${DESKTOP_IP}:22" > /dev/tty
    echo -e "    Användare:    ${DESKTOP_USER}" > /dev/tty
    echo -e "    Lösenord:     (det du angav)" > /dev/tty
    echo "" > /dev/tty
fi

if [ "$INSTALL_GUAC" == "y" ]; then
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" > /dev/tty
    echo -e "  ${BOLD}Nästa steg — Exponera via Cloudflare:${NC}" > /dev/tty
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" > /dev/tty
    echo "" > /dev/tty
    echo -e "  ${BOLD}1. NPM Proxy Host:${NC}" > /dev/tty
    echo -e "     Domain:     rdp.dindomän.se" > /dev/tty
    echo -e "     Scheme:     http" > /dev/tty
    echo -e "     Forward:    ${GUAC_IP}:8080" > /dev/tty
    echo -e "     Websockets: PÅ" > /dev/tty
    echo -e "     Force SSL:  AV (Cloudflare hanterar HTTPS)" > /dev/tty
    echo "" > /dev/tty
    echo -e "  ${BOLD}2. Cloudflare Tunnel (om wildcard redan finns):${NC}" > /dev/tty
    echo -e "     Om du har *.dindomän.se → NPM i tunneln" > /dev/tty
    echo -e "     behövs inget mer — rdp.dindomän.se fungerar direkt!" > /dev/tty
    echo "" > /dev/tty
    echo -e "  ${BOLD}3. Zero Trust Access (rekommenderat):${NC}" > /dev/tty
    echo -e "     Skydda rdp.dindomän.se med inloggning:" > /dev/tty
    echo -e "     Cloudflare Zero Trust → Access → Applications → Add" > /dev/tty
    echo -e "     Application domain: rdp.dindomän.se" > /dev/tty
    echo -e "     Policy: Allow → Emails ending in @dindomän.se" > /dev/tty
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" > /dev/tty
fi

echo "" > /dev/tty
msg_ok "Remote Desktop-installationen klar!"
