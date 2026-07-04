# ShopWithMe — Roadmap / Checkpoints

Jeder Checkpoint ist ein Git-Commit, der die Version (`VERSION`-Datei + `project.yml`
`MARKETING_VERSION`) um `0.1` erhöht. Format: `vX.Y: <Kurzbeschreibung>`.

## Umgesetzt / in Arbeit

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
- [ ] **v0.6** — KI-Artikelvorschlag (`AISuggestionService`) +
  Einstellungen/Hilfe-Bildschirme + Datenbank-Speicherort-Funktion.
- [ ] **v0.7** — Belegscan (`ReceiptScanService`) + Preishistorie-Ansicht.

## Zukünftig (nicht terminiert)

- Standort-basierte automatische Anzeige der passenden Einkaufsliste (Geschäft in der
  Nähe erkennen). Datenmodell (Lat/Long am Geschäft) ist vorbereitet.
- Echter iCloud-/CloudKit-Sync der Datenbank (aktuell nur lokale Speicherort-Wahl ohne
  Sync-Logik).
- Ablösen von `ReceiptScanService`/`VisionFoundationModelsReceiptScanner` durch
  speziellere, künftige On-Device-Scan-APIs, sobald verfügbar und mit verifizierten
  Namen bekannt (zum Zeitpunkt der Erstellung war kein iOS-27-SDK verfügbar).
