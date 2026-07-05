# Mehrere Einkaufslisten

Status: **Umgesetzt** (`Models/Einkaufsliste.swift`, `Models/EinkaufslistenEintrag.swift`,
`Views/Einkaufen/EinkaufenView.swift`).

## Ausgangslage

Bis einschließlich v0.2 war die Einkaufsliste global und geräteweit eindeutig: ob ein
`Artikel` „auf der Liste“ stand, dessen aktuell gewünschte Menge und eine temporäre
Notiz waren direkte, nicht-optionale Attribute auf `Artikel` selbst
(`istAufEinkaufsliste: Bool`, `menge`/`mengeRaw`, `einkaufslistenNotiz`) — siehe
`docs/PRODUCT_SPEC.md` ("Die Einkaufsliste ist global und nicht von einem Geschäft
abhängig"). Das funktionierte nur, weil es genau eine Liste gab: ein Artikel konnte
nicht gleichzeitig mit unterschiedlicher Menge auf zwei Listen stehen.

## Entscheidung

- **Neues Modell `Einkaufsliste`** (`id`, `name`, `erstelltAm`): beliebig viele,
  vom Nutzer benannte Listen (z.B. „Wocheneinkauf“, „Baumarkt“).
- **Neues Join-Modell `EinkaufslistenEintrag`**: die Mitgliedschaft eines `Artikel`s
  auf einer bestimmten `Einkaufsliste`, mit dafür eigener `menge` und `notiz`. Ein
  Artikel kann dadurch gleichzeitig auf mehreren Listen stehen, jeweils mit eigener
  Menge. `Artikel.istAufEinkaufsliste`/`menge`/`einkaufslistenNotiz` wurden dafür
  **entfernt** (keine additiv-optionale Ergänzung, sondern eine strukturelle
  Verschiebung auf ein neues Modell — siehe „Migration“ unten).
- **`Einkaufsvorgang` bekommt ein neues Feld `einkaufsliste: Einkaufsliste?`**: ein
  Einkauf bezieht sich jetzt auf die Kombination aus Geschäft *und* Liste — pro
  Kombination existiert höchstens ein offener `Einkaufsvorgang` gleichzeitig
  (`EinkaufenView.aktuellerEinkauf`).
- **`EinkaufenView`** bekommt einen zweiten Picker (Menü, `.topBarLeading`) zur
  Auswahl der aktiven Liste, mit einer „Neue Liste …“-Schnellaktion direkt darin.
  Eine vollständige Verwaltung (Umbenennen/Löschen) liegt wie bei Kategorien in den
  Einstellungen (`EinkaufslistenVerwaltungView`).
- **Fetch-or-Create-Idiom** `Einkaufsliste.standard(context:)` (analog
  `ArtikelKategorie.sonstige(context:)`) legt beim allerersten Öffnen von „Einkaufen“
  automatisch eine erste Liste namens „Einkaufsliste“ an, damit der Nutzer nicht ohne
  Liste dasteht.
- **Abhaken** (`Einkaufsvorgang.artikelAbhaken`) übernimmt die Menge aus dem
  `EinkaufslistenEintrag` der aktuellen Liste in den neu angelegten `KaufEintrag` und
  löscht anschließend nur diesen einen Eintrag — Mitgliedschaften auf anderen Listen
  bleiben unberührt. Rückgängigmachen (`artikelAbwaehlen`) legt über
  `Einkaufsliste.artikelHinzufuegen(_:context:)` wieder einen frischen Eintrag an
  (Menge zurückgesetzt auf `Artikel.mengenSchritt`, Notiz geleert — exakt das
  bisherige Verhalten von `aufEinkaufslisteSetzen()`).
- Für einen bereits abgehakten Artikel gibt es keinen `EinkaufslistenEintrag` mehr;
  Menge-Anzeige und Swipe-Mengenänderung greifen für diesen Zustand stattdessen direkt
  auf den zugehörigen `KaufEintrag.menge` zu (siehe `EinkaufslisteView.menge(fuer:)`).

## Migration

Diese Änderung ist strukturell (Felder werden von `Artikel` auf ein neues Modell
verschoben), aber **ohne neue `SchemaVN`/`MigrationStage`** umgesetzt — die beiden
neuen Modelltypen wurden einfach additiv zu `SchemaV1.models` ergänzt (siehe
`docs/DECISIONS.md`, `Models/SchemaDefinition.swift`: neue Modelltypen sind
unkritisch, SwiftDatas Lightweight-Migration legt dafür einfach neue Tabellen an).
Kritisch wäre nur eine neue, nicht-optionale Spalte auf einem *bestehenden* Modell
gewesen (siehe die dokumentierten SwiftData-Fallen in `docs/DECISIONS.md`) — das
Entfernen von `Artikel.istAufEinkaufsliste`/`mengeRaw`/`einkaufslistenNotiz` fällt
nicht darunter.

**Bewusst in Kauf genommener Datenverlust:** Es gibt keine automatische Übernahme der
vor diesem Update auf der (damals einzigen, globalen) Liste stehenden Artikel in die
neu angelegte Standardliste — wer beim Update Artikel angehakt hatte, muss sie einmalig
erneut hinzufügen. Wurde bewusst so entschieden, da es sich um rein ephemeren
„aktueller Warenkorb“-Zustand handelt (kein Verlust von Artikel-Katalog, Kategorien,
Geschäften oder Kaufhistorie/Preisen) und eine echte Datenübernahme eine eingefrorene
`SchemaV2` samt `MigrationStage` vorausgesetzt hätte — der in `docs/DECISIONS.md`
dokumentierte, für dieses Projekt (flache Modell-Klassen statt versionierter Typen)
bislang ungelöste Aufwand.

## Bekannte Grenzen

- Keine Reihenfolge/Drag-Sortierung der Listen selbst — Anzeige- und Auswahl-Reihenfolge
  ist schlicht `erstelltAm` (älteste zuerst).
- Löschen einer Liste löscht nur ihre `EinkaufslistenEintrag`e (cascade), nicht
  vergangene `Einkaufsvorgang`e/`KaufEintrag`e, die sich einmal auf sie bezogen haben
  (`Einkaufsvorgang.einkaufsliste` wird beim Löschen der Liste einfach `nil`) — die
  Kaufhistorie bleibt dadurch vollständig erhalten.
