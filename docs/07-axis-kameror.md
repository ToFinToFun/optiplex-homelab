# Steg 7: Axis Kamerakonfiguration

För att Frigate ska prestera optimalt och inte överbelasta servern, skickar vi aldrig in kamerans högupplösta huvudström till AI-detektorn. Istället konfigurerar vi kameran att skicka två separata strömmar:

1. **Detect Stream:** Lågupplöst (t.ex. 640x480 eller 720p) med 5 bilder per sekund (FPS). Används enbart av AI:n.
2. **Main/Record Stream:** Högupplöst (t.ex. 5MP) med 15-20 FPS. Används för livevy och sparas till disken när rörelse upptäcks.

## 1. Konfigurera kameran (via Axis webbgränssnitt)

Logga in på din Axis-kamera via dess IP-adress i webbläsaren.

1. Gå till **Video** -> **Stream Profiles**.
2. Skapa en profil som heter `main`:
   - **Resolution:** Max upplösning (t.ex. 2592x1944).
   - **Frame rate:** 15 eller 20 fps.
   - **Compression:** H.264 (undvik Zipstream eller "smart codecs" då de tar bort viktiga keyframes).
   - **GOV length / I-frame interval:** Samma som din framerate (t.ex. 15 eller 20).
3. Skapa en profil som heter `detect`:
   - **Resolution:** 640x480 (eller 1280x720 om kameran täcker en stor yta).
   - **Frame rate:** 5 fps.
   - **Compression:** H.264.
   - **GOV length / I-frame interval:** 5.

*(Om du har många kameror kan du använda skriptet `scripts/axis-create-stream-profiles.sh` i detta repo för att automatisera processen via Axis API).*

## 2. Lägg till kameran i Frigate

Öppna din `config/config.yml` i Frigate-containern och lägg till din kamera. Vi använder Frigates inbyggda `go2rtc` för att hämta strömmarna från kameran en enda gång, vilket sparar nätverksbandbredd.

```yaml
# Lägg till detta under mqtt/detectors-sektionerna i din config.yml

go2rtc:
  streams:
    # Byt ut IP och lösenord mot dina egna
    kamera1_main:
      - rtsp://root:{FRIGATE_RTSP_PASSWORD}@192.168.1.50/axis-media/media.amp?streamprofile=main
    kamera1_detect:
      - rtsp://root:{FRIGATE_RTSP_PASSWORD}@192.168.1.50/axis-media/media.amp?streamprofile=detect

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
      width: 640  # Måste matcha upplösningen du satte i Axis-profilen
      height: 480 # Måste matcha upplösningen du satte i Axis-profilen
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
