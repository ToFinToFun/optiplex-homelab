# Steg 8: Home Assistant & Migrering

> **Varför en VM istället för LXC för Home Assistant?** Home Assistant OS (HAOS) innehåller en egen "Supervisor" som hanterar Add-ons (som Mosquitto MQTT) via Docker. Att köra Docker inuti Docker inuti LXC blir rörigt och stöds inte officiellt. Genom att köra HAOS som en virtuell maskin (VM) får vi den officiella, fullt stödda upplevelsen där allt bara fungerar med ett klick.

Vi kör Home Assistant som en virtuell maskin (VM) istället för en LXC-container. Detta är det officiella och rekommenderade sättet (Home Assistant OS), vilket ger dig tillgång till "Add-ons" (t.ex. Mosquitto MQTT) och full kontroll över systemet.

## 1. Skapa Home Assistant VM (VM 100)

Vi använder ett populärt installationsskript från tteck för att ladda ner och konfigurera Home Assistant OS automatiskt.

1. Öppna **Shell** för din Proxmox-nod.
2. Kör följande kommando:
   ```bash
   bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/vm/haos-vm.sh)"
   ```
3. Följ guiden i terminalen:
   - Välj **Advanced** installation för att kunna styra resurserna.
   - **VM ID:** `100`
   - **Machine Type:** `q35`
   - **Disk Size:** `40` GB (eller mer om du vill). Välj din NVMe/SSD-disk.
   - **CPU Cores:** `2`
   - **RAM:** `6144` MB (6 GB)
   - **Bridge:** `vmbr0`
   - **Start VM when completed:** Yes
4. När skriptet är klart, gå till routern och skapa en DHCP-reservation (statisk IP) för den nya virtuella maskinen.

## 2. Återställ din befintliga backup

Istället för att börja om från noll, flyttar vi över din befintliga Home Assistant-installation.

1. I din **gamla** Home Assistant, gå till **Inställningar** -> **System** -> **Säkerhetskopior**.
2. Skapa en fullständig säkerhetskopia och ladda ner den till din dator.
3. Surfa till din **nya** Home Assistant via dess IP-adress: `http://[NY-HA-IP]:8123`.
4. På välkomstskärmen, istället för att skapa en ny användare, klicka på texten **"Alternativt kan du återställa från en tidigare säkerhetskopia"**.
5. Ladda upp filen du laddade ner från det gamla systemet och klicka på Återställ.
6. Detta kan ta allt från 10 minuter till en timme beroende på storleken på din backup. När det är klart kommer systemet att starta om och du kan logga in med dina vanliga uppgifter.

## 3. Konfigurera MQTT (Mosquitto)

Frigate och Home Assistant måste prata med varandra via MQTT. Eftersom du nu kör Home Assistant OS är det enklast att installera MQTT direkt där.

1. I din nya Home Assistant, gå till **Inställningar** -> **Tillägg** (Add-ons) -> **Tilläggsbutik**.
2. Sök efter **Mosquitto broker** och installera det.
3. Starta tillägget och slå på "Starta vid uppstart" och "Watchdog".
4. Gå till **Inställningar** -> **Personer** -> fliken **Användare**.
5. Skapa en ny användare. Döp den till `mqtt-user` och ge den ett starkt lösenord. (Detta är lösenordet du ska ange som `FRIGATE_MQTT_PASSWORD` i Frigates `docker-compose.yml`).
6. Gå till **Inställningar** -> **Enheter och tjänster**. Home Assistant bör automatiskt ha upptäckt MQTT. Klicka på Konfigurera och godkänn.

## 4. Uppdatera Frigate med MQTT

1. Gå tillbaka till din Frigate-container (CT 103) i Proxmox.
2. Öppna `config/config.yml` och aktivera MQTT:
   ```yaml
   mqtt:
     enabled: true
     host: 192.168.1.X # IP-adressen till din nya Home Assistant
     port: 1883
     user: mqtt-user
     password: "{FRIGATE_MQTT_PASSWORD}"
   ```
3. Starta om Frigate (`docker compose restart`).
4. I Home Assistant, gå till **Inställningar** -> **Enheter och tjänster** -> **Lägg till integration**.
5. Sök efter **Frigate**. Ange URL:en till Frigate (`http://[Frigate-IP]:5000`).
6. Nu kommer alla dina kameror och sensorer från Frigate att dyka upp i Home Assistant!

## 5. Stäng ner det gamla systemet

1. När du har verifierat att allt fungerar i det nya systemet, gå in i din Home Assistant-app i telefonen.
2. Gå till appens inställningar och ändra den lokala IP-adressen till den nya servern.
3. Ändra den externa URL:en till din nya domän (`https://ha.mindomän.se`).
4. Du kan nu stänga av din gamla Home Assistant och **ta bort eventuella gamla port forward-regler** i din router. All extern trafik går nu säkert via Cloudflare Tunnel.

## Verifiering
1. Gå till Inställningar -> Enheter & Tjänster i Home Assistant. Du ska se "Frigate" och "MQTT" i listan över konfigurerade integrationer.
2. Klicka på Frigate-integrationen. Du ska se dina kameror som enheter.
3. Om du går framför en kamera ska sensorn för "person" i Home Assistant ändras från "Clear" till "Detected".

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| MQTT-integrationen kan inte ansluta | Dubbelkolla att du skapade en användare i Home Assistant för MQTT och att du skrev in exakt samma lösenord i Frigates `docker-compose.yml`. |
| Frigate-integrationen hittar inte servern | Säkerställ att du angav `http://[FRIGATE-IP]:5000` i integrationen. |
| Jag kan inte ladda upp min backup-fil | Om filen är jättestor (flera gigabyte) kan det vara gamla databas-filer. Prova att packa upp tar-filen på din dator, ta bort `home-assistant_v2.db` och packa ihop den igen. |
