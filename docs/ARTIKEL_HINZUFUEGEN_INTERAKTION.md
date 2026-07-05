# Artikel hinzufügen — Mehrfachauswahl

Status: **Umgesetzt** (`Views/Einkaufen/ArtikelHinzufuegenView.swift`).

## Ausgangslage

`ArtikelHinzufuegenView` fügte einen Artikel bislang einzeln hinzu: ein Tap auf
eine Zeile übernahm sie sofort auf die `Einkaufsliste` und schloss das Sheet.
Wollte man mehrere Artikel ergänzen, musste man das Sheet für jeden Artikel
erneut öffnen.

## Entscheidung

- **Tap auf die ganze Zeile wählt aus/ab**, statt sofort zu übernehmen — ein
  gefüllter Haken (`checkmark.circle.fill`, Akzentfarbe) markiert eine
  ausgewählte Zeile, ein leerer Kreis eine unausgewählte; die Zeile selbst wird
  zusätzlich farblich hervorgehoben (`listRowBackground`).
- **„Hinzufügen (n)“ im Toolbar übernimmt alle ausgewählten Artikel auf
  einmal** und schließt danach das Sheet; ohne Auswahl ist der Button
  deaktiviert. „Abbrechen“ verwirft die gesamte Auswahl.
- **Bereits auf der Liste stehende Artikel** zeigen statt der
  Auswahlmöglichkeit einen „Auf Liste“-Hinweis und sind nicht antippbar.
- **Direktanlage eines neuen Artikels** (`„X“ neu anlegen`) landet nach dem
  Sichern automatisch in der Auswahl, statt wie zuvor sofort committet zu
  werden — der Nutzer kann direkt weitere Artikel dazu auswählen.
- Zeilen zeigen zusätzlich Kategorie-Icon/Farbe über den gemeinsamen
  `GlassSymbolBadge`-Baustein (`DesignSystem/GlassStyles.swift`), analog zu
  `GeschaeftListView`/`GeschaeftDetailView`.

## Bugfix: Sheet-Dismiss-Reihenfolge bei `.sheet(item:onDismiss:)`

Bei der Umstellung auf Mehrfachauswahl zeigte sich, dass ein über „neu
anlegen“ erstellter Artikel nie in der Auswahl landete. Ursache: SwiftUI
setzt die an `.sheet(item: $neuerArtikelEntwurf)` gebundene Property bereits
**vor** dem Aufruf von `onDismiss` auf `nil` zurück. Der bisherige Code las
innerhalb von `onDismiss` erneut `neuerArtikelEntwurf`, um zu prüfen, ob der
Entwurf tatsächlich gesichert wurde — und griff damit immer auf `nil` zu.

**Fix:** Eine zweite, vom Sheet-Binding unabhängige `@State`-Property
(`zuletztAngelegterEntwurf`) hält die Referenz auf den Entwurf über den
Dismiss-Vorgang hinweg fest; `onDismiss` liest ausschließlich daraus.

## Begründung

| Aspekt | Begründung |
|---|---|
| Mehrfachauswahl statt Sofort-Hinzufügen | Beim Einkaufsplanen werden typischerweise mehrere Artikel auf einmal ergänzt — wiederholtes Öffnen/Schließen des Sheets pro Artikel war unnötiger Aufwand. |
| Auswahl über die ganze Zeile | Größere Trefferfläche als ein separates Checkbox-Element, entdeckbarer, entspricht der expliziten Anforderung. |
| Direktanlage landet in Auswahl statt Sofort-Commit | Konsistent mit dem neuen Mehrfachauswahl-Modell — ein neu angelegter Artikel ist fachlich nichts anderes als ein ausgewählter Artikel. |
| Getrennte `zuletztAngelegterEntwurf`-Property | Einfachster Fix für die SwiftUI-Timing-Falle, ohne die Sheet-Signatur (`sheet(item:onDismiss:content:)`, kein Item-Parameter im Closure) zu verlassen. |

## Bekannte Grenzen

- Während das Suchfeld aktiv fokussiert ist, blendet iOS die Navigationsleiste
  (inkl. „Abbrechen“/„Hinzufügen“) systemseitig aus, bis der Suchfokus verlassen
  wird (Tippen außerhalb, Wischen in der Liste) — Standardverhalten von
  `.searchable()`, nicht spezifisch für diese Ansicht.
