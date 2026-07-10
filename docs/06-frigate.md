# Steg 6: Frigate NVR (LXC med iGPU)

Frigate är en AI-driven nätverksvideoinspelare (NVR). Genom att köra Frigate i en LXC-container och skicka in OptiPlexens inbyggda grafikkrets (iGPU) kan vi utföra extremt resurseffektiv objekt- och persondetektering (OpenVINO) utan att behöva en separat Google Coral-accelerator.

## 1. Skapa LXC-containern (CT 103)

> **Varför LXC istället för VM för Frigate?** En virtuell maskin lägger till ett helt eget operativsystem mellan Frigate och hårdvaran, vilket gör det komplicerat och prestandakrävande att skicka in grafikkretsen (iGPU). I en LXC-container delas kärnan med Proxmox, vilket gör att Frigate kan använda iGPU:n med noll prestandaförlust genom enkla "bind mounts".

Vi skapar containern via kommandoraden (Shell i Proxmox-noden) eftersom vi behöver lägga till specifika rättigheter för grafikkretsen och lagringsdisken.

1. Öppna **Shell** för din Proxmox-nod.
2. Kör följande kommando (byt ut `192.168.1.103` mot din valda Frigate-IP, och `192.168.1.1` mot din router-IP):

```bash
pct create 103 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
  --hostname frigate \
  --memory 6144 \
  --swap 0 \
  --cores 4 \
  --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.103/24,gw=192.168.1.1 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1
```
*(Observera: Om du använder Debian 13/Trixie, ändra filnamnet i kommandot ovan till motsvarande mall).*

## 2. Konfigurera iGPU Passthrough och Lagring

Vi måste redigera containerns konfigurationsfil för att ge den tillgång till grafikkretsen och den dedikerade lagringsdisken vi skapade i Steg 3.

1. I Proxmox Shell, redigera filen:
   ```bash
   nano /etc/pve/lxc/103.conf
   ```
2. Lägg till följande rader längst ner i filen:
   ```text
   # iGPU passthrough för Intel UHD
   lxc.cdev.allow: c 226:0 rwm
   lxc.cdev.allow: c 226:128 rwm
   lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
   lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
   
   # Montera den dedikerade Frigate-disken
   mp0: /mnt/pve/frigate-storage,mp=/media/frigate
   ```
3. Spara (`Ctrl+O`, `Enter`) och stäng (`Ctrl+X`).

För att den obepriviligierade containern ska få läsa från grafikkretsen måste vi sätta rättigheter på värdmaskinen. Kör:
```bash
chmod 666 /dev/dri/renderD128
```
*(Tips: För att detta ska överleva en omstart av Proxmox-servern, lägg till kommandot i `/etc/rc.local` eller skapa en udev-regel).*

## 3. Installera Docker inuti containern

1. Starta containern (CT 103) i Proxmox GUI och öppna dess **Console**.
2. Logga in som `root`.
3. Installera Docker och VAAPI-drivrutiner:

```bash
apt update && apt upgrade -y
apt install -y curl wget gnupg ca-certificates vainfo intel-media-va-driver-non-free

# Verifiera att grafikkretsen syns
vainfo
# (Du bör se output om VA-API version och Intel iHD driver)

# Installera Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## 4. Konfigurera Frigate

1. Skapa mappar för Frigates konfiguration:
   ```bash
   mkdir -p /opt/frigate/config
   cd /opt/frigate
   ```

2. Skapa `docker-compose.yml`:
   ```bash
   nano docker-compose.yml
   ```
   Klistra in:
   ```yaml
   services:
     frigate:
       container_name: frigate
       image: ghcr.io/blakeblackshear/frigate:stable
       restart: unless-stopped
       privileged: false
       network_mode: host
       cap_add:
         - CAP_PERFMON  # Krävs för GPU-statistik i UI
       shm_size: "1gb"
       volumes:
         - /opt/frigate/config:/config
         - /media/frigate:/media/frigate
         - /dev/dri:/dev/dri
         - type: tmpfs
           target: /tmp/cache
           tmpfs:
             size: 1000000000
       environment:
         - FRIGATE_RTSP_PASSWORD=ditt_kamera_losenord
         - FRIGATE_MQTT_PASSWORD=ditt_mqtt_losenord
   ```
   *(Byt ut lösenorden ovan, eller använd en `.env`-fil. Om ditt lösenord innehåller specialtecken som `#`, måste det URL-encodas till `%23` i konfigurationsfilen senare).*

3. Skapa grundkonfigurationen `config/config.yml`. Vi börjar med en extremt grundläggande konfiguration för att verifiera att AI:n startar. Mer detaljer om kameror finns i Steg 7.
   ```bash
   nano config/config.yml
   ```
   Klistra in:
   ```yaml
   mqtt:
     enabled: false # Vi slår på detta senare när HA är installerat

   detectors:
     ov_0:
       type: onnx
       device: GPU

   model:
     model_type: yolo-generic
     width: 320
     height: 320
     input_tensor: nchw
     input_dtype: float
     path: /config/model_cache/yolov9s.onnx
     labelmap_path: /labelmap/coco-80.txt

   ffmpeg:
     hwaccel_args: preset-vaapi

   cameras:
     # Kameror läggs till här i nästa steg
   ```

4. Starta Frigate:
   ```bash
   docker compose up -d
   ```

5. Starta Frigate:
   ```bash
   docker compose up -d
   ```

## Verifiering
1. Surfa till `http://[Frigate-IP]:5000`. Första gången du loggar in genererar Frigate ett slumpmässigt admin-lösenord som visas i terminalen/loggen. Läs loggen med:
   ```bash
   docker logs frigate | grep password
   ```
   Logga in i webbgränssnittet och byt lösenord omedelbart.
2. Gå till "System" i vänstermenyn. Under GPU ska du se din Intel-grafikkrets, och under Detectors ska du se `ov_0` (OpenVINO).

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| `vainfo` ger felmeddelande inuti containern | Dubbelkolla att du körde `chmod 666 /dev/dri/renderD128` på Proxmox-värden (inte inuti containern). Kolla också att raderna finns i `/etc/pve/lxc/103.conf`. |
| Frigate startar om hela tiden | Läs loggen med `docker logs frigate`. Oftast beror det på ett stavfel i `config.yml` (t.ex. fel indragning/indentering). |
| Frigate klagar på "No EdgeTPU detected" | Du har förmodligen glömt att ändra `detectors` till OpenVINO i `config.yml`. Frigate letar som standard efter en Google Coral. |
