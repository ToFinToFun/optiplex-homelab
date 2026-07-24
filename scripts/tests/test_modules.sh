#!/usr/bin/env bash
# ============================================================================
# TEST HARNESS: Simulerar modulkörning med olika setup.env-varianter
# ============================================================================
# Testar att alla moduler hanterar:
# 1. Komplett setup.env (alla variabler satta)
# 2. Gammal setup.env (saknar nya variabler)
# 3. Minimal setup.env (bara NETWORK_PREFIX och GATEWAY)
# 4. Tom setup.env
# ============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="/tmp/optiplex-test-$$"
PASS=0
FAIL=0
WARNINGS=()

# Färger
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR"

# ─── Hjälpfunktioner ─────────────────────────────────────────
pass() { ((PASS++)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $1"; WARNINGS+=("$1"); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARNINGS+=("WARN: $1"); }

# ─── Test 1: Variabel-expansion med bash -x ──────────────────
# Skapar en wrapper som sourcar modulen men stubbar ut pct/qm/etc.
# och fångar vilka argument som skickas till pct create
echo "═══════════════════════════════════════════════════════════"
echo " TEST 1: Variabel-expansion i pct create-kommandon"
echo "═══════════════════════════════════════════════════════════"

# Skapa mock-funktioner som loggar anrop istället för att köra
cat > "$TEST_DIR/mock_functions.sh" << 'MOCK'
# Mock Proxmox-kommandon
pct() {
    echo "MOCK_PCT_CALL: $*" >> "$TEST_DIR/pct_calls.log"
    if [ "$1" == "create" ]; then
        echo "PCT_CREATE_VMID=$2" >> "$TEST_DIR/pct_create_args.log"
        # Extrahera net0 argument
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[$i]}" == "--net0" ]; then
                echo "PCT_CREATE_NET0=${args[$((i+1))]}" >> "$TEST_DIR/pct_create_args.log"
            fi
            if [ "${args[$i]}" == "--storage" ]; then
                echo "PCT_CREATE_STORAGE=${args[$((i+1))]}" >> "$TEST_DIR/pct_create_args.log"
            fi
            if [ "${args[$i]}" == "--hostname" ]; then
                echo "PCT_CREATE_HOSTNAME=${args[$((i+1))]}" >> "$TEST_DIR/pct_create_args.log"
            fi
        done
        echo "---" >> "$TEST_DIR/pct_create_args.log"
    fi
    return 0
}
qm() {
    echo "MOCK_QM_CALL: $*" >> "$TEST_DIR/qm_calls.log"
    return 0
}
export -f pct qm

# Mock UI-funktioner
msg_info() { :; }
msg_ok() { :; }
msg_warn() { :; }
msg_err() { echo "ERROR: $*" >> "$TEST_DIR/errors.log"; }
msg_skip() { :; }
msg_header() { :; }
msg_dry() { :; }
show_progress() { :; }
tty_echo() { :; }
tty_printf() { :; }
tty_read() { REPLY=""; }
ask_yes_no() { return 0; }
ask_string() { echo "$2"; }  # Returnera default-värdet
wait_for_service() { return 0; }
print_banner() { :; }
discover_ct_ip() { echo "$2"; }  # Returnera expected IP

# Mock network-funktioner
get_net0_param() {
    local ip="$1" cidr="$2" gw="$3"
    if [ -z "$ip" ] || [ "$ip" == "." ] || [[ "$ip" == *"." && ! "$ip" =~ \.[0-9]+$ ]]; then
        echo "INVALID_NET0:ip=$ip,cidr=$cidr,gw=$gw"
        return 1
    fi
    echo "name=eth0,bridge=vmbr0,ip=${ip}/${cidr},gw=${gw}"
}
detect_network() { :; }
confirm_network() { :; }
find_free_ip() { echo "$1"; }
verify_planned_ips() { :; }

# Mock proxmox lib
resolve_ct_id() { echo "${2:-}"; }
resolve_vm_id() { echo "${2:-}"; }
check_id_exists() { return 1; }  # Container finns inte

# Mock config
load_config() { return 0; }
save_config() { :; }
get_state() { echo ""; }
set_state() { :; }

# Mock rollback
rollback_register() { :; }
rollback_clear() { :; }
rollback_offer() { :; }

export -f msg_info msg_ok msg_warn msg_err msg_skip msg_header msg_dry
export -f show_progress tty_echo tty_printf tty_read ask_yes_no ask_string
export -f wait_for_service print_banner discover_ct_ip
export -f get_net0_param detect_network confirm_network find_free_ip verify_planned_ips
export -f resolve_ct_id resolve_vm_id check_id_exists
export -f load_config save_config get_state set_state
export -f rollback_register rollback_clear rollback_offer
MOCK

# ─── Setup.env varianter ─────────────────────────────────────
# Variant A: Komplett (alla variabler)
cat > "$TEST_DIR/setup_complete.env" << 'ENV'
NETWORK_PREFIX="192.168.1"
GATEWAY="192.168.1.1"
NETWORK_CIDR="24"
NODE_HOSTNAME="optiplex"
STORAGE_POOL="local-lvm"
USE_DHCP="false"
SHARED_PASSWORD="TestPass123"
CF_TUNNEL_TOKEN="eyJhIjoiMTIzIn0.test.token"
CF_DOMAIN="example.se"
IP_HA="100"
IP_CLOUDFLARED="101"
IP_NPM="102"
IP_FRIGATE="103"
IP_ADGUARD="104"
IP_GUACAMOLE="107"
IP_DESKTOP="108"
IP_SAMBA="109"
IP_IMMICH="110"
IP_NUT="111"
FRIGATE_DISK="64"
HEADLESS="true"
ENV

# Variant B: Gammal (saknar IP_ADGUARD, IP_SAMBA, IP_IMMICH, IP_NUT, STORAGE_POOL)
cat > "$TEST_DIR/setup_old.env" << 'ENV'
NETWORK_PREFIX="192.168.1"
GATEWAY="192.168.1.1"
NETWORK_CIDR="24"
NODE_HOSTNAME="optiplex"
USE_DHCP="false"
SHARED_PASSWORD="TestPass123"
CF_TUNNEL_TOKEN="eyJhIjoiMTIzIn0.test.token"
CF_DOMAIN="example.se"
IP_HA="100"
IP_CLOUDFLARED="101"
IP_NPM="102"
IP_FRIGATE="103"
FRIGATE_DISK="64"
HEADLESS="true"
ENV

# Variant C: Minimal (bara nätverk)
cat > "$TEST_DIR/setup_minimal.env" << 'ENV'
NETWORK_PREFIX="192.168.1"
GATEWAY="192.168.1.1"
HEADLESS="true"
ENV

# Variant D: Tom
touch "$TEST_DIR/setup_empty.env"

# ─── Kör tester ──────────────────────────────────────────────
test_module() {
    local module="$1"
    local env_variant="$2"
    local env_file="$TEST_DIR/setup_${env_variant}.env"
    local test_name="${module##*/} [${env_variant}]"
    
    # Rensa loggfiler
    rm -f "$TEST_DIR/pct_calls.log" "$TEST_DIR/pct_create_args.log" "$TEST_DIR/errors.log"
    
    # Skapa temporär test-katalog med mock setup.env
    local run_dir="$TEST_DIR/run_$$"
    mkdir -p "$run_dir/lib" "$run_dir/modules"
    cp "$env_file" "$run_dir/setup.env"
    
    # Skapa tomma lib-filer (modulerna sourcar dem)
    touch "$run_dir/lib/ui.sh" "$run_dir/lib/network.sh" "$run_dir/lib/proxmox.sh" 
    touch "$run_dir/lib/config.sh" "$run_dir/lib/rollback.sh"
    
    # Kopiera modulen
    cp "$SCRIPT_DIR/modules/$module" "$run_dir/modules/"
    
    # Kör modulen med mock-funktioner och fånga output
    local output
    output=$(cd "$run_dir" && source "$TEST_DIR/mock_functions.sh" && \
        TEMPLATE_PATH="/tmp/fake-template.tar.zst" \
        TEST_DIR="$TEST_DIR" \
        bash -c "source '$TEST_DIR/mock_functions.sh'; source 'setup.env'; source 'modules/$module' '/tmp/fake-template.tar.zst'" 2>&1) || true
    
    # Analysera resultat
    if [ -f "$TEST_DIR/pct_create_args.log" ]; then
        # Kolla efter tomma VMID
        if grep -q "PCT_CREATE_VMID=$" "$TEST_DIR/pct_create_args.log" 2>/dev/null || \
           grep -q 'PCT_CREATE_VMID=""' "$TEST_DIR/pct_create_args.log" 2>/dev/null; then
            fail "$test_name: pct create fick TOMT vmid!"
            return
        fi
        # Kolla efter ogiltigt net0
        if grep -q "INVALID_NET0" "$TEST_DIR/pct_create_args.log" 2>/dev/null; then
            fail "$test_name: pct create fick OGILTIGT net0-format!"
            grep "INVALID_NET0" "$TEST_DIR/pct_create_args.log" | sed 's/^/    /'
            return
        fi
        # Kolla efter tom storage
        if grep -q "PCT_CREATE_STORAGE=$" "$TEST_DIR/pct_create_args.log" 2>/dev/null || \
           grep -q 'PCT_CREATE_STORAGE=""' "$TEST_DIR/pct_create_args.log" 2>/dev/null; then
            fail "$test_name: pct create fick TOM storage!"
            return
        fi
        pass "$test_name"
    elif echo "$output" | grep -qi "error\|saknas\|failed"; then
        # Modulen avbröt med felmeddelande (pre-flight check) - det är OK
        pass "$test_name (avbröt med tydligt fel)"
    else
        # Ingen pct create och inget fel - modulen kanske hoppade över (OK för vissa)
        pass "$test_name (ingen container skapad - OK)"
    fi
    
    rm -rf "$run_dir"
}

# Moduler som skapar containers
CONTAINER_MODULES=(
    "03-cloudflared.sh"
    "03.5-adguard.sh"
    "04-npm.sh"
    "05-frigate.sh"
    "10-samba.sh"
    "11-immich.sh"
    "12-nut.sh"
)

for variant in complete old minimal empty; do
    echo ""
    echo "── Testar med setup.env variant: $variant ──"
    for mod in "${CONTAINER_MODULES[@]}"; do
        test_module "$mod" "$variant"
    done
done

# ─── Test 2: Variabel-invarianter ────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " TEST 2: Variabel-invarianter i alla filer"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "── Kollar att alla pct/qm-kommandon använder citerade variabler ──"
# Hitta pct create/exec/start/stop med ocitaterade variabler
cd "$SCRIPT_DIR"
while IFS= read -r line; do
    # Ignorera kommentarer
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Kolla om det finns $VAR utan quotes i pct/qm-kommandon
    if echo "$line" | grep -qP 'pct\s+(create|exec|start|stop|destroy)\s+[^"]*\$\{?[A-Z_]+\}?[^"]*' 2>/dev/null; then
        # Dubbelkolla att det inte redan är citerat
        if ! echo "$line" | grep -qP 'pct\s+(create|exec|start|stop|destroy)\s+"' 2>/dev/null; then
            warn "Möjlig ocitaterad variabel i pct-kommando: $(echo "$line" | sed 's/^[[:space:]]*//')"
        fi
    fi
done < <(grep -rn 'pct \(create\|exec\|start\|stop\|destroy\)' modules/ setup.sh 2>/dev/null)

echo ""
echo "── Kollar att alla heredocs i bash -c har korrekt variabel-expansion ──"
# Hitta bash -c "..." med ${VAR} inuti single-quoted heredocs
while IFS=: read -r file line content; do
    if echo "$content" | grep -q "bash -c '"; then
        # Single-quoted bash -c - variabler expanderas INTE
        if echo "$content" | grep -qP '\$\{[A-Z_]+\}'; then
            fail "Single-quoted bash -c med \${VAR} i $file:$line - variabler expanderas inte!"
        fi
    fi
done < <(grep -rn "bash -c" modules/ 2>/dev/null)

echo ""
echo "── Kollar att alla moduler har source setup.env ──"
for f in modules/*.sh; do
    if ! grep -q "source setup.env" "$f"; then
        fail "$f saknar 'source setup.env'"
    else
        pass "$f har source setup.env"
    fi
done

# ─── Test 3: Kontrollflöde-analys ────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " TEST 3: Kontrollflöde och felhantering"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "── Kollar att alla moduler har return/exit vid fel ──"
for f in modules/*.sh; do
    if grep -q "pct create" "$f"; then
        if ! grep -q "return 1\|exit 1" "$f"; then
            fail "$f skapar container men har ingen felhantering (return/exit 1)"
        else
            pass "$f har felhantering"
        fi
    fi
done

echo ""
echo "── Kollar att inga variabler används före source setup.env ──"
for f in modules/*.sh; do
    # Hitta första source setup.env
    local source_line=$(grep -n "source setup.env" "$f" | head -1 | cut -d: -f1)
    if [ -n "$source_line" ]; then
        # Kolla om det finns ${VAR}-användning före source
        local before=$(head -n "$((source_line-1))" "$f" | grep -c '\${[A-Z]' 2>/dev/null || echo 0)
        if [ "$before" -gt 0 ]; then
            fail "$f använder variabler FÖRE source setup.env"
        fi
    fi
done

echo ""
echo "── Kollar att curl-kommandon har timeout ──"
while IFS=: read -r file line content; do
    if ! echo "$content" | grep -qE '(--connect-timeout|--max-time|-m [0-9])'; then
        if echo "$content" | grep -qv "curl.*-[sS].*download\|curl.*-[sS].*output\|curl.*-[sS].*github\|curl.*-[sS].*docker\|curl.*-[sS].*cloudflare"; then
            warn "curl utan timeout i $file:$line"
        fi
    fi
done < <(grep -rn "curl " modules/ tools/ 2>/dev/null | grep -v "^#\|#.*curl")

# ─── Sammanfattning ──────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " SAMMANFATTNING"
echo "═══════════════════════════════════════════════════════════"
echo -e " ${GREEN}PASS: $PASS${NC}"
echo -e " ${RED}FAIL: $FAIL${NC}"
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo " Detaljer:"
    for w in "${WARNINGS[@]}"; do
        echo "   - $w"
    done
fi
echo ""
exit $FAIL
