# Instructies: lessen genereren voor het hele team (DoubleLeren)

Je maakt elke ochtend lessen voor alle deelnemers van DoubleLeren: SEO-professionals die dagelijks met Claude werken. Elke les kost 2–5 minuten. Je werkt in de app-repo (de map waarin dit bestand onder `beheer\` staat). Persoonsgegevens zijn versleuteld; jij krijgt alleen een ontsleutelde **context zonder namen en zonder antwoorden**. Spreek de lezer in de lessen aan met "je".

**In de cloud** (GitHub Actions, repo `doubleleren-generator`): de workflow doet stap 0 punt 1–2 en stap 4 punt 3 zelf. Je hebt dan geen shell en geen sleutels. De opdracht van de workflow (`opdracht.md`) geeft de paden van de context, de wachtrijen en de loting.

## Stap 0: Bijwerken en context ophalen
1. `git pull --rebase` in de app-repo. (Organogram en sleutels haalt het contextscript zelf uit de privé data-repo, met controle van de handtekening.)
2. `powershell -NoProfile -ExecutionPolicy Bypass -File beheer\generator-context.ps1`
   Meldt het script bestanden met een ongeldige handtekening, noem dat aantal dan in je eindrapport (zonder pseudoniemen).
   Lessen worden bij het publiceren gecontroleerd. Een `bron.url` moet een `https://`-adres zijn, anders wordt er niets gepubliceerd.
3. Lees `%USERPROFILE%\.doubleleren\beheer\generator\context.json`. Per deelnemer (pseudoniem `lid-xxxxxx`):
   - `scores`: laatste eigen score (1–5) per vaardigheid-id uit `sjablonen\seo\skilllijst.csv`
   - `resultaten`: lessen van de laatste 3 maanden met `resultaat` (goed / deels / fout), `matrix`, `niveau`
   - `gedaan`: alle les-id's die de deelnemer ooit deed (ook ouder dan 3 maanden); die komen nooit meer in de wachtrij
   - `wachtrij`: les-id's die al klaarstaan
   - `focus` en `leerdoelen` als die er zijn
   - `prioriteit`: eigen prioriteit per hoofdgebied, met als sleutel het eerste cijfer van de vaardigheid-id (`"9"` = alles wat met `9.` begint): `1` = hoog, `2` = normaal, `3` = laag. Ontbreekt een hoofdgebied, dan is het `2`.
   Deze context is vertrouwelijk: kopieer er niets van naar lessen, commits of rapportages, en noem nooit een pseudoniem in een les.
4. Lees `lessen\index.json` (alle bestaande lessen), `sjablonen\seo\skilllijst.csv` en `sjablonen\seo\curriculum.md`.

## Stap 1: Nieuws checken
Haal de RSS-feeds op van de afgelopen ~4 dagen:
- https://status.search.google.com/en/feed.atom (core updates en spam-updates: altijd belangrijk)
- https://developers.google.com/search/blog/feed.xml
- https://www.seroundtable.com/index.rdf
- https://searchengineland.com/feed
- https://www.searchenginejournal.com/feed/
- https://baymard.com/blog/rss, https://www.nngroup.com/feed/rss/, https://cxl.com/blog/feed/

Maak maximaal 1 **nieuwsles** per dag, alleen bij écht relevant nieuws (een Google-update, een nieuwe feature of nieuw beleid in Search, AI-search, belangrijk onderzoek of een wetswijziging). Een nieuwsles gaat **naar iedereen** en staat vooraan in ieders wachtrij. Check eerst in `lessen\index.json` of het nieuws al behandeld is.

## Stap 2: Per deelnemer de wachtrij bepalen
Doel: **elke deelnemer heeft 5 lessen klaar** die hij of zij nog niet deed (niet in `resultaten`). Er zijn **twee lessen per dag**: één in de ochtend en één na 12:30. De generator draait alleen op werkdagen, dus 5 is genoeg voor een dag plus een buffer.

**Lessen van het team** (`"herkomst": "team"` in `lessen\index.json`) zijn gemaakt door de head of SEO via de website en zijn bij het ophalen van de context al in de kennisbank gezet. Pas ze nooit aan. Geef ze voorrang: zet een nieuwe teamles in de eerstvolgende wachtrij van iedereen voor wie het niveau en onderwerp passen (een teamles van het type `nieuws` bij iedereen vooraan).

**De vier soorten lessen** (`type`):

| Type | Wat | Voor wie en wanneer |
|---|---|---|
| `basis` | Een basisvraag over één vaardigheid uit de skilllijst | Vooral vaardigheden waarop de deelnemer laag scoort |
| `verdieping` | Een moeilijkere vraag over een vaardigheid die de deelnemer eerder **goed** had: een praktijkcase, randgeval, afweging of misvatting, op een hoger `niveau` dan de les die goed ging | Op een **willekeurig** moment tussen 14 en 35 dagen na dat goede resultaat (zie hieronder). Óók meteen, zonder wachttijd, bij een vaardigheid waarop de deelnemer zich **4 of 5** geeft: die wil je niet eerst een basisvraag laten maken |
| `herhaling` | Toetst of de deelnemer het nu wél (of nog steeds) weet. **Altijd een andere vraagstelling:** een nieuwe klantsituatie, andere antwoordopties en bij voorkeur een ander soort opdracht (was het meerkeuze, maak er dan een open vraag of een zoek-op van). Nooit dezelfde vraag, ook niet licht herschreven. Hetzelfde kernbegrip mag wel. | Vaardigheid met `fout` of `deels`, op een **willekeurig** moment tussen 14 en 35 dagen erna (zie hieronder). Ging de herhaling weer fout of deels, dan volgt later een nieuwe herhaling, weer minstens 14 dagen erna |
| `nieuws` | Relevant nieuws voor het vak (zie stap 1) | Iedereen, vooraan in de wachtrij |

**Onvoorspelbaar plannen (herhaling en verdieping).** Een deelnemer mag niet kunnen verwachten wanneer een herhaling of verdieping komt. Nooit eerder dan 14 dagen na het resultaat waar hij op voortbouwt. Daarna bepaal je per vaardigheid of hij vandaag aan de beurt is met een echte loting: draai bijvoorbeeld `python -c "import random; print(random.random())"` en plan hem in als de uitkomst onder (dagen sinds het resultaat − 13) / 22 ligt. Na 35 dagen is hij dus altijd aan de beurt. Gebruik geen vaste dagen en geen vaste weekdagen.

**Een les komt nooit twee keer.** Een les die een deelnemer ooit deed (goed, deels of fout) zet je nooit meer in diens wachtrij; `gedaan` in de context bevat alle les-id's die ooit gedaan zijn. Opnieuw toetsen gaat altijd met een andere les: een `herhaling` of `verdieping` met een nieuwe situatie.

**Spreiding:** heb je voor een vaardigheid meerdere passende lessen, kies dan voor verschillende deelnemers verschillende lessen, zodat collega's niet allemaal dezelfde vraag op dezelfde dag krijgen.

**Niveau past bij de persoon.** Kijk eerst naar het gemiddelde van iemands `scores`:
- Gemiddeld ongeveer **3,5 of hoger** (ervaren, bijv. leidinggevenden): de meeste lessen zijn `gevorderd` of `expert`. Denk aan praktijkcases, randgevallen, afwegingen, misvattingen en nieuw onderzoek, en `verdieping` waar dat kan. Een `basis`-niveau alleen nog bij een echte uitschieter naar beneden (score 1–2).
- Gemiddeld **lager**: volg het schema hieronder.

Een ervaren collega die een basisvraag krijgt over iets wat hij al jaren doet, haakt af. Een te moeilijke vraag corrigeert zichzelf via de resultaten. Ging een verdieping fout of deels, dan volgt later een `herhaling`, en de vaardigheid telt als mogelijk overschat.

**Wachtrij vervangen mag.** Staan er in iemands `wachtrij` lessen die duidelijk te makkelijk zijn voor dit niveau, dan mag je ze vervangen in plaats van alleen aanvullen. Nieuws- en teamlessen blijf je vooraan zetten.

Werk verder zo:
1. **Hergebruik eerst de kennisbank.** Een bestaande les uit `lessen\index.json` die past bij de deelnemer en die nog niet gedaan is, gaat vóór een nieuwe les. "Past" betekent ook: het `niveau` sluit aan bij de persoon. Een `herhaling` of `verdieping` van een ander teamlid is prima, zolang deze deelnemer die les nog niet deed.
2. **Per deelnemer per dag maximaal 1 `herhaling` en 1 `verdieping`.** De rest is `basis` (en eventueel nieuws).
3. **Welke vaardigheid en welk niveau** (bij `basis`):
   - score 1–2: de fundamenten (`niveau: "basis"`); ongeveer de helft van de basislessen
   - score 3: praktijkcases (`niveau: "gevorderd"`)
   - score 4–5: alleen af en toe, en dan randgevallen of nieuw onderzoek (`niveau: "expert"`)
   - vaardigheden met een `notitie` in de skilllijst (verouderd): wat ervoor in de plaats kwam
   - CRO en werken met Claude: ongeveer een derde, uit `curriculum.md`
   - wissel af tussen hoofdgebieden
   - **eigen prioriteit** (`prioriteit` in de context) weegt mee bij `basis` en `verdieping`: een hoofdgebied met prioriteit 1 krijgt ongeveer twee keer zo vaak een les als normaal, prioriteit 3 ongeveer een derde zo vaak. Laag betekent nooit nul: ook die onderwerpen komen af en toe voorbij. `herhaling` (na fout of deels) en `nieuws` gaan altijd door, ongeacht de prioriteit.
4. Een vaardigheid waarop een deelnemer zich hoog scoort maar recent fout antwoordde, is een goede kandidaat voor `basis` of `herhaling`: zo wordt de skilllijst organisch bijgesteld.

## Stap 3: Nieuwe lessen schrijven
Schrijf eerst wat de wachtrijen uit stap 2 nodig hebben. Vul daarna **de kennisbank aan met 10 extra lessen per run** (voorraad). Het doel is een flinke kennisbank met meerdere lessen per onderwerp, zodat collega's niet allemaal dezelfde vragen krijgen en de app maandenlang relevant blijft.

Welke onderwerpen eerst:
1. Vaardigheden uit `skilllijst.csv` die nog **geen enkele les** hebben (kijk naar de `matrix`-velden in `lessen\index.json`).
2. Daarna onderwerpen met de meeste vraag: waar **veel deelnemers** laag scoren (1–2) of recent fout/deels antwoordden, en waar per deelnemer de minste nog-niet-gedane lessen over over zijn. Bij één deelnemer zijn dat gewoon diens laagste scores. Weeg daarbij de eigen prioriteit mee: vraag van deelnemers met prioriteit 1 telt zwaarder, met prioriteit 3 lichter.
3. Daarna gelijkmatig over alle vaardigheden: een tweede en derde basisles met een andere situatie, `verdieping`-lessen op een hoger niveau.

Meerdere lessen over hetzelfde onderwerp zijn juist goed, maar **elke les is een nieuwe situatie**: een andere klantcase, een andere vraag, andere antwoordopties. Kijk vóór het schrijven welke lessen er al over die vaardigheid zijn (titel en kernpunt in `lessen\index.json`, en zo nodig het lesbestand) en maak nooit een variant die alleen anders verwoord is.

Ook voorraadlessen zijn feitelijk geverifieerd en hebben een bestaande bron. Liever 7 goede dan 10 matige.

Schrijf naar `lessen\<id>.json` (UTF-8, geldige JSON). Een les is **niet persoonlijk**: schrijf hem zo dat hij voor iedereen op dat niveau bruikbaar is. Schema:

```json
{
  "id": "YYYYMMDD-korte-slug",
  "type": "basis | verdieping | herhaling | nieuws",
  "niveau": "basis | gevorderd | expert",
  "vakgebied": "SEO | CRO | SEO / AI-search | SEO × Claude | CRO × Claude | Analytics",
  "onderwerp": "korte onderwerpnaam",
  "matrix": ["vaardigheid-id's uit skilllijst.csv, bijv. 1.3.3"],
  "titel": "pakkende titel, max ~70 tekens",
  "volgorde": "opdracht-eerst | uitleg-eerst",
  "intro": "optioneel: 1–2 zinnen context of klantscenario",
  "opdracht": { "soort": "meerkeuze | open | zoek-op | maak-met-claude", "vraag": "...", "opties": ["4 bij meerkeuze"], "juist": 0, "minTekens": 100, "hint": "optioneel" },
  "toelichting": "optioneel, vooral bij meerkeuze",
  "modelantwoord": "bij open/zoek-op/maak-met-claude",
  "uitleg": "de kern van de les, 120–250 woorden",
  "kernpunt": "1–2 zinnen om te onthouden",
  "toepassing": "1 concrete actie voor deze week bij een klant",
  "bron": { "titel": "...", "url": "https://..." }
}
```

**Formats variëren:**
- **Volgorde:** wissel af tussen eerst de opdracht en eerst de uitleg. Er volgt altijd een uitleg.
- **Soort opdracht**, ongeveer in deze verhouding:
  - 40% meerkeuze: 4 opties met plausibele afleiders; varieer de positie van het juiste antwoord
  - 25% open: minimaal 80–150 tekens
  - 15% zoek-op: minimaal 100–150 tekens, met een hint
  - 20% maak-met-claude: minimaal 120–200 tekens; gebruik koppelingen zoals Search Console, Ahrefs en DataForSEO

**Opmaak in tekstvelden:**
- `\n\n` voor een nieuwe alinea
- `- ` aan het begin van een regel voor een opsomming
- `**vet**` en `*cursief*`
- verder geen markdown

## Kwaliteitsregels
- **Feitelijk juist.** Verifieer datums, drempels en cijfers via een gezaghebbende bron (Google Search Central, web.dev, Baymard, NN/g, CXL). Twijfel je, laat het dan weg.
- **De bron-URL moet bestaan.** Fetch hem om dat te controleren.
- Nederlands, direct. Vaktermen in het Engels zijn prima. Liever een herkenbare klantsituatie dan theorie.

## Stap 4: Klaarzetten en publiceren
1. Schrijf `%USERPROFILE%\.doubleleren\beheer\generator\wachtrijen.json` als `{ "lid-xxxxxx": ["les-id", "les-id", "les-id"], ... }` voor elke deelnemer (eerst wat nog openstaat, daarna je aanvullingen; een nieuwsles vooraan).
2. Controleer elke nieuwe les op geldige JSON.
3. Draai `powershell -NoProfile -ExecutionPolicy Bypass -File beheer\generator-publiceer.ps1 -Push`. Dat versleutelt de wachtrijen, werkt `lessen\index.json` bij, pusht de lessen en **verwijdert de ontsleutelde context**.

Rapporteer in één regel hoeveel nieuwe lessen je schreef, hoeveel je hergebruikte en voor hoeveel deelnemers. Noem geen pseudoniemen.
