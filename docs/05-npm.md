# Steg 5: Nginx Proxy Manager (NPM)

Nginx Proxy Manager (NPM) agerar som en trafikpolis i ditt nätverk. Den tar emot all trafik som kommer från Cloudflare Tunnel och skickar den vidare till rätt container baserat på subdomänen (t.ex. `ha.domän.se` går till Home Assistant, `frigate.domän.se` går till Frigate).

Vi använder NPM för att det har ett enkelt, klickbaserat webbgränssnitt och stödjer WebSockets (vilket krävs för Home Assistant och Frigates livevy).

## 1. Skapa LXC-containern (CT 102)

1. I Proxmox, klicka på "Create CT".
2. **General:** 
   - ID: `102`
   - Hostname: `npm`
   - Unprivileged container: Ibockad (Ja)
   - Ange lösenord.
3. **Template:** Debian 12/13 Standard.
4. **Disks:** 4 GB.
5. **CPU:** 1 core.
6. **Memory:** 512 MB RAM, 0 MB Swap.
7. **Network:** Ange en statisk IP (t.ex. `192.168.1.102/24` med gateway `192.168.1.1`). Denna IP måste matcha den du angav som "URL" i Cloudflare Tunnel i föregående steg.

## 2. Installera Docker och NPM

> **Varför Docker inuti LXC?** Nginx Proxy Manager (och Frigate) distribueras enklast som Docker-containrar. Genom att köra Docker inuti en LXC-container får vi det bästa av två världar: Proxmox kan hantera containern som en "virtuell maskin" (backups, nätverk), och programmet får exakt den miljö det förväntar sig.

Öppna Console för CT 102, logga in som `root` och kör följande kommandon:

```bash
# Uppdatera systemet och installera beroenden
apt update && apt upgrade -y
apt install -y curl wget gnupg ca-certificates

# Installera Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Skapa mappar för NPM
mkdir -p /opt/npm
cd /opt/npm

# Ladda ner färdig docker-compose.yml från repot
curl -sL https://raw.githubusercontent.com/ToFinToFun/optiplex-homelab/master/configs/docker-compose-npm.yml -o docker-compose.yml

# Starta NPM
docker compose up -d
```

## 3. Första inloggningen

1. Surfa till `http://[NPM-IP]:81` (t.ex. `http://192.168.1.102:81`).
2. Logga in med standarduppgifterna:
   - **Email:** `admin@example.com`
   - **Password:** `changeme`
3. Du kommer omedelbart att uppmanas att byta e-postadress och lösenord. Gör det och spara uppgifterna i din `TOKENS.md`-fil.

## 4. Lägga till tjänster (Proxy Hosts)

För varje tjänst du vill nå utifrån måste du skapa en "Proxy Host" i NPM.

1. Gå till **Hosts** -> **Proxy Hosts** -> **Add Proxy Host**.
2. **Details-fliken:**
   - **Domain Names:** Ange subdomänen, t.ex. `frigate.mindomän.se`
   - **Scheme:** `http`
   - **Forward Hostname/IP:** IP-adressen till containern (t.ex. `192.168.1.103` för Frigate)
   - **Forward Port:** Porten tjänsten lyssnar på (t.ex. `5000` för Frigate, `8123` för HA)
   - **Cache Assets:** Av
   - **Block Common Exploits:** På (För Home Assistant måste denna ibland vara AV)
   - **Websockets Support:** PÅ (Kritiskt för både HA och Frigate!)
3. **SSL-fliken:**
   - Eftersom trafiken mellan Cloudflare och NPM går via tunneln och krypteras där, behöver du **inte** konfigurera SSL-certifikat här för extern åtkomst. Cloudflare hanterar HTTPS mot användaren.
   - **Force SSL:** Måste vara AV. Om du slår på denna skapas en redirect-loop eftersom tunneln pratar HTTP med NPM.
4. Klicka **Save**.

### Tjänster att lägga till:
- `npm.mindomän.se` -> `192.168.1.102` port `81` (Websockets: På)
- `ha.mindomän.se` -> `[HA-IP]` port `8123` (Websockets: På, Block Exploits: Av)
- `frigate.mindomän.se` -> `[Frigate-IP]` port `5000` (Websockets: På)

*(Kom ihåg att NPM och Frigate ska skyddas av Cloudflare Access enligt Steg 4, medan HA lämnas öppen för att mobilappen ska fungera smidigt).*

## Verifiering
1. Surfa till `http://[NPM-IP]:81` lokalt på ditt nätverk — du ska se inloggningsskärmen.
2. Om du har lagt till NPM som en Proxy Host (enligt ovan), prova att surfa till `npm.mindomän.se` från din mobil (på 4G/5G). Du ska först mötas av Cloudflare Access inloggning, och därefter NPM-gränssnittet.

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| `docker compose` ger felmeddelande | Kontrollera att du kör kommandot inuti mappen `/opt/npm` där `docker-compose.yml` ligger. |
| Jag får 502 Bad Gateway via domänen | Dubbelkolla att IP-adressen i NPM:s Proxy Host exakt matchar containerns IP. Kolla också att "Scheme" är satt till HTTP, inte HTTPS. |
| Jag får "Too many redirects" | Gå till SSL-fliken i NPM för din Proxy Host och se till att "Force SSL" är avstängt. Cloudflare hanterar SSL, NPM ska bara prata HTTP. |
