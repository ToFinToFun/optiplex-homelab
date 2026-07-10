# OptiPlex Homelab — Komplett Setup-guide

Detta repo innehåller en steg-för-steg-guide för att sätta upp en Dell OptiPlex XE4 (eller liknande) som en kraftfull hemmaserver för Home Assistant och AI-driven videoövervakning (Frigate).

## Syfte
Att bygga en "site-in-a-box" som är säker, stabil och extremt resurseffektiv genom att använda Proxmox, LXC-containrar och hårdvaruacceleration (iGPU) för AI-detektering.

## Komma igång
Följ guiderna i `docs/` i nummerordning. Börja med att läsa `00-projektbeskrivning-manus.md` och klistra in den i din egen AI-assistent (t.ex. Manus) för att få hjälp med installationen.

## Innehåll
- `STATUS.md` - Din live-status (fyll i denna vartefter du bygger)
- `SETUP-CHECKLIST.md` - Hela resan som avbockningsbar lista
- `docs/` - Steg-för-steg guider
- `configs/` - Exempelkonfigurationer för Frigate
- `scripts/` - Hjälpskript för Proxmox och kameror
