#!/usr/bin/env bash
# ============================================================================
# Modul 03.5: AdGuard Home — Nätverksblockering + Split-DNS
# ============================================================================
# Skapar en LXC-container med AdGuard Home som DNS-server.
# Konfigurerar:
#   - Upstream DNS (Cloudflare DoH eller router)
#   - Split-DNS rewrites (intern trafik pekar direkt på tjänster)
#   - Blockering av annonser och trackers
# ============================================================================

source setup.env
source lib/ui.sh
source lib/network.sh
TEMPLATE_PATH=$1

# Säkerställ defaults (kan saknas i äldre setup.env)
IP_ADGUARD="${IP_ADGUARD:-104}"
STORAGE_POOL="${STORAGE_POOL:-local-lvm}"

# Pre-flight check
preflight_check_network || { return 1 2>/dev/null || exit 1; }

CIDR="${NETWORK_CIDR:-24}"
CT_IP="${NETWORK_PREFIX}.${IP_ADGUARD}"

# Bestäm nätverksparameter (DHCP eller statisk)
NET0_PARAM=$(get_net0_param "$CT_IP" "$CIDR" "$GATEWAY")

msg_info "Skapar LXC-container ${IP_ADGUARD} (AdGuard Home)..."

if ! pct create "${IP_ADGUARD}" "${TEMPLATE_PATH}" \
    --hostname adguard \
    --cores 1 \
    --memory 512 \
    --swap 0 \
    --net0 "$NET0_PARAM" \
    --storage "${STORAGE_POOL}" \
    --rootfs "${STORAGE_POOL}:4" \
    --password "${SHARED_PASSWORD:-$CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 2>&1; then
    msg_err "Kunde inte skapa container ${IP_ADGUARD}. Se felmeddelande ovan."
    return 1 2>/dev/null || exit 1
fi

pct start "${IP_ADGUARD}"
sleep 5

# Upptäck faktisk IP (viktigt vid DHCP)
ACTUAL_IP=$(discover_ct_ip "${IP_ADGUARD}" "$CT_IP" 30)
if [ "${USE_DHCP:-false}" == "true" ] && [ -n "$ACTUAL_IP" ]; then
    msg_info "Container fick IP: ${ACTUAL_IP}"
    msg_warn "Lås denna IP i din router för att den ska vara permanent."
fi
ADGUARD_IP="${ACTUAL_IP:-$CT_IP}"

# ── Installera AdGuard Home ──────────────────────────────────────────────────
msg_info "Installerar AdGuard Home..."

pct exec "${IP_ADGUARD}" -- bash -c '
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq curl ca-certificates > /dev/null 2>&1

    # Inaktivera systemd-resolved (frigör port 53)
    if systemctl is-active systemd-resolved &>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/adguardhome.conf << RESOLVEDEOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
RESOLVEDEOF
        mv /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        systemctl reload-or-restart systemd-resolved
        sleep 2
    fi

    # Ladda ner och installera AdGuard Home
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v 2>&1 | tail -5
'

# Vänta på att AdGuard Home startar (initial setup-läge, port 3000)
msg_info "Väntar på att AdGuard Home startar..."
for i in $(seq 1 20); do
    if pct exec "${IP_ADGUARD}" -- curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000/" 2>/dev/null | grep -q "200\|302"; then
        break
    fi
    sleep 2
done

# ── Automatisk initial konfiguration via API ─────────────────────────────────
msg_info "Konfigurerar AdGuard Home via API..."

# Skapa admin-konto och konfigurera portar
AGH_PASSWORD="${SHARED_PASSWORD:-$CT_PASSWORD}"
pct exec "${IP_ADGUARD}" -- bash -c "
    # Generera bcrypt-hash för lösenordet (AdGuard kräver det)
    # Använd AdGuardHome inbyggda hash-funktion
    AGH_HASH=\$(./opt/AdGuardHome/AdGuardHome --hash-password '${AGH_PASSWORD}' 2>/dev/null || echo '')
    
    # Om hash-funktionen inte finns, använd python
    if [ -z \"\$AGH_HASH\" ]; then
        apt-get install -y -qq python3 > /dev/null 2>&1
        AGH_HASH=\$(python3 -c \"
import hashlib, os, base64
password = '${AGH_PASSWORD}'.encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha256', password, salt, 100000)
print('\\\$2a\\\$10\\\$' + base64.b64encode(salt + dk).decode()[:53])
\" 2>/dev/null || echo '')
    fi

    # Kör initial setup via API
    curl -s -X POST 'http://127.0.0.1:3000/control/install/configure' \
        -H 'Content-Type: application/json' \
        -d '{
            \"web\": {\"port\": 80, \"ip\": \"0.0.0.0\"},
            \"dns\": {\"port\": 53, \"ip\": \"0.0.0.0\"},
            \"username\": \"admin\",
            \"password\": \"${AGH_PASSWORD}\"
        }' 2>/dev/null
" 2>/dev/null

# Vänta på omstart efter konfiguration (port 80 nu)
sleep 5
for i in $(seq 1 15); do
    if pct exec "${IP_ADGUARD}" -- curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/" 2>/dev/null | grep -q "200\|302\|401"; then
        break
    fi
    sleep 2
done

# ── Konfigurera upstream DNS ─────────────────────────────────────────────────
msg_info "Konfigurerar upstream DNS..."

# Bestäm upstream baserat på val (default: Cloudflare DoH)
UPSTREAM="${ADGUARD_UPSTREAM:-cloudflare}"
if [ "$UPSTREAM" == "router" ]; then
    UPSTREAM_DNS="[\"${GATEWAY}\"]"
    BOOTSTRAP_DNS="[\"${GATEWAY}\"]"
    msg_info "Upstream DNS: Router (${GATEWAY})"
else
    UPSTREAM_DNS="[\"https://dns.cloudflare.com/dns-query\", \"https://dns.google/dns-query\"]"
    BOOTSTRAP_DNS="[\"1.1.1.1\", \"8.8.8.8\"]"
    msg_info "Upstream DNS: Cloudflare DoH + Google DoH"
fi

pct exec "${IP_ADGUARD}" -- bash -c "
    curl -s -X POST 'http://127.0.0.1/control/dns_config' \
        -u 'admin:${AGH_PASSWORD}' \
        -H 'Content-Type: application/json' \
        -d '{
            \"upstream_dns\": ${UPSTREAM_DNS},
            \"bootstrap_dns\": ${BOOTSTRAP_DNS},
            \"protection_enabled\": true,
            \"ratelimit\": 0
        }' 2>/dev/null
" 2>/dev/null

# ── Konfigurera Split-DNS rewrites ──────────────────────────────────────────
msg_info "Konfigurerar Split-DNS rewrites (intern trafik pekar direkt på tjänster)..."

# Samla ihop alla tjänster och deras faktiska IP:er
DOMAIN="${CF_DOMAIN:-}"

if [ -n "$DOMAIN" ]; then
    # Beräkna faktiska IP:er
    _HA_IP="${HA_ACTUAL_IP:-${NETWORK_PREFIX}.${IP_HA}}"
    _NPM_IP="${NPM_ACTUAL_IP:-${NETWORK_PREFIX}.${IP_NPM}}"
    _FRIGATE_IP="${FRIGATE_ACTUAL_IP:-${NETWORK_PREFIX}.${IP_FRIGATE}}"
    _GUAC_IP="${GUAC_ACTUAL_IP:-${NETWORK_PREFIX}.${IP_GUACAMOLE:-107}}"
    
    # Definiera rewrites: subdomain → intern IP
    declare -a REWRITES=(
        "ha.${DOMAIN}:${_HA_IP}"
        "frigate.${DOMAIN}:${_FRIGATE_IP}"
        "npm.${DOMAIN}:${_NPM_IP}"
        "guacamole.${DOMAIN}:${_GUAC_IP}"
        "remote.${DOMAIN}:${_GUAC_IP}"
    )
    
    REWRITE_COUNT=0
    for entry in "${REWRITES[@]}"; do
        _domain="${entry%%:*}"
        _ip="${entry##*:}"
        
        # Lägg till rewrite via API
        RESULT=$(pct exec "${IP_ADGUARD}" -- bash -c "
            curl -s -o /dev/null -w '%{http_code}' -X POST 'http://127.0.0.1/control/rewrite/add' \
                -u 'admin:${AGH_PASSWORD}' \
                -H 'Content-Type: application/json' \
                -d '{\"domain\": \"${_domain}\", \"answer\": \"${_ip}\"}' 2>/dev/null
        " 2>/dev/null)
        
        if [ "$RESULT" == "200" ]; then
            REWRITE_COUNT=$((REWRITE_COUNT + 1))
        fi
    done
    
    msg_ok "Lade till ${REWRITE_COUNT} DNS-rewrites (intern trafik undviker tunnel)"
else
    msg_warn "Ingen domän konfigurerad (CF_DOMAIN) — split-DNS rewrites hoppas över."
    msg_info "Kör wizarden igen efter att du konfigurerat Cloudflare DNS (steg 7)."
    msg_info "Rewrites kan också läggas till manuellt i AdGuard UI: http://${ADGUARD_IP}"
fi

# ── Verifiera att AdGuard svarar på DNS ──────────────────────────────────────
msg_info "Verifierar DNS-funktionalitet..."

DNS_TEST=$(pct exec "${IP_ADGUARD}" -- bash -c "
    # Installera dnsutils om det saknas
    which nslookup > /dev/null 2>&1 || apt-get install -y -qq dnsutils > /dev/null 2>&1
    nslookup cloudflare.com 127.0.0.1 2>/dev/null | grep -c 'Address' || echo '0'
" 2>/dev/null)

if [ "${DNS_TEST:-0}" -ge 2 ]; then
    msg_ok "AdGuard Home DNS fungerar korrekt!"
else
    msg_warn "DNS-test misslyckades — kontrollera manuellt: http://${ADGUARD_IP}"
fi

# ── Slutmeddelande ───────────────────────────────────────────────────────────
echo ""
msg_ok "AdGuard Home installerad och konfigurerad!"
echo ""
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}AdGuard Home${NC}"
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Admin UI:    ${GREEN}http://${ADGUARD_IP}${NC}"
echo -e "  DNS-server:  ${GREEN}${ADGUARD_IP}:53${NC}"
echo -e "  Login:       admin / (ditt gemensamma lösenord)"
echo ""
echo -e "  ${YELLOW}${BOLD}VIKTIGT — Gör detta i din router:${NC}"
echo -e "  ${YELLOW}Peka routerns DNS-server till: ${ADGUARD_IP}${NC}"
echo -e ""
echo -e "  ${DIM}Var:${NC}"
echo -e "  ${DIM}  Unifi: Settings → Networks → Default → DHCP DNS Server → ${ADGUARD_IP}${NC}"
echo -e "  ${DIM}  Eller: Routerns DNS-inställning → Primary DNS → ${ADGUARD_IP}${NC}"
echo -e ""
if [ -n "$DOMAIN" ]; then
    echo -e "  ${BOLD}Split-DNS aktiv:${NC}"
    echo -e "  ${DIM}  Intern trafik till *.${DOMAIN} löser direkt till lokala IP:er.${NC}"
    echo -e "  ${DIM}  Undviker onödig rundtur via Cloudflare Tunnel.${NC}"
fi
echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
