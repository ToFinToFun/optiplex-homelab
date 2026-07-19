# Steg 1: Dell OptiPlex XE4 SFF BIOS-konfiguration

Innan vi installerar operativsystemet måste BIOS ställas in korrekt för att stödja virtualisering, hårdvaru-passthrough, automatisk uppstart efter strömavbrott och headless-drift (utan skärm).

Gör alla ändringar med monitor och tangentbord anslutna till OptiPlexen. Starta datorn och tryck **F2** upprepade gånger vid boot för att komma in i BIOS Setup.

> **Tips:** Från Windows kan du starta om direkt till BIOS genom att öppna CMD/PowerShell som administratör och skriva: `shutdown /r /fw /t 0`

Nedan följer de inställningar som måste ändras från fabriksvärdet (Default) samt de som måste vara aktiverade.

## 1. Storage
- **SATA Operation:** Ändra till **AHCI** *(Default: RAID On)*
- **M.2 PCIe SSD-0/1/2:** Enabled
- **SATA-0, SATA-1, SATA-3:** Enabled

> **Varför AHCI?** Linux och Proxmox kräver AHCI för korrekt diskhantering. RAID On (Intel RST) orsakar problem med diskdetektering och SMART-data.

## 2. Display
- **Multi-Display:** Enabled
- **Full Screen Logo:** Disabled *(Snabbare boot)*

## 3. Connection (Nätverk)
- **Integrated NIC (EmbNic1):** Enabled with PXE
- **UEFI Network Stack:** Enabled
- **WLAN / Bluetooth:** Enabled
- **HTTPs Boot:** Enabled

## 4. Power Management
En server ska alltid vara vaken och starta automatiskt om strömmen går.
- **AC Recovery:** Ändra till **On (Always On)** *(Default: Power Off)*
- **Block Sleep:** Ändra till **Enabled** *(Default: Disabled)*
- **Deep Sleep Control:** Ändra till **Disabled** *(Default: S5Only)*
- **Wake on LAN:** Ändra till **LAN+WLAN** *(Default: Disabled)*
- **USB Wake Support:** Enabled
- **USB PowerShare:** Ändra till **Disabled** *(Default: Enabled)*
- **ASPM:** Ändra till **Disabled** *(Default: Auto)*
- **Intel Speed Shift Technology:** Enabled
- **Fan Control Override:** Disabled

> **Varför Block Sleep och Disabled ASPM?** En server ska aldrig sova. ASPM (Active State Power Management) sparar marginellt med ström men kan orsaka latens-spikar och instabilitet på PCIe-enheter som NVMe-diskar och nätverkskort.

## 5. CPU & Prestanda
- **Intel SpeedStep:** Enabled
- **C-State Control:** Enabled *(CPU-kärnor vilar mellan uppgifter för att spara ström)*
- **Turbo Mode:** Enabled
- **Logical Processor (Hyper-Threading):** Enabled
- **CPU Cores (Active Cores):** All Cores

## 6. Virtualization & PCIe
Dessa inställningar är helt avgörande för att kunna köra virtuella maskiner och ge Frigate direkt tillgång till grafikkretsen.
- **Intel Virtualization (VT-x):** Enabled
- **VT for Direct I/O (VT-d):** Ändra till **Enabled** *(Default: Disabled)*
- **Intel TXT (Trusted Execution):** Disabled
- **PCIe Resizable BAR (ReBAR):** Ändra till **Enabled** *(Default: Disabled)*
- **MMIO Above 4GB:** Enabled

> **Varför VT-d och ReBAR?** VT-d krävs för IOMMU och GPU-passthrough. ReBAR låter processorn mappa hela GPU-minnet på en gång, vilket ger bättre prestanda för AI-detektering.

## 7. DMA-skydd
- **Pre-Boot DMA Support:** Ändra till **Disabled** *(Default: Enabled)*
- **Kernel DMA Protection:** Ändra till **Disabled** *(Default: Enabled)*
- **Internal Port DMA:** Ändra till **Disabled** *(Default: Enabled)*

> **Varför stänga av DMA Protection?** DMA-skydd är en säkerhetsfunktion för Windows. I Linux och Proxmox kan detta störa IOMMU-grupperna och PCIe-enheter vid passthrough, vilket gör att vi inte kan dela ut grafikkretsen till Frigate.

## 8. Security
- **Secure Boot:** Ändra till **Disabled** *(Default: Enabled)*
- **TPM 2.0 Security:** Enabled
- **Intel TME:** Disabled
- **Chassis Intrusion:** Disabled
- **SMM Security Mitigation:** Disabled

> **Varför inaktivera Secure Boot?** Secure Boot förhindrar att osignerade drivrutiner laddas. För att Proxmox ska fungera optimalt med hårdvaru-passthrough behöver vi inaktivera detta.

## 9. USB
- **USB Emulation:** Enabled
- **Front USB / Rear USB:** Enabled

## 10. Boot & Headless-drift
- **Warnings and Errors:** Ändra till **Continue** *(Default: Prompt)*
- **Fast Boot:** Auto
- **Extend BIOS POST Time:** Ändra till **0 seconds** *(Default: 5 seconds)*
- **NumLock LED:** Enabled

> **Varför Warnings and Errors till Continue?** Servern ska INTE stanna vid boot och vänta på att du trycker F1, eftersom den kommer köras "headless" (utan skärm och tangentbord).

## 11. Dell-tjänster (inaktivera alla)
Dessa tjänster är onödiga i ett homelab och potentiella säkerhetsrisker.
- **BIOSConnect:** Ändra till **Disabled** *(Default: Enabled)*
- **Dell Core Service:** Ändra till **Disabled** *(Default: Enabled)*
- **SupportAssist OS Recovery:** Ändra till **Disabled** *(Default: Enabled)*
- **FOTA (Firmware Over The Air):** Ändra till **Disabled** *(Default: Enabled)*
- **Absolute/Computrace:** Ändra till **Disabled** *(Default: Enabled)*

## 12. Update & Recovery
- **Allow BIOS Downgrade:** Enabled
- **Capsule Firmware Update:** Enabled
- **Auto RTC Recovery:** Enabled
- **BIOS Recovery from HDD:** Enabled

---

## Valfritt: Intel AMT (Active Management Technology)
Intel AMT ger remote KVM-åtkomst (tangentbord, video, mus) via webbläsare — inklusive BIOS-access utan fysisk monitor. Värt att aktivera så du aldrig behöver koppla in monitor igen.

1. Starta om maskinen.
2. Tryck **Ctrl+P** vid boot (innan OS laddar) för att komma in i **Intel MEBx**.
3. Default-lösenord är `admin` (du tvingas byta vid första inloggning).
4. Sätt nytt lösenord *(krav: minst 8 tecken, versal + gemen + siffra + specialtecken)*.
5. Gå till **Intel AMT Configuration**.
6. Sätt **Manageability Feature Selection** till **Enabled**.
7. Gå till **Network Setup** → Intel ME Network Name Settings och sätt hostname (t.ex. `optiplex-amt`).
8. Gå till **Network Setup** → TCP/IP Settings → Wired LAN IPV4 Configuration och välj DHCP (eller statisk IP).
9. Aktivera **SOL/IDER** (Serial over LAN / IDE Redirection) — krävs för remote KVM.
10. Gå till **KVM Configuration** → Sätt **User Consent** till **NONE** (annars måste du godkänna på lokal skärm).
11. Spara och starta om.

Du kan nu komma åt servern via `http://<maskinens-IP>:16992` eller använda verktyg som MeshCommander.

---

## Verifiering
När du sparat inställningarna och startar om med USB-stickan i, ska datorn automatiskt visa Proxmox installationsmeny. Om den klagar på "No bootable device" eller startar Windows, gick något fel i Boot Sequence.

## Vanliga problem

| Problem | Lösning |
|---------|---------|
| Hittar inte "VT-d" i BIOS | Leta efter "IOMMU" eller "Intel Virtualization Technology for Directed I/O". Det kan ligga under "Advanced" eller "Security". |
| Datorn startar Windows istället för USB | Tryck F12 upprepade gånger vid uppstart för att få upp en manuell boot-meny och välj USB-stickan därifrån. |
| "Secure Boot Violation" visas vid uppstart | Du glömde stänga av Secure Boot i steg 8. Gå tillbaka in i BIOS och inaktivera det. |

## Nästa steg
Spara inställningarna (Save & Exit). Datorn kommer nu att starta om. Sätt i din USB-sticka med Proxmox för att gå vidare till nästa steg.
