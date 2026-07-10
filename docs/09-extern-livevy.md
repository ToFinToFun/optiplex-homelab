# Steg 9: Extern Livevy i Frigate

När du tittar på kamerorna i Frigates webbgränssnitt eller via Home Assistant, vill du ha så lite fördröjning (latens) som möjligt.

Frigate (och den inbyggda streamingmotorn `go2rtc`) stöder flera olika streamingtekniker. När du är hemma på ditt eget nätverk fungerar de flesta tekniker felfritt. Utmaningen uppstår när du är utanför hemmet och trafiken måste gå genom Cloudflare Tunnel.

## Streamingtekniker

1. **WebRTC:** Ger lägst latens (under 0,5 sekunder). Problemet är att WebRTC bygger på UDP-trafik, medan Cloudflare Tunnel enbart hanterar TCP/HTTP-trafik. För att WebRTC ska fungera externt måste du antingen öppna en port i din router (vilket vi vill undvika) eller sätta upp en separat TURN-server på en VPS.
2. **MSE (Media Source Extensions):** Ger något högre latens (ca 1-2 sekunder) men bygger på WebSockets (TCP/HTTP). **Detta fungerar perfekt rakt genom Cloudflare Tunnel** utan att du behöver öppna några portar eller sätta upp extra servrar.
3. **JSMpeg:** Den äldsta tekniken. Drar mycket prestanda och rekommenderas inte.

## Konfiguration för MSE (Rekommenderas)

Som standard är Frigate (från version 0.14 och framåt) väldigt smart. Den försöker först använda WebRTC. Om det misslyckas (vilket det kommer göra när du är utanför hemmet via tunneln), faller den automatiskt och blixtsnabbt tillbaka på MSE.

För att detta ska fungera måste vi säkerställa att WebSockets är tillåtet i Nginx Proxy Manager (NPM).

1. Gå in i NPM (`http://[NPM-IP]:81`).
2. Redigera din Proxy Host för `frigate.mindomän.se`.
3. Säkerställ att **Websockets Support** är **PÅ**.
4. Gör samma sak för din Proxy Host för `ha.mindomän.se`.

Du behöver inte göra några fler inställningar i Frigate. När du surfar in på din Frigate-adress externt, kommer videon att laddas via MSE med minimal fördröjning.

## Tillval: WebRTC via TURN-server

Om du upplever att MSE har för hög fördröjning och du absolut vill ha WebRTC även utanför hemmet, är den säkraste lösningen att använda en TURN-server. En TURN-server agerar som en relästation på internet (t.ex. på en billig VPS) som skickar vidare UDP-videotrafiken till din telefon.

*(Notera: Om du känner någon som redan har en TURN-server, t.ex. en vän med ett liknande homelab, kan de enkelt skapa en extra användare åt dig på sin server).*

Om du får tillgång till en TURN-server, lägger du till den i din `config/config.yml` i Frigate:

```yaml
go2rtc:
  webrtc:
    candidates:
      - 192.168.1.103:8555 # Din lokala Frigate-IP (för när du är hemma)
      - stun:8555
    ice_servers:
      - urls: [stun:stun.l.google.com:19302]
      - urls: [turn:turn.derasdomän.se:3478]
        username: ditt_turn_användarnamn
        credential: ditt_turn_lösenord
```

Starta om Frigate. Nu kommer systemet att använda TURN-servern för att leverera blixtsnabb WebRTC-video även när du är på 4G/5G, helt utan att du behöver öppna några portar i din hemma-router.
