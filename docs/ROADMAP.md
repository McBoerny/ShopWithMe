# ShopWithMe — Roadmap / Checkpoints

Jeder Checkpoint ist ein Git-Commit mit einem `docs/CHANGELOG.md`-Eintrag. Format:
`vX.Y (Build N): <Kurzbeschreibung>`. `X.Y` (Major.Minor, `MARKETING_VERSION` in
`project.yml` + `VERSION`-Datei) wird manuell vom Nutzer festgelegt; `N`
(`CURRENT_PROJECT_VERSION`) ist die Build-Nummer und wird automatisch bei jedem
Commit über `.githooks/pre-commit` erhöht (siehe `docs/DECISIONS.md`). Die
Checkpoints unten aus der Zeit vor diesem Schema (bis v1.6) verwendeten `X.Y` noch
als reinen Inkrement-Zähler ohne separate Build-Nummer. Vollständige Checkliste für
Checkpoints (Versionierung, Migrationsentscheidung, Build-Umgebung, wann zusätzlich
die übrige Doku aktualisiert wird): `docs/BUILD_WORKFLOW.md`.

## Umgesetzt

- [x] **v0.1** — Projekt-Scaffold: XcodeGen-Setup, Doku-Grundgerüst, komplettes
  SwiftData-Datenmodell inkl. Seed-Daten, leere App die kompiliert.
- [x] **v0.2** — Artikel-Verwaltung: Liste/Anlegen/Bearbeiten inkl. Symbol-/Farb-Picker,
  Liquid-Glass-Designsystem-Basis.
- [x] **v0.3** — Geschäfte-Verwaltung: Liste/Anlegen/Bearbeiten, Regal-Verwaltung pro
  Geschäft, Kategorie-zu-Regal-Zuordnung.
- [x] **v0.4** — Einkaufen-Flow: Einkaufsliste pro Geschäft (nur zugeordnete
  Kategorien, gruppiert nach Regal), Einkaufsvorgang starten/abschließen, manuelle
  Regal-Reihenfolge editierbar.
- [x] **v0.5** — Lern-Algorithmus für automatische Regal-Reihenfolge
  (`ShelfOrderLearningService`) + Vorschlag in der UI.
- [x] **v0.6** — KI-Artikelvorschlag (`AISuggestionService`) +
  Einstellungen/Hilfe-Bildschirme + Datenbank-Speicherort-Funktion.
- [x] **v0.7** — Belegscan (`ReceiptScanService`) + Preishistorie-Ansicht (in
  Artikel- und Geschäfts-Detailansicht).
- [x] **v0.2 (Build 30)** — Mehrbenutzerzugriff auf einen geteilten Fileshare-Ordner
  (`DatabaseLeaseService`: Micro-Lease für diskrete Aktionen, Session-Lease für
  Bearbeitungs-Bildschirme) + optionaler DB-Debug-Logging-Mechanismus
  (`DebugLogWriter`/`DatabaseDebugLogger`) — siehe `docs/DATABASE_CONCURRENCY.md`,
  `docs/LOGGING.md`.
- [x] **v0.3** — `ArtikelHinzufuegenView` neu gestaltet: Mehrfachauswahl statt
  Sofort-Hinzufügen pro Artikel, Direktanlage landet automatisch in der Auswahl —
  siehe `docs/ARTIKEL_HINZUFUEGEN_INTERAKTION.md`.
- [x] **v0.4** — Automatische, konfigurierbare Bereinigung alter Preishistorie
  (`PreisHistorieBereinigungService`) + Einstellungen-Bildschirm — siehe
  `docs/PREISHISTORIE_BEREINIGUNG.md`.
- [x] **v0.5** — Standort-basierte automatische Ladenerkennung
  (`GeschaeftErkennungService`, Vorschlags-Banner in `EinkaufenView`) + neue
  Geschäftsverwaltung in den Einstellungen + Löschen eines Geschäfts löscht jetzt auch
  dessen Preishistorie — siehe `docs/GESCHAEFTSERKENNUNG.md`.
- [x] **v0.5** — Preisschild-Scan (`PriceTagScanService`, `PreisschildScanView`):
  fotografiert ein einzelnes Regal-Preisschild und legt Artikelname + Verkaufspreis
  direkt als `KaufEintrag` an, unabhängig vom tatsächlichen Kauf (Preisvergleich vor
  der Kaufentscheidung) — Einstieg über „Preisschild scannen“ in
  `GeschaeftDetailView`. Siehe `docs/PREISSCHILD_SCAN.md`.
- [x] **v0.5** — Automatischer Geschäfts-Abgleich beim Belegscan
  (`Geschaeft.passendes(fuerErkannterName:unter:)`, `GeschaeftWahlSheet`,
  `Geschaeft.alternativenNamenLernen(_:)`): erkennt beim nachträglichen (z.B.
  zuhause) Scannen das Geschäft automatisch anhand des erkannten Namens und
  gelernter Alias-Namen, fragt sonst nach und lernt den Namen für künftige Scans.
  Neuer geschäftsloser Scan-Einstieg in `GeschaeftListView` (nur für Belege — der
  Preisschild-Scan funktioniert bewusst weiterhin nur direkt für ein bereits
  feststehendes Geschäft, siehe `docs/PREISSCHILD_SCAN.md` → „Kein geschäftsloser
  Einstieg“) sowie Scan-Buttons in `EinkaufenView` bei bereits gewähltem Geschäft.
  Siehe `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“.

Damit ist die in der Kickoff-Unterhaltung beschriebene Kernfunktionalität
vollständig umgesetzt; weitere Ideen siehe „Zukünftig“ unten.

## Zukünftig (nicht terminiert)

- Echter iCloud-/CloudKit-Sync der Datenbank (aktuell nur lokale Speicherort-Wahl ohne
  Sync-Logik).
- Ablösen von `ReceiptScanService`/`VisionFoundationModelsReceiptScanner` durch
  speziellere, künftige On-Device-Scan-APIs, sobald verfügbar und mit verifizierten
  Namen bekannt (zum Zeitpunkt der Erstellung war kein iOS-27-SDK verfügbar).
- **Regal-Scan**: aus einem Foto eines ganzen Regals mehrere Preisschilder gleichzeitig
  erkennen (statt wie aktuell nur ein einzelnes Schild pro Foto). Konzept inkl.
  Begründung, warum das kein triviales Ausweiten von `PriceTagScanService` ist
  (räumliches Zuordnungsproblem der OCR-Textblöcke zu einzelnen Schildern, nicht die
  Texterkennung selbst), siehe `docs/PREISSCHILD_SCAN.md` → „Zukünftige Erweiterung:
  Regal-Scan“.
- Echte Trennung der Preishistorie in einen eigenen DB-Store (statt nur der
  umgesetzten Lösch-Logik in `PreisHistorieBereinigungService`) — zurückgestellt, da
  SwiftData-`@Relationship`s nicht store-übergreifend funktionieren und die dafür
  nötige Ablösung von `KaufEintrag`s operativer Rolle (laufender Einkaufsvorgang,
  `ShelfOrderLearningService`) ein eigenständiges, größeres Vorhaben wäre. Details/
  erwogene Alternativen siehe `docs/PREISHISTORIE_BEREINIGUNG.md`.
