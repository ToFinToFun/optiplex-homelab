# Setup Wizard вЂ” MenytrГ¤d & FlГ¶desГ¶versikt

Komplett karta Г¶ver alla val och vГ¤gar genom `setup.sh`.

---

## Startpunkter

```
bash setup.sh [flaggor]
    в”‚
    в”њв”Ђв”Ђ (inga flaggor)     в†’ Interaktiv wizard
    в”њв”Ђв”Ђ --headless         в†’ Automatisk installation (inga frГҐgor)
    в”њв”Ђв”Ђ --dry-run          в†’ Simulering (visar vad som SKULLE hГ¤nda)
    в””в”Ђв”Ђ --headless --dry-run в†’ Simulerad headless (kombineras)
```

---

## Г–vergripande flГ¶de

```
в”Њв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”ђ
в”‚  START                                                               в”‚
в”‚    в”‚                                                                 в”‚
в”‚    в”њв”Ђ Auto-uppdatering (git pull)                                    в”‚
в”‚    в”њв”Ђ Ladda bibliotek (lib/ui, config, proxmox, network, rollback)   в”‚
в”‚    в”њв”Ђ Preflight: Verifiera att alla funktioner finns                 в”‚
в”‚    в”‚                                                                 в”‚
в”‚    в”њв”Ђв”Ђв”Ђ [--dry-run?] в†’ Visa "DRY-RUN MODE"-banner                   в”‚
в”‚    в”‚                                                                 в”‚
в”‚    в”њв”Ђв”Ђв”Ђ [--headless?] в”Ђв”Ђв”Ђ JA в”Ђв”Ђв†’ Headless-flГ¶de (se nedan)          в”‚
в”‚    в”‚         в”‚                                                       в”‚
в”‚    в”‚         NEJ                                                     в”‚
в”‚    в”‚         в†“                                                       в”‚
в”‚    в”њв”Ђ BIOS & HГҐrdvarustatus                                          в”‚
в”‚    в”њв”Ђ Konfiguration (setup.env finns? / fГ¶rsta gГҐngen?)              в”‚
в”‚    в”њв”Ђ Inventering (vad Г¤r redan installerat?)                        в”‚
в”‚    в”њв”Ђ HUVUDMENY (val 1-5/Q)                                          в”‚
в”‚    в”њв”Ђ SГ¤kerhetskontroll (befintliga CT/VM)                           в”‚
в”‚    в”њв”Ђ Execution Phase (moduler kГ¶rs)                                 в”‚
в”‚    в”њв”Ђ BrandvГ¤ggsverifiering                                          в”‚
в”‚    в”њв”Ђ IP-konsistenskontroll                                          в”‚
в”‚    в”њв”Ђ Sammanfattning + TODO.md                                       в”‚
в”‚    в””в”Ђ SLUT                                                           в”‚
в””в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”�
```

---

## Headless-flГ¶de (--headless)

```
bash setup.sh --headless
    в”‚
    в”њв”Ђ Pre-flight checks:
    в”‚   в”њв”Ђ [вњ“/вњ—] SHARED_PASSWORD finns i setup.env?
    в”‚   в”њв”Ђ [вњ“/вњ—] NETWORK_PREFIX + GATEWAY finns?
    в”‚   в”њв”Ђ [вњ“/вљ ] iGPU tillgГ¤nglig? (om ej: Frigate hoppas Г¶ver)
    в”‚   в”њв”Ђ [вњ“/вљ ] CF_TUNNEL_TOKEN finns? (om ej: tunnel aktiveras ej)
    в”‚   в””в”Ђ [вњ“/вљ ] IP-konflikter? в†’ Auto-fixar (hittar lediga IP:er)
    в”‚       в”‚
    в”‚       в”њв”Ђв”Ђ Alla OK в†’ FortsГ¤tt
    в”‚       в””в”Ђв”Ђ Kritiskt fel в†’ ABORT (exit 1)
    в”‚
    в”њв”Ђ Installerar allt som saknas (hoppar Г¶ver redan installerat):
    в”‚   в”њв”Ђ Modul 00: Proxmox Host
    в”‚   в”њв”Ђ Modul 01: Storage
    в”‚   в”њв”Ђ Modul 02: Home Assistant VM
    в”‚   в”њв”Ђ Modul 03: Cloudflared
    в”‚   в”њв”Ђ Modul 04: NPM (+ auto-byt admin-lГ¶senord)
    в”‚   в”њв”Ђ Modul 05: Frigate (om iGPU finns)
    в”‚   в””в”Ђ Modul 09: Remote Desktop (Guacamole + Desktop)
    в”‚
    в”њв”Ђ Hoppas Г¶ver (krГ¤ver manuell input):
    в”‚   в”њв”Ђ Modul 06: Kamerakonfiguration
    в”‚   в”њв”Ђ Modul 07: Cloudflare DNS-routing
    в”‚   в””в”Ђ Modul 08: NPM proxy-regler
    в”‚
    в”њв”Ђ BrandvГ¤ggsverifiering
    в”њв”Ђ IP-konsistenskontroll (ip-check.sh --auto-fix)
    в”њв”Ђ Sammanfattning + TODO.md
    в””в”Ђ Post-run: "DU MГ…STE GГ–RA FГ–LJANDE MANUELLT" (lista)
```

---

## Konfigurationsfasen (fГ¶rsta kГ¶rningen)

```
setup.env finns INTE в†’ FГ¶rsta kГ¶rningen
    в”‚
    в”њв”Ђ NГ¤tverksdetektering (auto-detect subnet + gateway)
    в”‚   в””в”Ђв”Ђ Misslyckas? в†’ Manuell inmatning
    в”‚
    в”њв”Ђ FrГҐga: Servernamn (hostname)
    в”њв”Ђ FrГҐga: Cloudflare Tunnel Token (valfritt, Enter = hoppa Г¶ver)
    в”‚
    в”њв”Ђ FrГҐga: Gemensamt lГ¶senord
    в”‚   в””в”Ђв”Ђ (AnvГ¤nds fГ¶r: CT root, NPM admin, MQTT, kamera RTSP)
    в”‚
    в”њв”Ђ FrГҐga: TjГ¤nsteanvГ¤ndarnamn (default: "frigate")
    в”‚
    в”њв”Ђ в•”в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•—
    в”‚   в•‘  DHCP vs Statisk IP                   в•‘
    в”‚   в• в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•Ј
    в”‚   в•‘  1) Statiska IP (rekommenderat)       в•‘
    в”‚   в•‘  2) DHCP (routern tilldelar)          в•‘
    в”‚   в•љв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ќ
    в”‚   в”‚
    в”‚   в”њв”Ђв”Ђ Statisk vald:
    в”    в”‚   в”њв”Ђ FrГҐga: VM/CT ID:n (100, 101, 102, 103, 104)
    в”‚   в”њв”Ђ FrГҐga: AdGuard upstream DNS (Cloudflare DoH / Router)
    в”‚   в”њв”Ђ FrГҐga: DomГ¤n fГ¶r split-DNS (t.ex. example.com)
    в”‚   в”њв”Ђ IP-konfliktcheck (ping + arping)
    в”‚   в”‚   в”‚   в”њв”Ђв”Ђ Inga konflikter в†’ OK
    в”‚   в”‚   в”‚   в””в”Ђв”Ђ Konflikter hittade:
    в”‚   в”‚   в”‚       в”њв”Ђв”Ђ "Auto-fixa?" в†’ Ja в†’ FГ¶reslГҐr lediga IP:er
    в”‚   в”‚   в”‚       в””в”Ђв”Ђ "Auto-fixa?" в†’ Nej в†’ Manuell fix senare
    в”‚   в”‚   в””в”Ђ Spara setup.env
    в”‚   в”‚
    в”‚   в””в”Ђв”Ђ DHCP vald:
    в”‚       в”њв”Ђ FrГҐga: VM/CT ID:n (bara Proxmox-ID, inte IP)
    в”‚       в”њв”Ђ FrГҐga: AdGuard upstream DNS + domГ¤n
    в”‚       в”њв”Ђ Varning: "LГҐs IP:erna i routern!"
    в”‚       в””в”Ђ Spara setup.env
    в”‚
    в””в”Ђ в†’ FortsГ¤tt till Inventering & Huvudmeny
```

```
setup.env FINNS в†’ Г…terkГ¶rning
    в”‚
    в”њв”Ђ Ladda config
    в”њв”Ђ Visa vad som saknas (tunnel-token, DNS, etc.)
    в”‚
    в”њв”Ђ Erbjud: "Har du tunnel-token nu?" (om den saknas)
    в”‚   в””в”Ђв”Ђ Ja в†’ FrГҐga token в†’ Spara
    в”‚
    в”њв”Ђ Erbjud: "BehГҐlla befintligt lГ¶senord?"
    в”‚   в””в”Ђв”Ђ Nej в†’ FrГҐga nytt в†’ Spara
    в”‚
    в””в”Ђ в†’ FortsГ¤tt till Inventering & Huvudmeny
```

---

## Huvudmeny (interaktiv)

```
в•”в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•—
в•‘  OptiPlex Homelab Setup                                в•‘
в• в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•Ј
в•‘  1) Installera det som saknas                          в•‘
в•‘  2) Laga / Uppgradera befintligt                       в•‘
в•‘  3) Konfigurera (kameror, DNS, regler)                 в•‘
в•‘  5) Reparera / Verifiera (IP + NPM + status)           в•‘
в•‘  4) Avancerat (vГ¤lj enskilda steg)                     в•‘
в•‘  Q) Avsluta                                             в•‘
в•љв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ќ
```

---

### Val 1: Installera det som saknas

```
Val 1
    в”‚
    в”њв”Ђв”Ђ FГ¶rsta kГ¶rningen (inget installerat):
    в”‚   в””в”Ђв”Ђ KГ¶r ALLA steg (1-9)
    в”‚
    в””в”Ђв”Ђ Г…terkГ¶rning (nГҐgot redan installerat):
        в””в”Ђв”Ђ KГ¶r BARA steg som saknas
            (redan installerade hoppas Г¶ver automatiskt)
```

**Steg som kГ¶rs (i ordning):**

| Steg | Modul | Vad den gГ¶r |
|------|-------|-------------|
| 4.1 | 01-storage.sh | SГ¶ker extra SSD, formaterar fГ¶r Frigate |
| 4.2 | 00-proxmox-host.sh | Repos, TRIM, udev, BIOS |
| 4.3 | 02-ha-vm.sh | Laddar HAOS, skapar UEFI-VM |
| 4.4 | 03-cloudflared.sh | Cloudflare Tunnel CT |
| 4.4.5 | 03.5-adguard.sh | AdGuard Home CT, split-DNS rewrites |
| 4.5 | 04-npm.sh | NPM + Docker CT, byter admin-lГ¶senord |
| 4.6 | 05-frigate.sh | Frigate + Docker + iGPU passthrough |
| 4.7 | 06-axis-cameras.sh | NГ¤tverksskanning, kameranamn, config.yml |
| 4.8 | 07-cloudflare-dns.sh | CNAME-records, tunnel-routes |
| 4.9 | 08-npm-config.sh | Proxy hosts via NPM API |
| 4.10 | 09-remote-desktop.sh | Guacamole + Linux Desktop |

---

### Val 2: Laga / Uppgradera

```
Val 2
    в”‚
    в”њв”Ђв”Ђ Visar status fГ¶r varje tjГ¤nst (вњ“/вњ—)
    в”‚
    в”њв”Ђв”Ђ Frigate installerad?
    в”‚   в”њв”Ђв”Ђ JA в†’ DO_FRIGATE="upgrade"
    в”‚   в”‚   в”‚
    в”‚   в”‚   в”њв”Ђв”Ђ Kolla senaste version (GitHub API)
    в”‚   в”‚   в”њв”Ђв”Ђ JГ¤mfГ¶r med nuvarande
    в”‚   в”‚   в”‚   в”њв”Ђв”Ђ Samma version в†’ "Redan uppdaterad"
    в”‚   в”‚   в”‚   в”‚   в””в”Ђв”Ђ KГ¶r inte? в†’ Starta Docker-container
    в”‚   в”‚   в”‚   в””в”Ђв”Ђ Ny version в†’ Uppdatera docker-compose.yml + pull + restart
    в”‚   в”‚   в”‚
    в”‚   в”‚   в”њв”Ђв”Ђ Disk < 32GB?
    в”‚   в”‚   в”‚   в””в”Ђв”Ђ "UtГ¶ka disk?" в†’ Ja в†’ pct resize
    в”‚   в”‚   в”‚
    в”‚   в”‚   в””в”Ђв”Ђ VГ¤nta pГҐ att Frigate svarar (timeout 60s)
    в”‚   в”‚
    в”‚   в””в”Ђв”Ђ NEJ в†’ "VГ¤lj '1' fГ¶r att installera"
    в”‚
    в””в”Ђв”Ђ Г–vriga tjГ¤nster: Inget upgrade-stГ¶d Г¤nnu (bara Frigate)
```

---

### Val 3: Konfigurera

```
Val 3
    в”‚
    в”њв”Ђв”Ђ Visar status (вњ“/вњ—) fГ¶r:
    в”‚   в”њв”Ђв”Ђ Kameror & Frigate-config
    в”‚   в”њв”Ђв”Ђ Cloudflare DNS-routing
    в”‚   в””в”Ђв”Ђ NPM Proxy-regler
    в”‚
    в””в”Ђв”Ђ KГ¶r:
        в”њв”Ђв”Ђ Modul 06: Axis-kameror (skanna, namnge, generera config)
        в”њв”Ђв”Ђ Modul 07: Cloudflare DNS (CNAME, tunnel-routes, Zero Trust)
        в””в”Ђв”Ђ Modul 08: NPM Auto-Config (proxy hosts via API)
```

---

### Val 4: Avancerat

```
Val 4
    в”‚
    в”њв”Ђв”Ђ Visar detaljerad meny med status per steg:
    в”‚
    в”‚   в•”в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•—
    в”‚   в•‘  1. [вњ“/вњ—] Proxmox Host                    в•‘
    в”‚   в•‘  2. [вњ“/вњ—] Home Assistant                   в•‘
    в”‚   в•‘  3. [вњ“/вњ—] Cloudflared                      в•‘
    в”‚   в•‘  4. [вњ“/вњ—] AdGuard Home                     в•‘
    в”‚   в•‘  5. [вњ“/вњ—] NPM                             в•‘
    в”‚   в•‘  6. [вњ“/вњ—] Frigate                          в•‘
    в”‚   в•‘  7. [вњ“/вњ—] Kameror & Config                 в•‘
    в”‚   в•‘  8. [вњ“/вњ—] Cloudflare DNS                   в•‘
    в”‚   в•‘  9. [вњ“/вњ—] NPM Auto-Config                 в•‘
    в”‚   в•‘ 10. [вњ“/вњ—] Remote Desktop                   в•‘
    в”‚   в•‘                                            в•‘
    в”‚   в•‘  A = KГ¶r ALLT                              в•‘
    в”‚   в•‘  1-10 = VГ¤lj specifika (t.ex. 6,10)       в•‘
    в”‚   в•‘  Q = Avsluta                               в•‘
    в”‚   в•љв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ќ
    в”‚
    в”њв”Ђв”Ђ Val A: KГ¶r alla steg (befintliga skrivs EJ Г¶ver)
    в”њв”Ђв”Ђ Val Q: Avsluta
    в””в”Ђв”Ђ Val 1-10 (kommaseparerat): KГ¶r bara valda steg
```

---

### Val 5: Reparera / Verifiera

```
Val 5
    в”‚
    в”њв”Ђв”Ђ KГ¶r tools/ip-check.sh:
    в”‚   в”њв”Ђв”Ђ UpptГ¤cker faktiska IP:er (hostname -I / qm guest agent)
    в”‚   в”њв”Ђв”Ђ JГ¤mfГ¶r mot setup.env
    в”‚   в”‚   в””в”Ђв”Ђ Mismatch? в†’ "Uppdatera setup.env?" в†’ Ja в†’ sed -i
    в”‚   в”њв”Ђв”Ђ Loggar in i NPM API
    в”‚   в”њв”Ђв”Ђ JГ¤mfГ¶r NPM proxy-regler mot faktiska IP:er
    в”‚   в”‚   в””в”Ђв”Ђ Mismatch? в†’ "Uppdatera NPM?" в†’ Ja в†’ PUT API
    в”‚   в”њв”Ђв”Ђ Kontrollerar WebSockets (Frigate)
    в”‚   в”‚   в””в”Ђв”Ђ Saknas? в†’ Aktiverar automatiskt
    в”‚   в””в”Ђв”Ђ Kontrollerar Force SSL
    в”‚       в””в”Ђв”Ђ Aktiverat? в†’ Inaktiverar (fГ¶rhindrar redirect-loop)
    в”‚
    в”њв”Ђв”Ђ KГ¶r tools/status-dashboard.sh:
    в”‚   в”њв”Ђв”Ђ Visar tabell: TjГ¤nst | Intern | Status | Extern | Status | NPM | Status
    в”‚   в”њв”Ђв”Ђ Verifierar intern reachability (nc port-check)
    в”‚   в”њв”Ђв”Ђ Verifierar extern HTTPS (curl)
    в”‚   в”њв”Ђв”Ђ Visar rekommendationer vid problem
    в”‚   в””в”Ђв”Ђ StГ¶der --json output
    в”‚
    в””в”Ђв”Ђ EXIT (installerar inget)
```

---

## SГ¤kerhetskontroller (efter menyval, fГ¶re exekvering)

```
Innan moduler kГ¶rs:
    в”‚
    в”њв”Ђв”Ђ HA VM finns redan + DO_HA=y?
    в”‚   в””в”Ђв”Ђ "RADERA och ГҐterskapa? (ALL DATA FГ–RSVINNER)" [Y/N, default: N]
    в”‚       в”њв”Ђв”Ђ Ja в†’ Radera + installera om
    в”‚       в””в”Ђв”Ђ Nej в†’ Hoppa Г¶ver
    в”‚
    в”њв”Ђв”Ђ Cloudflared CT finns + DO_CF=y?
    в”‚   в””в”Ђв”Ђ "RADERA och ГҐterskapa?" [Y/N, default: N]
    в”‚
    в”њв”Ђв”Ђ NPM CT finns + DO_NPM=y?
    в”‚   в””в”Ђв”Ђ "RADERA och ГҐterskapa?" [Y/N, default: N]
    в”‚
    в””в”Ђв”Ђ Frigate CT finns + DO_FRIGATE=y?
        в””в”Ђв”Ђ Tre val:
            в”њв”Ђв”Ђ 1) Uppgradera/fixa (behГҐll config + inspelningar)
            в”њв”Ђв”Ђ 2) Radera och ГҐterskapa frГҐn scratch
            в””в”Ђв”Ђ 3) Hoppa Г¶ver
```

---

## Tunnel-aktivering (vid ГҐterkГ¶rning)

```
Cloudflared CT finns + tunnel EJ aktiv + token finns i config:
    в”‚
    в””в”Ђв”Ђ "Vill du aktivera Cloudflare Tunnel med din token nu?" [Y/N]
        в”њв”Ђв”Ђ Ja в†’ cloudflared service install <TOKEN>
        в”‚   в”њв”Ђв”Ђ Lyckades в†’ "Tunnel aktiverad!"
        в”‚   в””в”Ђв”Ђ Misslyckades в†’ Visa manuellt kommando
        в””в”Ђв”Ђ Nej в†’ Hoppa Г¶ver
```

---

## Felhantering (under exekvering)

```
Modul misslyckas:
    в”‚
    в”њв”Ђв”Ђ Headless-mode:
    в”‚   в””в”Ђв”Ђ Logga felet, fortsГ¤tt med nГ¤sta steg
    в”‚
    в””в”Ђв”Ђ Interaktiv:
        в”њв”Ђв”Ђ Visa felmeddelande
        в”њв”Ђв”Ђ Erbjud rollback: "Ta bort det som skapades?" [Y/N]
        в””в”Ђв”Ђ "FortsГ¤tta med nГ¤sta steg Г¤ndГҐ?" [Y/N]
            в”њв”Ђв”Ђ Ja в†’ FortsГ¤tt
            в””в”Ђв”Ђ Nej в†’ EXIT
```

```
Ctrl+C / Avbrott:
    в”‚
    в”њв”Ђв”Ђ Visa vad som skapades (rollback-stack)
    в”њв”Ђв”Ђ "Vill du ta bort dem?" [Y/N, timeout 10s]
    в”‚   в”њв”Ђв”Ђ Ja в†’ pct/qm destroy
    в”‚   в””в”Ђв”Ђ Nej в†’ Visa manuella kommandon
    в””в”Ђв”Ђ Visa loggfil-sГ¶kvГ¤g
```

---

## Post-exekvering

```
Efter alla moduler:
    в”‚
    в”њв”Ђв”Ђ BrandvГ¤ggsverifiering:
    в”‚   в”њв”Ђв”Ђ Proxmox-brandvГ¤gg aktiverad? в†’ Varning + portlista
    в”‚   в”њв”Ђв”Ђ nftables drop/reject-regler? в†’ Varning
    в”‚   в””в”Ђв”Ђ Per-CT brandvГ¤gg aktiverad? в†’ Varning
    в”‚
    в”њв”Ђв”Ђ IP-konsistenskontroll (om NPM finns):
    в”‚   в””в”Ђв”Ђ KГ¶r tools/ip-check.sh (--auto-fix i headless)
    в”‚
    в”њв”Ђв”Ђ Sammanfattning:
    в”‚   в”њв”Ђв”Ђ Tabell: TjГ¤nst | Lokal URL | Status
    в”‚   в”њв”Ђв”Ђ DHCP-varning (om USE_DHCP=true)
    в”‚   в”њв”Ђв”Ђ Wake-on-LAN info (MAC + kommandon)
    в”‚   в””в”Ђв”Ђ "NГ¤sta steg" (MQTT, NPM login, HA setup, Frigate zoner)
    в”‚
    в”њв”Ђв”Ђ Genererar TODO.md:
    в”‚   в”њв”Ђв”Ђ HA IP-reservation i router
    в”‚   в”њв”Ђв”Ђ MQTT/Mosquitto setup
    в”‚   в”њв”Ђв”Ђ Kamera-anvГ¤ndare
    в”‚   в”њв”Ђв”Ђ Cloudflare Tunnel token (om saknas)
    в”‚   в””в”Ђв”Ђ Frigate zoner/masker
    в”‚
    в””в”Ђв”Ђ Headless post-run:
        в””в”Ђв”Ђ "DU MГ…STE GГ–RA FГ–LJANDE MANUELLT:"
            в”њв”Ђв”Ђ Reboot (om BIOS Г¤ndrades)
            в”њв”Ђв”Ђ Frigate hoppades Г¶ver (om iGPU saknas)
            в”њв”Ђв”Ђ Konfigurera kameror/DNS/NPM-regler
            в””в”Ђв”Ђ Tunnel-token (om saknas)
```

---

## Verktyg (kan kГ¶ras separat)

| Kommando | Beskrivning |
|----------|-------------|
| `sudo bash tools/ip-check.sh` | IP-konsistens + NPM-reparation |
| `sudo bash tools/ip-check.sh --auto-fix` | Samma, utan frГҐgor |
| `sudo bash tools/status-dashboard.sh` | Service Dashboard (tabell) |
| `sudo bash tools/status-dashboard.sh --json` | MaskinlГ¤sbar output |
| `sudo bash tools/doctor.sh` | Full hГ¤lsokontroll |
| `sudo bash tools/status.sh` | Snabb statusГ¶versikt |
| `sudo bash tools/upgrade-proxmox.sh` | Proxmox-uppdatering |
| `sudo bash tools/usb-backup.sh` | USB-backup |
| `sudo bash tools/update.sh` | Git-uppdatering av scripten |

---

## Sammanfattning: Alla vГ¤gar

| Scenario | VГ¤g |
|----------|-----|
| Helt ny maskin, fГ¶rsta gГҐngen | `bash setup.sh` в†’ Config в†’ Meny 1 в†’ Alla moduler |
| Ny maskin, obemannad | `bash setup.sh --headless` в†’ Auto-install allt |
| NГҐgot saknas (t.ex. Frigate) | `bash setup.sh` в†’ Meny 1 в†’ Bara det som saknas |
| Uppgradera Frigate | `bash setup.sh` в†’ Meny 2 в†’ Upgrade-flГ¶de |
| Konfigurera kameror/DNS/NPM | `bash setup.sh` в†’ Meny 3 |
| Bara Frigate + NPM-regler | `bash setup.sh` → Meny 4 → Val "6,9" |
| NГҐgot funkar inte (IP-byte etc.) | `bash setup.sh` в†’ Meny 5 в†’ ip-check + dashboard |
| Snabb diagnostik utan wizard | `sudo bash tools/ip-check.sh` |
| Se alla tjГ¤nsters status | `sudo bash tools/status-dashboard.sh` |
| Testa utan att Г¤ndra nГҐgot | `bash setup.sh --dry-run` |
