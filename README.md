# OptiPlex Homelab

En komplett, automatiserad setup-wizard för att bygga ett kraftfullt homelab på en Dell OptiPlex (eller liknande Intel-maskin) med **Proxmox VE**. Från noll till fullt fungerande smart home-hub, AI-videoövervakning, nätverksblockering, filserver och mer — med ett enda kommando.

Guiden fungerar oavsett om du har tillgång till en AI-assistent (som Manus) eller följer stegen manuellt. Varje guide innehåller förklaringar av *varför* vi gör varje val, verifieringssteg, och felsökningsavsnitt.

## Arkitektur

Hela systemet bygger på principen att **ingen port öppnas i din router**. All extern åtkomst går via en krypterad Cloudflare Tunnel.

![Arkitekturöversikt](docs/architecture.png)

| Komponent | Roll | Varför just denna? |
|-----------|------|-------------------|
| **Proxmox VE** | Hypervisor (kör allt) | Gratis, industristandard, LXC + VM-stöd |
| **VM 100 — Home Assistant** | Smart home-hub | HAOS med Add-ons (Mosquitto MQTT) |
| **CT 101 — Cloudflared** | Tunnel-connector | Utgående anslutning, ingen port forwarding |
| **CT 102 — NPM** | Reverse proxy | Klickbart GUI, wildcard-routing, WebSocket-stöd |
| **CT 103 — Frigate** | AI-videoövervakning | OpenVINO på iGPU, YOLOv9c, 16+ kameror |
| **CT 104 — AdGuard Home** | DNS + nätverksblockering | Split-DNS, annonsblockering, DoH upstream |
| **CT 105 — Samba** | Filserver | Nätverksdelad mapp för alla enheter |
| **CT 106 — Immich** | Foto/video-backup | Self-hosted Google Photos-ersättare |
| **CT 107 — NUT** | UPS-övervakning | Graceful shutdown vid strömavbrott |
| **CT 108 — Guacamole** | Webb-baserad remote desktop | Åtkomst via webbläsare |
| **Dedikerad SSD** | Frigate-inspelningar | Skyddar OS-disken från slitage |

## Snabbstart (ett kommando)

```bash
# SSH:a in på din Proxmox-nod och kör:
bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh)
```

Bootstrappern installerar eventuella saknade beroenden, laddar ner repot och startar wizarden automatiskt.

## Huvudmeny

```
╔════════════════════════════════════════════════════════╗
║  OptiPlex Homelab Setup                                ║
╠════════════════════════════════════════════════════════╣
║  1) Installera det som saknas                          ║
║  2) Laga / Uppgradera befintligt                       ║
║  3) Konfigurera (kameror, DNS, regler)                 ║
║  4) Tillägg (Samba, Immich, NUT...)                    ║
║  5) Reparera / Verifiera (IP + NPM + status)           ║
║  6) Avancerat (välj enskilda steg)                     ║
║  Q) Avsluta                                             ║
╚════════════════════════════════════════════════════════╝
```

## Funktioner

### Installation & Setup
- **Interaktiv wizard** — Steg-för-steg med progressbar och tydliga val
- **Headless-mode** — Helt obemannad installation (`bash setup.sh --headless`)
- **Dry-run** — Testa utan att ändra något (`bash setup.sh --dry-run`)
- **Resume-stöd** — Hoppar över steg som redan är klara vid nästa körning
- **Auto-uppdatering** — Hämtar senaste scriptet från GitHub vid varje start
- **Rollback** — Erbjuder att ångra halvfärdiga installationer vid fel

### Nätverkshantering
- **DHCP eller statisk IP** — Välj vid installation, med tydlig vägledning
- **IP-konfliktdetektering** — Pingas alla planerade IP:er innan tilldelning
- **Auto-fix** — Hittar nästa lediga IP om en krock upptäcks
- **IP-konsistenskontroll** — Verifierar att NPM, AdGuard och config matchar verkligheten
- **Split-DNS** — Intern trafik pekar direkt på tjänster (ingen omväg via tunnel)

### Diagnostik & Underhåll
- **Doctor** — Komplett hälsokontroll (iGPU, containers, Docker, tunnel, disk, versioner)
- **Status Dashboard** — Visar alla tjänster med intern/extern adress och grönt/rött
- **IP-check** — Hittar och reparerar mismatchar mellan faktiska IP:er och NPM-regler
- **Versionscheck** — Jämför installerade versioner mot senaste GitHub-release

### Säkerhet
- **Cloudflare Tunnel** — All extern trafik krypterad, ingen port forwarding
- **Zero Trust Access** — Valfri extra autentisering via Cloudflare
- **AdGuard Home** — DNS-baserad annons/tracker-blockering för hela nätverket
- **Inga lösenord i config** — Environment-variabler och `.env`-filer

## Moduler

### Grundinstallation (Meny 1)

| # | Modul | Beskrivning |
|---|-------|-------------|
| 00 | Proxmox Host | BIOS-config, repos, TRIM, SSD-optimering |
| 01 | Storage | Dedikerad SSD för Frigate-inspelningar |
| 02 | Home Assistant | HAOS VM med MQTT |
| 03 | Cloudflared | Tunnel-connector (utgående, ingen port forwarding) |
| 03.5 | AdGuard Home | DNS-server med split-DNS + annonsblockering |
| 04 | NPM | Nginx Proxy Manager (reverse proxy med GUI) |
| 05 | Frigate | AI-videoövervakning med Docker + OpenVINO |
| 06 | Axis-kameror | Dual stream-konfiguration + Frigate config.yml |
| 07 | Cloudflare DNS | CNAME-poster för extern åtkomst |
| 08 | NPM Auto-Config | Proxy-regler + SSL + WebSockets |
| 09 | Remote Desktop | Guacamole + Linux Desktop (xrdp) |

### Tillägg (Meny 4)

| # | Modul | Beskrivning | Krav |
|---|-------|-------------|------|
| 10 | Samba | Nätverksdelad mapp (filserver) | Inga speciella |
| 11 | Immich | Self-hosted foto/video-backup | 4GB+ RAM, 50GB+ disk |
| 12 | NUT | UPS-övervakning + graceful shutdown | USB-ansluten UPS |

## Verktyg

Alla verktyg körs från `scripts/`-katalogen:

| Kommando | Beskrivning |
|----------|-------------|
| `sudo bash tools/doctor.sh` | Komplett diagnostik + versionscheck |
| `sudo bash tools/status-dashboard.sh` | Service Dashboard (alla tjänster, grönt/rött) |
| `sudo bash tools/ip-check.sh` | IP-konsistens + NPM auto-repair |
| `bash tools/status.sh` | Snabb statusöversikt |
| `bash tools/usb-backup.sh` | Säkerhetskopia till USB |
| `bash tools/update.sh` | Uppdaterar Proxmox + Docker-images |
| `bash tools/upgrade-proxmox.sh` | Uppgradera Proxmox 8 → 9 |
| `bash tools/uninstall.sh` | Tar bort alla skapade containers/VMs |
| `bash setup.sh --dry-run` | Visa vad som SKULLE hända |
| `bash setup.sh --headless` | Obemannad installation |

## Guider (manuell installation)

Följ guiderna i `docs/` i nummerordning om du föredrar att göra allt manuellt:

| # | Guide | Beskrivning |
|---|-------|-------------|
| 00 | [Manus-projektbeskrivning](docs/00-projektbeskrivning-manus.md) | Mall att klistra in i AI-assistenten |
| 00.5 | [Förberedelser](docs/00.5-forberedelser.md) | Allt du kan göra INNAN hårdvaran kommer |
| 01 | [BIOS-konfiguration](docs/01-bios-setup.md) | Virtualisering, iGPU, strömhantering |
| 02 | [Proxmox-installation](docs/02-proxmox-install.md) | OS-installation + post-install |
| 03 | [Lagringsdisk](docs/03-lagringsdisk.md) | Dedikerad disk för videoinspelningar |
| 03.5 | [Domän & Cloudflare](docs/03.5-doman-cloudflare.md) | Flytta/registrera domän hos Cloudflare |
| 04 | [Cloudflare Tunnel](docs/04-cloudflare-tunnel.md) | Säker extern åtkomst utan port forwarding |
| 05 | [Nginx Proxy Manager](docs/05-npm.md) | Reverse proxy med GUI |
| 06 | [Frigate NVR](docs/06-frigate.md) | AI-videoövervakning med iGPU |
| 07 | [Axis-kameror](docs/07-axis-kameror.md) | Dual stream-konfiguration |
| 08 | [Home Assistant](docs/08-home-assistant.md) | VM + migrering + MQTT |
| 09 | [Extern livevy](docs/09-extern-livevy.md) | MSE via tunnel (+ TURN som tillval) |
| 10 | [Cloudflare API Setup](docs/10-cloudflare-api-setup.md) | Konto, Loopia-flytt, Tunnel & API-nyckel |

### Referensmaterial

| Fil | Beskrivning |
|-----|-------------|
| [Menyträd](docs/setup-menytraed.md) | Komplett flödesschema för setup-wizarden |
| [Kapacitetsplanering](docs/kapacitetsplanering.md) | RAM/CPU per antal kameror |
| [Backup-strategi](docs/backup-strategi.md) | Automatisk säkerhetskopiering |
| [Ordlista & FAQ](docs/ordlista-faq.md) | Termer förklarade i klartext |
| [Default Setup](docs/default-setup.md) | Standardkonfiguration som wizarden skapar |
| [SETUP-CHECKLIST](SETUP-CHECKLIST.md) | Avbockningsbar lista |

## Konfigurationsfiler

| Fil | Beskrivning |
|-----|-------------|
| [setup.env.example](scripts/setup.env.example) | Mall för all konfiguration |
| [frigate-config-template.yml](configs/frigate-config-template.yml) | Komplett Frigate-template |
| [docker-compose-frigate.yml](configs/docker-compose-frigate.yml) | Docker Compose för Frigate |
| [docker-compose-npm.yml](configs/docker-compose-npm.yml) | Docker Compose för NPM |
| [axis-create-stream-profiles.sh](scripts/axis-create-stream-profiles.sh) | Axis-kamerakonfiguration |

## Filstruktur

```
optiplex-homelab/
├── scripts/
│   ├── setup.sh              ← Huvudwizard
│   ├── bootstrap.sh          ← Ett-kommando-installer
│   ├── setup.env.example     ← Konfigurationsmall
│   ├── lib/
│   │   ├── ui.sh             ← Färger, progress, frågor
│   │   ├── config.sh         ← Spara/ladda setup.env
│   │   ├── proxmox.sh        ← CT/VM-hantering
│   │   ├── network.sh        ← IP-konflikt, DHCP, discovery
│   │   └── rollback.sh       ← Ångra vid fel
│   ├── modules/
│   │   ├── 00-proxmox-host.sh
│   │   ├── 01-storage.sh
│   │   ├── 02-ha-vm.sh
│   │   ├── 03-cloudflared.sh
│   │   ├── 03.5-adguard.sh
│   │   ├── 04-npm.sh
│   │   ├── 05-frigate.sh
│   │   ├── 06-axis-cameras.sh
│   │   ├── 07-cloudflare-dns.sh
│   │   ├── 08-npm-config.sh
│   │   ├── 09-remote-desktop.sh
│   │   ├── 10-samba.sh
│   │   ├── 11-immich.sh
│   │   └── 12-nut.sh
│   └── tools/
│       ├── doctor.sh
│       ├── status-dashboard.sh
│       ├── ip-check.sh
│       ├── status.sh
│       ├── usb-backup.sh
│       ├── update.sh
│       ├── upgrade-proxmox.sh
│       └── uninstall.sh
├── configs/                  ← Template-filer
├── docs/                     ← Manuella guider
└── README.md
```

## Frigate Config Generator

Modul 06 i wizarden genererar en **komplett Frigate config.yml** baserat på:

1. **Nätverksskanning** — Hittar Axis-kameror automatiskt (eller manuell inmatning)
2. **Interaktiv namngivning** — Ge varje kamera ett vettigt namn
3. **Multi-channel stöd** — Axis-kameror med flera linser (t.ex. P3265-LVE)
4. **Beprövad bas-template** — 2x OpenVINO GPU, YOLOv9c, VAAPI, semantic search
5. **Google Gemini AI** — Valfritt steg för AI-beskrivningar
6. **Environment-variabler** — Inga lösenord i YAML (allt i `.env`)

## Hårdvara

| Del | Specifikation |
|-----|---------------|
| Dator | Dell OptiPlex XE4 SFF |
| CPU | Intel Core i5-12500T (6C/12T) |
| RAM | 32 GB DDR5 (2x16 dual channel) |
| OS-disk | 256 GB NVMe SSD |
| Frigate-disk | 500 GB+ SATA/NVMe SSD (dedikerad) |
| iGPU | Intel UHD 770 (OpenVINO + VAAPI) |
| Kameror | Axis (RTSP, dual stream) |

## Principer

- **Research first** — Verifiera paket, versioner och best practices innan implementation
- **Kvalitet före hastighet** — Gör det rätt första gången, inga workarounds
- **Minimera SSD-slitage** — TRIM, tmpfs, dedikerad inspelningsdisk
- **Säkerhet** — Cloudflare Tunnel + Zero Trust, ingen port forwarding
- **LXC framför VM** — Lägre overhead där möjligt
- **Debian 13 (Trixie)** — Samma bas som Proxmox VE 9

## Licens

MIT — Använd fritt, dela med vänner!
