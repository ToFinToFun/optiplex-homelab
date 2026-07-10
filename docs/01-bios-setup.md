# Steg 1: Dell OptiPlex BIOS-konfiguration

Innan vi installerar operativsystemet måste BIOS ställas in korrekt för att stödja virtualisering, hårdvaru-passthrough och automatisk uppstart efter strömavbrott.

Gör alla ändringar med monitor och tangentbord anslutna till OptiPlexen. Starta datorn och tryck **F2** upprepade gånger vid boot för att komma in i BIOS Setup.

## 1. System Time & Date
Korrekt klocka är kritiskt för HTTPS-certifikat och loggar.
- **Time Format:** 24H
- **Date/Time:** Ställ in dagens datum och aktuell tid.

## 2. Boot Sequence
Säkerställ att datorn kan starta från din USB-sticka när du ska installera Proxmox.
- **Boot Mode:** UEFI
- **Boot Sequence #1:** USB Storage Device
- **Boot Sequence #2:** Internal NVMe/SSD
- **Secure Boot:** Disabled

> **Varför inaktivera Secure Boot?** Secure Boot förhindrar att osignerade drivrutiner laddas. För att Proxmox ska kunna skicka grafikkretsen (iGPU) direkt in i Frigate-containern behöver vi använda drivrutiner som ibland blockeras av Secure Boot.

## 3. Storage
- **SATA Operation:** AHCI *(RAID On fungerar dåligt med Linux)*

## 4. Virtualisering & Säkerhet
Dessa inställningar är helt avgörande för att kunna köra virtuella maskiner och ge Frigate direkt tillgång till grafikkretsen.
- **Intel Virtualization (VT-x):** Enabled
- **VT for Direct I/O (VT-d):** Enabled
- **Intel TXT:** Disabled
- **DMA Protection (Pre-Boot, Kernel, Internal Port):** Disabled
- **TPM 2.0:** Enabled

> **Varför stänga av DMA Protection?** DMA (Direct Memory Access) Protection är en säkerhetsfunktion för Windows som förhindrar att externa enheter läser minnet. I Linux och Proxmox kan detta störa IOMMU-grupperna, vilket gör att vi inte kan dela ut grafikkretsen till Frigate.

## 5. Ström & Sleep
En server ska alltid vara vaken och starta automatiskt om strömmen går.
- **Block Sleep:** Enabled *(Förhindrar att servern går i viloläge)*
- **Deep Sleep Control:** Disabled
- **AC Recovery:** Last State *(Servern startar automatiskt efter ett strömavbrott)*
- **ASPM:** Disabled *(Undviker latensspikar på PCIe-enheter)*

## 6. CPU & Prestanda
- **Intel Speed Shift Technology:** Enabled
- **Intel SpeedStep:** Enabled
- **C-State Control:** Enabled *(Låter processorn vila mellan uppgifter för att spara ström)*

## 7. Nätverk
- **UEFI Network Stack:** Enabled
- **Wake on LAN:** LAN Only *(Tillåter fjärrstart av servern via nätverket)*

## 8. PCIe & Grafik
Dessa inställningar maximerar prestandan för AI-detektering i Frigate.
- **PCIe Resizable BAR (ReBAR):** Enabled
- **DVMT Pre-Allocated:** 512 MB *(Ger grafikkretsen en stor startbuffert för OpenVINO)*
*(Notera: Om DVMT saknas i din BIOS-version, hoppa över den. Linux löser det dynamiskt).*

## 9. Boot-hastighet
- **Warning on Error:** Disabled *(Servern ska inte stanna och vänta på att du trycker F1)*
- **Fast Boot:** Minimal

## Verifiering
När du sparat inställningarna och startar om med USB-stickan i, ska datorn automatiskt visa Proxmox installationsmeny. Om den klagar på "No bootable device" eller startar Windows, gick något fel i Boot Sequence.

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| Hittar inte "VT-d" i BIOS | Leta efter "IOMMU" eller "Intel Virtualization Technology for Directed I/O". Det kan ligga under "Advanced" eller "Security". |
| Datorn startar Windows istället för USB | Tryck F12 upprepade gånger vid uppstart för att få upp en manuell boot-meny och välj USB-stickan därifrån. |
| "Secure Boot Violation" visas vid uppstart | Du glömde stänga av Secure Boot i steg 2. Gå tillbaka in i BIOS och inaktivera det. |

## Nästa steg
Spara inställningarna (Save & Exit). Datorn kommer nu att starta om. Sätt i din USB-sticka med Proxmox för att gå vidare till nästa steg.
