# Live Status - Proxmox Homelab

> **Senast uppdaterad:** YYYY-MM-DD
> **Proxmox VE:** 9.x | **Domän:** [din-domän.se]

## Hårdvara
- **Nod 1:** Dell OptiPlex XE4 (Intel Core i5-12500T, 32GB RAM)
- **Lagring:** [Ange OS-disk] + [Ange Frigate-disk]
- **IP:** [Din statiska IP, t.ex. 192.168.1.100]

## Tjänster

| ID | Namn | Typ | IP | Status | Beskrivning |
|----|------|-----|-----|--------|-------------|
| 100 | Home Assistant | VM | [IP] | 🔴 Ej startad | Smart home hub (HAOS) |
| 101 | Cloudflared | LXC | [IP] | 🔴 Ej startad | Cloudflare Tunnel proxy |
| 102 | Nginx Proxy Manager | LXC | [IP] | 🔴 Ej startad | Reverse proxy + SSL |
| 103 | Frigate NVR | LXC | [IP] | 🔴 Ej startad | AI-videoövervakning |

## Extern åtkomst

| Subdomän | Tjänst | Backend | Skydd |
|----------|--------|---------|-------|
| ha.[domän.se] | Home Assistant | [HA-IP]:8123 | Publik (HA egen auth) |
| frigate.[domän.se] | Frigate NVR | [Frigate-IP]:5000 | Access (OTP) |
| npm.[domän.se] | Nginx Proxy Manager | [NPM-IP]:81 | Access (OTP) |
