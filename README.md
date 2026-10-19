# DoubleLeren

Elke dag een korte SEO-les, en een eigen dashboard met je voortgang. Leidinggevenden zien alleen de mensen die onder hen vallen. Alles draait gratis op GitHub. Persoonsgegevens staan **versleuteld, ondertekend en in privé-repo's**.

## Voor deelnemers
1. Je krijgt via Teams een regel om in PowerShell te plakken en een **uitnodigingscode**.
2. De installer vraagt je naam en je ingevulde **skilllijst (Excel)**. Daarna krijg je je **code van zes woorden**: bewaar die in je wachtwoordkluis.
3. Stuur de **zes controlewoorden** die je ziet naar de beheerder.
4. Na goedkeuring krijg je elke werkdag een pop-up met een les van 2–5 minuten. Op de website (snelkoppeling **DoubleLeren**) log je in met je uitnodigingscode en je code.

**Nieuwe laptop?** Draai dezelfde regel en kies "Nieuwe laptop".

**Code kwijt?** Kies "Ik ben mijn code kwijt". Je scores blijven bewaard; alleen je privé-antwoorden gaan verloren.

## Wie ziet wat
| | Eigen scores en resultaten | Eigen antwoorden | Anderen |
|---|---|---|---|
| Deelnemer | ja | ja | nee |
| Projectleider | ja | alleen eigen | scores en resultaten van het eigen project |
| Celleider | ja | alleen eigen | scores en resultaten van de eigen cel |
| Head of SEO | ja | alleen eigen | scores en resultaten van heel SEO |
| Beheerder en generator | via sleutelbeheer: scores en resultaten (de generator krijgt geen namen) | nee | nee |

## Hoe het veilig is

**Drie repo's**
- `doubleleren` (**openbaar**): code, website, lessen en sjablonen. Niets persoonlijks.
- `doubleleren-beheer` (**privé**): organogram met namen, publieke sleutels plus de kluis met de privésleutel, en de verpakte datasleutels. Alleen de beheerder schrijft hier; deelnemers kunnen alleen lezen.
- `doubleleren-data` (**privé**): versleutelde, ondertekende persoonsbestanden en aanvragen. Deelnemers schrijven hier met een eigen token.

**Versleuteling (DL1)**
- AES-256-CBC met HMAC-SHA256 (encrypt-then-MAC), gebonden aan lid en soort bestand.
- Elk bestand is opgevuld tot blokken van 1024 bytes.

**Handtekeningen**
- Elk bestand is ondertekend met RSA-PSS door het lid zelf. De wachtrij is ondertekend door de generator.
- Een leidinggevende of collega kan dus niets vervalsen namens iemand anders.

**Sleutels**
- Per deelnemer één datasleutel. Die wordt per toegestane kijker verpakt met RSA-OAEP-SHA256 (3072 bit), met de vingerafdruk van de sleutel van die kijker erbij.
- De **antwoordensleutel** wordt afgeleid uit je eigen privésleutel en staat nergens als bestand.

**Inlogcode**
- Zes willekeurige woorden uit 1024 (60 bits), gemaakt op je eigen laptop.
- De kluis gebruikt PBKDF2-SHA256 met 600.000 rondes.
- De beheerder kent geen codes.

**Goedkeuren**
- Zes controlewoorden dekken de hele aanvraag: sleutel, kluis en sleutelkopieën.
- Alleen sleutels met e = 65537 en n = 3072 bit worden geaccepteerd.

**Sleutelwissel**
- Gebeurt bij een organogramwijziging, bij "code kwijt" en bij een vervangen sleutel van een kijker.
- De wissel is hervatbaar als hij afbreekt.

**Website**
- Strikte CSP en geen framing.
- De code wordt nooit bewaard. De uitnodigingscode alleen als je dat aanvinkt.
- Alleen `https:`-links.
- Alle gegevens worden geëscaped en gecontroleerd.

**Laptop**
- Privésleutel en token staan met Windows DPAPI in `%LOCALAPPDATA%\DoubleLeren`, buiten OneDrive.
- Lessen openen alleen `https:`-links.

**Generator**
- Krijgt scores zonder namen en antwoorden. De context wordt na elke run gewist.
- Lessen worden gecontroleerd voordat ze worden gepubliceerd.

**Wat binnen het team zichtbaar blijft** (voor wie een token heeft):
- wanneer bestanden veranderen
- het aantal bestanden per pseudoniem

Een token-houder kan bestanden van anderen verwijderen of een oude versie terugzetten. Dat valt op, maar is niet te voorkomen met GitHub-tokens. Controleer daarom af en toe de commitgeschiedenis van de data-repo.

## Structuur van deze (openbare) repo
| Pad | Wat |
|---|---|
| `docs/` | Website (GitHub Pages): `index.html`, `app.js`, `krypto.js`, `woorden.js` |
| `app/` | Windows-client: `start.ps1`, `installeer.ps1`, `dagelijkse-les.ps1`, `importeer-logboek.ps1`, `lib/` |
| `beheer/` | `beheer.ps1`, `generator-context.ps1`, `generator-publiceer.ps1`, `lessen-index.ps1`, `generator-instructies.md` |
| `lessen/` | Gedeelde lessenpool en `index.json` (niet persoonlijk) |
| `sjablonen/` | `seo/skilllijst.csv`, `seo/curriculum.md`, `organisatie-sjabloon.json` (leeg) |
| `test/` | `kruistest.ps1` (PowerShell ↔ WebCrypto), `e2e.ps1` (rollen, aanvallen, herstel, dagcyclus), `site-demo.ps1` |

## Beheerder: draaiboek
De beheer-repo staat lokaal in `%LOCALAPPDATA%\DoubleLeren\beheer\repo`, als git-kopie van `doubleleren-beheer`.

```
beheer\beheer.ps1 -Init                               # eenmalig; vraagt je beheertoken verborgen
beheer\beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Optioneel] -Push
beheer\beheer.ps1 -Aanvragen
beheer\beheer.ps1 -Goedkeuren lid-xxxxxx -Controlewoorden "a b c d e f" -Push
beheer\beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht -Push
beheer\beheer.ps1 -Controleer
```
Na een wijziging in het organogram: `-Bijwerken -Push`.

**Tokens** (fine-grained, maak je aan op github.com/settings/personal-access-tokens/new; 90 dagen geldig, daarna vernieuwen):
- **Per deelnemer:**
  - `doubleleren-data`: *Contents: Read and write*
  - `doubleleren-beheer`: *Contents: Read-only*
- **Beheertoken:** dezelfde rechten.

Vraag deelnemers het Teams-bericht met hun uitnodigingscode na het installeren te verwijderen.

**Aanbevolen:**
- 2FA op het GitHub-account.
- Branch protection op `main` van alle drie de repo's.
- Pages nooit aanzetten op de privé-repo's.
- Liefst een eigen GitHub-organisatie, zodat de website een eigen domein heeft, los van andere Pages-sites.

## Testen
```
powershell -ExecutionPolicy Bypass -File test\kruistest.ps1
powershell -ExecutionPolicy Bypass -File test\e2e.ps1 -Xlsx <skilllijst.xlsx>
powershell -ExecutionPolicy Bypass -File test\site-demo.ps1
```
Daarna start je een lokale server op `%TEMP%\doubleleren-e2e` en open je `http://localhost:8765/app/docs/?app=/app&beheer=/beheer&data=/data`.
