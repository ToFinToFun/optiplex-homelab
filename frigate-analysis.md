# Analys av Jerrys Frigate config.yml

## Vad som är IDENTISKT oavsett installation (bas-template):

### Globala inställningar
- `auth.session_length: 15552000`
- `tls.enabled: false`
- `detectors`: 2x OpenVINO GPU (ov_0, ov_1) — samma iGPU
- `model`: yolov9c_openvino, 320x320, nchw, float
- `semantic_search.enabled: true`, model_size: large
- `ffmpeg.path: '5.0'`, hwaccel_args: preset-vaapi
- `objects.track`: person, bicycle, car, motorcycle, bus, truck, cat, dog, horse, boat
- `objects.filters`: alla med min_score 0.5/threshold 0.7 (boat 0.3/0.5)
- `detect.stationary`: interval 50, threshold 20
- `detect.max_disappeared: 750`
- `motion`: threshold 25, contour_area 10, improve_contrast true
- `record`: continuous 0d, motion 0d, alerts 5/5/30d, detections 5/5/7d
- `snapshots`: enabled, retain 30d
- `ui.time_format: 24hour`
- `face_recognition`: enabled, large, min_area 500, threshold 0.8
- `lpr`: enabled, format ^[A-Z]{3} [0-9]{2}[A-Z0-9]$
- `classification.bird.enabled: true`
- `review.genai`: enabled, alerts true, detections false
- `version: 0.18-0`

### GenAI (valfritt — kräver API-nyckel)
- `genai.gemini`: provider gemini, model gemini-3.1-flash-lite
- `objects.genai.enabled: true`

## Vad som är DYNAMISKT (per installation):

### Credentials (frågas interaktivt)
- `genai.gemini.api_key` → FRIGATE_GEMINI_API_KEY
- `mqtt.password` → FRIGATE_MQTT_PASSWORD  
- `mqtt.host` → IP till MQTT-broker (vanligtvis HA)
- RTSP-lösenord → FRIGATE_RTSP_PASSWORD (samma för alla kameror)
- `go2rtc.webrtc.candidates` → Frigate-containerns IP

### Kameror (genereras baserat på antal + namn)
- go2rtc streams (main + sub per kamera)
- cameras block (ffmpeg inputs, detect-storlek, fps)
- Zoner, masker → TOMMA (användaren konfigurerar i Frigate UI)
- camera_groups → genereras baserat på kameranamn

### Saker som INTE passar i template:
- Specifika motion masks (koordinater unika per vy)
- Specifika zones (koordinater unika per vy)
- semantic_search triggers (unika per installation)
- classification.custom (Garagedörr, Entredörr — crop-koordinater)
- lpr.known_plates (personligt)
- TURN-server config (vi skippar VPS/TURN)

## Design-beslut:

1. **Bas-template** med alla globala inställningar hårdkodade
2. **Kameror**: Fråga antal, namn, IP, typ (single/multi-channel)
3. **Credentials**: Fråga RTSP user/pass, MQTT, Gemini API-nyckel (valfritt)
4. **go2rtc**: Generera automatiskt baserat på kameror
5. **Zones/masks**: Lämna tomma med kommentar "Konfigurera i Frigate UI"
6. **camera_groups**: Generera en "Alla"-grupp + låt användaren skapa egna
7. **TURN**: Skippa (MSE via tunnel räcker)
8. **Kommentarer**: Rikligt med # per sektion för enkel aktivering/deaktivering
