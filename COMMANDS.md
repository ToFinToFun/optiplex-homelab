═══════════════════════════════════════════════════════════════
  OptiPlex Homelab — Kommandon
═══════════════════════════════════════════════════════════════


INSTALLATION & WIZARD (en rad gör allt)
────────────────────────────────────────
Installerar verktyg, klonar repot och startar wizarden.
Om repot redan finns: uppdaterar och visar interaktiv meny.
Kan köras hur många gånger som helst — den kommer ihåg vad
som redan är gjort och du väljer vad du vill köra/ändra.

bash <(curl -fsSL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/bootstrap.sh)


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
Visar installerad vs tillgänglig version med key features.
Erbjuder uppgradering/uppdatering om ny version finns.

  Bara kolla (ändrar inget):
  cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh --check

  Kolla och installera:
  cd /opt/optiplex-homelab/scripts && bash tools/upgrade-proxmox.sh


UPPDATERA ALLT
──────────────
Uppdaterar repot (git pull), Proxmox-paket och alla
Docker-images (Frigate, NPM).

cd /opt/optiplex-homelab/scripts && bash tools/update.sh


BACKUP TILL USB
───────────────
Tar en komplett backup av alla containers (exkl.
Frigate-video) till ett USB-minne.

cd /opt/optiplex-homelab/scripts && bash tools/usb-backup.sh


AVINSTALLERA ALLT (börja om)
────────────────────────────
Tar bort alla skapade containers och VM.
Frågar innan varje borttagning.

cd /opt/optiplex-homelab/scripts && bash tools/uninstall.sh


FRESH START (radera ALLT och börja om från scratch)
───────────────────────────────────────────────────
Raderar ALLA containers/VMs, config, state och repot.
Klonar om från GitHub utan cache och startar wizarden.
Som att köra på en helt färsk Proxmox-installation.

  Från installerat repo:
  cd /opt/optiplex-homelab/scripts && bash tools/fresh-start.sh

  Direkt one-liner (fungerar även om repot är trasigt):
  bash <(curl -fsSL "https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/tools/fresh-start.sh?v=$(date +%s)")


VISA INSTALLATIONSLOGGEN (vid problem)
──────────────────────────────────────
Visar vad som hände under installationen,
användbart för felsökning.

cat /var/log/optiplex-setup.log


═══════════════════════════════════════════════════════════════
  Bonus
═══════════════════════════════════════════════════════════════


BYTA ROOT-LÖSENORD PÅ ALLA CONTAINERS
──────────────────────────────────────
Fristående script som byter root-lösenord på alla
befintliga LXC-containers. Användbart om du redan har
containers som skapades med annat lösenord, eller om du
vill byta lösenord utan att köra hela wizarden.

bash <(curl -s https://gist.githubusercontent.com/ToFinToFun/ae2fcd9bdc5cb7a54f95969b972241fa/raw/change-ct-passwords.sh)


═══════════════════════════════════════════════════════════════
  Repo: https://github.com/ToFinToFun/optiplex-homelab
═══════════════════════════════════════════════════════════════
