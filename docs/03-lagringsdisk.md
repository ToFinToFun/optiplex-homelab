# Steg 3: Dedikerad lagringsdisk för Frigate

Att spela in kontinuerlig video från flera kameror sliter hårt på lagringsmedia. Om du sparar videoinspelningarna på samma SSD som Proxmox är installerat på, riskerar du att slita ut disken i förtid, vilket kan krascha hela systemet.

Lösningen är att använda en dedikerad disk enbart för Frigates inspelningar.

## Val av disk
- **HDD (Mekanisk hårddisk):** Traditionellt det bästa valet för NVR (Network Video Recorder). Diskar som WD Purple eller Seagate SkyHawk är byggda för kontinuerlig skrivning 24/7. De är billigare per gigabyte, men låter mer och drar något mer ström.
- **SSD:** Blir allt vanligare i hemmamiljöer då de är helt tysta och strömsnåla. Om du väljer en SSD för Frigate, välj en modell med högt TBW-värde (Terabytes Written) avsedd för NAS eller tung arbetsbelastning. Undvik de allra billigaste konsument-SSD:erna.

> **Varför en dedikerad disk?** Om OS-disken går sönder kraschar hela servern och du måste installera om allt. Om Frigate-disken går sönder förlorar du bara gamla videoinspelningar (vilket sällan är en katastrof), och servern fortsätter fungera.

## Montera disken i Proxmox

När du har installerat den extra disken fysiskt i din OptiPlex och startat servern, behöver vi formatera den och göra den tillgänglig för Frigate.

### 1. Identifiera disken
Öppna Proxmox webbgränssnitt, klicka på din nod i vänstermenyn och gå till **Disks**.
Leta upp din nya disk i listan (ofta `/dev/sdb` eller `/dev/nvme1n1`) och notera namnet.

### 2. Formatera med ext4
Istället för att skapa LVM (som används för virtuella maskiner), formaterar vi disken som en traditionell mapp (Directory) med ext4-filsystem. Detta gör det extremt enkelt att mappa in den i en LXC-container.

> **Varför ext4 istället för ZFS?** ZFS är fantastiskt men kräver mycket RAM och drar extra processorkraft. För en ensam videodisk är det klassiska ext4-filsystemet snabbare, enklare och mer resurseffektivt.

1. I vänstermenyn under din nod, gå till **Disks** -> **Directory**.
2. Klicka på **Create: Directory**.
3. **Disk:** Välj din nya disk från rullgardinsmenyn.
4. **Filesystem:** Välj `ext4`.
5. **Name:** Döp den till något tydligt, t.ex. `frigate-storage`.
6. Klicka på **Create**.

Proxmox kommer nu att formatera disken och montera den under `/mnt/pve/frigate-storage`.

### 3. Förbered för LXC-containern
När vi senare skapar LXC-containern för Frigate, kommer vi att berätta för Proxmox att "binda" denna mapp in i containern. Detta gör att containern kan skriva videofiler direkt till den fysiska disken med noll prestandaförlust.

## Verifiering
1. Gå till din nod i vänstermenyn och titta under "Storage". Du bör se `frigate-storage` i listan med en ikon som ser ut som en mapp.
2. Klicka på `frigate-storage` och välj "Summary". Du ska se hur mycket plats som finns tillgänglig.

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| Disken syns inte i Proxmox | Kontrollera att kablarna (SATA och ström) sitter i ordentligt i OptiPlexen. |
| Kan inte klicka "Create" när jag formaterar | Disken kan innehålla gamla partitioner. Gå till din nod -> Disks, klicka på disken och välj "Wipe Disk" först. |
| Jag råkade formatera OS-disken! | Det går (förhoppningsvis) inte eftersom Proxmox skyddar disken den är installerad på. Men dubbelkolla alltid diskstorleken så du väljer rätt! |

Du är nu redo att gå vidare och sätta upp nätverksinfrastrukturen.
