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
                          │                            regale: [Regal] ──┘
                          └── (many-to-many mit Kategorie)

Artikel                              Einkaufsvorgang            KaufEintrag
───────                              ───────────────            ───────────
id: UUID                             id: UUID                   id: UUID
name: String                         geschaeft: Geschaeft?      artikel: Artikel?
symbolName: String                   startZeit: Date            einkaufsvorgang: Einkaufsvorgang?
farbeHex: String                     endZeit: Date?             geschaeft: Geschaeft?  (denormalisiert)
kategorie: ArtikelKategorie?         kaufEintraege: [KaufEintrag]  datum: Date
  (nach Anlage UI-seitig fixiert)                                preis: Decimal
istAufEinkaufsliste: Bool                                        menge: Double
erstelltAm: Date                                                 regalBesuchsIndex: Int?

RegalBesuchsStatistik
─────────────────────
id: UUID
geschaeft: Geschaeft?
regal: Regal?
besucheAnzahl: Int
summeSequenzPosition: Double
→ durchschnittlichePosition (computed = summe/anzahl)
```

Design-Entscheidung: **Kein separates Zuordnungsmodell "Kategorie ↔ Geschäft"**. Die
Menge der in einem Geschäft verfügbaren Kategorien ergibt sich aus der Vereinigung aller
`kategorien`, die den `Regal`-Objekten dieses Geschäfts zugeordnet sind. Das vermeidet
Dateninkonsistenzen (Kategorie am Regal, aber nicht als "verfügbar" markiert o.ä.).

## Services

- **AISuggestionService**: prüft `SystemLanguageModel.default.availability`; nutzt bei
  Verfügbarkeit `LanguageModelSession` mit einem `@Generable`-Ergebnistyp, um Symbol,
  Farbe, Kategorie- und Regalname vorzuschlagen. Bekommt bestehende Kategorie-/Regalnamen
  als Kontext, damit bevorzugt bestehende Werte wiederverwendet werden.
- **ReceiptScanService** (Protokoll): Implementierung `VisionFoundationModelsReceiptScanner`
  kombiniert Vision-OCR mit FoundationModels-Extraktion. Als Protokoll gekapselt, damit
  eine spätere, spezifischere On-Device-API (z.B. eine künftige System-Beleg-Scan-API)
  ohne UI-Änderungen eingesetzt werden kann.
- **ShelfOrderLearningService**: aktualisiert nach jedem abgeschlossenen
  `Einkaufsvorgang` die `RegalBesuchsStatistik` und liefert ab einer Mindestanzahl
  Einkäufe eine vorgeschlagene automatische Regal-Reihenfolge.
- **DatabaseLocationService**: verwaltet Security-Scoped-Bookmarks für einen vom Nutzer
  gewählten Speicherort außerhalb des App-Containers und das Verschieben der
  SwiftData-Store-Dateien dorthin.

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
App-Hilfe.
