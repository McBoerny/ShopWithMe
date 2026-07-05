# ShopWithMe — Architektur

## Stack

- **SwiftUI**, iOS-only (kein macOS/Catalyst-Target), min. Deployment-Target iOS 26.0.
- **SwiftData** für Persistenz (kein Core Data, kein iCloud/CloudKit).
- **FoundationModels** (Apple Intelligence, on-device) für Artikel-Vorschläge und
  Beleg-Extraktion.
- **Vision** (`VNRecognizeTextRequest`) für Beleg-OCR.
- **XcodeGen** erzeugt das `.xcodeproj` aus `project.yml` — das Projektfile selbst wird
  nicht versioniert, nur `project.yml`. Neu auschecken: `xcodegen generate`.

## Projektstruktur

```
ShopWithMe/
  project.yml
  VERSION
  docs/                       # dieses Verzeichnis
  ShopWithMe/                 # App-Sourcen
    App/                      # App-Entry-Point, ModelContainer-Setup
    Models/                   # SwiftData @Model Typen + Seed-Daten
    Services/                 # AISuggestionService, ReceiptScanService,
                               # ShelfOrderLearningService, DatabaseLocationService
    DesignSystem/              # Liquid-Glass-Wrapper, Symbol/Farb-Picker
    Views/                    # nach Feature gruppiert: Artikel, Geschaefte,
                               # Einkaufen, Historie, Einstellungen
    Resources/                # Assets.xcassets
  ShopWithMe.docc/             # DocC-Landing-Page (Kommentare leben im Code)
  ShopWithMeTests/
```

## Datenmodell

```
ArtikelKategorie          Regal                      Geschaeft
────────────────          ─────                      ─────────
id: UUID                  id: UUID                    id: UUID
name: String              name: String                name: String
standardSymbol: String    sortIndex: Int              typ: GeschaeftTyp
standardFarbeHex: String  ┌─geschaeft: Geschaeft?      adresse: String?
sortIndex: Int            │ kategorien: [ArtikelKategorie]  breitengrad/laengengrad: Double?
┌─regale: [Regal] ────────┘                            regale: [Regal] ──┘
└─geschaefte: [Geschaeft] ─────────────────────────────kategorien: [ArtikelKategorie]
  (many-to-many, direkt —                              regalSortierModusRaw: String?
   ohne Regal nötig)                                    artikelFilterModusRaw: String?

Artikel                              Einkaufsvorgang            KaufEintrag
───────                              ───────────────            ───────────
id: UUID                             id: UUID                   id: UUID
name: String                         geschaeft: Geschaeft?      artikel: Artikel?
symbolName: String                   startZeit: Date            einkaufsvorgang: Einkaufsvorgang?
farbeHex: String                     endZeit: Date?             geschaeft: Geschaeft?  (denormalisiert)
kategorie: ArtikelKategorie?         kaufEintraege: [KaufEintrag]  datum: Date
istAufEinkaufsliste: Bool                                        preis: Decimal?
erstelltAm: Date                                                 menge: Double
                                                                  produktName: String?
                                                                  alternativerName: String?
                                                                  kategorieBesuchsIndex: Int?

KategorieBesuchsStatistik
─────────────────────────
id: UUID
geschaeft: Geschaeft?
kategorie: ArtikelKategorie?
besucheAnzahl: Int
summeSequenzPosition: Double
→ durchschnittlichePosition (computed = summe/anzahl)
```

Design-Entscheidung (aktualisiert, siehe `docs/DECISIONS.md`): **Kategorien sind
wichtiger als Regale, Regale sind optional.** Ein `Geschaeft` kann `ArtikelKategorie`n
direkt zugeordnet bekommen (`Geschaeft.kategorien`), ganz ohne ein `Regal` anzulegen.
`Geschaeft.verfuegbareKategorien` ist die Vereinigung dieser direkten Zuordnung und der
Kategorien, die über `Regal.kategorien` zugeordnet sind — ein Regal organisiert damit
nur noch die Reihenfolge beim Einkaufen, ist aber keine Voraussetzung für
Verfügbarkeit.

## Services

- **AISuggestionService**: prüft `SystemLanguageModel.default.availability`; nutzt bei
  Verfügbarkeit `LanguageModelSession` mit einem `@Generable`-Ergebnistyp, um Symbol,
  Farbe, Kategorie- und Regalname vorzuschlagen. Bekommt bestehende Kategorie-/Regalnamen
  als Kontext, damit bevorzugt bestehende Werte wiederverwendet werden.
- **ReceiptScanService** (Protokoll): Implementierung `VisionFoundationModelsReceiptScanner`
  kombiniert Vision-OCR mit FoundationModels-Extraktion. Als Protokoll gekapselt, damit
  eine spätere, spezifischere On-Device-API (z.B. eine künftige System-Beleg-Scan-API)
  ohne UI-Änderungen eingesetzt werden kann. `KaufEintrag.anzeigeName` priorisiert einen
  optionalen, vom Nutzer pro Position vergebenen `alternativerName` (Alias) vor dem
  erkannten `produktName`/`artikel`/`artikelNameSnapshot`; `KaufEintragZuordnenSheet`
  lässt Alias und `Artikel`-Zuordnung (inkl. Neuanlage) gemeinsam pflegen.
  `ArtikelPreisSpanne.gruppieren(_:)` aggregiert die Preisübersicht eines Geschäfts pro
  Artikel; `KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)` schlägt beim nächsten
  Scan bereits bekannte Alias-/Artikel-Kombinationen automatisch vor — Details in
  `docs/BELEGSCAN.md`.
- **ShelfOrderLearningService**: aktualisiert nach jedem abgeschlossenen
  `Einkaufsvorgang` die `KategorieBesuchsStatistik` und leitet daraus sowohl eine
  vorgeschlagene automatische Regal-Reihenfolge als auch (für Geschäfte ohne Regale
  bzw. für Kategorien ohne Regal-Zuordnung) eine reine Kategorie-Reihenfolge ab.
- **ArtikelVerfuegbarkeitService**: bestimmt, ob ein `Artikel` in einem `Geschaeft`
  verfügbar ist — über `Geschaeft.verfuegbareKategorien`, oder (besitzt das Geschäft
  keine eigenen Kategorien) gelernt aus der Kaufhistorie (`KaufEintrag`). Grundlage für
  den Filter `ArtikelFilterModus.nurVerfuegbare` beim Einkaufen.
- **DatabaseLocationService**: verwaltet Security-Scoped-Bookmarks für einen vom Nutzer
  gewählten Speicherort außerhalb des App-Containers und das Verschieben der
  SwiftData-Store-Dateien dorthin.
- **DatabaseLeaseService**: koordiniert Mehrbenutzerzugriff auf einen geteilten
  Fileshare-Ordner über eine `NSFileCoordinator`-basierte Lock-Datei (Micro-Lease für
  diskrete Aktionen, Session-Lease für Bearbeitungs-Bildschirme) — siehe
  `docs/DATABASE_CONCURRENCY.md`.
- **DebugLogWriter**/**DatabaseDebugLogger**: optionaler, standardmäßig deaktivierter
  Diagnose-Logging-Mechanismus für den Mehrbenutzerzugriff (Rotation, `os.Logger`,
  Spiegelung in den geteilten DB-Ordner) — siehe `docs/LOGGING.md`.

## Liquid Glass

`DesignSystem/GlassStyles.swift` bündelt `.glassEffect()` / `GlassEffectContainer` /
`.buttonStyle(.glass)`-Verwendung in wiederverwendbaren View-Modifiern, damit das
Erscheinungsbild app-weit konsistent bleibt statt an jeder View-Stelle einzeln
angewendet zu werden.

## Datenbank-Speicherort

Standard: SwiftData-Standardpfad im App-Container. Alternative: vom Nutzer per
`.fileImporter` gewählter Ordner (z.B. lokal gespiegelter Cloud-Ordner). Kein
CloudKit/iCloud-Sync — bei Cloud-Sync-Ordnern liegt die Verantwortung für
Konfliktvermeidung (nur ein aktiv schreibendes Gerät) beim Nutzer, dokumentiert in der
App-Hilfe. Koordinierter Mehrbenutzerzugriff auf einen solchen Fileshare-Ordner
(Micro-/Session-Lease über `NSFileCoordinator`/`NSFilePresenter`) ist seit Build 30
umgesetzt: siehe `docs/DATABASE_CONCURRENCY.md`.

## Builds, Versionierung & Migrationen

Checkliste für Checkpoints (Changelog, DocC, wann zusätzlich Doku aktualisiert wird),
Versionsschema und die Entscheidungsregel additiv-optional vs. strukturell für
SwiftData-Schemaänderungen: `docs/BUILD_WORKFLOW.md`.
