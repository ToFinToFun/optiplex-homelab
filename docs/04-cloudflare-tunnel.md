# Steg 4: Cloudflare Tunnel & Zero Trust

För att komma åt ditt homelab externt på ett säkert sätt använder vi **Cloudflare Tunnel**. Detta innebär att din server skapar en utgående, krypterad anslutning till Cloudflares nätverk. 

**Fördelar:**
- Du behöver **inte** öppna några portar (port forwarding) i din router.
- Du behöver **inte** konfigurera DDNS (Dynamic DNS) för att hantera om din IP-adress hemma ändras.
- All trafik skyddas av Cloudflares brandvägg och Zero Trust-autentisering.

## Förutsättningar
- En egen domän (t.ex. `mindomän.se`).
- Domänen måste vara ansluten till ett gratis Cloudflare-konto (Cloudflare hanterar DNS för domänen).

## 1. Skapa en Tunnel i Cloudflare
1. Logga in på [Cloudflare Zero Trust-panelen](https://one.dash.cloudflare.com).
2. Gå till **Networks** -> **Tunnels**.
3. Klicka på **Create a tunnel**.
4. Välj **Cloudflared** som connector type och klicka Next.
5. Döp tunneln till t.ex. `proxmox-home` och spara.
6. Du får nu upp installationsinstruktioner. Välj fliken **Debian** och kopiera kommandot som visas. Det innehåller din unika tunnel-token (en lång sträng som börjar med `ey...`).
7. **Spara din token i filen `TOKENS.md`** lokalt på din dator.

## 2. Skapa LXC-containern för Cloudflared (CT 101)
Nu ska vi skapa en dedikerad container på Proxmox som enbart kör tunnel-mjukvaran.

1. I Proxmox, klicka på "Create CT" (Create Container) uppe till höger.
2. **General:** 
   - ID: `101`
   - Hostname: `cloudflared`
   - Avbocka "Unprivileged container" (krävs ibland för nätverkstunnlar, men testa med ibockad först om du vill).
   - Ange ett lösenord.
3. **Template:** Välj en Debian 12/13 Standard-mall. (Om du saknar mallar, gå till `local (nodnamn)` -> CT Templates -> Templates och ladda ner Debian).
4. **Disks:** 2 GB räcker gott.
5. **CPU:** 1 core.
6. **Memory:** 256 MB RAM, 0 MB Swap.
7. **Network:** Välj DHCP (vi reserverar IP i routern senare) eller ange en statisk IP.
8. Slutför och starta containern.

## 3. Installera mjukvaran
1. Öppna Console för CT 101 i Proxmox.
2. Logga in med `root` och ditt lösenord.
3. Klistra in kommandot du kopierade från Cloudflare i steg 1. Det ser ungefär ut så här:
   ```bash
   curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && dpkg -i cloudflared.deb && cloudflared service install ey...[DIN-TOKEN]...
   ```
4. Gå tillbaka till Cloudflare-dashboarden. Längst ner på sidan bör det nu stå att en connector är ansluten. Klicka Next.

## 4. Konfigurera Public Hostname (Catch-all till NPM)
I nästa steg ska vi sätta upp Nginx Proxy Manager (NPM). För att koppla ihop tunneln med NPM skapar vi en enda "catch-all" regel i tunneln.

1. I fliken **Public Hostnames** i Cloudflare-tunneln, klicka på **Add a public hostname**.
2. **Subdomain:** Skriv `*` (en asterisk, vilket betyder wildcard).
3. **Domain:** Välj din domän i rullgardinsmenyn.
4. **Service Type:** Välj `HTTP`.
5. **URL:** Ange IP-adressen som NPM-containern kommer att få (t.ex. `192.168.1.102`) följt av port `80`.
   - Exempel: `192.168.1.102:80`
6. Klicka Save.

Nu kommer ALL trafik till `*.mindomän.se` att skickas genom tunneln till NPM. Det är sedan NPM:s jobb att dirigera trafiken till rätt tjänst (Home Assistant, Frigate, etc) baserat på vilken subdomän besökaren angav.

## 5. Konfigurera Zero Trust Access (OTP)
Vi vill att Home Assistant ska vara öppen (den har egen inloggning), men admin-gränssnitt som Frigate och NPM ska skyddas av en PIN-kod som skickas till din e-post.

1. I Cloudflare Zero Trust, gå till **Access** -> **Applications** och klicka **Add an application**.
2. Välj **Self-hosted**.
3. **Application name:** T.ex. "Frigate NVR".
4. **Subdomain:** `frigate`
5. **Domain:** Din domän.
6. Klicka Next.
7. Skapa en policy:
   - **Policy name:** "Allow My Email"
   - **Action:** Allow
   - Under **Include**, välj "Emails" och skriv in din e-postadress.
8. Spara. Upprepa processen för subdomänen `npm`.

När du surfar till `frigate.mindomän.se` kommer Cloudflare nu att kräva din e-postadress och skicka en engångskod innan du släpps fram till ditt nätverk.
