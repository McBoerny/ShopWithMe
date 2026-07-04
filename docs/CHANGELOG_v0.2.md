# ShopWithMe v0.2 — Änderungen gegenüber v0.1

Diese Datei konsolidiert alle Änderungen des abgeschlossenen `v0.1`-Zyklus
(Build 17 bis Build 24) zu einem Versions-Changelog für den Wechsel auf `v0.2`. Die
einzelnen Build-für-Build-Einträge mit vollem Detailgrad bleiben weiterhin in
`docs/CHANGELOG.md` erhalten — diese Datei fasst sie thematisch zusammen.

## Kategorien & Regale

- Ein Regal kann jetzt nur noch Kategorien zur Auswahl anbieten, die nicht bereits
  einem anderen Regal desselben Geschäfts zugeordnet sind — jede Kategorie soll
  innerhalb eines Geschäfts höchstens einem Regal angehören
  (`Regal.auswaehlbareKategorien(aus:)`). Neue Kategorien lassen sich direkt aus der
  Regal-Bearbeitung heraus anlegen (Name, Symbol & Farbe wie bei Artikeln).
- Die Geschäft-Detailansicht zeigt jetzt einen eigenen „Kategorien“-Abschnitt neben
  „Regale“: listet alle im Geschäft verfügbaren Kategorien mit dem Regal, dem sie
  ggf. zugeordnet sind, erlaubt das Entfernen per Wischgeste und das Hinzufügen über
  ein eigenes Sheet (`KategorieHinzufuegenSheet`).
- **Architekturwechsel: Kategorien sind wichtiger als Regale, Regale sind optional.**
  Ein Geschäft kann Kategorien jetzt direkt zugeordnet bekommen
  (`Geschaeft.kategorien`), ganz ohne ein Regal anzulegen. `verfuegbareKategorien` ist
  die Vereinigung aus dieser direkten Zuordnung und den über Regale zugeordneten
  Kategorien — ein Regal ist damit nur noch für die Sortierung der Einkaufs-Reihenfolge
  relevant, keine Voraussetzung für Verfügbarkeit mehr. Das korrigiert die
  ursprüngliche Entscheidung „Kein separates Kategorie-pro-Geschäft-Modell“ aus der
  Frühphase des Projekts (siehe `docs/DECISIONS.md`).

## Einkaufen-Flow

- Ein Einkauf startet jetzt automatisch beim Öffnen des Einkaufen-Tabs — kein
  manueller „Start“ mehr nötig.
- Neues `ArtikelFilterModus`-Attribut pro Geschäft (`nurVerfuegbare`/`alle`) plus
  neuer `ArtikelVerfuegbarkeitService`: bestimmt, ob ein Artikel in einem Geschäft
  verfügbar ist — über die Kategorien des Geschäfts, oder (besitzt es keine eigenen
  Kategorien) gelernt aus der Kaufhistorie, sobald der Artikel dort einmal gekauft
  wurde.
- Der bisherige Zwei-Werte-Anzeige-Umschalter („Nur offene“/„Alle“) ist einem
  dritten „Lernmodus“ gewichen, der den Verfügbarkeitsfilter für einen Einkauf gezielt
  übergeht, um bislang unbekannte Artikel abzuhaken und dadurch als verfügbar zu
  lernen.
- Bereits abgehakte Artikel lassen sich während eines laufenden Einkaufs weiterhin
  anzeigen, zurückholen oder per Wischgeste dauerhaft aus der Ansicht entfernen
  (`Einkaufsvorgang.artikelDauerhaftEntfernen`).

## Kaufbeleg-Scan & Preishistorie

- Kaufbeleg-Scan funktioniert jetzt auch unabhängig von einem laufenden Einkauf
  direkt aus der Geschäfts-Detailansicht heraus (neuer `BelegScanKontext`), inklusive
  Einzelpreis-Erkennung bei Mehrfachpositionen (z.B. „3 x 1.50 = 4.50“).
- Das erkannte Einkaufsdatum eines Kassenbons ist vor der Übernahme korrigierbar
  (`erkanntesDatum`, `DatePicker` in der Ergebnisliste).
- Der ursprünglich vom Beleg erkannte Produkt-/Markenname (`KaufEintrag.produktName`)
  bleibt auch dann erhalten, wenn eine Position beim Zuordnen auf einen generischeren
  Artikel umbenannt wird — die Preishistorie zeigt weiterhin den genauen Produktnamen
  pro Geschäft.

## Sonstiges

- Neue Unit-Tests decken die Kategorie-Ausschlusslogik pro Regal, die direkte
  Geschäft-Kategorie-Zuordnung (inkl. Deduplizierung und Entfernen ohne Regal) sowie
  Kaufhistorie-basierte Artikel-Verfügbarkeit ab.
- `docs/DECISIONS.md`, `docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md` und die
  In-App-Hilfe (`HelpView`) an die neue Kategorien-/Regal-Architektur angepasst.

Details je Build: siehe `docs/CHANGELOG.md` (Build 18–24).
