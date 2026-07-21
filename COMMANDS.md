# OptiPlex Homelab — Kommandon

---

## Installation & Wizard (en rad gör allt)

Installerar verktyg, klonar repot och startar wizarden.
Om repot redan finns: uppdaterar till senaste versionen och startar wizarden med interaktiv meny.

Kan köras hur många gånger som helst — den kommer ihåg vad som redan är gjort och visar en meny där du väljer vad du vill köra.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh)
```

---

## Diagnostik (felsökning)

Kollar BIOS, iGPU, containers, Docker, MQTT, brandvägg, NPM SSL, disk, temperatur — allt.

```bash
cd /opt/optiplex-homelab/scripts && bash tools/doctor.sh
```

---

## Systemstatus (snabb health-check)

Visar status för alla containers/VM, iGPU-last, disk-utrymme och tunnel-anslutning.

```bash
cd /opt/optiplex-homelab/scripts && bash tools/status.sh
```

---

## Proxmox-uppdatering

Visar installerad vs tillgänglig version med key features. Erbjuder uppgradering om ny version finns.

```bash
# Bara kolla (ändrar inget):
cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh --check

# Kolla och installera om det finns uppdateringar:
cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh
```

---

## Uppdatera allt

Uppdaterar repot (git pull), Proxmox-paket och alla Docker-images (Frigate, NPM).

```bash
cd /opt/optiplex-homelab/scripts && bash tools/update.sh
```

---

## Backup till USB

Tar en komplett backup av alla containers (exkl. Frigate-video) till ett USB-minne.

```bash
cd /opt/optiplex-homelab/scripts && bash tools/usb-backup.sh
```

---

## Avinstallera allt (börja om)

Tar bort alla skapade containers och VM. Frågar innan varje borttagning.

```bash
cd /opt/optiplex-homelab/scripts && bash tools/uninstall.sh
```

---

## Visa installationsloggen (vid problem)

Visar vad som hände under installationen, användbart för felsökning.

```bash
cat /var/log/optiplex-setup.log
```

---

**Repo:** https://github.com/ToFinToFun/optiplex-homelab
