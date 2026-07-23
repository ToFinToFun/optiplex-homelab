#!/usr/bin/env bash
# ============================================================
# OptiPlex Homelab — IP Consistency Checker
# ============================================================
# Verifierar att faktiska CT/VM-IP:er matchar NPM proxy-regler.
# Reparerar automatiskt vid mismatch (med bekräftelse).
# Säkerställer att WebSockets är aktiverat för Frigate.
#
# Användning: sudo bash tools/ip-check.sh [--auto-fix]
# ============================================================

cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/proxmox.sh
source lib/network.sh

# Ladda config
if [ -f setup.env ]; then
    source setup.env
else
    msg_err "setup.env saknas! Kör setup.sh först."
    exit 1
fi

# Flaggor
AUTO_FIX=false
if [[ "$1" == "--auto-fix" ]] || [[ "$1" == "--headless" ]]; then
    AUTO_FIX=true
fi

# ============================================================
# ROOT-CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}${BOLD}  IP-check måste köras som root.${NC}"
    echo -e "  Kör: ${YELLOW}sudo bash tools/ip-check.sh${NC}"
    exit 1
fi

clear
echo -e "${BOLD}${BLUE}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║     OptiPlex Homelab — IP Consistency Check   ║"
echo "  ╠═══════════════════════════════════════════════╣"
echo "  ║  Verifierar att IP:er matchar NPM-regler...   ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

ISSUES=0
FIXED=0
NW="${NETWORK_PREFIX:-192.168.0}"

# ============================================================
# 1. UPPTÄCK FAKTISKA IP:ER FRÅN VARJE CT/VM
# ============================================================
msg_header "Faktiska IP-adresser"

declare -A ACTUAL_IPS
declare -A SERVICE_PORTS
declare -A SERVICE_NAMES

# Definiera tjänster och deras portar
SERVICE_NAMES[ha]="Home Assistant"
SERVICE_NAMES[cloudflared]="Cloudflared"
SERVICE_NAMES[npm]="NPM"
SERVICE_NAMES[frigate]="Frigate"
SERVICE_NAMES[adguard]="AdGuard Home"
SERVICE_NAMES[guacamole]="Guacamole"
SERVICE_NAMES[desktop]="Desktop"

SERVICE_PORTS[ha]=8123
SERVICE_PORTS[frigate]=5000
SERVICE_PORTS[npm]=81
SERVICE_PORTS[adguard]=80
SERVICE_PORTS[guacamole]=8080

# Upptäck HA (VM — använder qm guest exec eller nätverksconfig)
HA_ID=$(resolve_vm_id "ha" "${IP_HA:-100}")
if [ -n "$HA_ID" ] && qm status "$HA_ID" 2>/dev/null | grep -q "running"; then
    # HAOS: försök via guest agent
    HA_ACTUAL=$(qm guest cmd "$HA_ID" network-get-interfaces 2>/dev/null | \
        python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for iface in data:
        if iface.get('name') in ('enp0s18', 'eth0', 'end0'):
            for addr in iface.get('ip-addresses', []):
                if addr.get('ip-address-type') == 'ipv4' and not addr['ip-address'].startswith('127.'):
                    print(addr['ip-address'])
                    sys.exit(0)
    # Fallback: hitta första icke-loopback IPv4
    for iface in data:
        if iface.get('name') == 'lo':
            continue
        for addr in iface.get('ip-addresses', []):
            if addr.get('ip-address-type') == 'ipv4' and not addr['ip-address'].startswith('127.'):
                print(addr['ip-address'])
                sys.exit(0)
except:
    pass
" 2>/dev/null)
    
    if [ -z "$HA_ACTUAL" ]; then
        # Fallback: pinga förväntad IP
        EXPECTED_HA="${NW}.${IP_HA}"
        if ping -c 1 -W 2 "$EXPECTED_HA" > /dev/null 2>&1; then
            HA_ACTUAL="$EXPECTED_HA"
        fi
    fi
    
    if [ -n "$HA_ACTUAL" ]; then
        ACTUAL_IPS[ha]="$HA_ACTUAL"
        msg_ok "Home Assistant (VM $HA_ID): ${HA_ACTUAL}"
    else
        msg_warn "Home Assistant (VM $HA_ID): Kunde inte upptäcka IP"
        ISSUES=$((ISSUES + 1))
    fi
else
    msg_info "Home Assistant: Inte igång eller finns inte"
fi

# Upptäck CT:er
discover_ct_actual_ip() {
    local hostname="$1"
    local config_id="$2"
    local ct_id
    
    ct_id=$(resolve_ct_id "$hostname" "$config_id")
    if [ -z "$ct_id" ]; then
        echo ""
        return 1
    fi
    
    if ! pct status "$ct_id" 2>/dev/null | grep -q "running"; then
        echo ""
        return 2
    fi
    
    # Hämta IP från containerns nätverksconfig
    local ip
    ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
    
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        echo "$ip"
        return 0
    fi
    
    # Fallback: läs från LXC-config (statisk IP)
    local conf_file="/etc/pve/lxc/${ct_id}.conf"
    if [ -f "$conf_file" ]; then
        ip=$(grep "^net0:" "$conf_file" | grep -oP 'ip=\K[^/]+')
        if [ -n "$ip" ] && [ "$ip" != "dhcp" ]; then
            echo "$ip"
            return 0
        fi
    fi
    
    echo ""
    return 1
}

# Cloudflared
CF_ID=$(resolve_ct_id "cloudflared" "${IP_CLOUDFLARED:-101}")
CF_ACTUAL=$(discover_ct_actual_ip "cloudflared" "${IP_CLOUDFLARED:-101}")
if [ -n "$CF_ACTUAL" ]; then
    ACTUAL_IPS[cloudflared]="$CF_ACTUAL"
    msg_ok "Cloudflared (CT $CF_ID): ${CF_ACTUAL}"
elif [ -n "$CF_ID" ]; then
    msg_warn "Cloudflared (CT $CF_ID): Inte igång"
fi

# NPM
NPM_CT_ID=$(resolve_ct_id "npm" "${IP_NPM:-102}")
NPM_ACTUAL=$(discover_ct_actual_ip "npm" "${IP_NPM:-102}")
if [ -n "$NPM_ACTUAL" ]; then
    ACTUAL_IPS[npm]="$NPM_ACTUAL"
    msg_ok "NPM (CT $NPM_CT_ID): ${NPM_ACTUAL}"
elif [ -n "$NPM_CT_ID" ]; then
    msg_warn "NPM (CT $NPM_CT_ID): Inte igång"
fi

# Frigate
FRIG_ID=$(resolve_ct_id "frigate" "${IP_FRIGATE:-103}")
FRIG_ACTUAL=$(discover_ct_actual_ip "frigate" "${IP_FRIGATE:-103}")
if [ -n "$FRIG_ACTUAL" ]; then
    ACTUAL_IPS[frigate]="$FRIG_ACTUAL"
    msg_ok "Frigate (CT $FRIG_ID): ${FRIG_ACTUAL}"
elif [ -n "$FRIG_ID" ]; then
    msg_warn "Frigate (CT $FRIG_ID): Inte igång"
fi

# AdGuard Home
AGH_ID=$(resolve_ct_id "adguard" "${IP_ADGUARD:-104}")
AGH_ACTUAL=$(discover_ct_actual_ip "adguard" "${IP_ADGUARD:-104}")
if [ -n "$AGH_ACTUAL" ]; then
    ACTUAL_IPS[adguard]="$AGH_ACTUAL"
    msg_ok "AdGuard Home (CT $AGH_ID): ${AGH_ACTUAL}"
elif [ -n "$AGH_ID" ]; then
    msg_warn "AdGuard Home (CT $AGH_ID): Inte igång"
fi

# Guacamole
GUAC_ID=$(resolve_ct_id "guacamole" "${IP_GUACAMOLE:-107}")
GUAC_ACTUAL=$(discover_ct_actual_ip "guacamole" "${IP_GUACAMOLE:-107}")
if [ -n "$GUAC_ACTUAL" ]; then
    ACTUAL_IPS[guacamole]="$GUAC_ACTUAL"
    msg_ok "Guacamole (CT $GUAC_ID): ${GUAC_ACTUAL}"
fi

# Desktop
DESK_ID=$(resolve_ct_id "desktop" "${IP_DESKTOP:-108}")
DESK_ACTUAL=$(discover_ct_actual_ip "desktop" "${IP_DESKTOP:-108}")
if [ -n "$DESK_ACTUAL" ]; then
    ACTUAL_IPS[desktop]="$DESK_ACTUAL"
    msg_ok "Desktop (CT $DESK_ID): ${DESK_ACTUAL}"
fi

# ============================================================
# 2. JÄMFÖR MOT SETUP.ENV (konfigurerade IP:er)
# ============================================================
msg_header "Jämförelse mot setup.env"

# Mappning: tjänstnamn → setup.env variabelnamn
declare -A SVC_TO_VAR
SVC_TO_VAR[ha]="IP_HA"
SVC_TO_VAR[cloudflared]="IP_CLOUDFLARED"
SVC_TO_VAR[npm]="IP_NPM"
SVC_TO_VAR[frigate]="IP_FRIGATE"
SVC_TO_VAR[adguard]="IP_ADGUARD"
SVC_TO_VAR[guacamole]="IP_GUACAMOLE"
SVC_TO_VAR[desktop]="IP_DESKTOP"

# Samla config-uppdateringar
declare -A CONFIG_UPDATES

check_config_match() {
    local svc="$1"
    local config_suffix="$2"
    local actual="${ACTUAL_IPS[$svc]}"
    
    [ -z "$actual" ] && return  # Tjänsten körs inte
    
    local expected="${NW}.${config_suffix}"
    if [ "$actual" != "$expected" ]; then
        msg_warn "${SERVICE_NAMES[$svc]}: Faktisk IP (${actual}) ≠ Konfigurerad (${expected})"
        msg_info "  setup.env säger ${expected}, men containern har ${actual}"
        ISSUES=$((ISSUES + 1))
        
        # Extrahera sista oktetten från faktisk IP
        local actual_suffix
        actual_suffix=$(echo "$actual" | awk -F. '{print $4}')
        if [ -n "$actual_suffix" ] && [ "$actual_suffix" != "$config_suffix" ]; then
            CONFIG_UPDATES[$svc]="$actual_suffix"
        fi
    else
        msg_ok "${SERVICE_NAMES[$svc]}: Matchar setup.env (${actual})"
    fi
}

check_config_match "ha" "${IP_HA:-100}"
check_config_match "cloudflared" "${IP_CLOUDFLARED:-101}"
check_config_match "npm" "${IP_NPM:-102}"
check_config_match "frigate" "${IP_FRIGATE:-103}"
check_config_match "guacamole" "${IP_GUACAMOLE:-107}"
check_config_match "desktop" "${IP_DESKTOP:-108}"

# Erbjud att uppdatera setup.env om mismatchar hittades
if [ ${#CONFIG_UPDATES[@]} -gt 0 ]; then
    echo ""
    msg_info "Följande IP-ändringar kan sparas till setup.env:"
    for svc in "${!CONFIG_UPDATES[@]}"; do
        local var_name="${SVC_TO_VAR[$svc]}"
        local new_suffix="${CONFIG_UPDATES[$svc]}"
        msg_info "  ${var_name}: ${!var_name} → ${new_suffix}"
    done
    echo ""
    
    local do_update=false
    if [ "$AUTO_FIX" == "true" ]; then
        do_update=true
    else
        if ask_yes_no "Uppdatera setup.env med faktiska IP:er? (förhindrar att nästa körning \"fixar tillbaka\")" "Y"; then
            do_update=true
        fi
    fi
    
    if [ "$do_update" == "true" ]; then
        for svc in "${!CONFIG_UPDATES[@]}"; do
            local var_name="${SVC_TO_VAR[$svc]}"
            local new_suffix="${CONFIG_UPDATES[$svc]}"
            # Uppdatera i setup.env
            if grep -q "^${var_name}=" setup.env 2>/dev/null; then
                sed -i "s/^${var_name}=.*/${var_name}=\"${new_suffix}\"/" setup.env
                msg_ok "Uppdaterade ${var_name}=${new_suffix} i setup.env"
                FIXED=$((FIXED + 1))
            fi
        done
        # Ladda om config efter ändring
        source setup.env
    fi
fi

# ============================================================
# 3. KONTROLLERA NPM PROXY-REGLER
# ============================================================
msg_header "NPM Proxy Host-verifiering"

NPM_IP="${ACTUAL_IPS[npm]:-${NW}.${IP_NPM:-102}}"

# Kontrollera att NPM svarar
if ! nc -z -w 3 "$NPM_IP" 81 2>/dev/null; then
    msg_warn "NPM svarar inte på ${NPM_IP}:81 — kan inte verifiera proxy-regler."
    msg_info "Starta NPM: pct start ${NPM_CT_ID:-102}"
else
    # Logga in i NPM API
    NPM_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
    NPM_PASS="${SHARED_PASSWORD:-changeme}"
    
    TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\": \"${NPM_EMAIL}\", \"secret\": \"${NPM_PASS}\"}")
    TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    
    # Fallback: default credentials
    if [ -z "$TOKEN" ] && [ "$NPM_PASS" != "changeme" ]; then
        TOKEN_RES=$(curl -s --max-time 5 -X POST "http://${NPM_IP}:81/api/tokens" \
            -H "Content-Type: application/json" \
            -d '{"identity": "admin@example.com", "secret": "changeme"}')
        TOKEN=$(echo "$TOKEN_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    fi
    
    if [ -z "$TOKEN" ]; then
        msg_warn "Kunde inte logga in i NPM API. Kontrollera lösenord."
        msg_info "  Manuell kontroll: http://${NPM_IP}:81"
    else
        msg_ok "Inloggad i NPM API"
        
        # Hämta alla proxy hosts
        HOSTS_JSON=$(curl -s --max-time 10 "http://${NPM_IP}:81/api/nginx/proxy-hosts" \
            -H "Authorization: Bearer $TOKEN")
        
        # Spara till tempfil för python-parsing
        echo "$HOSTS_JSON" > /tmp/npm_hosts.json
        
        # Analysera varje proxy host
        python3 << 'PYEOF' > /tmp/npm_analysis.txt
import json, sys

try:
    with open('/tmp/npm_hosts.json') as f:
        hosts = json.load(f)
except:
    print("ERROR: Kunde inte parsa NPM-data")
    sys.exit(1)

if not isinstance(hosts, list):
    print("ERROR: Oväntat API-svar")
    sys.exit(1)

for h in hosts:
    host_id = h.get('id', '?')
    domains = ','.join(h.get('domain_names', []))
    fwd_host = h.get('forward_host', '')
    fwd_port = h.get('forward_port', '')
    ws = h.get('allow_websocket_upgrade', 0)
    ssl_forced = h.get('ssl_forced', 0)
    enabled = h.get('enabled', 1)
    
    print(f"{host_id}|{domains}|{fwd_host}|{fwd_port}|{ws}|{ssl_forced}|{enabled}")
PYEOF
        
        if [ -f /tmp/npm_analysis.txt ] && ! grep -q "^ERROR:" /tmp/npm_analysis.txt; then
            echo ""
            echo -e "  ${BOLD}NPM Proxy Hosts:${NC}"
            echo -e "  ${CYAN}┌────┬──────────────────────────────┬────────────────────┬────┬────┐${NC}"
            echo -e "  ${CYAN}│${NC} ID ${CYAN}│${NC} Domän                        ${CYAN}│${NC} Forward            ${CYAN}│${NC} WS ${CYAN}│${NC} SSL${CYAN}│${NC}"
            echo -e "  ${CYAN}├────┼──────────────────────────────┼────────────────────┼────┼────┤${NC}"
            
            while IFS='|' read -r id domains fwd_host fwd_port ws ssl enabled; do
                ws_icon=$( [ "$ws" == "1" ] && echo "✓" || echo "✗" )
                ssl_icon=$( [ "$ssl" == "1" ] && echo "⚠" || echo "—" )
                printf "  ${CYAN}│${NC} %-2s ${CYAN}│${NC} %-28s ${CYAN}│${NC} %-18s ${CYAN}│${NC} %-2s ${CYAN}│${NC} %-2s ${CYAN}│${NC}\n" \
                    "$id" "${domains:0:28}" "${fwd_host}:${fwd_port}" "$ws_icon" "$ssl_icon"
            done < /tmp/npm_analysis.txt
            
            echo -e "  ${CYAN}└────┴──────────────────────────────┴────────────────────┴────┴────┘${NC}"
            echo ""
            
            # Kontrollera mismatchar
            while IFS='|' read -r id domains fwd_host fwd_port ws ssl enabled; do
                # Identifiera vilken tjänst denna proxy pekar på
                MATCHED_SVC=""
                case "$fwd_port" in
                    8123) MATCHED_SVC="ha" ;;
                    5000) MATCHED_SVC="frigate" ;;
                    8080) MATCHED_SVC="guacamole" ;;
                esac
                
                # Matcha även på domännamn
                if echo "$domains" | grep -qi "ha\|home"; then
                    MATCHED_SVC="ha"
                elif echo "$domains" | grep -qi "frigate\|nvr\|cam"; then
                    MATCHED_SVC="frigate"
                elif echo "$domains" | grep -qi "guac\|rdp\|remote"; then
                    MATCHED_SVC="guacamole"
                fi
                
                if [ -n "$MATCHED_SVC" ] && [ -n "${ACTUAL_IPS[$MATCHED_SVC]}" ]; then
                    ACTUAL="${ACTUAL_IPS[$MATCHED_SVC]}"
                    if [ "$fwd_host" != "$ACTUAL" ]; then
                        msg_warn "MISMATCH: ${domains} pekar på ${fwd_host} men ${SERVICE_NAMES[$MATCHED_SVC]} har IP ${ACTUAL}"
                        ISSUES=$((ISSUES + 1))
                        
                        # Reparera
                        if [ "$AUTO_FIX" == "true" ] || ask_yes_no "  Uppdatera NPM-regeln till ${ACTUAL}?" "Y"; then
                            # Hämta full host-data för PUT
                            HOST_DATA=$(curl -s --max-time 5 "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                                -H "Authorization: Bearer $TOKEN")
                            
                            # Uppdatera forward_host via PUT
                            UPDATE_RES=$(curl -s --max-time 10 -X PUT "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                                -H "Authorization: Bearer $TOKEN" \
                                -H "Content-Type: application/json" \
                                -d "$(echo "$HOST_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['forward_host'] = '${ACTUAL}'
# Ta bort fält som inte ska skickas vid PUT
for key in ['id', 'created_on', 'modified_on', 'owner_user_id', 'owner', 'access_list', 'certificate', 'use_default_location', 'ipv6']:
    data.pop(key, None)
print(json.dumps(data))
")")
                            
                            if echo "$UPDATE_RES" | grep -q "\"id\":${id}"; then
                                msg_ok "  Uppdaterade ${domains}: ${fwd_host} → ${ACTUAL}"
                                FIXED=$((FIXED + 1))
                            else
                                msg_err "  Kunde inte uppdatera! Svar: $(echo "$UPDATE_RES" | head -c 200)"
                            fi
                        fi
                    else
                        msg_ok "${domains}: Pekar korrekt på ${fwd_host}"
                    fi
                fi
                
                # WebSocket-check för Frigate
                if [ "$MATCHED_SVC" == "frigate" ] && [ "$ws" != "1" ]; then
                    msg_warn "WEBSOCKETS: ${domains} (Frigate) har INTE WebSockets aktiverat!"
                    msg_info "  Frigate kräver WebSockets för live-video i UI:t."
                    ISSUES=$((ISSUES + 1))
                    
                    if [ "$AUTO_FIX" == "true" ] || ask_yes_no "  Aktivera WebSockets för Frigate?" "Y"; then
                        HOST_DATA=$(curl -s --max-time 5 "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                            -H "Authorization: Bearer $TOKEN")
                        
                        UPDATE_RES=$(curl -s --max-time 10 -X PUT "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                            -H "Authorization: Bearer $TOKEN" \
                            -H "Content-Type: application/json" \
                            -d "$(echo "$HOST_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['allow_websocket_upgrade'] = 1
for key in ['id', 'created_on', 'modified_on', 'owner_user_id', 'owner', 'access_list', 'certificate', 'use_default_location', 'ipv6']:
    data.pop(key, None)
print(json.dumps(data))
")")
                        
                        if echo "$UPDATE_RES" | grep -q '"allow_websocket_upgrade":1'; then
                            msg_ok "  WebSockets aktiverat för ${domains}"
                            FIXED=$((FIXED + 1))
                        else
                            msg_err "  Kunde inte aktivera WebSockets!"
                        fi
                    fi
                fi
                
                # Force SSL-check (ska INTE vara aktiverat med Cloudflare Tunnel)
                if [ "$ssl" == "1" ]; then
                    msg_warn "FORCE SSL: ${domains} har 'Force SSL' aktiverat — orsakar redirect-loop med Cloudflare!"
                    ISSUES=$((ISSUES + 1))
                    
                    if [ "$AUTO_FIX" == "true" ] || ask_yes_no "  Inaktivera Force SSL?" "Y"; then
                        HOST_DATA=$(curl -s --max-time 5 "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                            -H "Authorization: Bearer $TOKEN")
                        
                        UPDATE_RES=$(curl -s --max-time 10 -X PUT "http://${NPM_IP}:81/api/nginx/proxy-hosts/${id}" \
                            -H "Authorization: Bearer $TOKEN" \
                            -H "Content-Type: application/json" \
                            -d "$(echo "$HOST_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['ssl_forced'] = 0
for key in ['id', 'created_on', 'modified_on', 'owner_user_id', 'owner', 'access_list', 'certificate', 'use_default_location', 'ipv6']:
    data.pop(key, None)
print(json.dumps(data))
")")
                        
                        if echo "$UPDATE_RES" | grep -q '"ssl_forced":0\|"ssl_forced":false'; then
                            msg_ok "  Force SSL inaktiverat för ${domains}"
                            FIXED=$((FIXED + 1))
                        else
                            msg_err "  Kunde inte inaktivera Force SSL!"
                        fi
                    fi
                fi
                
            done < /tmp/npm_analysis.txt
        else
            msg_warn "Kunde inte analysera NPM proxy hosts."
            cat /tmp/npm_analysis.txt 2>/dev/null
        fi
        
        # Cleanup
        rm -f /tmp/npm_hosts.json /tmp/npm_analysis.txt
    fi
fi

# ============================================================
# 4. CLOUDFLARE TUNNEL INGRESS-CHECK
# ============================================================
msg_header "Cloudflare Tunnel Ingress"

if [ -n "$CF_ID" ] && pct status "$CF_ID" 2>/dev/null | grep -q "running"; then
    # Hämta tunnel-config (om den finns)
    TUNNEL_CONFIG=$(pct exec "$CF_ID" -- cat /root/.cloudflared/config.yml 2>/dev/null || \
                    pct exec "$CF_ID" -- cat /etc/cloudflared/config.yml 2>/dev/null || echo "")
    
    if [ -n "$TUNNEL_CONFIG" ]; then
        # Kolla om NPM-IP i tunnel-config matchar faktisk NPM-IP
        TUNNEL_NPM_IP=$(echo "$TUNNEL_CONFIG" | grep -oP 'http://\K[0-9.]+(?=:80)')
        if [ -n "$TUNNEL_NPM_IP" ] && [ -n "${ACTUAL_IPS[npm]}" ]; then
            if [ "$TUNNEL_NPM_IP" != "${ACTUAL_IPS[npm]}" ]; then
                msg_warn "Cloudflare Tunnel pekar på NPM ${TUNNEL_NPM_IP} men NPM har IP ${ACTUAL_IPS[npm]}"
                msg_info "  Tunneln konfigureras via Cloudflare Dashboard (Zero Trust → Tunnels → Configure)"
                msg_info "  Eller: uppdatera /root/.cloudflared/config.yml i CT $CF_ID"
                ISSUES=$((ISSUES + 1))
            else
                msg_ok "Tunnel → NPM: Matchar (${TUNNEL_NPM_IP})"
            fi
        fi
    else
        msg_info "Tunnel körs via token (remotely managed) — kontrollera i Cloudflare Dashboard"
    fi
else
    msg_info "Cloudflared inte igång — hoppar över tunnel-check"
fi

# ============================================================
# 5. SAMMANFATTNING
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $ISSUES -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ Alla IP:er och NPM-regler matchar! Inga problem.${NC}"
elif [ $FIXED -gt 0 ]; then
    REMAINING=$((ISSUES - FIXED))
    echo -e "  ${YELLOW}${BOLD}⚠ ${ISSUES} problem hittade, ${FIXED} åtgärdade automatiskt.${NC}"
    if [ $REMAINING -gt 0 ]; then
        echo -e "  ${YELLOW}  ${REMAINING} kvarstår — se ovan.${NC}"
    fi
else
    echo -e "  ${RED}${BOLD}✗ ${ISSUES} IP-mismatch(er) hittade!${NC}"
    echo -e "  ${RED}  Kör med --auto-fix för att reparera automatiskt.${NC}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Tips
if [ $ISSUES -gt 0 ] && [ $FIXED -eq 0 ]; then
    echo -e "  ${BOLD}Tips:${NC}"
    echo -e "    Auto-fix:    ${YELLOW}sudo bash tools/ip-check.sh --auto-fix${NC}"
    echo -e "    NPM manuellt: http://${NPM_IP}:81"
    echo -e "    Kör wizard:   ${YELLOW}cd /opt/optiplex-homelab/scripts && bash setup.sh${NC}"
    echo ""
fi

exit $ISSUES
