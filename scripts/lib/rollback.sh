#!/usr/bin/env bash
# ============================================================
# Rollback-stöd — Ångra skapade containers/VMs vid fel
# ============================================================
# Användning:
#   rollback_register <type> <id> <name>   — Registrera en resurs
#   rollback_last                           — Ångra senast registrerade resurs
#   rollback_offer <id> <name>             — Fråga användaren om rollback
# ============================================================

ROLLBACK_FILE="/tmp/.optiplex_rollback_stack"

# Registrera en skapad resurs (CT eller VM)
rollback_register() {
    local type="$1"   # "ct" eller "vm"
    local id="$2"
    local name="$3"
    echo "${type}:${id}:${name}" >> "$ROLLBACK_FILE"
}

# Ångra senast registrerade resurs
rollback_last() {
    if [ ! -f "$ROLLBACK_FILE" ]; then
        return 1
    fi
    
    local last_entry=$(tail -1 "$ROLLBACK_FILE")
    if [ -z "$last_entry" ]; then
        return 1
    fi
    
    local type=$(echo "$last_entry" | cut -d: -f1)
    local id=$(echo "$last_entry" | cut -d: -f2)
    local name=$(echo "$last_entry" | cut -d: -f3)
    
    msg_info "Tar bort ${type} ${id} (${name})..."
    
    if [ "$type" == "vm" ]; then
        qm stop "$id" 2>/dev/null || true
        sleep 2
        qm destroy "$id" --purge 2>/dev/null
    else
        pct stop "$id" 2>/dev/null || true
        sleep 2
        pct destroy "$id" --purge 2>/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        msg_ok "${type} ${id} (${name}) borttagen"
        # Ta bort sista raden från filen
        sed -i '$ d' "$ROLLBACK_FILE"
        return 0
    else
        msg_err "Kunde inte ta bort ${type} ${id}"
        return 1
    fi
}

# Erbjud rollback vid fel
rollback_offer() {
    local id="$1"
    local name="$2"
    
    echo "" > /dev/tty
    msg_warn "Installationen av ${name} (ID ${id}) misslyckades."
    
    if ask_yes_no "Vill du ta bort den halvfärdiga ${name}-installationen?" "Y"; then
        rollback_last
    else
        msg_info "Behåller ${name} (ID ${id}). Du kan ta bort den manuellt med:"
        msg_info "  pct destroy ${id} --purge   (för containers)"
        msg_info "  qm destroy ${id} --purge    (för VMs)"
    fi
}

# Rensa rollback-stack (anropas vid lyckad installation)
rollback_clear() {
    rm -f "$ROLLBACK_FILE"
}
