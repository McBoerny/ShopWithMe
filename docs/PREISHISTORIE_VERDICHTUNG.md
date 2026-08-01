# ShopWithMe — Verdichtung der Preishistorie

Status: **Umgesetzt** (`Services/PreispunktVerdichtungService.swift`, GitHub
#76-Folgearbeit). Ergänzt `docs/PREISHISTORIE_BEREINIGUNG.md` (löscht ganze
`Preispunkt`e ab einer Altersfrist) um eine zweite, unabhängige Maßnahme:
**verdichten** statt komplett löschen — die grobe Preisentwicklung bleibt auch für
sehr alte Zeiträume erhalten, nur die Auflösung nimmt mit dem Alter ab.

## Drei Stufen

| Stufe | Schwelle (Standard) | Regel |
| --- | --- | --- |
| Täglich | ``maxPunkteProTag`` = 1 | Pro (Artikel, Geschäft, Kalendertag) höchstens so viele Punkte — bei Überschuss bleiben nur die zuletzt beobachteten. |
| Wöchentlich | ``tageBisWochenVerdichtung`` = 7 Tage | Punkte älter als die Frist: pro (Artikel, Geschäft, Kalenderwoche) auf einen reduziert — den mit dem **höchsten** Preis. |
| Monatlich | ``tageBisMonatsVerdichtung`` = 365 Tage | Bereits wochenverdichtete Punkte, zusätzlich älter als die Frist: pro (Artikel, Geschäft, Kalendermonat) noch einmal auf einen reduziert — wieder den höchsten. |

Alle drei laufen in dieser Reihenfolge in `PreispunktVerdichtungService.verdichten(context:jetzt:)`,
jede Stufe als eigener, abgeschlossener Fetch+`performMicroLease`+Save-Durchlauf
statt einer gemeinsamen Transaktion (vermeidet die in GitHub #77 gefundene Klasse
von Stale-Relationship-Problemen — eine spätere Stufe soll nie auf einem innerhalb
desselben Durchlaufs noch nicht gespeicherten Zwischenstand aufbauen müssen).

**Warum „den höchsten" statt Durchschnitt/Median:** Nutzerentscheidung — der
Höchstpreis ist die für einen späteren Preisvergleich relevantere Kennzahl
("wie teuer wurde es maximal") als ein geglätteter Mittelwert.

**Warum das echte Beobachtungsdatum statt eines Bucket-Datums (z.B.
Wochenanfang):** Nutzerentscheidung — der überlebende Punkt behält sein
tatsächliches `datum` (der Tag, an dem der Höchstpreis wirklich gemessen wurde),
kein künstliches, dem Original nicht entsprechendes Datum.

**Heutiger Tag bleibt bei Stufe 1 immer unangetastet:** eine Kollision am selben
Kalendertag wird stattdessen sofort beim Scannen interaktiv abgefragt (siehe
unten) — Stufe 1 fängt hauptsächlich rückwirkend bereits bestehende
Mehrfach-Punkte älterer Tage ab (z.B. aus der `KaufEintrag`→`Preispunkt`-Migration,
GitHub #76 Phase 1).

## Konfiguration (Debug-Menü)

Alle drei Schwellwerte sind in Einstellungen → Debugging → „Preishistorie-
Verdichtung" einstellbar (`DebuggingView.PreispunktVerdichtungSection`) — **global**
für alle Geschäfte einheitlich, keine Pro-Geschäft-Overrides (Nutzerentscheidung:
ein zweiter Konfigurationsgrad hätte für den erwarteten Nutzen zu viel zusätzliche
UI-Fläche gekostet). Die Sektion dient nur zum Nachjustieren/Testen — es gibt
keinen Ein-/Ausschalter, das Feature läuft automatisch für alle Nutzer (anders als
die nutzerkonfigurierbare Preishistorie-Aufbewahrung).

- **Automatischer Trigger**: `RootView` ruft
  `PreispunktVerdichtungService.automatischVerdichtenFallsFaellig(context:)` bei
  App-Start sowie bei jedem Wechsel von `scenePhase` auf `.active` auf, gedrosselt
  auf einmal pro 24h (`automatischesIntervall`), analog
  `PreisHistorieBereinigungService`/`KaufEintragBereinigungService`.
- **Manueller Trigger**: Button „Jetzt verdichten" in derselben Debug-Sektion.
- Löschungen (der nicht mehr benötigten Einzelpunkte nach einer Verdichtung)
  hinterlassen einen `SyncTombstone`, damit sie im Mehrgeräte-Fall nicht von einem
  Peer unwissentlich wiederbelebt werden — dieselbe Begründung wie bei
  `PreisHistorieBereinigungService`/`KaufEintragBereinigungService`.

## Interaktive Tages-Kollisionsabfrage beim Scannen

Ergänzung zu Stufe 1, aber **kein** Teil von `PreispunktVerdichtungService` selbst
— läuft direkt in `BelegScanView`/`PreisschildScanView`, sobald beim Scannen ein
Artikel/Geschäft bereits feststehen und für diese Kombination **heute** schon ein
`Preispunkt` mit abweichendem Preis existiert (`PreispunktService.vorhandenerPunktHeute(...)`):

- Die Prüf-Ansicht zeigt inline einen Hinweis („Heute bereits X € erfasst") mit
  einem Umschalt-Button (`TagesKollisionZeile`, `DesignSystem/TagesKollisionZeile.swift`).
- **Vorbelegung: „wird ersetzt"** — der bestehende Tagespunkt wird beim Übernehmen
  gelöscht (`PreispunktService.ersetzeVorhandenenPunkt(...)`) und durch den neuen
  ersetzt.
- Tippen auf den Button schaltet auf „Bisherigen behalten" um — dann entsteht für
  diese Position beim Übernehmen gar kein neuer Preispunkt, der bestehende bleibt
  unverändert. Nutzerentscheidung: gibt dem Anwender die Möglichkeit, einen
  offensichtlichen OCR-Fehlerkannten Preis manuell abzufangen, statt dass er den
  korrekten, bereits erfassten Preis stillschweigend überschreibt.
- Die Prüfung läuft einmalig beim Einlesen der Position (`verarbeite(bild:)`), nicht
  laufend bei jeder Korrektur — ändert der Anwender die Artikel-Zuordnung
  nachträglich im Prüf-Schritt, bleibt der ursprünglich ermittelte
  Kollisionshinweis bestehen (kleine, bewusst in Kauf genommene Ungenauigkeit für
  diesen Rand-Fall).

## Bewusst nicht umgesetzt

- **Keine Pro-Geschäft-Konfiguration** der drei Schwellwerte (siehe oben).
- **Keine Rückfrage bei Wochen-/Monatsverdichtung** — anders als bei der
  Tages-Kollision läuft diese Stufe vollautomatisch ohne Interaktion
  (Nutzerentscheidung: „höchsten behalten" ist eine feste, immer gleich
  angewendete Regel, keine Einzelfall-Entscheidung wie bei einer möglichen
  Scan-Fehlerkennung).
