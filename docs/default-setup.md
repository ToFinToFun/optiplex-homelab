# Default Setup — OptiPlex Homelab Automation

Denna fil beskriver vad `bash setup.sh --headless` skapar med standardinställningar.

## Översikt

Headless-mode installerar en komplett homelab-infrastruktur på en enda Proxmox-nod utan att ställa frågor under körningen. Alla tjänster får statiska IP-adresser i samma subnät som Proxmox-hosten.

**Tidsåtgång:** ~15 minuter (beroende på internetanslutning)

**Krav:** `setup.env` måste finnas med lösenord och nätverksinställningar (skapas vid första interaktiva körningen).

---

## Containers & VMs (default)

| ID | Typ | Hostname | IP (default) | Tjänst | Beskrivning |
|----|-----|----------|--------------|--------|-------------|
| 100 | VM | ha | 192.168.x.100 | Home Assistant OS | Smart home-central. Kör HAOS med full supervisor-support för add-ons, backups och integrationer. |
| 101 | CT | cloudflared | 192.168.x.101 | Cloudflare Tunnel | Säker extern åtkomst utan port forwarding. Exponerar HA, Frigate, Guacamole etc. via Cloudflare Zero Trust. |
| 102 | CT | npm | 192.168.x.102 | Nginx Proxy Manager | Reverse proxy för intern trafik. Hanterar SSL-certifikat och routing mellan tjänster. Admin-UI på port 81. |
| 103 | CT | frigate | 192.168.x.103 | Frigate NVR | AI-baserad kameraövervakning med realtidsdetektering (person, bil, djur). Använder iGPU via OpenVINO. Docker-baserad i LXC. |
| 107 | CT | guacamole | 192.168.x.107 | Apache Guacamole | Webbbaserad remote desktop-gateway. Ger RDP/SSH/VNC-åtkomst via webbläsaren utan klient-installation. |
| 108 | CT | desktop | 192.168.x.108 | Linux Desktop (XFCE) | Lättvikts Linux-skrivbord med xrdp. Nås via Guacamole eller valfri RDP-klient. Användbart för admin-uppgifter. |

> **Notera:** IP-adresserna ovan antar `NETWORK_PREFIX=192.168.x`. Det faktiska subnätet sätts i `setup.env`. ID-numret i Proxmox är alltid samma som sista oktetten i IP-adressen.

---

## Resursfördelning (default)

| ID | CPU (kärnor) | RAM | Disk | OS |
|----|:---:|:---:|:---:|:---|
| 100 (HA) | 2 | 4 GB | 32 GB | HAOS (VM) |
| 101 (Cloudflared) | 1 | 256 MB | 2 GB | Debian 13 |
| 102 (NPM) | 1 | 512 MB | 4 GB | Debian 13 |
| 103 (Frigate) | 4 | 4 GB | 8 GB + frigate-storage | Debian 13 + Docker |
| 107 (Guacamole) | 2 | 1 GB | 8 GB | Debian 13 |
| 108 (Desktop) | 2 | 2 GB | 16 GB | Debian 13 + XFCE |

**Totalt (alla igång):** 12 kärnor, ~12 GB RAM, ~70 GB disk

---

## Nätverksarkitektur

```
Internet
    │
    ▼
Cloudflare (DNS + Tunnel + Zero Trust)
    │
    ▼ (krypterad tunnel, ingen port forwarding)
┌───────────────────────────────────────────────┐
│  CT 101 — cloudflared                         │
│  Tar emot trafik från Cloudflare Tunnel       │
└───────────────┬───────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────┐
│  CT 102 — NPM (Nginx Proxy Manager)          │
│  Routar trafik baserat på domännamn:          │
│    ha.domain.se      → 192.168.x.100:8123     │
│    frigate.domain.se → 192.168.x.103:5000     │
│    rdp.domain.se     → 192.168.x.107:8080     │
└───────────────────────────────────────────────┘
                │
    ┌───────────┼───────────┬───────────┐
    ▼           ▼           ▼           ▼
  VM 100      CT 103      CT 107      CT 108
  (HA)       (Frigate)  (Guacamole)  (Desktop)
```

---

## Vad varje modul gör

### Modul 00 — Proxmox Host
- Konfigurerar apt-repos (no-subscription)
- Aktiverar fstrim (SSD TRIM)
- Fixar BIOS-inställningar (VT-d, iGPU) via efibootmgr
- Sätter upp udev-regler för iGPU passthrough

### Modul 01 — Storage
- Detekterar och formaterar extra SSD (om tillgänglig)
- Skapar LVM-Thin pool för VM/CT-diskar
- Skapar `frigate-storage` directory storage för inspelningar

### Modul 02 — Home Assistant VM
- Laddar ner senaste HAOS qcow2-image
- Skapar VM med UEFI, Q35 machine type, VirtIO-disk
- Startar VM och väntar på att HA-webUI svarar

### Modul 03 — Cloudflared
- Skapar minimal Debian 13 LXC
- Installerar cloudflared från officiellt Cloudflare-repo
- Aktiverar tunnel-service (om token finns)

### Modul 04 — NPM (Nginx Proxy Manager)
- Skapar Debian 13 LXC
- Installerar NPM via officiellt installationsscript
- Byter default-lösenord via API till gemensamt lösenord

### Modul 05 — Frigate NVR
- Skapar privilegierad Debian 13 LXC med iGPU passthrough
- Installerar Docker + Docker Compose
- Driftsätter Frigate med OpenVINO-detector
- Konfigurerar MQTT-anslutning (kräver manuell Mosquitto-setup i HA)

### Modul 09 — Remote Desktop
- **Guacamole CT:** Tomcat + guacamole-server + MariaDB, webb-UI på port 8080
- **Desktop CT:** XFCE4 + xrdp, nås via Guacamole eller direkt RDP (port 3389)
- Auto-konfigurerar Guacamole-anslutning till Desktop via REST API

---

## Credentials (default)

Alla tjänster använder samma **gemensamma lösenord** (satt i `setup.env`):

| Tjänst | Användare | Lösenord |
|--------|-----------|----------|
| CT root (alla) | root | Gemensamt lösenord |
| NPM Admin | admin@example.com | Gemensamt lösenord |
| Guacamole | guacadmin (eller custom) | Gemensamt lösenord |
| Desktop (xrdp) | user | Gemensamt lösenord |
| Frigate RTSP | frigate | Gemensamt lösenord |
| MQTT (Mosquitto) | frigate | Gemensamt lösenord |

---

## Portar

| Port | Tjänst | Protokoll |
|------|--------|-----------|
| 8123 | Home Assistant | HTTP |
| 80/443 | NPM (proxy) | HTTP/HTTPS |
| 81 | NPM Admin | HTTP |
| 5000 | Frigate UI | HTTP |
| 8554 | Frigate RTSP restream | RTSP |
| 8555 | Frigate WebRTC | HTTP |
| 1883 | MQTT (Mosquitto i HA) | TCP |
| 8080 | Guacamole | HTTP |
| 3389 | Desktop xrdp | RDP |

---

## Headless-flöde

```
bash setup.sh --headless
    │
    ├─ Pre-flight checks (lösenord, nätverk, iGPU, tunnel-token)
    │
    ├─ Modul 00: Proxmox Host (repos, TRIM, BIOS)
    ├─ Modul 01: Storage (auto-detect)
    ├─ Modul 02: Home Assistant VM
    ├─ Modul 03: Cloudflared
    ├─ Modul 04: NPM
    ├─ Modul 05: Frigate (om iGPU finns)
    ├─ Modul 09: Guacamole + Desktop
    │
    ├─ Brandväggsverifiering
    ├─ Tjänst-tabell (URLs + status)
    └─ Post-run sammanfattning ("Du måste göra X, Y, Z")
```

**Hoppas över i headless** (kräver manuell input):
- Modul 06: Kamerakonfiguration
- Modul 07: Cloudflare DNS-routing
- Modul 08: NPM proxy-regler

Dessa konfigureras genom att köra `bash setup.sh` interaktivt efteråt.

---

## Filstruktur efter installation

```
/opt/optiplex-homelab/
├── scripts/
│   ├── setup.sh          # Huvudwizard
│   ├── setup.env         # Sparad konfiguration
│   ├── .state/           # Installationsstatus per steg
│   ├── lib/              # Hjälpfunktioner
│   ├── modules/          # Installationsmoduler (00-09)
│   └── tools/            # doctor.sh, status.sh, update.sh, etc.
├── docs/                 # Dokumentation
├── configs/              # Genererade config-filer (frigate.yml etc.)
└── TODO.md               # Manuella steg som kvarstår
```
