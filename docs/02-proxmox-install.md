# Steg 2: Installation av Proxmox VE

Denna guide täcker installationen av Proxmox VE (Virtual Environment) 9.x och de viktiga efterjusteringar som krävs för att få ett stabilt system.

## Förberedelser
1. Ladda ner den senaste ISO-filen för Proxmox VE från deras officiella hemsida.
2. Använd ett verktyg som BalenaEtcher eller Rufus för att "flasha" ISO-filen till en USB-sticka (minst 2 GB).
3. Bestäm vilken IP-adress servern ska ha på ditt nätverk (t.ex. `192.168.1.100`).

## Installation
1. Sätt USB-stickan i OptiPlexen och starta datorn. Den bör automatiskt boota från USB (enligt våra BIOS-inställningar). Om inte, tryck **F12** vid uppstart och välj USB-enheten.
2. Välj **"Install Proxmox VE (Graphical)"** i menyn.
3. Följ installationsprogrammets steg:
   - **Target Harddisk:** Välj din primära NVMe/SSD (inte den extra disken du ska ha till Frigate). Klicka på "Options" och säkerställ att filsystemet är satt till **ext4**.
   - **Country/Timezone/Keyboard:** Sweden, Europe/Stockholm, Swedish.
   - **Password:** Välj ett starkt root-lösenord och ange din e-postadress.
   - **Management Interface:** Välj nätverkskortet som kabeln sitter i.
   - **Hostname:** Ange ett fullständigt domännamn, t.ex. `server1.dindomän.se`.
   - **IP Address:** Ange den statiska IP du bestämt.
   - **Gateway & DNS:** Ange din routers IP-adress (t.ex. `192.168.1.1`).
4. Klicka på Install. När det är klart, ta ur USB-stickan och klicka på Reboot.

> **Viktigt:** När datorn startar om, gå in i BIOS (F2) en sista gång och ändra Boot Sequence så att din NVMe/SSD ligger först. Detta förhindrar att datorn råkar boota från en kvarglömd USB-sticka i framtiden.

## Första inloggningen
Du behöver nu inte längre ha monitor och tangentbord inkopplat till servern.
1. Gå till din vanliga dator och öppna en webbläsare.
2. Surfa till `https://[DIN-SERVER-IP]:8006` (t.ex. `https://192.168.1.100:8006`).
3. Acceptera webbläsarens säkerhetsvarning (det är normalt eftersom certifikatet är självsignerat).
4. Logga in med användarnamn `root` och lösenordet du valde vid installationen.

Du kommer att se en varning om att du saknar en giltig prenumeration. Det löser vi i nästa steg.

## Post-install script (Byt till gratis-repos)
Proxmox är inställt på att använda "Enterprise"-arkiv som kräver en betald licens. Vi måste byta till "No-Subscription"-arkiven för att kunna uppdatera systemet gratis.

1. I Proxmox webbgränssnitt, klicka på din nod i vänstermenyn och välj sedan **Shell**.
2. Klistra in följande skript och tryck Enter:

```bash
#!/bin/bash
echo "Inaktiverar Enterprise-repos..."
cat > /etc/apt/sources.list.d/pve-enterprise.sources << 'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: no
EOF

cat > /etc/apt/sources.list.d/ceph.sources << 'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: no
EOF

echo "Aktiverar No-Subscription repo..."
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

echo "Uppdaterar systemet..."
apt update && apt upgrade -y
```

När skriptet kört klart och uppdaterat systemet, skriv `reboot` och tryck Enter för att starta om servern om en ny kernel installerades.

## Aktivera SSD TRIM
För att förlänga livslängden på din SSD, aktivera veckovis TRIM. Öppna Shell igen och kör:
```bash
systemctl enable fstrim.timer
systemctl start fstrim.timer
```

## Routern (DHCP-reservation)
Gå in i din routers gränssnitt (t.ex. Unifi Network) och leta upp servern i listan över klienter. Skapa en **DHCP-reservation** (Fixed IP) för serverns MAC-adress till samma IP-adress som du angav vid installationen. Detta garanterar att IP-adressen aldrig ändras.
