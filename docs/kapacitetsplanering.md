# Kapacitetsplanering

Denna sida hjälper dig förstå vad din OptiPlex XE4 med 32 GB RAM klarar av, och hur du bör fördela resurserna mellan tjänsterna.

## Hårdvaruöversikt

| Komponent | Specifikation | Kommentar |
|-----------|---------------|-----------|
| **CPU** | Intel i5-12500T (6C/12T, 2.0–4.4 GHz) | "T"-varianten är energieffektiv (35W TDP) |
| **iGPU** | Intel UHD 770 | Används för VAAPI (videoavkodning) + OpenVINO (AI) |
| **RAM** | 32 GB DDR4 Dual Channel | Dual channel ger ~2× minnesbandbredd |
| **OS-disk** | NVMe SSD | Proxmox + containrar |
| **Frigate-disk** | Dedikerad SSD | Kontinuerlig videoinspelning |

## RAM-fördelning

Tabellen nedan visar rekommenderad RAM-allokering. Proxmox själv använder ca 1-2 GB.

| Tjänst | Allokerat | Faktisk användning | Kommentar |
|--------|-----------|-------------------|-----------|
| VM 100 — Home Assistant | 6 GB | 1–4 GB | HAOS + Add-ons (Mosquitto, ev. fler) |
| CT 101 — cloudflared | 256 MB | ~50 MB | Extremt lättviktig |
| CT 102 — NPM | 512 MB | ~100 MB | Nginx + Node.js |
| CT 103 — Frigate | 8 GB | 3–7 GB | Beror på antal kameror |
| Proxmox host | ~2 GB | 1–2 GB | Kernel + ZFS/LVM cache |
| **Totalt allokerat** | **~17 GB** | | **15 GB marginal** |

> **Varför så stor marginal?** Linux använder oanvänt RAM som disk-cache, vilket gör att Frigate-inspelningar skrivs snabbare. Dessutom ger marginalen utrymme att lägga till fler tjänster i framtiden utan att behöva uppgradera.

## Frigate: Kameror vs. Resurser

Baserat på erfarenhet från ett identiskt system som kör 16 Axis-kameror med OpenVINO (YOLOv9) på iGPU:

| Antal kameror | RAM (Frigate) | CPU-last (snitt) | iGPU-last | Kommentar |
|---------------|---------------|------------------|-----------|-----------|
| 1–4 | 2–3 GB | 5–10% | 10–20% | Mycket god marginal |
| 5–8 | 3–4 GB | 10–20% | 20–40% | Fortfarande bekvämt |
| 9–12 | 4–6 GB | 15–30% | 40–60% | Bra, ingen flaskhals |
| 13–16 | 5–7 GB | 20–40% | 50–75% | Fungerar utmärkt (verifierat) |
| 17–20 | 6–8 GB | 30–50% | 70–90% | Möjligt men nära gränsen |

Dessa siffror förutsätter att du använder **dual streams** korrekt (detect-strömmen på 640×480 @ 5fps). Om du matar in full 5MP-ström till detektorn ökar belastningen dramatiskt.

## CPU-fördelning

OptiPlexen har 6 kärnor / 12 trådar. Proxmox tillåter "overcommit" (du kan tilldela fler kärnor till containrar än vad som fysiskt finns), men det är bra att ha en överblick:

| Tjänst | Tilldelade kärnor | Kommentar |
|--------|-------------------|-----------|
| VM 100 — HA | 2 | Räcker gott för HA |
| CT 101 — cloudflared | 1 | Behöver knappt en |
| CT 102 — NPM | 1 | Behöver knappt en |
| CT 103 — Frigate | 4 | FFmpeg-avkodning + go2rtc |

## Lagringsdisk: Hur länge räcker den?

Frigate sparar video i segment och rensar automatiskt äldre inspelningar. Hur mycket plats som krävs beror på antal kameror, upplösning, och hur mycket rörelse som sker.

| Antal kameror | Upplösning | Dagar (1 TB SSD) | Dagar (2 TB SSD) |
|---------------|------------|-------------------|-------------------|
| 4 | 1080p | ~30 dagar | ~60 dagar |
| 8 | 1080p | ~15 dagar | ~30 dagar |
| 12 | 5MP | ~7 dagar | ~14 dagar |
| 16 | 5MP | ~5 dagar | ~10 dagar |

> **Tips:** Frigate sparar bara video när det finns rörelse (mode: motion). I praktiken sparas betydligt mindre än "24/7 continuous recording". Siffrorna ovan antar ~50% rörelsetid under dagtid.

## Rekommendation

För en setup med upp till 16 Axis-kameror på en OptiPlex XE4 med 32 GB RAM och en 1–2 TB lagringsdisk har du mer än tillräckligt med kapacitet. Systemet kommer att vara responsivt, tyst och dra under 40W total strömförbrukning.
