# DoubleLeren

Elke dag een korte SEO-les, en een eigen dashboard met je voortgang. Leidinggevenden zien alleen de mensen die onder hen vallen. Alles draait gratis op GitHub. Persoonsgegevens staan **versleuteld, ondertekend en in privé-repo's**.

## Voor deelnemers
Alles gaat in de browser; je hoeft niets te installeren.
1. Je krijgt via Teams een link (`https://doubleleren.github.io/doubleleren/#welkom`) en een **uitnodigingscode**.
2. Plak de uitnodigingscode, vul je naam in en kies je ingevulde **skilllijst (Excel)**. Je browser maakt je **code van zes woorden**: bewaar die in je wachtwoordkluis.
3. Stuur de **zes controlewoorden** die je ziet via Teams naar de beheerder.
4. Na goedkeuring log je in met je uitnodigingscode en je code. Onder **Les van vandaag** staat elke werkdag een les van 2–5 minuten.
5. Wil je dat DoubleLeren elke ochtend vanzelf opent? Na je les staat hoe je een opstart-snelkoppeling maakt (Windows en Mac). Vink bij het inloggen **Onthoud mij** aan, dan opent hij meteen in je les zonder code (30 dagen, tot je uitlogt).

**Andere computer?** Gewoon inloggen op de website.

**Terugkijken:** klik op een les in de kalender, onder *Recent geleerd*, in de kennisbank of bij *Wat gaat goed, wat minder*: je leest de vraag en de uitleg terug (zonder je eigen antwoord).

**Skilllijst:** onder *Skilllijst* zie je je scores en werk je ze bij. Twee keer per jaar is dat verplicht: vóór **31 januari** en vóór **31 juli**. Ben je te laat, dan kun je (op de website en in de pop-up) pas weer een les doen als je hem hebt bijgewerkt. Wie zich minder dan drie maanden voor de deadline aanmeldde, slaat die ronde over.

**Scorebord:** elke maand een kleine competitie. Je ziet van collega's alleen hun naam, het aantal goede antwoorden en hun reeks (punten = goed + langste reeks van de maand). Eerdere maanden en de jaarstand blijven bewaard. Niet meedoen? Zet in *Mijn voortgang* "Toon mij op het scorebord" uit; dan zie je het bord zelf ook niet.

**Geef feedback:** met de knop bovenaan (of onder een les) meld je een bug, een fout of onvolledig antwoord, iets wat je nog wilt leren, of wat goed gaat. Alleen de beheerder kan het lezen, met je naam erbij.

**Head of SEO:** onder *Les toevoegen* maak je zelf een les. Die gaat ondertekend naar de data-repo. De generator controleert je handtekening en de les, zet hem de volgende ochtend in de kennisbank (gemarkeerd als *Van het team*) en plant hem met voorrang in. Meer lesmakers kan de beheerder toevoegen via `lesmakers` in het organogram.

**Code kwijt?** Kies op de website *Aanmelden* en daarna *Code kwijt*. Je scores blijven bewaard; alleen je privé-antwoorden gaan verloren.

**Liever een pop-up die je tot de les dwingt (Windows)?** Dat kan nog steeds, optioneel, via `app\start.ps1`.

## Wie ziet wat
| | Eigen scores en resultaten | Eigen antwoorden | Anderen |
|---|---|---|---|
| Deelnemer | ja | ja | alleen het scorebord: naam, aantal goed en reeks per maand (wie zich verbergt niet) |
| Projectleider | ja | alleen eigen | scorebord + scores en resultaten van het eigen project |
| Celleider | ja | alleen eigen | scorebord + scores en resultaten van de eigen cel |
| Head of SEO | ja | alleen eigen | scorebord + scores en resultaten van heel SEO |
| Beheerder en generator | via sleutelbeheer: scores en resultaten (de generator krijgt geen namen) | nee | de beheerder leest ook de feedback, met naam |

## Hoe het veilig is

**Twee repo's**, in de GitHub-organisatie `doubleleren`, zodat de website een eigen domein heeft:
- `doubleleren` (**openbaar**): code, website, lessen en sjablonen, plus `vertrouwd.json` met de publieke beheersleutel. Niets persoonlijks. Alleen de beheerder schrijft hier.
- `doubleleren-data` (**privé**): versleutelde, ondertekende persoonsbestanden en aanvragen. Deelnemers schrijven hier met een eigen token.
  - In `beheer/` staan het organogram met namen, de publieke sleutels plus de kluis met de privésleutel, en de verpakte datasleutels.
  - Al die bestanden zijn **ondertekend met de beheersleutel**. Een collega met een token kan ze overschrijven, maar niet vervalsen.
  - Website, pop-up en generator weigeren alles zonder geldige handtekening die past bij `vertrouwd.json`.

**Versleuteling (DL1)**
- AES-256-CBC met HMAC-SHA256 (encrypt-then-MAC), gebonden aan lid en soort bestand.
- Elk bestand is opgevuld tot blokken van 1024 bytes.

**Handtekeningen**
- Elk bestand is ondertekend met RSA-PSS door het lid zelf. De wachtrij is ondertekend door de generator.
- Een leidinggevende of collega kan dus niets vervalsen namens iemand anders.

**Sleutels**
- Per deelnemer één datasleutel. Die wordt per toegestane kijker verpakt met RSA-OAEP-SHA256 (3072 bit), met de vingerafdruk van de sleutel van die kijker erbij.
- De **antwoordensleutel** wordt afgeleid uit je eigen privésleutel en staat nergens als bestand.
- **Twee beheersleutels.**
  - De **beheersleutel** ondertekent alles onder `beheer/` (organogram, sleutels, toegang). De publieke helft staat in `vertrouwd.json`. Hij blijft alleen op de laptop van de beheerder.
  - De **generatorsleutel** opent alleen de generatorkopie van de datasleutels en ondertekent wachtrijen en scorebordstanden. De publieke helft staat in `beheer/generator.json`, ondertekend met de beheersleutel. Hij kan dus straks in de cloud draaien zonder dat daarmee het organogram of de rechten te vervalsen zijn.
  - Een handtekening "generator" is geldig met de generatorsleutel of met de beheersleutel (die tekende vóór de splitsing).

**Inlogcode**
- Zes willekeurige woorden uit 1024 (60 bits), gemaakt in je eigen browser (of op je laptop bij de pop-up).
- De skilllijst wordt in de browser gelezen en versleuteld. Het Excel-bestand zelf gaat nergens naartoe.
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
- De code wordt nooit bewaard. Met *Onthoud mij* bewaart de browser je sleutel en uitnodigingscode in IndexedDB, versleuteld met een niet-exporteerbare AES-GCM-apparaatsleutel; na 30 dagen, bij Uitloggen of na *Code kwijt* is die sessie weg.
- Alleen `https:`-links.
- Alle gegevens worden geëscaped en gecontroleerd.

**Laptop**
- Privésleutel en token staan met Windows DPAPI in `%USERPROFILE%\.doubleleren`, buiten OneDrive.
- Lessen openen alleen `https:`-links.

**Generator**
- Krijgt scores zonder namen en antwoorden. De context wordt na elke run gewist.
- Lessen worden gecontroleerd voordat ze worden gepubliceerd.

**Scorebord en feedback**
- Scorebord: `scorebord/<maand>/<id>.json`, ondertekend door het lid zelf en bewust **niet versleuteld** (het hele team leest mee). Er staan alleen het aantal goed en de reeks in, geen naam (die komt uit het ondertekende organogram), geen skilllijst en geen antwoorden. Net als de rest van de voortgang berust het op vertrouwen: een lid kan zijn eigen logboek verzinnen, maar niet dat van een ander.
- Feedback: `feedback/<tijd>-<willekeurig>.json`, versleuteld met een eigen datasleutel die alleen voor de beheersleutel is verpakt, en binnenin ondertekend door het lid. De buitenkant verraadt geen naam, soort of tekst. De beheerder leest het met `beheer\feedback.ps1`; de vrije tekst wordt daar als gegevens getoond, nooit als opdracht.

**Wat binnen het team zichtbaar blijft** (voor wie een token heeft):
- wanneer bestanden veranderen
- het aantal bestanden per pseudoniem

Een token-houder kan bestanden van anderen verwijderen of een oude versie terugzetten. Dat valt op, maar is niet te voorkomen met GitHub-tokens. Controleer daarom af en toe de commitgeschiedenis van de data-repo.

## Structuur van deze (openbare) repo
| Pad | Wat |
|---|---|
| `docs/` | Website (GitHub Pages): `index.html`, `app.js` (inloggen, aanmelden, les van vandaag, dashboard), `krypto.js`, `xlsx.js`, `woorden.js` |
| `app/` | Windows-client: `start.ps1`, `installeer.ps1`, `dagelijkse-les.ps1`, `importeer-logboek.ps1`, `lib/` |
| `beheer/` | `beheer.ps1`, `feedback.ps1`, `generator-context.ps1`, `generator-publiceer.ps1`, `voorstellen-opnemen.ps1` (lessen van de head), `lescontrole.ps1`, `kloon.ps1` (data-repo via git), `lessen-index.ps1`, `generator-instructies.md` |
| `lessen/` | Gedeelde lessenpool en `index.json` (niet persoonlijk) |
| `sjablonen/` | `seo/skilllijst.csv`, `seo/curriculum.md`, `organisatie-sjabloon.json` (leeg) |
| `test/` | `kruistest.ps1` (PowerShell ↔ WebCrypto), `e2e.ps1` (rollen, aanvallen, herstel, dagcyclus), `site-demo.ps1`, `lokale-server.py` |

## Beheerder: draaiboek
De beheersleutel en je beheertoken staan met DPAPI in `%USERPROFILE%\.doubleleren\beheer\beheer.dpapi`. Wijzigingen gaan direct en ondertekend naar `doubleleren-data/beheer/`.

```
beheer\beheer.ps1 -Init                               # eenmalig; vraagt je beheertoken verborgen; daarna vertrouwd.json committen en pushen
beheer\beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Optioneel]
beheer\beheer.ps1 -Aanvragen
beheer\beheer.ps1 -Goedkeuren lid-xxxxxx -Controlewoorden "a b c d e f"
beheer\beheer.ps1 -Verplaats lid-xxxxxx -Project ecom-nationaal
beheer\beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht
beheer\beheer.ps1 -Controleer
beheer\beheer.ps1 -NieuweGeneratorsleutel             # eenmalig: aparte generatorsleutel (hervatbaar; beheersleutel blijft gelijk)
beheer\scorebord-bijwerken.ps1 -Push                  # ieders scorebordstand (draait ook elke ochtend met de generator)
beheer\feedback.ps1 -Nieuw                            # nieuwe feedback (draait ook bij elke Claude-chat via een SessionStart-hook)
beheer\feedback.ps1 -Lijst                            # alle feedback met status
beheer\feedback.ps1 -Afhandelen <bestand>
```

**Tokens:** fine-grained, met *Resource owner* `doubleleren` en zonder vervaldatum. `-Uitnodigen` geeft een vooraf ingevulde link. Trek een token in bij vertrek of bij een verloren laptop.
- **Per deelnemer en voor de beheerder:** alleen `doubleleren-data`, met *Contents: Read and write*.

Vraag deelnemers het Teams-bericht met hun uitnodigingscode na het aanmelden te verwijderen.

**Aanbevolen:**
- 2FA op het GitHub-account.
- Branch protection op `main` van de app-repo.
- Pages nooit aanzetten op de data-repo.

## Testen
```
powershell -ExecutionPolicy Bypass -File test\kruistest.ps1
powershell -ExecutionPolicy Bypass -File test\e2e.ps1 -Xlsx <skilllijst.xlsx>
powershell -ExecutionPolicy Bypass -File test\site-demo.ps1
```
Start daarna `python test\lokale-server.py 8765 %TEMP%\doubleleren-e2e` en open `http://localhost:8765/app/docs/?app=/app&data=/data`. Met `#welkom` test je het aanmelden; de testserver laat de website in `data/` schrijven.
