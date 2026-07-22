═══════════════════════════════════════════════════════════════
  OptiPlex Homelab — Kommandon
═══════════════════════════════════════════════════════════════


BÖRJA OM FRÅN SCRATCH (fresh start)
────────────────────────────────────
Raderar ALLA containers, VMs, konfiguration och repot.
Klonar om från GitHub utan cache och startar om wizarden.
Kör detta om något gått snett och du vill börja helt rent.

  bash <(curl -fsSL "https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/tools/fresh-start.sh?v=$(date +%s)")


INSTALLATION (första gången)
─────────────────────────────
Installerar verktyg, klonar repot och startar wizarden.
Kör detta på en färsk Proxmox-installation.

  bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh)


KÖRA OM WIZARDEN (utan att ladda ner allt igen)
────────────────────────────────────────────────
Om repot redan finns och du bara vill köra wizarden igen.
Den kommer ihåg vad som redan är gjort — du väljer vad
du vill köra/ändra.

  cd /opt/optiplex-homelab/scripts && bash setup.sh


DIAGNOSTIK (felsökning)
───────────────────────
Kollar BIOS, iGPU, containers, Docker, MQTT, brandvägg,
NPM SSL, disk, temperatur — allt. Visar ✓/✗ per punkt.

  cd /opt/optiplex-homelab/scripts && bash tools/doctor.sh


SYSTEMSTATUS (snabb health-check)
─────────────────────────────────
Visar status för alla containers/VM, iGPU-last,
disk-utrymme och tunnel-anslutning.

  cd /opt/optiplex-homelab/scripts && bash tools/status.sh


PROXMOX-UPPDATERING
───────────────────
Visar installerad vs tillgänglig version.
Erbjuder uppgradering om ny version finns.

  Bara kolla (ändrar inget):
  cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh --check

  Kolla och installera:
  cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh


UPPDATERA ALLT (repo + paket + Docker)
───────────────────────────────────────
Uppdaterar repot (git pull), Proxmox-paket och alla
Docker-images (Frigate, NPM).

  cd /opt/optiplex-homelab/scripts && bash tools/update.sh


BACKUP TILL USB
───────────────
Tar en komplett backup av alla containers (exkl.
Frigate-video) till ett USB-minne.

  cd /opt/optiplex-homelab/scripts && bash tools/usb-backup.sh


AVINSTALLERA (ta bort containers/VMs)
──────────────────────────────────────
Tar bort alla skapade containers och VM.
Frågar innan varje borttagning. Behåller repot.

  cd /opt/optiplex-homelab/scripts && bash tools/uninstall.sh


VISA INSTALLATIONSLOGGEN
────────────────────────
Visar vad som hände under installationen.
Användbart vid felsökning.

  cat /var/log/optiplex-setup.log


═══════════════════════════════════════════════════════════════
  Bonus
═══════════════════════════════════════════════════════════════


BYTA ROOT-LÖSENORD PÅ ALLA CONTAINERS
──────────────────────────────────────
Byter root-lösenord på alla befintliga LXC-containers.
Användbart om du vill byta lösenord utan att köra wizarden.

  bash <(curl -s https://gist.githubusercontent.com/ToFinToFun/ae2fcd9bdc5cb7a54f95969b972241fa/raw/change-ct-passwords.sh)


═══════════════════════════════════════════════════════════════
  Repo: https://github.com/ToFinToFun/optiplex-homelab
═══════════════════════════════════════════════════════════════
