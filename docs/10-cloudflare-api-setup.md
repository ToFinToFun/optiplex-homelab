# Komplett Cloudflare Setup (Loopia → API Token)

För att automationsskriptet (wizarden) ska kunna sätta upp domäner, tunnlar och Zero Trust-skydd åt dig, behöver du ett Cloudflare-konto, en domän som pekar dit, och en API-nyckel.

Denna guide tar dig steg-för-steg från ett tomt Cloudflare-konto till en färdig API-nyckel, med specifika instruktioner för hur du flyttar din domän från **Loopia**.

---

## Steg 1: Skapa Cloudflare-konto och lägg till domän

1. Gå till [Cloudflare.com](https://dash.cloudflare.com/sign-up) och skapa ett gratis konto.
2. När du loggat in, klicka på knappen **"Add a Site"** (eller "Add a domain").
3. Skriv in ditt domännamn (t.ex. `dindoman.se`) och klicka på **Continue**.
4. Scrolla längst ner på nästa sida och välj **Free**-planen (kostar 0 kr/mån). Klicka **Continue**.
5. Cloudflare skannar nu dina befintliga DNS-poster hos Loopia (eller din nuvarande leverantör). 
   - Granska listan för att se att dina gamla poster (om du har några viktiga, t.ex. e-post/MX-poster) kom med.
   - Klicka på **Continue**.

---

## Steg 2: Ändra Namnservrar hos Loopia

Cloudflare kommer nu att ge dig två nya namnservrar (Nameservers). De ser ut ungefär så här:
- `alex.ns.cloudflare.com`
- `betty.ns.cloudflare.com`

För att Cloudflare ska få kontroll över domänen måste du byta till dessa hos Loopia.

1. Logga in på [Loopia Kundzon](https://www.loopia.se/loggain/).
2. Klicka på ditt domännamn i listan över domäner.
3. Scrolla ner och klicka på knappen **"Namnservrar"** (eller "Byt namnservrar").
4. Välj alternativet för att ange **externa namnservrar**.
5. Radera Loopias namnservrar (ns1.loopia.se, ns2.loopia.se) och klistra in de två namnservrarna du fick från Cloudflare.
6. Spara ändringarna.

> **Varför gör vi detta?**
> Genom att byta namnservrar flyttar vi *adressboken* (DNS) för domänen från Loopia till Cloudflare. Du betalar fortfarande årsavgiften för domänen till Loopia, men Cloudflare sköter trafiken. Det tar ofta mellan 10 minuter och några timmar innan ändringen slår igenom på internet.

7. Gå tillbaka till Cloudflare och klicka på **"Check nameservers"**. När Cloudflare upptäcker bytet kommer domänen att stå som **"Active"**. Du kan gå vidare till nästa steg under tiden.

---

## Steg 3: Skapa Zero Trust-konto och Tunnel

Innan vi kan skapa en API-nyckel måste vi aktivera Zero Trust, eftersom vi behöver API-behörigheter för det.

1. I Cloudflare-dashboarden, klicka på **Zero Trust** i vänstermenyn.
2. Första gången du klickar här måste du välja ett "Team name" (kan vara vad som helst, t.ex. ditt efternamn).
3. Välj den **gratis (Free)** Zero Trust-planen. Du måste oftast ange ett betalkort för att verifiera dig, men du kommer inte att debiteras för gratisplanen.
4. När Zero Trust är aktiverat, gå till **Networks -> Tunnels** i vänstermenyn.
5. Klicka på **"Create a tunnel"**.
6. Välj **Cloudflared** och klicka Next.
7. Döp tunneln till något (t.ex. `homelab-tunnel`) och klicka på **Save tunnel**.
8. Du får nu upp en installationsskärm med ett långt kommando (t.ex. `cloudflared service install eyJh...`). 
   - Kopiera hela koden som börjar på `eyJh...` (detta är din **Tunnel Token**).
   - Spara denna token i `setup.env` (eller ha den redo när wizarden frågar).
9. Du behöver inte klicka vidare eller installera något här — wizarden på din Proxmox-server kommer att använda denna token för att koppla upp sig.

---

## Steg 4: Skapa API-nyckel (Token)

För att wizarden ska kunna skapa DNS-poster (ha.domän.se), sätta upp routing till tunneln och aktivera Zero Trust-skydd (inloggning via e-post) behöver den en API-nyckel med exakta behörigheter.

1. Gå till [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (finns under My Profile -> API Tokens).
2. Klicka på **"Create Token"**.
3. Scrolla längst ner och klicka på **"Create Custom Token"** (Get started).
4. Döp token till t.ex. `Homelab Setup Wizard`.
5. Under **Permissions**, lägg till följande tre rader (klicka på "Add more" för att lägga till rader):

   | Kategori | Område | Behörighet |
   |----------|--------|------------|
   | **Zone** | **DNS** | **Edit** |
   | **Account** | **Cloudflare Tunnel** | **Edit** |
   | **Account** | **Access: Apps and Policies** | **Edit** |

6. Under **Account Resources** (strax nedanför):
   - Include -> **ditt kontonamn**
7. Under **Zone Resources**:
   - Include -> Specific zone -> **dindoman.se**
8. Klicka på **Continue to summary** längst ner.
9. Verifiera att sammanfattningen stämmer överens med tabellen ovan och klicka på **Create Token**.
10. Du får nu se din API-nyckel (en lång rad tecken). **Kopiera denna och spara den direkt** (t.ex. i `setup.env`). Du kan aldrig se den igen när du stänger sidan.

---

## Sammanfattning: Vad du behöver till wizarden

När du kör installationsskriptet på din Proxmox-server behöver du ha dessa tre saker redo:

1. **Din domän:** (t.ex. `dindoman.se`) — måste vara "Active" i Cloudflare.
2. **Din Tunnel Token:** (börjar på `eyJh...`) — från Zero Trust -> Tunnels.
3. **Din API Token:** (lång teckensträng) — med behörigheter för DNS, Tunnel och Access.

När du matar in dessa i wizarden sköter den resten automatiskt!
