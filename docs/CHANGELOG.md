# Changelog

## v1.6 — Explizite SwiftData-Migrationslogik (`SchemaMigrationPlan`)

- `Models/SchemaDefinition.swift`: neue `SchemaV1` (``VersionedSchema``, aktueller
  Modellstand) und `ShopWithMeMigrationPlan` (``SchemaMigrationPlan``, aktuell mit
  einer Version und ohne Stages). `SchemaDefinition.schema`/`.migrationPlan` liefern
  beides zentral für App-Start und `DatabaseLocationService`.
- `App/ShopWithMeApp.swift`: `ModelContainer` wird jetzt mit `migrationPlan:
  SchemaDefinition.migrationPlan` aufgebaut statt sich implizit auf SwiftDatas
  automatische Lightweight-Migration zu verlassen.
- Ausführliche DocC-Dokumentation an `ShopWithMeMigrationPlan` legt das Vorgehen für
  jede künftige Datenmodell-Änderung fest (neue `SchemaVN` + passende
  `MigrationStage`, `.lightweight` vs. `.custom`) — Hintergrund und Auslöser
  (v1.4→v1.5-Absturz) in `docs/DECISIONS.md` festgehalten.

## v1.5 — Absturz beim Öffnen eines Geschäfts nach v1.4-Update behoben

- `Models/Geschaeft.swift`: `regalSortierModus` (neu in v1.4) crashte für vor
  v1.4 angelegte Geschäfte, sobald die Detailansicht geöffnet wurde — SwiftData
  konnte den fehlenden Spaltenwert bestehender Datensätze nicht auf das
  nicht-optionale `RegalSortierModus`-Enum casten
  (`Could not cast value of type 'Swift.Optional<Any>' to 'RegalSortierModus'`).
  Reproduziert über ein eigenständiges Migrationsexperiment: Store mit altem
  Schema (ohne die Spalte) anlegen, mit neuem Schema erneut öffnen und den
  bestehenden Datensatz lesen — das löste den exakt gemeldeten Absturz aus.
  Behoben, indem der Rohwert jetzt optional (`regalSortierModusRaw: String?`)
  gespeichert wird; `regalSortierModus` ist ein Computed-Property darüber, das
  bei fehlendem/ungültigem Rohwert sicher auf `.manuell` zurückfällt.
- Neuer Unit-Test `regalSortierModusFaelltOhneGespeichertenRohwertAufManuellZurueck`
  (`ModelTests`) hält dieses Verhalten fest.

## v1.4 — Manuelle und automatische Regal-Reihenfolge als gleichberechtigte Alternativen

- `Models/Geschaeft.swift`: neues `RegalSortierModus`-Enum (`manuell`/`automatisch`)
  und neue Property `regalSortierModus` (Default `.manuell`) legen pro Geschäft fest,
  welche Regal-Reihenfolge tatsächlich verwendet wird.
- `Services/ShelfOrderLearningService.swift`: neue
  `automatischeReihenfolgeVerfuegbar(fuer:context:)` und
  `effektiveReihenfolge(fuer:context:)` — Letztere liefert je nach
  `regalSortierModus` entweder die manuelle (`Regal/sortIndex`) oder die gelernte
  Reihenfolge, ohne dass ein Moduswechsel die jeweils andere überschreibt.
- `Views/Geschaefte/GeschaeftDetailView.swift`: die bisherige einmalige
  „Automatische Reihenfolge übernehmen“-Aktion ist einem Segmented-Picker
  gewichen, mit dem der Anwender jederzeit zwischen „Manuell“ (Drag & Drop im
  Bearbeiten-Modus) und „Automatisch“ wechselt, sobald genug Einkäufe gelernt
  wurden. Der Picker erscheint nur, wenn genügend Statistiken vorliegen.
- `Views/Einkaufen/EinkaufenView.swift`: die Gruppierung der Einkaufsliste nach
  Regal folgt jetzt ebenfalls `effektiveReihenfolge(fuer:context:)` statt starr
  `Regal/sortIndex`.
- Neuer Unit-Test `automatischerModusUeberschreibtManuelleReihenfolgeNicht`
  (`ShelfOrderLearningServiceTests`) prüft, dass Hin- und Herschalten zwischen den
  Modi die manuelle Reihenfolge unangetastet lässt.

## v1.3 — Unkategorisierte Artikel fallen automatisch unter „Sonstiges“

- `Models/ArtikelKategorie.swift`: neue statische Methode `sonstige(context:)`
  findet die "Sonstiges"-Kategorie (normalerweise über `SeedData` angelegt) oder
  erzeugt sie defensiv, falls sie ausnahmsweise fehlt.
- `Models/Artikel.swift`: neue `effektiveKategorie(context:)` liefert `kategorie`,
  oder — falls keine gesetzt ist — automatisch "Sonstiges". Wird jetzt überall
  verwendet, wo bisher zwischen "hat Kategorie" und "hat keine Kategorie"
  unterschieden wurde.
- `Models/Einkaufsvorgang.swift`: `artikelAbhaken(_:context:)` nutzt
  `effektiveKategorie(context:)` — unkategorisierte Artikel teilen sich jetzt den
  `kategorieBesuchsIndex` mit explizit als "Sonstiges" kategorisierten Artikeln,
  statt separat gezählt zu werden. `naechsterKategorieBesuchsIndex` braucht damit
  keinen Sonderfall für `nil` mehr.
- `Views/Einkaufen/EinkaufenView.swift`: die bisherige separate „Ohne Kategorie“-
  Sektion entfällt; unkategorisierte Artikel landen jetzt in derselben Sektion wie
  Artikel mit expliziter "Sonstiges"-Kategorie, inklusive gelernter Sortierung.
- `Views/Artikel/ArtikelEditView.swift`: Kategorie-Auswahl ist beim Anlegen/
  Bearbeiten eines Artikels nicht mehr Pflicht — ohne Auswahl greift automatisch
  "Sonstiges" (Hinweistext in der Fußzeile ergänzt).
- Neue Unit-Tests: `unkategorisierterArtikelFaelltUnterSonstigesUndTeiltSichDenIndex`
  (`EinkaufsvorgangTests`) und `sonstigeKategorieWirdBeiBedarfAngelegtUndWiederverwendet`
  (`ModelTests`).
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 10 Unit-Tests bestehen.

## v1.2 — Lern-Algorithmus auf Artikelkategorie umgestellt

- `Models/KategorieBesuchsStatistik.swift` (neu) ersetzt `RegalBesuchsStatistik`:
  die gelernte Besuchsstatistik hängt jetzt an der ``ArtikelKategorie`` eines
  Artikels statt am ``Regal`` — Grundlage dafür, dass auch Geschäfte ohne Regale
  (seit v1.0 möglich) eine sinnvolle Sortierung bekommen.
- `Models/KaufEintrag.swift` / `Models/Einkaufsvorgang.swift`: `regal`/
  `regalBesuchsIndex` durch `kategorie`/`kategorieBesuchsIndex` ersetzt;
  `artikelAbhaken(_:context:)` leitet die Kategorie jetzt selbst vom Artikel ab
  (kein `regal`-Parameter mehr nötig).
- `Services/ShelfOrderLearningService.swift`: neue
  `kategoriePositionen(fuer:context:)` liefert die gelernten Kategorie-Positionen
  eines Geschäfts direkt — genutzt sowohl zur Regal-Reihenfolge (Durchschnitt über
  `Regal/kategorien`) als auch von `EinkaufenView` zur Sortierung der „Sonstige“-
  Sektion in Geschäften ohne Regal.
- Neuer Unit-Test `liefertKategorieReihenfolgeFuerLadenOhneRegal` verifiziert die
  Kategorie-Reihenfolge für ein Geschäft ganz ohne Regale.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 8 Unit-Tests bestehen.

## v1.1 — Artikel direkt aus der Einkaufsliste hinzufügen

- Neu: `Views/Einkaufen/ArtikelHinzufuegenView.swift` — Sheet mit Suchfeld über alle
  bereits angelegten Artikel, aufrufbar über den neuen „+“-Button in der
  Einkaufsliste (`Views/Einkaufen/EinkaufenView.swift`). Antippen eines
  Suchtreffers setzt den Artikel direkt auf die Einkaufsliste.
- Findet die Suche keinen exakten Namenstreffer, kann der Artikel per „„…“ neu
  anlegen“ sofort über die bestehende `ArtikelEditView` angelegt werden
  (inkl. Kategorie-Auswahl) und landet danach automatisch auf der Einkaufsliste.

## v1.0 — Globale Einkaufsliste & frei änderbare Kategorie

- `Views/Einkaufen/EinkaufenView.swift`: Die Einkaufsliste ist jetzt global und nicht
  mehr von einer Geschäftsauswahl abhängig. Der Geschäft-Picker bekommt eine „Kein
  Geschäft“-Option; ohne Geschäftsauswahl ist die Liste flach, mit Geschäftsauswahl
  weiterhin nach Regal gruppiert. Artikel ohne Kategorie oder ohne Regal-Zuordnung im
  gewählten Geschäft wurden bisher ausgeblendet — sie erscheinen jetzt in einer
  eigenen „Sonstige“-Sektion statt nur als Hinweistext gezählt zu werden.
- `Models/Artikel.swift` / `Views/Artikel/ArtikelEditView.swift`: die Kategorie eines
  Artikels ist nun auch nach dem Anlegen jederzeit änderbar (vorher nach dem ersten
  Speichern schreibgeschützt).
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- Das in v0.9 vermerkte offene Problem behoben: `ShopWithMeTests` bekommt über
  `GENERATE_INFOPLIST_FILE: YES` (`project.yml`) ein automatisch generiertes
  Info.plist, wodurch Code-Signing für das Test-Target wieder funktioniert.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 7 Unit-Tests bestehen.

## v0.9 — Kamera-Funktion reaktiviert

- `NSCameraUsageDescription` wieder ergänzt (jetzt über `info.properties` in
  `project.yml`, da die App auf ein explizites `ShopWithMe/Info.plist` umgestellt
  wurde und nun mit `DEVELOPMENT_TEAM` code-signed wird).
- `Views/Einkaufen/BelegScanView.swift`: Kamera-Aufnahme (`KameraAufnahmeView`,
  `UIImagePickerController`) und der „Foto aufnehmen“-Button wieder hergestellt;
  Fotomediathek bleibt als Alternative bestehen.
- Hilfe-Eintrag in `HelpView` entsprechend zurückgesetzt.
- Verifiziert: Simulator-Build (`xcodegen generate` + `xcodebuild build`,
  `generic/platform=iOS Simulator`) läuft mit reaktivierter Kamera fehlerfrei durch.
- Verifiziert: echter code-signierter Geräte-Build (`generic/platform=iOS`,
  Team `CBYLYH36PT`) baut und signiert erfolgreich; das entstandene `.app`
  enthält gültige Entitlements (`application-identifier`,
  `com.apple.developer.team-identifier`). Ein vorheriger Versuch mit Team
  `BB7HRC29RE` scheiterte mit „No Account for Team“/fehlendem
  Provisioning-Profil, weil für diesen Team kein Account in Xcode hinterlegt
  war — kein Camera-spezifisches Problem, sondern ein Account-/Team-Mismatch,
  der sich mit dem Wechsel auf `CBYLYH36PT` erledigt hat.
- Separat aufgefallen (nicht durch diese Änderung verursacht): das
  `ShopWithMeTests`-Target hat inzwischen `CODE_SIGN_STYLE`/`DEVELOPMENT_TEAM`
  gesetzt, aber kein Info.plist-Setup, wodurch `xcodebuild test` aktuell mit
  „Cannot code sign because the target does not have an Info.plist file“
  fehlschlägt.

## v0.8 — Kamera-Funktion deaktiviert

- Das Camera-Entitlement (`NSCameraUsageDescription`) wird vom Apple-Developer-Account
  aktuell nicht unterstützt und wurde daher wieder entfernt (`project.yml`).
- `Views/Einkaufen/BelegScanView.swift`: Beleg-Erfassung nur noch über die
  Fotomediathek (`PhotosPicker`); die Kamera-Aufnahme (`UIImagePickerController`,
  `KameraAufnahmeView`) wurde entfernt.
- Hilfe-Eintrag „Belegscan & Preishistorie“ in `HelpView` an den Wegfall der
  Kamera-Option angepasst.

## v0.7 — Belegscan & Preishistorie

- `Services/ReceiptScanService.swift`: Protokoll + `VisionFoundationModelsReceiptScanner`
  (Vision-OCR + FoundationModels-Strukturextraktion) erkennt Artikel und Preise auf
  einem fotografierten Kassenbon.
- `Views/Einkaufen/BelegScanView.swift`: Foto aufnehmen (Kamera, falls verfügbar)
  oder aus der Fotomediathek wählen, erkannte Positionen prüfen/korrigieren und
  übernehmen. Nach „Einkauf abschließen“ bietet `EinkaufenView` den Scan aktiv an.
  Erkannte Positionen werden bestehenden `KaufEintrag`en zugeordnet (Namensabgleich)
  oder als eigenständiger Eintrag ohne Artikel-Verknüpfung gespeichert, damit keine
  erfassten Preise verloren gehen.
- `Views/Historie/PreisHistorieZeile.swift`: gemeinsame Zeilen-Ansicht für die
  Preishistorie, eingebunden in `ArtikelEditView` (pro Artikel) und
  `GeschaeftDetailView` (pro Geschäft).
- `NSCameraUsageDescription` in `project.yml` ergänzt.
- Hilfe-Eintrag „Belegscan & Preishistorie“ in `HelpView` ergänzt.

## v0.6 — KI-Vorschlag, Einstellungen & Datenbank-Speicherort

- `Services/AISuggestionService.swift`: FoundationModels-basierter Vorschlag
  (Symbol, Farbe, Kategorie, informativer Regal-Hinweis) beim Anlegen eines
  Artikels; blendet sich aus, wenn Apple Intelligence auf dem Gerät nicht
  verfügbar ist (`SystemLanguageModel.default.isAvailable`).
- `ArtikelEditView` bekommt einen „Mit Apple Intelligence vorschlagen“-Button
  (nur bei neuen Artikeln, nur wenn verfügbar).
- `Views/Einstellungen/SettingsView.swift` + `HelpView.swift`: Einstellungsmenü mit
  ausklappbaren Anleitungen zu Regal-Zuordnung, Lern-Algorithmus,
  KI-Vorschlägen und Datenbank-Speicherort.
- `Services/DatabaseLocationService.swift` + `DatabaseLocationSettingsView.swift`:
  erlaubt, die SwiftData-Datenbank in einen selbst gewählten Ordner zu verlegen
  (Security-Scoped-Bookmark, reine Dateiverlagerung, kein iCloud-Sync). Wirksam
  nach Neustart der App.
- `Models/SchemaDefinition.swift`: zentrale Schema-Definition, damit App-Start und
  Datenbank-Speicherort-Logik dieselbe Modell-Liste verwenden.
- Toter Platzhalter-Code in `RootView` entfernt, da alle vier Tabs jetzt echte
  Views zeigen.

## v0.5 — Lern-Algorithmus für Regal-Reihenfolge

- `Services/ShelfOrderLearningService.swift`: wertet abgeschlossene
  Einkaufsvorgänge aus, pflegt `RegalBesuchsStatistik` je Regal und leitet daraus
  eine vorgeschlagene Regal-Reihenfolge ab (ab 5 abgeschlossenen Einkäufen in einem
  Geschäft).
- `GeschaeftDetailView` zeigt den Vorschlag als Banner an, wenn er von der
  aktuellen manuellen Reihenfolge abweicht; der Anwender übernimmt ihn explizit
  über einen Button — die manuelle Reihenfolge wird nie automatisch überschrieben.
- `EinkaufenView` ruft `ShelfOrderLearningService.lernenAus(...)` beim Abschließen
  eines Einkaufs auf.
- Neuer Unit-Test `ShelfOrderLearningServiceTests` verifiziert, dass die gelernte
  Reihenfolge von einer bewusst falsch gewählten manuellen Reihenfolge abweichen
  und korrekt übernommen werden kann.

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
