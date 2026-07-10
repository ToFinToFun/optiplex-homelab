# Ordlista & FAQ

## Ordlista

Här förklaras alla tekniska termer som används i guiderna, i klartext.

| Term | Förklaring |
|------|-----------|
| **Proxmox VE** | Ett gratis operativsystem som låter dig köra flera "datorer inuti en dator" (virtuella maskiner och containrar) på en enda fysisk maskin. Tänk det som att ha flera separata datorer, men de delar samma hårdvara. |
| **LXC (Container)** | En lättviktig "dator inuti datorn". Till skillnad från en virtuell maskin delar den kärna (kernel) med värdmaskinen, vilket gör den snabbare och mer resurseffektiv. Perfekt för tjänster som inte behöver ett helt eget operativsystem. |
| **VM (Virtuell Maskin)** | En fullständig "dator inuti datorn" med eget operativsystem. Tyngre än en container men nödvändig för saker som Home Assistant OS som kräver full kontroll. |
| **iGPU** | Den inbyggda grafikkretsen i din Intel-processor. Vi använder den inte för att visa bild på en skärm, utan för att snabbt avkoda videoströmmar och köra AI-modeller. |
| **OpenVINO** | Intels ramverk för att köra AI-modeller (som persondetektering) på deras hårdvara. Det gör att din iGPU kan identifiera personer, bilar och djur i videobilder i realtid. |
| **YOLOv9** | En AI-modell som kan identifiera objekt i bilder. "YOLO" står för "You Only Look Once" — den analyserar hela bilden på en gång istället för att skanna den bit för bit, vilket gör den extremt snabb. |
| **VAAPI** | Ett gränssnitt som låter program (som Frigate) använda grafikkretsen för att avkoda video istället för processorn. Sparar enormt mycket CPU-kraft. |
| **RTSP** | Ett protokoll (språk) som kameror använder för att skicka videoströmmar över nätverket. Tänk det som en "live TV-kanal" som kameran sänder och Frigate tittar på. |
| **go2rtc** | En streamingmotor inbyggd i Frigate som hämtar videoströmmar från kamerorna och gör dem tillgängliga för webbläsaren. Den hanterar översättningen mellan kamerans RTSP och webbläsarens MSE/WebRTC. |
| **MSE** | Media Source Extensions — en teknik som låter webbläsaren spela upp live-video via en vanlig HTTPS-anslutning. Fungerar genom Cloudflare Tunnel utan extra konfiguration. |
| **WebRTC** | En teknik för video/ljud med extremt låg fördröjning. Kräver dock UDP-trafik som inte fungerar genom Cloudflare Tunnel utan en TURN-server. |
| **TURN-server** | En relästation på internet som vidarebefordrar WebRTC-trafik när en direkt anslutning inte är möjlig. Behövs bara om du vill ha WebRTC externt (MSE räcker för de flesta). |
| **Cloudflare Tunnel** | En krypterad, utgående anslutning från din server till Cloudflares nätverk. Eftersom anslutningen går *ut* från ditt hem behöver du aldrig öppna portar i din router. Cloudflare "vänder" sedan trafiken tillbaka in till dig. |
| **Zero Trust Access** | Cloudflares system för att skydda webbsidor bakom en inloggning (engångskod via e-post). Även om någon gissar din URL kan de inte komma åt tjänsten utan att verifiera sin identitet. |
| **Reverse Proxy (NPM)** | En "trafikpolis" som tar emot all inkommande trafik och skickar den vidare till rätt tjänst baserat på vilken adress besökaren angav. T.ex. `ha.domän.se` → Home Assistant, `frigate.domän.se` → Frigate. |
| **MQTT** | Ett lättviktigt meddelandeprotokoll. Frigate skickar meddelanden ("person detekterad vid entre!") via MQTT till Home Assistant, som sedan kan trigga automationer (slå på ljus, skicka notis). |
| **Mosquitto** | Den vanligaste MQTT-servern (brokern). Vi kör den som ett tillägg i Home Assistant. |
| **Docker** | Ett verktyg för att köra program i isolerade "containrar" (inte att förväxla med LXC). Frigate distribueras som en Docker-container som vi kör inuti vår LXC-container. |
| **Docker Compose** | En fil (`docker-compose.yml`) som beskriver hur en Docker-container ska startas — vilka portar, volymer och inställningar den behöver. |
| **DHCP-reservation** | En inställning i din router som garanterar att en specifik enhet alltid får samma IP-adress. Viktigt för servrar som andra tjänster behöver hitta. |
| **Dual Stream** | Att kameran skickar två videoströmmar samtidigt: en högupplöst för inspelning/visning och en lågupplöst för AI-analys. Sparar enormt med CPU/GPU-kraft. |
| **Keyframe / I-frame** | En komplett bild i en videoström. Mellan keyframes skickas bara skillnaderna (för att spara bandbredd). Korta keyframe-intervall = snabbare uppstart av livevy. |
| **TRIM** | Ett kommando som berättar för SSD:n vilka datablock som inte längre används, så den kan städa internt. Förlänger diskens livslängd avsevärt. |
| **udev-regel** | En konfigurationsfil i Linux som automatiskt sätter rättigheter på hårdvaruenheter (som grafikkretsen) varje gång systemet startar. |

## Vanliga frågor (FAQ)

### Behöver jag öppna portar i min router?
**Nej.** Det är hela poängen med Cloudflare Tunnel. Tunneln skapar en utgående anslutning från din server till Cloudflare. All extern trafik går genom den anslutningen. Din router behöver inte veta om det.

### Vad händer om mitt internet går ner?
Home Assistant och Frigate fortsätter att fungera lokalt. Kamerorna spelar in, automationer körs, allt fungerar — du kan bara inte komma åt det utifrån. När internet kommer tillbaka återansluter tunneln automatiskt.

### Vad händer om min hem-IP ändras?
Ingenting. Cloudflare Tunnel bryr sig inte om din IP-adress. Tunneln är en utgående anslutning som identifieras med en token, inte en IP.

### Kan jag lägga till fler tjänster senare?
Absolut. Du har ~15 GB oanvänt RAM och gott om CPU-marginal. Skapa en ny LXC-container i Proxmox, lägg till en Proxy Host i NPM, och den nya tjänsten är nåbar via `nytjänst.domän.se`.

### Hur uppdaterar jag Frigate?
```bash
cd /opt/frigate
docker compose pull    # Ladda ner senaste versionen
docker compose up -d   # Starta om med nya versionen
```
Ta alltid en snapshot innan (`pct snapshot 103 pre-upgrade`).

### Hur mycket ström drar systemet?
En OptiPlex XE4 med SSD och inga mekaniska diskar drar typiskt 15–25W i idle och 30–45W under belastning. Det motsvarar ungefär en LED-lampa — ca 100–200 kr/år i elkostnad.

### Måste jag ha Axis-kameror?
Nej, Frigate stöder alla kameror som kan leverera en RTSP-ström. Axis rekommenderas för sin pålitlighet och enkla API, men Hikvision, Dahua, Reolink och många andra fungerar också. Anpassa RTSP-URL:en i konfigurationen.

### Vad är skillnaden mellan "privileged" och "unprivileged" container?
En **unprivileged** container körs med begränsade rättigheter och är säkrare (om den hackas kan angriparen inte påverka värdmaskinen). Vi använder unprivileged för allt utom om det krävs speciella rättigheter. Frigate behöver iGPU-access men löser det via bind mounts istället för att köra privileged.
