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
- [x] **v0.5** — Verfügbarkeitsfilter beim Einkaufen direkt im laufenden Einkauf statt
  als persistente Geschäfts-Einstellung: `Geschaeft.artikelFilterModus`/
  `ArtikelFilterModus` entfernt. Drei vorherige Einzel-Buttons zu einer einzigen
  Schnellauswahl in der Toolbar verschmolzen (neben „Artikel hinzufügen“): kurzer
  Tap schaltet „Nur offene“/„Auch abgehakte Artikel“ um, langer Tap (`Menu` mit
  `primaryAction`) den Lernmodus (alle Artikel, unabhängig vom Verfügbarkeitsfilter).
- [x] **v0.5** — Standort-Vorschlag „Ignorieren“ und „Alle Geschäfte in der Nähe“:
  neues Modell `IgnorierterGeschaeftsVorschlag` merkt sich dauerhaft ignorierte
  Vorschläge; neue Liste zeigt alle Läden im 100m-Radius inkl. ignorierter mit
  „Wieder aufnehmen“-Option. Zusätzlich bleibt „Neues Geschäft hinzufügen“ im
  selben Geschäft-Menü weiterhin rein manuell (unabhängig von Standort/Apple Maps)
  möglich. Suchradius in Debug-Builds über neue Einstellungen testweise erhöhbar
  (`DebugEinstellungen`, `#if DEBUG`, kein Teil des Release-Binaries). Siehe
  `docs/GESCHAEFTSERKENNUNG.md`.

- [x] **v0.9** — Mehrfachkategorien-Anzeige: ein Artikel mit mehreren Kategorien
  erscheint beim Einkaufen jetzt gleichzeitig in allen zugehörigen Abschnitten
  statt nur in einer „führenden“ (GitHub-Nachfolgefund zu #36); die getappte
  Kategorie fließt explizit in den `KaufEintrag` ein, sodass
  `AbteilungsDistanzService` pro Geschäft lernen kann, in welcher der
  mehreren Kategorien ein Artikel dort tatsächlich steht. Dazu mehrere
  Sync-Robustheits-Fixes (dangling `Einkaufsvorgang` nach „Einkauf
  abschließen“, Distanzlern-Isolation gegen fremd abgehakte Artikel) — siehe
  `docs/ARCHITECTURE.md` → „v0.9-Robustheits-Fixes“.

- [x] **v0.11** — Mehrgeräte-Live-Test-Fixes rund um „Einkauf abschließen":
  schließt jetzt alle offenen Vorgänge einer Liste statt nur den lokalen
  Anker (verhindert liegen bleibende Duplikat-Vorgänge samt daran hängender
  abgehakter Artikel); Sync-Merge-Sicherheitsnetz gegen verpasste Events
  behandelt einen bereits erfassten Kauf jetzt als dauerhaftes Faktum statt
  vorgangs-abhängig (verhindert, dass ein noch nicht aktueller Peer-Snapshot
  bereits gekaufte Artikel zurückholt); DB-Debug-Log-Writer-Instanz wird
  zwischengespeichert statt bei jedem Aufruf neu erzeugt. Details:
  `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3/4.7, `docs/LOGGING.md`.
- [x] **v0.12** — [Issue #49](https://github.com/McBoerny/ShopWithMe/issues/49):
  Multipeer-Beschleunigungskanal — spiegelt Bereich-A-`SyncEvent`s zusätzlich
  sofort per `MCSession` an verbundene Peers, solange beide Geräte gleichzeitig
  im Einkaufen-Bildschirm aktiv sind; rein additiv neben dem bestehenden
  FileProvider-Kanal, der die verlässliche Zustellung bleibt. Zurückgestellt
  gewesen, bis die beiden im Issue genannten Bedingungen (echter
  Mehrgeräte-Live-Test des Sync-Verfahrens, wiederholte reale Verzögerung
  beim gemeinsamen Einkaufen) erfüllt waren — beides durch die
  Live-Test-Serie in v0.9–v0.11 belegt (GitHub #91/#92). Details:
  `docs/DATENSYNCHRONISATION.md` Abschnitt 1, `MultipeerSyncService`-Typ-Doku.
  **Noch ohne echten Zwei-Geräte-Live-Test dieses konkreten Kanals** (siehe
  dortige „Bekannte Grenzen").
- [x] **v0.13** — [Issue #111](https://github.com/McBoerny/ShopWithMe/issues/111):
  Artikel-Alias-Namen — ein Artikel kann mehrere zusätzliche Suchbegriffe
  bekommen (z.B. „Zahncreme“ für „Zahnpasta“), unter denen ihn die
  Artikelsuche beim Einkaufen ebenfalls findet. Bleibt derselbe Artikel,
  kein eigenes Produkt/kein eigener Preis — Abgrenzung zur weiterhin
  offenen Artikelausprägung ([#47](https://github.com/McBoerny/ShopWithMe/issues/47),
  siehe „Zukünftig“ unten). Wiederverwendet das bereits vorhandene
  `ArtikelAlias`-Modell (bisher nur Bon-Scan-Erkennung) statt eines neuen Typs.

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
  `AbteilungsDistanzService`) ein eigenständiges, größeres Vorhaben wäre. Details/
  erwogene Alternativen siehe `docs/PREISHISTORIE_BEREINIGUNG.md`.
- **Nutzungs-Tracking/Analytics**: anonymisiertes Tracking-Framework zur Analyse der
  App-Nutzung — erfassen, welche Funktionen wie häufig genutzt werden, um die Roadmap
  datengestützt priorisieren zu können.
- **Artikelausprägung** ([#47](https://github.com/McBoerny/ShopWithMe/issues/47)):
  ein Artikel kann mehrere konkrete Produkt-Ausprägungen mit eigenem Preis
  haben (z.B. „Odol“/„Paradontol“/„Sebamed“ für „Zahnpasta“), im Unterschied
  zu den bereits umgesetzten Alias-Namen (v0.13, [#111](https://github.com/McBoerny/ShopWithMe/issues/111))
  keine reine Textsuche, sondern ein eigenständiges 1:n-Datenmodell mit
  Preis-Kumulierung am übergeordneten Artikel. Größerer, eigener Umbau —
  siehe verwandtes [#10](https://github.com/McBoerny/ShopWithMe/issues/10)
  zur offenen Modellfrage.
- **Modell-unabhängige Sync-Architektur** ([#75](https://github.com/McBoerny/ShopWithMe/issues/75)):
  die Datensynchronisation (`docs/DATENSYNCHRONISATION.md`) ist als Architektur-Muster
  bereits solide, aber die Implementierung eng an ShopWithMes konkretes Datenmodell
  gekoppelt (jede Entität hat eine eigene handgeschriebene Merge-Funktion). Ein
  `SyncableModel`-Protokoll + generischer Merge-Engine würde sowohl künftige
  Erweiterungen innerhalb ShopWithMes vereinfachen als auch Wiederverwendung in
  anderen Apps ermöglichen — größerer, eigenständiger Umbau, nicht Teil des
  laufenden Betriebs.
- ~~**`export.json` als Paket statt Monolith**~~ ([#82](https://github.com/McBoerny/ShopWithMe/issues/82))
  — umgesetzt, siehe `docs/EXPORT_PAKET_UMBAU.md`.
- **`ArtikelKategorie` → `Abteilung`, vollständige Modell-Umbenennung**
  ([#62](https://github.com/McBoerny/ShopWithMe/issues/62), Rest nach
  GUI-/Bezeichner-Umbenennung 2026-08-02): der `@Model`-Typ selbst sowie alle
  davon persistierten Relationship-/Attribut-Namen bleiben bewusst
  unverändert, bis eine echte strukturelle SwiftData-Migration geplant wird —
  wegen der Relationship-Kopplung zu `Artikel`, `Geschaeft`, `KaufEintrag`,
  `WarengruppenDistanz` und `GeschaeftTyp` müssten mindestens sechs
  Modelltypen pro Schema-Version eingefroren werden (erste echte strukturelle
  Migration dieses Projekts überhaupt, siehe `docs/DECISIONS.md` →
  „Duplicate version checksums"-Vorfall). Größerer, eigenständiger Umbau,
  nicht Teil des laufenden Betriebs.
