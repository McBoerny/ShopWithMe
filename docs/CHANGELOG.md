# Changelog

## v0.4 — Einkaufen-Flow

- `Views/Einkaufen/EinkaufenView.swift`: Geschäft wählen, Einkauf starten, nach Regal
  gruppierte Einkaufsliste abarbeiten (nur Kategorien, die diesem Geschäft über
  Regale zugeordnet sind), Einkauf abschließen.
- `Einkaufsvorgang.artikelAbhaken(_:regal:context:)` /
  `artikelAbwaehlen(_:context:)`: legen/löschen `KaufEintrag`e und pflegen
  `regalBesuchsIndex` (Rohdaten für den späteren Lern-Algorithmus, v0.5).
- `KaufEintrag.preis` ist jetzt optional (`Decimal?`) und `KaufEintrag.regal`
  wurde ergänzt — siehe `docs/DECISIONS.md`.
- `Geschaeft.regal(fuer:)`: liefert das Regal, dem eine Kategorie in diesem
  Geschäft zugeordnet ist.
- Neue Unit-Tests (`EinkaufsvorgangTests`) für Abhaken/Abwählen und
  Regal-Sequenz-Zuordnung — dabei einen Bug gefunden und behoben: `context.delete()`
  aktualisierte die In-Memory-Relationship nicht sofort, `artikelAbwaehlen` entfernt
  den Eintrag jetzt zusätzlich direkt aus `kaufEintraege`.

## v0.3 — Geschäfte-Verwaltung

- `Views/Geschaefte/GeschaeftListView.swift`: Geschäfte anlegen, bearbeiten, löschen.
- `Views/Geschaefte/GeschaeftStammdatenEditView.swift`: Name/Typ/Adresse-Formular.
- `Views/Geschaefte/GeschaeftDetailView.swift`: Regal-Verwaltung pro Geschäft
  (hinzufügen, umbenennen über Regal-Detail, löschen, manuelle Reihenfolge per
  Drag & Drop im Bearbeiten-Modus).
- `Views/Geschaefte/RegalDetailView.swift`: Kategorie-zu-Regal-Zuordnung — bestimmt
  automatisch die beim Einkaufen in diesem Geschäft verfügbaren Kategorien.
- Geschäfte-Tab in `RootView` verdrahtet.

## v0.2 — Artikel-Verwaltung

- `DesignSystem/GlassStyles.swift`: `glassCard`-Modifier und `GlassSymbolBadge` als
  wiederverwendbare Liquid-Glass-Bausteine.
- `DesignSystem/Color+Hex.swift`: Hex-String-Farbkonvertierung + Standardpalette.
- `DesignSystem/SymbolColorPicker.swift`: kuratierte SF-Symbol-Auswahl, Farbpalette und
  Freitext-Eingabe für eigene SF-Symbole.
- `Views/Artikel/ArtikelListView.swift` + `ArtikelEditView.swift`: Artikel anlegen,
  bearbeiten, löschen. Kategorie ist nach Anlage schreibgeschützt.
- Artikel-Tab in `RootView` verdrahtet.

## v0.1 — Projekt-Scaffold

- XcodeGen-Setup (`project.yml`), iOS-26-Target, Bundle-ID `com.made4me.ShopWithMe`.
- Doku-Grundgerüst: `PRODUCT_SPEC.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `DECISIONS.md`.
- Komplettes SwiftData-Datenmodell: `Artikel`, `ArtikelKategorie`, `Regal`, `Geschaeft`,
  `Einkaufsvorgang`, `KaufEintrag`, `RegalBesuchsStatistik` + Seed-Daten für Standard-
  Kategorien und Geschäftstypen.
- Leere App-Hülle, die kompiliert und den `ModelContainer` aufsetzt.
