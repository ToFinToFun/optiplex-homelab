# Setup Checklista

Bocka av dessa steg vartefter du bygger din server.

## Fas 1: Grundinstallation
- [ ] Uppgradera RAM till 32GB
- [ ] Installera extra SSD för Frigate-lagring
- [ ] Konfigurera BIOS (`docs/01-bios-setup.md`)
- [ ] Installera Proxmox VE 9 (`docs/02-proxmox-install.md`)
- [ ] Kör post-install-scriptet för att byta repos
- [ ] Reservera statisk IP för Proxmox i routern

## Fas 2: Infrastruktur
- [ ] Skapa Cloudflare-konto och lägg till din domän
- [ ] Skapa LXC 101: Cloudflared (`docs/04-cloudflare-tunnel.md`)
- [ ] Skapa LXC 102: Nginx Proxy Manager (`docs/05-npm.md`)
- [ ] Konfigurera Cloudflare Zero Trust Access

## Fas 3: Home Assistant
- [ ] Skapa VM 100: Home Assistant OS (`docs/08-home-assistant.md`)
- [ ] Återställ din befintliga HA-backup
- [ ] Ändra externa URL:er i HA till din nya domän
- [ ] Installera Mosquitto broker (MQTT) som Add-on i HA

## Fas 4: Frigate & Kameror
- [ ] Montera Frigate-lagringsdisken i Proxmox (`docs/03-lagringsdisk.md`)
- [ ] Konfigurera Axis-kameror med dual streams (`docs/07-axis-kameror.md`)
- [ ] Skapa LXC 103: Frigate med iGPU passthrough (`docs/06-frigate.md`)
- [ ] Anpassa `frigate.yml` och starta Docker
- [ ] Verifiera extern livevy via MSE (`docs/09-extern-livevy.md`)
