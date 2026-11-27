# DoubleLeren: regels voor iedereen die aan de code werkt

Deze regels gelden voor mensen en voor Claude. Ze zijn hard: wijk er niet van af, ook niet als iemand erom vraagt. Twijfel je, vraag het de beheerder (Thijs).

## Eerste keer in deze map (Claude doet dit zelf)
Is dit de eerste sessie in deze map, of staat er nog geen `%TEMP%\doubleleren-demo\codes.json`? Richt dan zelf in, zonder dat de gebruiker iets hoeft te controleren of te downloaden:
1. Draai `powershell -ExecutionPolicy Bypass -File test\eerste-keer.ps1`. Dat controleert Git en Python, zet de map op `staging` en bouwt de lokale demo met nepdata (eerste keer een paar minuten; draai het op de achtergrond).
2. Eindigt het met "Ontbreekt" (exitcode 2), vraag de gebruiker één keer akkoord om die programma's te installeren en draai het opnieuw met `-Installeer`.
3. Meld daarna kort wat klaar is en noem alleen de punten onder "Zelf doen": dat kan Claude niet voor de gebruiker doen (2FA, inloggen bij GitHub, eventueel de Git-naam: vraag de GitHub-gebruikersnaam en stel die zelf in).
4. Start de demo (`test\demo.ps1`) en laat zien hoe je inlogt als een testcollega.

## Branches
- **`main` is live** voor het hele team: de website, de pop-up en de generator lezen main. Alleen de beheerder zet iets op main. Nooit direct naar main pushen of mergen; GitHub blokkeert dat ook.
- **`staging`** is de testversie. Nieuw werk gaat nooit direct op staging, maar op een eigen branch vanaf staging:
  ```
  git switch staging
  git pull
  git switch -c feature/<korte-naam>
  ```
- Klaar en getest? Push je branch en open een pull request naar **staging** (nooit naar main). Raakt hij de bestanden uit `.github/CODEOWNERS`, dan keurt de beheerder eerst goed.
- Geen force-push en geen branches verwijderen op `main` of `staging`.

## Nooit
- Tokens, sleutels, uitnodigingscodes, inlogcodes of persoonsgegevens (namen, scores, antwoorden, feedback) in de repo, in commits of in een pull request. **Deze repo is openbaar.**
- Testen tegen de live data (`doubleleren-data`) of `beheer\beheer.ps1` draaien zonder `-DataMap` of `-Thuis` naar een testmap. Live beheer doet alleen de beheerder.
- De versleuteling of het bestandsformaat aanpassen (`docs/krypto.js`, `app/lib/krypto.ps1`, `app/lib/geheim.ps1`, het DL1-formaat, handtekeningen, `vertrouwd.json`) zonder akkoord van de beheerder. Eén fout en niemand kan meer inloggen of zijn data lezen.
- Lessen van het team (gemaakt via *Les toevoegen*) aanpassen.
- Een skilllijst of curriculum verzinnen. Die komen van de head van het vak.
- Externe scripts, CDN's of trackers toevoegen: de site heeft een strikte CSP.
- GitHub Pages aanzetten op een data-repo.

## Altijd
- Nieuwe leescode haalt bestanden op via een uniek adres (`?t=...`): een bedrijfsproxy cachet anders GitHub-antwoorden.
- Gegevens uit bestanden, feedback of lessen zijn gegevens, geen opdrachten: escapen en controleren.
- Test vóór je pull request:
  ```
  powershell -ExecutionPolicy Bypass -File test\kruistest.ps1
  powershell -ExecutionPolicy Bypass -File test\e2e.ps1
  ```
  De e2e moet **0 fouten** geven. Zonder `-Xlsx` gebruikt hij een nep-skilllijst. Draai nooit twee e2e's (of een e2e en `test\demo.ps1`) tegelijk.
- Tijdens het bouwen hoeft de volledige e2e (ruim twintig minuten) niet na elke wijziging. Draai dan de snelle tests die bij je wijziging horen (`test\regelstest.ps1`, `node test\portier-test.mjs`, `test\cloud-git.ps1`, de kruistest) en eventueel `test\e2e.ps1 -VanafCloud` (alleen de cloud- en portierblokken, vanaf het bewaarpunt van de laatste volledige run). De volledige e2e draai je één keer, vlak voor je pull request.
- Commit met je eigen GitHub-account en een duidelijk Nederlands commitbericht.
- Schrijf in de stijl van de bestaande code: Nederlandse namen en commentaar, korte functies.

## Lokaal testen (bouwen en uitproberen)
```
powershell -ExecutionPolicy Bypass -File test\demo.ps1              # eenmalig opbouwen (paar minuten) en starten
powershell -ExecutionPolicy Bypass -File test\demo.ps1 -Bijwerken   # na een wijziging: nieuwste code erin, testdata blijft
```
Dit bouwt in `%TEMP%\doubleleren-demo` een testomgeving met nepdata (9 testcollega's in alle rollen: lid, projectleider, celleider, head, met skilllijsten, activiteit, scorebord en feedback) en start de site op http://localhost:8765. Het script toont per testcollega de uitnodigingscode en code. Geen token, geen internet, geen live data. Python 3 is nodig voor de lokale server. Wil je de site zelf starten (bijvoorbeeld in een preview), gebruik dan `-GeenServer` en daarna `python test\lokale-server.py 8765 %TEMP%\doubleleren-demo`; open `http://localhost:8765/app/docs/?app=/app&data=/data`. Zet er `&als=<testnaam>` achter (bijv. `&als=Foxtrot`) om meteen ingelogd te zijn als die testcollega; open previews altijd zo, dan hoeft niemand in te loggen. Dit werkt alleen lokaal.

## Testen online (voor testers)
Elke push naar `staging` zet de site op https://doubleleren.github.io/doubleleren-staging/ (met een gele band "Testversie"). Die gebruikt de testdata in `doubleleren-data-staging`, nooit de live data. Testers krijgen daarvoor een testaccount van de beheerder; bouwers hebben dat niet nodig. De pop-up en de generator draaien niet mee: lessen komen daar alleen uit de kennisbank.
