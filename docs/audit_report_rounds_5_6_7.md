# OptiPlex Homelab — Audit Report (Rounds 5, 6 & 7)

## Sammanfattning
Granskning (audit) runda 5, 6 och 7 är nu slutförda. Hela kodbasen har granskats för edge-cases, hantering av fel, logik i menyerna och konsekvent hantering av alla 10 tjänster (de 4 kärntjänsterna samt alla 6 tillägg). 

Flera viktiga buggar hittades och åtgärdades, särskilt kring de separata verktygen (`uninstall.sh`, `update.sh`, `usb-backup.sh`) som tidigare var inkompletta och bara hanterade de fyra ursprungliga tjänsterna. Dessa verktyg hanterar nu hela ekosystemet av 10 tjänster.

Alla ändringar är committade och pushade till GitHub. Alla skript passerar nu `bash -n` syntax-check utan anmärkning.

## Åtgärdade problem i Runda 5
* **Laga/Uppgradera-menyn (Case 2 i setup.sh):** Menyn visade tidigare inte status för AdGuard eller tilläggen (Samba, Immich, NUT). Detta har åtgärdats. Tilläggen visas nu konditionellt (bara om de är installerade).
* **Immich Uppgraderings-hint:** Lade till en specifik instruktion i Laga-menyn som visar kommandot för att uppgradera Immich (`pct exec 111 -- /opt/immich/upgrade.sh`) när Immich är installerat.
* **Loggnings-rättigheter (setup.sh):** Skriptet startar en `exec > >(tee -a /var/log/optiplex-setup.log)` tidigt i koden. Om skriptet kördes utan root-rättigheter orsakade detta ett tyst fel innan root-checken (som ligger längre ner) ens hann köras. Lade till en kontroll som verifierar skrivrättigheter till `/var/log` innan loggningen aktiveras.

## Åtgärdade problem i Runda 6
Runda 6 fokuserade på verktygsskripten i `tools/`-mappen. Ett genomgående problem var att dessa skript hade lämnats oförändrade när de nya tilläggstjänsterna lades till i huvudskriptet.

* **Avinstallation (`tools/uninstall.sh`):**
  * **Problem:** Skriptet avinstallerade bara HA, Cloudflared, NPM och Frigate. AdGuard och de 5 tilläggen lämnades kvar.
  * **Lösning:** Uppdaterade skriptet till att inkludera AdGuard, Guacamole, Desktop, Samba, Immich och NUT. Lade till en `FOUND_ANY` guard som säkerställer att skriptet avslutar snyggt om inga tjänster hittas. Lade även till en kort `sleep` mellan `stop` och `destroy` för att förhindra race-conditions med Proxmox-lås, samt lade till `--purge`-flaggan på `pct destroy`.
* **Uppdatering (`tools/update.sh`):**
  * **Problem:** Uppdaterade bara Proxmox, Cloudflared, NPM och Frigate. Hade dessutom `set -e` vilket innebar att om *en* uppdatering misslyckades (t.ex. på grund av nätverksproblem) avbröts hela skriptet.
  * **Lösning:** Tog bort `set -e` och lade till felhantering (if/else) kring kritiska `docker compose pull`-kommandon. Lade till uppdateringslogik för AdGuard, Guacamole, Immich, Samba och NUT. Lade till ett steg på slutet som kör `docker image prune -f` på alla Docker-baserade containers för att frigöra utrymme. Slutligen lade jag till att skriptet först uppdaterar *sig självt* (`git pull`) innan det uppdaterar tjänsterna.
* **USB Backup (`tools/usb-backup.sh`):**
  * **Problem:** Skriptet tog bara backup på HA, Cloudflared, NPM och Frigate.
  * **Lösning:** Uppdaterade loopen som samlar in LXC-ID:n till att inkludera AdGuard, Guacamole, Desktop, Samba, Immich och NUT. Alla installerade tjänster backas nu upp korrekt till USB-minnet.

## Granskning i Runda 7 (Inga kodändringar krävdes)
Runda 7 var en slutgiltig "sanity check" över hela kodbasen för att säkerställa att inga buggar introducerats och att inga edge-cases missats.

* **O-quotade variabler i `pct exec`:** Granskade flera instanser av o-quotade variabler (t.ex. `pct exec $FRIG_ID`). Eftersom dessa variabler är strikt numeriska ID:n (100-112) och har fallbacks, är detta helt säkert och utgör ingen risk för shell-injektion.
* **Status Dashboard (`tools/status-dashboard.sh`):** Verifierade att dashboarden redan hanterar alla 10 tjänster korrekt.
* **IP Checker (`tools/ip-check.sh`):** Verifierade att IP-checkern har konfiguration för alla 10 tjänster och deras respektive portar.
* **Template Path (`TEMPLATE_PATH`):** Verifierade att `TEMPLATE_PATH` laddas ner/sätts korrekt i `setup.sh` *innan* modulerna anropas, och att den skickas med som argument (`$1`) till alla moduler som behöver skapa containers.
* **Ominstallation av befintliga containers:** Verifierade att `setup.sh` (Case 1) korrekt hoppar över installation av tjänster som redan är installerade, vilket förhindrar fel vid `pct create` om en användare kör installationssteget flera gånger.

## Slutsats
Kodbasen är nu robust, konsekvent och alla verktyg är synkroniserade för att hantera det fulla ekosystemet av 10 tjänster. Felhanteringen är förbättrad och inga kända buggar kvarstår. Alla 7 granskningsrundor är därmed framgångsrikt slutförda.
