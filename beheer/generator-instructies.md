# Instructies: lessen genereren voor het hele team (DoubleLeren)

Je maakt elke ochtend lessen voor alle deelnemers van DoubleLeren: SEO-professionals die dagelijks met Claude werken. Elke les kost 2–5 minuten. Je werkt in de app-repo (de map waarin dit bestand onder `beheer\` staat). Persoonsgegevens zijn versleuteld; jij krijgt alleen een ontsleutelde **context zonder namen en zonder antwoorden**. Spreek de lezer in de lessen aan met "je".

## Stap 0: Bijwerken en context ophalen
1. `git pull --rebase` in de app-repo. (Organogram en sleutels haalt het contextscript zelf uit de privé data-repo, met controle van de handtekening.)
2. `powershell -NoProfile -ExecutionPolicy Bypass -File beheer\generator-context.ps1`
   Meldt het script bestanden met een ongeldige handtekening, noem dat aantal dan in je eindrapport (zonder pseudoniemen).
   Lessen worden bij het publiceren gecontroleerd. Een `bron.url` moet een `https://`-adres zijn, anders wordt er niets gepubliceerd.
3. Lees `%USERPROFILE%\.doubleleren\beheer\generator\context.json`. Per deelnemer (pseudoniem `lid-xxxxxx`):
   - `scores`: laatste eigen score (1–5) per vaardigheid-id uit `sjablonen\seo\skilllijst.csv`
   - `resultaten`: lessen van de laatste 3 maanden met `resultaat` (goed / deels / fout), `matrix`, `niveau`
   - `wachtrij`: les-id's die al klaarstaan
   - `focus` en `leerdoelen` als die er zijn
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
Doel: **elke deelnemer heeft 3 lessen klaar** die hij of zij nog niet deed (niet in `resultaten`). Werk zo:
1. **Hergebruik eerst de pool.** Een bestaande les uit `lessen\index.json` die past bij de deelnemer en die nog niet gedaan is, gaat vóór een nieuwe les. Zo bouwt het team één gedeelde kennisbank op.
2. **Herhaling:** een vaardigheid met `fout` of `deels` van 3, 7 of 30 dagen geleden krijgt een herhalingsles (`type: "herhaling"`) met een **nieuwe** vraag of invalshoek. Maximaal 1 per deelnemer per dag.
3. **Weging naar scores:**
   - vaardigheden met score 1–2: ongeveer de helft van de basislessen, met de fundamenten (`niveau: "basis"`)
   - score 3: praktijkcases (`niveau: "gevorderd"`)
   - score 4–5: af en toe, en alleen randgevallen, misvattingen of nieuw onderzoek (`niveau: "expert"`)
   - vaardigheden met een `notitie` in de skilllijst (verouderd): een les over wat ervoor in de plaats kwam
   - CRO en werken met Claude: ongeveer een derde, uit `curriculum.md`
   - wissel af tussen hoofdgebieden
4. Mix over de laatste ~10 lessen: ~60% basis/verdieping, ~40% nieuws. Geen nieuws? Dan aanvullen met basis.
5. Een vaardigheid waarop een deelnemer zich hoog scoort maar recent fout antwoordde, is een goede kandidaat: daarmee wordt de skilllijst organisch bijgesteld.

## Stap 3: Nieuwe lessen schrijven (alleen wat de pool mist)
Schrijf naar `lessen\<id>.json` (UTF-8, geldige JSON). Een les is **niet persoonlijk**: schrijf hem zo dat hij voor iedereen op dat niveau bruikbaar is. Schema:

```json
{
  "id": "YYYYMMDD-korte-slug",
  "type": "basis | nieuws | herhaling",
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
