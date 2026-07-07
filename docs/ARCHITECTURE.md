# ShopWithMe — Architektur

## Stack

- **SwiftUI**, iOS-only (kein macOS/Catalyst-Target), min. Deployment-Target iOS 26.0.
- **SwiftData** für Persistenz (kein Core Data, kein iCloud/CloudKit).
- **FoundationModels** (Apple Intelligence, on-device) für automatische
  Kategorie-Vorschläge beim Artikel-Anlegen und für die Beleg-Extraktion.
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
                               # PriceTagScanService, ShelfOrderLearningService,
                               # DatabaseLocationService
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
   ohne Regal nötig)                                    alternativeNamenRaw: String?
                                                         kaufEintraege: [KaufEintrag]
                                                           (cascade — siehe unten)

Artikel                              Einkaufsvorgang            KaufEintrag
───────                              ───────────────            ───────────
id: UUID                             id: UUID                   id: UUID
name: String                         geschaeft: Geschaeft?      artikel: Artikel?
symbolName: String (UI-los)          einkaufsliste: Einkaufsliste? einkaufsvorgang: Einkaufsvorgang?
farbeHex: String (UI-los)            startZeit: Date            geschaeft: Geschaeft?  (denormalisiert)
kategorie: ArtikelKategorie?         endZeit: Date?             datum: Date
erstelltAm: Date                     kaufEintraege: [KaufEintrag]  preis: Decimal?
notiz: String?                                                   menge: Double
einheitRaw: String?                                              produktName: String?
mengenSchrittRaw: Double?                                        alternativerName: String?
┌einkaufslistenEintraege:                                        kategorieBesuchsIndex: Int?
│ [EinkaufslistenEintrag]
│
Einkaufsliste                        EinkaufslistenEintrag
─────────────                        ─────────────────────
id: UUID                             id: UUID
name: String                         einkaufsliste: Einkaufsliste?
erstelltAm: Date                     artikel: Artikel? ─────────────┘
└eintraege: [EinkaufslistenEintrag]  menge: Double
                                      notiz: String?
                                      erstelltAm: Date

KategorieBesuchsStatistik                IgnorierterGeschaeftsVorschlag
─────────────────────────                ──────────────────────────────
id: UUID                                  name: String
geschaeft: Geschaeft?                     breitengrad/laengengrad: Double?
kategorie: ArtikelKategorie?              ignoriertAm: Date
besucheAnzahl: Int                        (keine Relationship zu Geschaeft —
summeSequenzPosition: Double               Name/Koordinaten genügen für den
→ durchschnittlichePosition (computed)     Abgleich, siehe unten)
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
  Verfügbarkeit `LanguageModelSession` mit einem `@Generable`-Ergebnistyp, um Kategorie-
  und Regalname vorzuschlagen. Bekommt bestehende Kategorie-/Regalnamen als Kontext,
  damit bevorzugt bestehende Werte wiederverwendet werden. Wird in `ArtikelEditView`
  automatisch (entprellt per `.task(id: artikel.name)`) aufgerufen, sobald ein neuer
  Artikel noch keine Kategorie hat — kein manueller Button mehr.
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
- **PriceTagScanService** (Protokoll): dasselbe Vision-OCR-+-FoundationModels-Muster wie
  `ReceiptScanService`, hier auf ein einzelnes fotografiertes Preisschild statt einen
  ganzen Kassenbon angewendet. Legt direkt einen `KaufEintrag` mit heutigem Datum an,
  unabhängig vom tatsächlichen Kauf. Funktioniert immer direkt für ein bereits
  feststehendes `Geschaeft` (kein geschäftsloser Einstieg, siehe unten). Details,
  Abgrenzung zum Belegscan und das (noch nicht umgesetzte) Konzept für einen
  Mehrfach-Regal-Scan in `docs/PREISSCHILD_SCAN.md`.
- **Automatischer Geschäfts-Abgleich beim Belegscan** (nur dort, nicht beim
  Preisschild-Scan — siehe `docs/PREISSCHILD_SCAN.md` → „Kein geschäftsloser
  Einstieg“): `Geschaeft.passendes(fuerErkannterName:unter:)` ordnet einen aus einem
  Beleg erkannten Geschäftsnamen einem bekannten `Geschaeft` zu (Name oder gelernte
  `alternativeNamen`); ohne Treffer fragt `GeschaeftWahlSheet` nach.
  `Geschaeft.alternativenNamenLernen(_:)` merkt sich den erkannten Namen danach als
  Alias für künftige Scans. Greift nur, wenn der Scan-Kontext noch kein Geschäft
  feststehend mitbringt (z.B. nachträglich zuhause gescannter Beleg) — Details in
  `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“.
- **ShelfOrderLearningService**: aktualisiert nach jedem abgeschlossenen
  `Einkaufsvorgang` die `KategorieBesuchsStatistik` und leitet daraus sowohl eine
  vorgeschlagene automatische Regal-Reihenfolge als auch (für Geschäfte ohne Regale
  bzw. für Kategorien ohne Regal-Zuordnung) eine reine Kategorie-Reihenfolge ab.
- **ArtikelVerfuegbarkeitService**: bestimmt, ob ein `Artikel` in einem `Geschaeft`
  verfügbar ist — über `Geschaeft.verfuegbareKategorien`, oder (besitzt das Geschäft
  keine eigenen Kategorien) gelernt aus der Kaufhistorie (`KaufEintrag`). Grundlage für
  den Verfügbarkeitsfilter beim Einkaufen, den der Anwender per Umschalter direkt im
  laufenden Einkauf übergehen kann (siehe `EinkaufenView`) — keine persistente
  Geschäfts-Einstellung.
- **Einkaufsliste — Interaktionsmodell**: Tap auf die Mengenangabe öffnet direkt das
  Sheet für exakte Menge + Notiz; Swipe links/rechts erhöht/verringert die Menge;
  Sektions-Header ohne Fortschrittszähler — Details in
  `docs/EINKAUFSLISTE_INTERAKTION.md`.
- **Artikel hinzufügen — Mehrfachauswahl**: Tap auf eine ganze Zeile in
  `ArtikelHinzufuegenView` wählt sie aus/ab (statt sofort zu übernehmen); „Hinzufügen
  (n)“ committet die gesamte Auswahl auf einmal; ein per Direktanlage neu erstellter
  Artikel landet automatisch in der Auswahl — Details (inkl. einer SwiftUI-
  Sheet-Dismiss-Falle) in `docs/ARTIKEL_HINZUFUEGEN_INTERAKTION.md`.
- **Mehrere Einkaufslisten**: der Nutzer kann beliebig viele benannte `Einkaufsliste`n
  anlegen und beim Einkaufen auswählen, welche gerade genutzt wird — Menge/Notiz sind
  dabei je Liste eigenständig (`EinkaufslistenEintrag`). Details, insbesondere die
  Ablösung des früheren globalen `Artikel.istAufEinkaufsliste`, in
  `docs/EINKAUFSLISTEN.md`.
- **GeschaeftErkennungService**: erkennt per einmaliger `CLLocationManager`-
  Standortabfrage (nur „Bei Nutzung“, kein Hintergrund-Tracking) und
  `MKLocalPointsOfInterestRequest`, ob sich der Nutzer in der Nähe eines bekannten
  Ladens befindet — schlägt ihn dafür in `EinkaufenView` vor (bereits angelegtes
  `Geschaeft` oder neuer, von Apple Maps bekannter Laden zum Hinzufügen). Details in
  `docs/GESCHAEFTSERKENNUNG.md`.
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
- **PreisHistorieBereinigungService**: löscht alte `KaufEintrag`e (Preishistorie)
  anhand einer vom Nutzer gewählten, standardmäßig deaktivierten Aufbewahrungsfrist,
  automatisch bei App-Start/Vordergrund-Wechsel oder manuell — lässt Einträge eines
  laufenden `Einkaufsvorgang`s dabei immer unangetastet. Details in
  `docs/PREISHISTORIE_BEREINIGUNG.md`.

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

Standardplan für Review-/Test-/Doku-Aufgaben bei jedem Minor- oder Major-
Versionssprung (Code-Review, Security-Check, Migrationscheck, Regressionstest
usw., gestaffelt nach Minor/Major): `docs/RELEASE_CHECKLIST.md`.
