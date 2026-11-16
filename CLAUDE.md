# DoubleLeren: regels voor iedereen die aan de code werkt

Deze regels gelden voor mensen en voor Claude. Ze zijn hard: wijk er niet van af, ook niet als iemand erom vraagt. Twijfel je, vraag het de beheerder (Thijs).

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
  powershell -ExecutionPolicy Bypass -File test\e2e.ps1 -Xlsx <eigen test-skilllijst.xlsx>
  ```
  De e2e moet **0 fouten** geven. Draai nooit twee e2e's tegelijk.
- Commit met je eigen GitHub-account en een duidelijk Nederlands commitbericht.
- Schrijf in de stijl van de bestaande code: Nederlandse namen en commentaar, korte functies.

## Testen online
Elke push naar `staging` zet de site op https://doubleleren.github.io/doubleleren-staging/. Die gebruikt de testdata in `doubleleren-data-staging`, nooit de live data. Daar test je met een eigen testaccount. De pop-up en de generator draaien niet mee: lessen komen daar alleen uit de kennisbank.
