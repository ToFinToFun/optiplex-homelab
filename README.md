# OptiPlex Homelab — Komplett Setup-guide

Detta repo innehåller en steg-för-steg-guide för att sätta upp en Dell OptiPlex XE4 (eller liknande Intel 12:e gen-maskin) som en kraftfull hemmaserver för **Home Assistant** och **AI-driven videoövervakning (Frigate NVR)**.

Guiden är skriven så att den fungerar för dig oavsett om du har tillgång till en AI-assistent (som Manus) eller följer stegen manuellt. Varje guide innehåller förklaringar av *varför* vi gör varje val, verifieringssteg så du vet att allt fungerar, och felsökningsavsnitt för vanliga problem.

## Arkitektur

Hela systemet bygger på principen att **ingen port öppnas i din router**. All extern åtkomst går via en krypterad Cloudflare Tunnel.

![Arkitekturöversikt](docs/architecture.png)

| Komponent | Roll | Varför just denna? |
|-----------|------|-------------------|
| **Proxmox VE** | Hypervisor (kör allt) | Gratis, industristandard, LXC + VM-stöd |
| **CT 101 — cloudflared** | Tunnel-connector | Utgående anslutning, ingen port forwarding |
| **CT 102 — NPM** | Reverse proxy | Klickbart GUI, wildcard-routing, WebSocket-stöd |
| **CT 103 — Frigate** | AI-videoövervakning | OpenVINO på iGPU, YOLOv9, 16+ kameror |
| **VM 100 — Home Assistant** | Smart home-hub | HAOS med Add-ons (Mosquitto MQTT) |
| **Dedikerad SSD** | Frigate-inspelningar | Skyddar OS-disken från slitage |

## Komma igång

Följ guiderna i `docs/` i nummerordning. Om du har tillgång till Manus, börja med att läsa `docs/00-projektbeskrivning-manus.md` och klistra in den i ditt projekt.

### Guider (i ordning)

| # | Guide | Beskrivning |
|---|-------|-------------|
| 00 | [Manus-projektbeskrivning](docs/00-projektbeskrivning-manus.md) | Mall att klistra in i AI-assistenten (valfritt) |
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

### Referensmaterial

| Fil | Beskrivning |
|-----|-------------|
| [Kapacitetsplanering](docs/kapacitetsplanering.md) | RAM/CPU per antal kameror |
| [Backup-strategi](docs/backup-strategi.md) | Automatisk säkerhetskopiering |
| [Ordlista & FAQ](docs/ordlista-faq.md) | Termer förklarade i klartext |
| [SETUP-CHECKLIST](SETUP-CHECKLIST.md) | Avbockningsbar lista |
| [STATUS](STATUS.md) | Din live-status (fyll i vartefter) |

### 🤖 Automatisk Installation Wizard (Ny!)

Istället för att följa guiderna steg-för-steg manuellt kan du använda vår nya interaktiva installer-wizard. Den hanterar hela uppsättningen åt dig.

Skriptet är en **fullfjädrad wizard** som:
- Kollar BIOS-inställningar (VT-x, VT-d, iGPU)
- Hittar automatiskt en extra SSD och formaterar den för Frigate
- Låter dig välja mellan Frigate 0.17.2 (Stable) och 0.18.0 (Beta)
- Verifierar iGPU-passthrough automatiskt (`vainfo`)
- Hoppar elegant över tjänster som redan är installerade (perfekt om du redan har HA)
- Hanterar saknade tokens graceful (installerar men väntar med start)

```bash
# SSH:a in på din Proxmox-nod och kör:
cd /tmp && git clone https://github.com/ToFinToFun/optiplex-homelab.git
cd optiplex-homelab/scripts
bash setup.sh
```
*(Skriptet ställer frågorna interaktivt. Vill du slippa svara kan du kopiera `setup.env.example` till `setup.env` först).*

#### Fler verktyg
- `bash tools/status.sh` — Health-check som visar status för alla tjänster, iGPU och lagring.
- `bash tools/usb-backup.sh` — Tar säkerhetskopia av hela systemet (Proxmox vzdump) till ett USB-minne.
- `bash tools/update.sh` — Uppdaterar Proxmox och drar ner senaste Docker-images.
- `bash tools/uninstall.sh` — Tar bort alla skapade containers/VMs rent så du kan börja om.

### Konfigurationsfiler

| Fil | Beskrivning |
|-----|-------------|
| [configs/frigate-config.example.yml](configs/frigate-config.example.yml) | Frigate-mall med OpenVINO + dual streams |
| [configs/docker-compose-frigate.yml](configs/docker-compose-frigate.yml) | Docker Compose för Frigate |
| [configs/docker-compose-npm.yml](configs/docker-compose-npm.yml) | Docker Compose för NPM |
| [scripts/axis-create-stream-profiles.sh](scripts/axis-create-stream-profiles.sh) | Automatisera Axis-kamerakonfiguration |
| [scripts/proxmox-post-install.sh](scripts/proxmox-post-install.sh) | Byt repos + aktivera TRIM |
| [configs/99-igpu-permissions.rules](configs/99-igpu-permissions.rules) | udev-regel för iGPU (överlever reboot) |
