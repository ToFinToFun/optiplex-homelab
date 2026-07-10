# Backup-strategi

En server utan backup är en tickande bomb. Denna guide beskriver vad som bör säkerhetskopieras, hur ofta, och vilka metoder som är enklast att sätta upp.

## Vad behöver säkerhetskopieras?

| Data | Plats | Kritiskhet | Metod |
|------|-------|-----------|-------|
| Home Assistant-konfiguration | VM 100 | **Hög** — månader av arbete | HA:s inbyggda backup |
| Frigate-konfiguration | CT 103: `/opt/frigate/config/` | **Hög** — kamerakonfiguration | Manuell kopia / cron |
| Frigate-inspelningar | Lagringsdisk | **Låg** — gammal video är sällan kritisk | Ingen backup (Frigate rensar automatiskt) |
| NPM-konfiguration | CT 102: `/opt/npm/data/` | **Medel** — enkelt att återskapa | Manuell kopia / cron |
| Cloudflared-token | CT 101 | **Låg** — finns i Cloudflare-dashboarden | Dokumenterad i TOKENS.md |

> **Varför inte säkerhetskopiera videoinspelningar?** Frigate-inspelningar tar enormt mycket plats och har begränsat värde efter några veckor. Om något viktigt händer, exportera klippet manuellt. Att säkerhetskopiera terabytes av video dagligen är opraktiskt och onödigt.

## Home Assistant: Automatisk backup till molnet

Home Assistant har inbyggt stöd för automatiska säkerhetskopior till Google Drive, OneDrive eller en nätverksresurs.

### Google Drive-metoden (rekommenderas)

1. I Home Assistant, gå till **Inställningar** → **System** → **Säkerhetskopior**.
2. Klicka på kugghjulet (⚙️) uppe till höger.
3. Under **Automatisk säkerhetskopiering**, aktivera den och välj:
   - **Schema:** Varje dag (eller vecka).
   - **Behåll:** De senaste 5 kopiorna.
4. Under **Platser**, klicka på **Lägg till plats** och välj **Google Drive** (kräver att du installerar Google Drive-tillägget först via Tilläggsbutiken).
5. Följ instruktionerna för att koppla ditt Google-konto.

Nu skapas en fullständig backup varje dag och laddas upp till din Google Drive. Om hela servern dör kan du återställa allt på en ny maskin.

## Frigate & NPM: Enkel cron-backup

För Frigate och NPM räcker det att kopiera konfigurationsfilerna till en säker plats (t.ex. en delad mapp, USB-sticka, eller samma Google Drive).

Skapa ett enkelt backup-skript på Proxmox-värden:

```bash
#!/bin/bash
# /root/backup-configs.sh
# Kör detta som cron-jobb varje söndag

BACKUP_DIR="/root/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

# Frigate config
pct exec 103 -- tar czf - /opt/frigate/config > "$BACKUP_DIR/frigate-config.tar.gz"

# NPM config
pct exec 102 -- tar czf - /opt/npm/data > "$BACKUP_DIR/npm-data.tar.gz"

# Behåll bara de 4 senaste backuperna
ls -dt /root/backups/*/ | tail -n +5 | xargs rm -rf

echo "Backup klar: $BACKUP_DIR"
```

Lägg till som cron-jobb:
```bash
crontab -e
# Lägg till denna rad (kör varje söndag kl 03:00):
0 3 * * 0 /root/backup-configs.sh
```

## Proxmox: Snapshot innan stora ändringar

Innan du gör stora förändringar (uppgraderar Frigate, ändrar konfiguration), ta en snapshot av containern:

```bash
# Snapshot av Frigate-containern
pct snapshot 103 pre-upgrade --description "Innan Frigate-uppgradering"

# Om något går fel, rulla tillbaka:
pct rollback 103 pre-upgrade
```

## Sammanfattning

| Vad | Hur | Hur ofta | Var |
|-----|-----|----------|-----|
| Home Assistant | Inbyggd auto-backup | Dagligen | Google Drive |
| Frigate config | cron-skript | Veckovis | Lokalt på Proxmox |
| NPM config | cron-skript | Veckovis | Lokalt på Proxmox |
| Containers | Proxmox snapshot | Innan ändringar | Lokalt (LVM) |
