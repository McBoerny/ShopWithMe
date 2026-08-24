# Artikel hinzufügen — Interaktionsmodell

Status: **Umgesetzt** (`Views/Einkaufen/ArtikelHinzufuegenView.swift`).

## Verhalten

- **Tap auf die Zeile (außer Mengenangabe) schaltet sofort um** — ein gefüllter
  Haken (`checkmark.circle.fill`, Akzentfarbe) markiert einen bereits auf der
  Liste stehenden Artikel, ein leerer Kreis einen nicht enthaltenen. Sofortiger
  Commit ohne Bestätigungsschritt; das Sheet bleibt offen, damit mehrere Artikel
  nacheinander ergänzt werden können (GitHub #45).
- **„Fertig" schließt das Sheet.** Kein Abbrechen nötig, da jede Aktion sofort
  rückgängig gemacht werden kann (erneuter Tap entfernt den Artikel wieder).
- **Hat ein Artikel Produkte**, erscheint ein Chevron — Tippen klappt die
  Produktliste inline aus. Jedes `(Artikel, Produkt)`-Paar ist ein unabhängiger
  Eintrag, sodass mehrere Produkte desselben Artikels gleichzeitig auf der Liste
  stehen können (GitHub #47).
- **Abteilung-Icon/Farbe** über den gemeinsamen `GlassSymbolBadge`-Baustein
  (`DesignSystem/GlassStyles.swift`).
- **Preise werden nicht angezeigt** (GitHub #124).

## Mengenanzeige und Verfeinerung (GitHub #124)

Für bereits auf der Liste stehende Einträge erscheint links vom Haken die aktuelle
Menge (z.B. „2 Stk."). Ein Tap darauf öffnet `MengenNotizSheet` — identisch zum
Verhalten beim Einkaufen (`ArtikelAbhakZeile`):

- **Hauptzeile (Artikel ohne benannte Produkte):** Menge wird angezeigt, wenn der
  Artikel auf der Liste steht. Der Rest der Zeile (Icon + Name) ist der Toggle.
- **Hauptzeile (Artikel mit Produkten):** Keine Menge in der Hauptzeile —
  Mengenanzeige findet ausschließlich in den ausgeklappten Produktzeilen statt.
- **Produktzeilen:** Menge wird angezeigt, wenn das jeweilige Produkt ausgewählt
  ist (`istGewaehlt`). Tap öffnet ebenfalls `MengenNotizSheet`.

Der Toggle-Bereich (die gesamte Zeile minus Mengenanzeige) wählt den Artikel bzw.
das Produkt an oder ab. Haken und Menge-Tap sind damit zwei getrennte Tippziele.

## Direktanlage neuer Artikel

Findet die Suche keinen exakten Treffer, erscheint „X neu anlegen". Der neue
Artikel landet nach dem Sichern sofort auf der Liste (GitHub #6).

## Bugfix: Sheet-Dismiss-Reihenfolge bei `.sheet(item:onDismiss:)`

SwiftUI setzt die an `.sheet(item: $neuerArtikelEntwurf)` gebundene Property bereits
**vor** dem Aufruf von `onDismiss` auf `nil` zurück. Der bisherige Code las
innerhalb von `onDismiss` erneut `neuerArtikelEntwurf` — und griff damit immer auf
`nil` zu, sodass ein neu angelegter Artikel nie auf der Liste landete.

**Fix:** Eine zweite, vom Sheet-Binding unabhängige `@State`-Property
(`zuletztAngelegterEntwurf`) hält die Referenz über den Dismiss-Vorgang hinweg fest;
`onDismiss` liest ausschließlich daraus.

## Suchfeld: sofortiger Fokus statt Pull-to-Search

Abweichend von der sonstigen Suchleisten-Konvention (`.searchable(text:prompt:)`
ohne weitere Parameter, siehe `ProduktVerwaltungView`) fokussiert das Suchfeld
hier beim Öffnen des Sheets automatisch, damit sofort getippt werden kann, ohne
vorher antippen zu müssen. Umgesetzt über `.searchable(text:placement:
.navigationBarDrawer(displayMode: .always), prompt:)` kombiniert mit
`.searchFocused($suchfeldFokussiert)` und `.onAppear { suchfeldFokussiert =
true }` — `.navigationBarDrawer(displayMode: .always)` hält Titel und „Fertig"
dauerhaft sichtbar, `.searchFocused` steuert nur den Tastaturfokus.

**Vormals `.searchable(isPresented:)` statt `.searchFocused`:** Eine frühere
Fassung koppelte den Auto-Fokus stattdessen an `isPresented`. Das koppelte den
Tastaturfokus an den „aktiv suchend"-Zustand des Suchfelds selbst — ein Tap auf
„Fertig" bei fokussiertem Suchfeld beendete dadurch zunächst nur die Suche
(erster Tap) und schloss das Sheet erst beim zweiten Tap. `.searchFocused`
steuert ausschließlich den Tastaturfokus, ohne diese Kopplung, und behebt damit
den Doppel-Tap.
