# Setup Wizard — Menyträd & Flödesöversikt

Komplett karta över alla val och vägar genom `setup.sh`.

---

## Startpunkter

```
bash setup.sh [flaggor]
    │
    ├── (inga flaggor)     → Interaktiv wizard
    ├── --headless         → Automatisk installation (inga frågor)
    ├── --dry-run          → Simulering (visar vad som SKULLE hända)
    └── --headless --dry-run → Simulerad headless (kombineras)
```

---

## Övergripande flöde

```
┌─────────────────────────────────────────────────────────────────────┐
│  START                                                               │
│    │                                                                 │
│    ├─ Auto-uppdatering (git pull)                                    │
│    ├─ Ladda bibliotek (lib/ui, config, proxmox, network, rollback)   │
│    ├─ Preflight: Verifiera att alla funktioner finns                 │
│    │                                                                 │
│    ├─── [--dry-run?] → Visa "DRY-RUN MODE"-banner                   │
│    │                                                                 │
│    ├─── [--headless?] ─── JA ──→ Headless-flöde (se nedan)          │
│    │         │                                                       │
│    │         NEJ                                                     │
│    │         ↓                                                       │
│    ├─ BIOS & Hårdvarustatus                                          │
│    ├─ Konfiguration (setup.env finns? / första gången?)              │
│    ├─ Inventering (vad är redan installerat?)                        │
│    ├─ HUVUDMENY (val 1-5/Q)                                          │
│    ├─ Säkerhetskontroll (befintliga CT/VM)                           │
│    ├─ Execution Phase (moduler körs)                                 │
│    ├─ Brandväggsverifiering                                          │
│    ├─ IP-konsistenskontroll                                          │
│    ├─ Sammanfattning + TODO.md                                       │
│    └─ SLUT                                                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Headless-flöde (--headless)

```
bash setup.sh --headless
    │
    ├─ Pre-flight checks:
    │   ├─ [✓/✗] SHARED_PASSWORD finns i setup.env?
    │   ├─ [✓/✗] NETWORK_PREFIX + GATEWAY finns?
    │   ├─ [✓/⚠] iGPU tillgänglig? (om ej: Frigate hoppas över)
    │   ├─ [✓/⚠] CF_TUNNEL_TOKEN finns? (om ej: tunnel aktiveras ej)
    │   └─ [✓/⚠] IP-konflikter? → Auto-fixar (hittar lediga IP:er)
    │       │
    │       ├── Alla OK → Fortsätt
    │       └── Kritiskt fel → ABORT (exit 1)
    │
    ├─ Installerar allt som saknas (hoppar över redan installerat):
    │   ├─ Modul 00: Proxmox Host
    │   ├─ Modul 01: Storage
    │   ├─ Modul 02: Home Assistant VM
    │   ├─ Modul 03: Cloudflared
    │   ├─ Modul 04: NPM (+ auto-byt admin-lösenord)
    │   ├─ Modul 05: Frigate (om iGPU finns)
    │   └─ Modul 09: Remote Desktop (Guacamole + Desktop)
    │
    ├─ Hoppas över (kräver manuell input):
    │   ├─ Modul 06: Kamerakonfiguration
    │   ├─ Modul 07: Cloudflare DNS-routing
    │   └─ Modul 08: NPM proxy-regler
    │
    ├─ Brandväggsverifiering
    ├─ IP-konsistenskontroll (ip-check.sh --auto-fix)
    ├─ Sammanfattning + TODO.md
    └─ Post-run: "DU MÅSTE GÖRA FÖLJANDE MANUELLT" (lista)
```

---

## Konfigurationsfasen (första körningen)

```
setup.env finns INTE → Första körningen
    │
    ├─ Nätverksdetektering (auto-detect subnet + gateway)
    │   └── Misslyckas? → Manuell inmatning
    │
    ├─ Fråga: Servernamn (hostname)
    ├─ Fråga: Cloudflare Tunnel Token (valfritt, Enter = hoppa över)
    │
    ├─ Fråga: Gemensamt lösenord
    │   └── (Används för: CT root, NPM admin, MQTT, kamera RTSP)
    │
    ├─ Fråga: Tjänsteanvändarnamn (default: "frigate")
    │
    ├─ ╔═══════════════════════════════════════╗
    │   ║  DHCP vs Statisk IP                   ║
    │   ╠═══════════════════════════════════════╣
    │   ║  1) Statiska IP (rekommenderat)       ║
    │   ║  2) DHCP (routern tilldelar)          ║
    │   ╚═══════════════════════════════════════╝
    │   │
    │   ├── Statisk vald:
    │   │   ├─ Fråga: VM/CT ID:n (100, 101, 102, 103)
    │   │   ├─ IP-konfliktcheck (ping + arping)
    │   │   │   ├── Inga konflikter → OK
    │   │   │   └── Konflikter hittade:
    │   │   │       ├── "Auto-fixa?" → Ja → Föreslår lediga IP:er
    │   │   │       └── "Auto-fixa?" → Nej → Manuell fix senare
    │   │   └─ Spara setup.env
    │   │
    │   └── DHCP vald:
    │       ├─ Fråga: VM/CT ID:n (bara Proxmox-ID, inte IP)
    │       ├─ Varning: "Lås IP:erna i routern!"
    │       └─ Spara setup.env
    │
    └─ → Fortsätt till Inventering & Huvudmeny
```

```
setup.env FINNS → Återkörning
    │
    ├─ Ladda config
    ├─ Visa vad som saknas (tunnel-token, DNS, etc.)
    │
    ├─ Erbjud: "Har du tunnel-token nu?" (om den saknas)
    │   └── Ja → Fråga token → Spara
    │
    ├─ Erbjud: "Behålla befintligt lösenord?"
    │   └── Nej → Fråga nytt → Spara
    │
    └─ → Fortsätt till Inventering & Huvudmeny
```

---

## Huvudmeny (interaktiv)

```
╔════════════════════════════════════════════════════════╗
║  OptiPlex Homelab Setup                                ║
╠════════════════════════════════════════════════════════╣
║  1) Installera det som saknas                          ║
║  2) Laga / Uppgradera befintligt                       ║
║  3) Konfigurera (kameror, DNS, regler)                 ║
║  5) Reparera / Verifiera (IP + NPM + status)           ║
║  4) Avancerat (välj enskilda steg)                     ║
║  Q) Avsluta                                             ║
╚════════════════════════════════════════════════════════╝
```

---

### Val 1: Installera det som saknas

```
Val 1
    │
    ├── Första körningen (inget installerat):
    │   └── Kör ALLA steg (1-9)
    │
    └── Återkörning (något redan installerat):
        └── Kör BARA steg som saknas
            (redan installerade hoppas över automatiskt)
```

**Steg som körs (i ordning):**

| Steg | Modul | Vad den gör |
|------|-------|-------------|
| 4.1 | 01-storage.sh | Söker extra SSD, formaterar för Frigate |
| 4.2 | 00-proxmox-host.sh | Repos, TRIM, udev, BIOS |
| 4.3 | 02-ha-vm.sh | Laddar HAOS, skapar UEFI-VM |
| 4.4 | 03-cloudflared.sh | Cloudflare Tunnel CT |
| 4.5 | 04-npm.sh | NPM + Docker CT, byter admin-lösenord |
| 4.6 | 05-frigate.sh | Frigate + Docker + iGPU passthrough |
| 4.7 | 06-axis-cameras.sh | Nätverksskanning, kameranamn, config.yml |
| 4.8 | 07-cloudflare-dns.sh | CNAME-records, tunnel-routes |
| 4.9 | 08-npm-config.sh | Proxy hosts via NPM API |
| 4.10 | 09-remote-desktop.sh | Guacamole + Linux Desktop |

---

### Val 2: Laga / Uppgradera

```
Val 2
    │
    ├── Visar status för varje tjänst (✓/✗)
    │
    ├── Frigate installerad?
    │   ├── JA → DO_FRIGATE="upgrade"
    │   │   │
    │   │   ├── Kolla senaste version (GitHub API)
    │   │   ├── Jämför med nuvarande
    │   │   │   ├── Samma version → "Redan uppdaterad"
    │   │   │   │   └── Kör inte? → Starta Docker-container
    │   │   │   └── Ny version → Uppdatera docker-compose.yml + pull + restart
    │   │   │
    │   │   ├── Disk < 32GB?
    │   │   │   └── "Utöka disk?" → Ja → pct resize
    │   │   │
    │   │   └── Vänta på att Frigate svarar (timeout 60s)
    │   │
    │   └── NEJ → "Välj '1' för att installera"
    │
    └── Övriga tjänster: Inget upgrade-stöd ännu (bara Frigate)
```

---

### Val 3: Konfigurera

```
Val 3
    │
    ├── Visar status (✓/✗) för:
    │   ├── Kameror & Frigate-config
    │   ├── Cloudflare DNS-routing
    │   └── NPM Proxy-regler
    │
    └── Kör:
        ├── Modul 06: Axis-kameror (skanna, namnge, generera config)
        ├── Modul 07: Cloudflare DNS (CNAME, tunnel-routes, Zero Trust)
        └── Modul 08: NPM Auto-Config (proxy hosts via API)
```

---

### Val 4: Avancerat

```
Val 4
    │
    ├── Visar detaljerad meny med status per steg:
    │
    │   ╔════════════════════════════════════════════╗
    │   ║  1. [✓/✗] Proxmox Host                    ║
    │   ║  2. [✓/✗] Home Assistant                   ║
    │   ║  3. [✓/✗] Cloudflared                      ║
    │   ║  4. [✓/✗] NPM                             ║
    │   ║  5. [✓/✗] Frigate                          ║
    │   ║  6. [✓/✗] Kameror & Config                 ║
    │   ║  7. [✓/✗] Cloudflare DNS                   ║
    │   ║  8. [✓/✗] NPM Auto-Config                 ║
    │   ║  9. [✓/✗] Remote Desktop                   ║
    │   ║                                            ║
    │   ║  A = Kör ALLT                              ║
    │   ║  1-9 = Välj specifika (t.ex. 6,9)         ║
    │   ║  Q = Avsluta                               ║
    │   ╚════════════════════════════════════════════╝
    │
    ├── Val A: Kör alla steg (befintliga skrivs EJ över)
    ├── Val Q: Avsluta
    └── Val 1-9 (kommaseparerat): Kör bara valda steg
```

---

### Val 5: Reparera / Verifiera

```
Val 5
    │
    ├── Kör tools/ip-check.sh:
    │   ├── Upptäcker faktiska IP:er (hostname -I / qm guest agent)
    │   ├── Jämför mot setup.env
    │   │   └── Mismatch? → "Uppdatera setup.env?" → Ja → sed -i
    │   ├── Loggar in i NPM API
    │   ├── Jämför NPM proxy-regler mot faktiska IP:er
    │   │   └── Mismatch? → "Uppdatera NPM?" → Ja → PUT API
    │   ├── Kontrollerar WebSockets (Frigate)
    │   │   └── Saknas? → Aktiverar automatiskt
    │   └── Kontrollerar Force SSL
    │       └── Aktiverat? → Inaktiverar (förhindrar redirect-loop)
    │
    ├── Kör tools/status-dashboard.sh:
    │   ├── Visar tabell: Tjänst | Intern | Status | Extern | Status | NPM | Status
    │   ├── Verifierar intern reachability (nc port-check)
    │   ├── Verifierar extern HTTPS (curl)
    │   ├── Visar rekommendationer vid problem
    │   └── Stöder --json output
    │
    └── EXIT (installerar inget)
```

---

## Säkerhetskontroller (efter menyval, före exekvering)

```
Innan moduler körs:
    │
    ├── HA VM finns redan + DO_HA=y?
    │   └── "RADERA och återskapa? (ALL DATA FÖRSVINNER)" [Y/N, default: N]
    │       ├── Ja → Radera + installera om
    │       └── Nej → Hoppa över
    │
    ├── Cloudflared CT finns + DO_CF=y?
    │   └── "RADERA och återskapa?" [Y/N, default: N]
    │
    ├── NPM CT finns + DO_NPM=y?
    │   └── "RADERA och återskapa?" [Y/N, default: N]
    │
    └── Frigate CT finns + DO_FRIGATE=y?
        └── Tre val:
            ├── 1) Uppgradera/fixa (behåll config + inspelningar)
            ├── 2) Radera och återskapa från scratch
            └── 3) Hoppa över
```

---

## Tunnel-aktivering (vid återkörning)

```
Cloudflared CT finns + tunnel EJ aktiv + token finns i config:
    │
    └── "Vill du aktivera Cloudflare Tunnel med din token nu?" [Y/N]
        ├── Ja → cloudflared service install <TOKEN>
        │   ├── Lyckades → "Tunnel aktiverad!"
        │   └── Misslyckades → Visa manuellt kommando
        └── Nej → Hoppa över
```

---

## Felhantering (under exekvering)

```
Modul misslyckas:
    │
    ├── Headless-mode:
    │   └── Logga felet, fortsätt med nästa steg
    │
    └── Interaktiv:
        ├── Visa felmeddelande
        ├── Erbjud rollback: "Ta bort det som skapades?" [Y/N]
        └── "Fortsätta med nästa steg ändå?" [Y/N]
            ├── Ja → Fortsätt
            └── Nej → EXIT
```

```
Ctrl+C / Avbrott:
    │
    ├── Visa vad som skapades (rollback-stack)
    ├── "Vill du ta bort dem?" [Y/N, timeout 10s]
    │   ├── Ja → pct/qm destroy
    │   └── Nej → Visa manuella kommandon
    └── Visa loggfil-sökväg
```

---

## Post-exekvering

```
Efter alla moduler:
    │
    ├── Brandväggsverifiering:
    │   ├── Proxmox-brandvägg aktiverad? → Varning + portlista
    │   ├── nftables drop/reject-regler? → Varning
    │   └── Per-CT brandvägg aktiverad? → Varning
    │
    ├── IP-konsistenskontroll (om NPM finns):
    │   └── Kör tools/ip-check.sh (--auto-fix i headless)
    │
    ├── Sammanfattning:
    │   ├── Tabell: Tjänst | Lokal URL | Status
    │   ├── DHCP-varning (om USE_DHCP=true)
    │   ├── Wake-on-LAN info (MAC + kommandon)
    │   └── "Nästa steg" (MQTT, NPM login, HA setup, Frigate zoner)
    │
    ├── Genererar TODO.md:
    │   ├── HA IP-reservation i router
    │   ├── MQTT/Mosquitto setup
    │   ├── Kamera-användare
    │   ├── Cloudflare Tunnel token (om saknas)
    │   └── Frigate zoner/masker
    │
    └── Headless post-run:
        └── "DU MÅSTE GÖRA FÖLJANDE MANUELLT:"
            ├── Reboot (om BIOS ändrades)
            ├── Frigate hoppades över (om iGPU saknas)
            ├── Konfigurera kameror/DNS/NPM-regler
            └── Tunnel-token (om saknas)
```

---

## Verktyg (kan köras separat)

| Kommando | Beskrivning |
|----------|-------------|
| `sudo bash tools/ip-check.sh` | IP-konsistens + NPM-reparation |
| `sudo bash tools/ip-check.sh --auto-fix` | Samma, utan frågor |
| `sudo bash tools/status-dashboard.sh` | Service Dashboard (tabell) |
| `sudo bash tools/status-dashboard.sh --json` | Maskinläsbar output |
| `sudo bash tools/doctor.sh` | Full hälsokontroll |
| `sudo bash tools/status.sh` | Snabb statusöversikt |
| `sudo bash tools/upgrade-proxmox.sh` | Proxmox-uppdatering |
| `sudo bash tools/usb-backup.sh` | USB-backup |
| `sudo bash tools/update.sh` | Git-uppdatering av scripten |

---

## Sammanfattning: Alla vägar

| Scenario | Väg |
|----------|-----|
| Helt ny maskin, första gången | `bash setup.sh` → Config → Meny 1 → Alla moduler |
| Ny maskin, obemannad | `bash setup.sh --headless` → Auto-install allt |
| Något saknas (t.ex. Frigate) | `bash setup.sh` → Meny 1 → Bara det som saknas |
| Uppgradera Frigate | `bash setup.sh` → Meny 2 → Upgrade-flöde |
| Konfigurera kameror/DNS/NPM | `bash setup.sh` → Meny 3 |
| Bara Frigate + NPM-regler | `bash setup.sh` → Meny 4 → Val "5,8" |
| Något funkar inte (IP-byte etc.) | `bash setup.sh` → Meny 5 → ip-check + dashboard |
| Snabb diagnostik utan wizard | `sudo bash tools/ip-check.sh` |
| Se alla tjänsters status | `sudo bash tools/status-dashboard.sh` |
| Testa utan att ändra något | `bash setup.sh --dry-run` |
