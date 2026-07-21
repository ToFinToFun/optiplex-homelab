# Steg 7: Axis Kamerakonfiguration

> **Varför Dual Streams?** AI-modellen (YOLOv9) analyserar bilder i låg upplösning (typiskt 320x320 eller 640x640). Om du skickar in en 4K-videoström till detektorn måste processorn skala ner varje enskild bildruta innan AI:n kan titta på den. Det drar enormt mycket processorkraft helt i onödan. Genom att låta kameran skicka en lågupplöst ström för AI och en högupplöst för inspelning sparar vi upp till 80% CPU.

För att Frigate ska prestera optimalt och inte överbelasta servern, skickar vi aldrig in kamerans högupplösta huvudström till AI-detektorn. Istället konfigurerar vi kameran att skicka två separata strömmar:

1. **Detect Stream:** Lågupplöst (t.ex. 640x480 eller 720p) med 5 bilder per sekund (FPS). Används enbart av AI:n.
2. **Main/Record Stream:** Högupplöst (t.ex. 5MP) med 15-20 FPS. Används för livevy och sparas till disken när rörelse upptäcks.

## 1. Konfigurera kameran (via Axis webbgränssnitt)

Logga in på din Axis-kamera via dess IP-adress i webbläsaren.

### 1.1 Skapa RTSP-användare

Gå till **System** -> **Users** och skapa en ny användare:

| Fält | Värde |
|------|-------|
| Användarnamn | `frigate` (eller det du valde i setup-wizarden) |
| Lösenord | Samma som du angav som gemensamt lösenord |
| Roll | **Viewer** (behöver bara läsa video, inte ändra inställningar) |

> **Tips:** Använd samma användare och lösenord på alla kameror — då räcker en enda credential i Frigate-configen.

### 1.2 Skapa stream-profiler

1. Gå till **Video** -> **Stream Profiles**.
2. Skapa en profil som heter `main` (inspelning + livevy):
   - **Codec:** H.265 (HEVC) — halverar lagringsbehov jämfört med H.264
   - **Resolution:** Max upplösning (t.ex. 2592×1944 för 5MP)
   - **Frame rate:** 15 fps
   - **Compression:** 30
   - **GOV length / I-frame interval:** 15 (= samma som framerate)
3. Skapa en profil som heter `detect` (AI-detektering):
   - **Codec:** H.265
   - **Resolution:** 1280×960 (4:3) eller 1280×720 (16:9)
   - **Frame rate:** 5 fps
   - **Compression:** 30
   - **GOV length / I-frame interval:** 5

*(Om du har många kameror kan du använda skriptet `scripts/axis-create-stream-profiles.sh` i detta repo för att automatisera processen via Axis API).*

## 2. Lägg till kameran i Frigate

Öppna din `config/config.yml` i Frigate-containern och lägg till din kamera. Vi använder Frigates inbyggda `go2rtc` för att hämta strömmarna från kameran en enda gång, vilket sparar nätverksbandbredd.

```yaml
# Lägg till detta under mqtt/detectors-sektionerna i din config.yml

go2rtc:
  streams:
    # Byt ut IP och lösenord mot dina egna
    kamera1_main:
      - rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.1.50/axis-media/media.amp?streamprofile=main&videocodec=h265&audio=1
    kamera1_detect:
      - rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.1.50/axis-media/media.amp?streamprofile=detect&videocodec=h265

cameras:
  kamera1:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/kamera1_main
          input_args: preset-rtsp-restream
          roles:
            - record
        - path: rtsp://127.0.0.1:8554/kamera1_detect
          input_args: preset-rtsp-restream
          roles:
            - detect
    detect:
      width: 1280  # Måste matcha upplösningen du satte i Axis-profilen
      height: 960  # 4:3 — ändra till 720 om du valde 1280x720
      fps: 5
    objects:
      track:
        - person
        - car
        - bicycle
    record:
      enabled: true
      retain:
        days: 7
        mode: motion
      events:
        retain:
          default: 14
          mode: motion
```

Starta om Frigate för att tillämpa ändringarna:
```bash
docker compose restart
```

Gå in i Frigates webbgränssnitt. Du bör nu se din kamera under "Cameras", och om du går framför den bör AI:n markera dig med en ruta. Inspelningar sparas nu på din dedikerade lagringsdisk.

## Verifiering
1. I Frigates webbgränssnitt, klicka på en kamera. Du bör se live-videon (detta är main-strömmen).
2. Klicka på "Debug" i övre menyn. Här ser du "detect"-strömmen. Rör dig framför kameran — du ska se en grön ruta runt dig med texten "person" och en procentsats.
3. Titta på System-fliken i Frigate. CPU-användningen bör vara låg (under 20-30% även med flera kameror).

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| Videon hackar eller buffrar ofta | Kamerans keyframe-intervall (GOV) är förmodligen för långt. Ändra det till samma siffra som FPS (t.ex. FPS 10 = GOV 10). |
| Frigate hittar inga personer alls | Dubbelkolla att "detect" är aktiverat för kameran i `config.yml` och att masken (om du ritat en) inte täcker hela bilden. |
| Skriptet ger "Authentication failed" | Vissa äldre Axis-kameror använder Basic Auth istället för Digest. Prova att ändra `--digest` till `--basic` i skriptet, eller skapa ett nytt användarkonto i kameran. |
