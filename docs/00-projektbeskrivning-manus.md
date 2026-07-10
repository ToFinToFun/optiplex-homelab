# Projektbeskrivning för Manus AI

> **TILL ANVÄNDAREN:** Kopiera all text nedanför linjen och klistra in i fältet "Project Instructions" i ditt Manus-projekt. Detta ger AI-assistenten den kontext som behövs för att hjälpa dig bygga och underhålla servern. Byt ut värden inom hakparenteser `[...]` mot dina egna innan du sparar.

---

## Proxmox Homelab - Projektbeskrivning

### Hårdvara
- **Enhet:** Dell OptiPlex XE4 SFF (eller liknande)
- **CPU:** Intel Core i5-12500T (med UHD 770 iGPU för AI-detektering)
- **RAM:** 32GB Dual Channel
- **OS-disk:** [Ange storlek] NVMe SSD
- **Frigate-disk:** [Ange storlek] SSD för kontinuerlig videoinspelning
- **Hostname:** [Ange önskat namn, t.ex. server1]
- **Domän:** [Ange din domän, t.ex. mindomän.se]

### Nätverk
- **Router:** [Ange märke, t.ex. Unifi]
- **Subnät:** [Ange subnät, t.ex. 192.168.1.0/24]
- **Proxmox IP:** [Ange statisk IP]
- **Gateway:** [Ange gateway IP]

### VMs och Containers (LXC)
- **VM 100 (ha):** Home Assistant OS (2 cores, 6GB RAM, 40GB disk)
- **CT 101 (cloudflared):** Cloudflare Tunnel (1 core, 256MB RAM)
- **CT 102 (npm):** Nginx Proxy Manager (1 core, 512MB RAM)
- **CT 103 (frigate):** Frigate NVR i Docker med iGPU passthrough (4 cores, 6GB RAM)

### Kameror
- [Ange antal] Axis-kameror konfigurerade med dual streams (Main + Detect)

### Principer för AI-assistenten
- **RESEARCH FIRST:** Innan NÅGOT beslut tas eller NÅGOT installeras/konfigureras, gör FÖRST djup research. Gissa ALDRIG.
- **Kvalitet före hastighet:** Gör det rätt första gången. Inga genvägar.
- **LXC framför VM:** Använd obepriviligierade Debian 13 LXC-containrar för allt utom Home Assistant.
- **Säkerhet:** All extern åtkomst går via Cloudflare Tunnel. INGA inkommande portar (port forwarding) får öppnas i routern.
- **Tokenhantering:** Alla lösenord, API-nycklar och tokens lagras ENDAST i filen `TOKENS.md` (som inte synkas till git). Skriv aldrig ut riktiga tokens i kod eller terminalkommandon om det kan undvikas.
- **Minimera SSD-slitage:** Frigates kontinuerliga inspelning ska sparas på den dedikerade lagringsdisken, inte på OS-disken.
