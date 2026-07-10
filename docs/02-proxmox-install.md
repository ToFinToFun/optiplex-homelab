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

> **Varför Proxmox VE?** Proxmox är en "hypervisor". Istället för att installera Windows eller Ubuntu och sedan köra program ovanpå det, är Proxmox byggt enbart för att dela ut hårdvaran till virtuella maskiner och containrar med minimal prestandaförlust (ofta under 1%). Det gör att vi kan isolera Home Assistant och Frigate från varandra.
1. Gå till din vanliga dator och öppna en webbläsare.
2. Surfa till `https://[DIN-SERVER-IP]:8006` (t.ex. `https://192.168.1.100:8006`).
3. Acceptera webbläsarens säkerhetsvarning (det är normalt eftersom certifikatet är självsignerat).
4. Logga in med användarnamn `root` och lösenordet du valde vid installationen.

Du kommer att se en varning om att du saknar en giltig prenumeration. Det löser vi i nästa steg.

## Post-install script
Vi har skapat ett färdigt skript som automatiserar tre viktiga saker:
1. Byter från betalda "Enterprise"-repos till gratis "No-Subscription"-repos så du kan uppdatera systemet.
2. Aktiverar SSD TRIM (vilket städar disken och förlänger dess livslängd avsevärt).
3. Lägger in en regel (`udev`) som ser till att Frigate alltid får tillgång till grafikkretsen, även efter omstart.

1. I Proxmox webbgränssnitt, klicka på din nod i vänstermenyn och välj sedan **Shell**.
2. Kör följande kommandon för att ladda ner och köra skriptet från detta repo:

```bash
apt install -y curl
curl -sL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/scripts/proxmox-post-install.sh | bash
```

När skriptet kört klart, skriv `reboot` och tryck Enter för att starta om servern.

## Routern (DHCP-reservation)
Gå in i din routers gränssnitt (t.ex. Unifi Network) och leta upp servern i listan över klienter. Skapa en **DHCP-reservation** (Fixed IP) för serverns MAC-adress till samma IP-adress som du angav vid installationen. Detta garanterar att IP-adressen aldrig ändras.

## Verifiering
1. Du kan logga in på `https://[DIN-SERVER-IP]:8006` utan problem.
2. I Proxmox Shell, skriv `apt update`. Du ska inte se några röda "Unauthorized" eller "401" fel (vilket betyder att gratis-repot fungerar).

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| Webbläsaren vägrar öppna sidan pga "Osäker anslutning" | Klicka på "Avancerat" och sedan "Fortsätt till [IP-adress] (osäker)". Proxmox använder ett självsignerat certifikat vilket är normalt. |
| Kan inte nå webbgränssnittet alls | Dubbelkolla att du skrev `https://` och port `:8006`. Kolla också i routern att servern faktiskt fått den IP-adress du tror. |
| Post-install-skriptet ger "command not found" | Säkerställ att du skrev kommandot exakt som det står. Du kan också kopiera innehållet från `scripts/proxmox-post-install.sh` och klistra in manuellt i terminalen. |
