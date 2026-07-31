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
                               # PriceTagScanService, WarengruppenDistanzService,
                               # SyncOrdnerService, MilkForUsImportService
    DesignSystem/              # Liquid-Glass-Wrapper, Symbol/Farb-Picker
    Views/                    # nach Feature gruppiert: Artikel, Geschaefte,
                               # Einkaufen, Historie, Einstellungen
    Resources/                # Assets.xcassets
  ShopWithMeShareExtension/    # Share Extension (MilkForUs-Textimport per Teilen-
                               # Funktion, siehe docs/MILKFORUS_IMPORT.md)
  ShopWithMe.docc/             # DocC-Landing-Page (Kommentare leben im Code)
  ShopWithMeTests/
```

## Datenmodell

```
ArtikelKategorie                     GeschaeftTyp               Geschaeft
────────────────                     ────────────               ─────────
id: UUID                             id: UUID                   id: UUID
name: String                         name: String               name: String
standardSymbol: String               symbolName: String         typenModelle: [GeschaeftTyp]
standardFarbeHex: String             sortIndex: Int              (→ typen, fuehrenderTyp = typen.first)
sortIndex: Int                       geschaefte: [Geschaeft]     adresse: String?
┌─geschaeftsTypModelle:               standardKategorien:         breitengrad/laengengrad: Double?
│  [GeschaeftTyp] (→geschaeftsTypen)   [ArtikelKategorie]          kategorien: [ArtikelKategorie]
└─geschaefte: [Geschaeft]                                         alternativeNamenRaw: String?
  (many-to-many, direkt)                                          anzahlEinkaufsvorgaengeRaw: Int?
                                                                   umbauVerdachtRaw: Bool?
                                                                   unauffaelligeEinkaeufeInFolgeRaw: Int?
                                                                   kaufEintraege: [KaufEintrag]
                                                                     (cascade — siehe unten)

Artikel                              Einkaufsvorgang            KaufEintrag
───────                              ───────────────            ───────────
id: UUID                             id: UUID                   id: UUID
name: String                         geschaeft: Geschaeft?      artikel: Artikel?
symbolName: String (UI-los)          einkaufsliste: Einkaufsliste? einkaufsvorgang: Einkaufsvorgang?
farbeHex: String (UI-los)            startZeit: Date            geschaeft: Geschaeft?  (denormalisiert)
kategorie: ArtikelKategorie? (führend) endZeit: Date?           datum: Date
kategorienRaw: [ArtikelKategorie] (→kategorien)                  preis: Decimal?
erstelltAm: Date                     kaufEintraege: [KaufEintrag]
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

WarengruppenDistanz                       IgnorierterGeschaeftsVorschlag
───────────────────                       ──────────────────────────────
id: UUID                                  name: String
geschaeft: Geschaeft?                     breitengrad/laengengrad: Double?
kategorieA: ArtikelKategorie?             ignoriertAm: Date
kategorieB: ArtikelKategorie?             (keine Relationship zu Geschaeft —
distanz: Double (0=nah, 1=fern)            Name/Koordinaten genügen für den
                                            Abgleich, siehe unten)
```

Design-Entscheidung (siehe `docs/DECISIONS.md`): Ein `Geschaeft` bekommt
`ArtikelKategorie`n direkt zugeordnet (`Geschaeft.kategorien`) — das ist der einzige
Weg, eine Kategorie verfügbar zu machen. Die Reihenfolge beim Einkaufen ist keine
manuell gepflegte Struktur (früher: `Regal`), sondern wird von
`WarengruppenDistanzService` aus dem Abhakverhalten gelernt (paarweise Distanz je
Kategorie-Paar und Geschäft, siehe
`docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`).

Ein Artikel mit mehreren Kategorien erscheint beim Einkaufen gleichzeitig in
JEDEM zugehörigen Abschnitt (`EinkaufenView.kategorieGruppen(fuer:)`, v0.9,
GitHub-Nachfolgefund zu #36) — keine Duplizierung mehr vermeidende
Einzelauswahl. Abgehakt wird überall zugleich (ein `KaufEintrag`); die
Kategorie des tatsächlich getappten Abschnitts wird explizit an
`Einkaufsvorgang.artikelAbhaken(_:context:kategorie:)` übergeben und im
`KaufEintrag` gespeichert — Grundlage dafür, dass `WarengruppenDistanzService`
pro Geschäft lernt, in welcher der mehreren Kategorien ein Artikel dort
tatsächlich steht (z.B. Sojasauce bei Edeka unter „Soßen", bei Aldi unter
„Asia"). `Artikel.fuehrendeKategorie(inGeschaeft:context:)` bleibt als
deterministisch sortierter Fallback für Kontexte ohne konkret getappten
Abschnitt (Belegscan, Preisschild-Scan, Sync-Import).

## Services

- **AISuggestionService**: prüft `SystemLanguageModel.default.availability`; nutzt bei
  Verfügbarkeit `LanguageModelSession` mit einem `@Generable`-Ergebnistyp, um eine
  Kategorie vorzuschlagen. Bekommt bestehende Kategorienamen als Kontext, damit
  bevorzugt bestehende Werte wiederverwendet werden. Wird in `ArtikelEditView`
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
- **WarengruppenDistanzService**: lernt nach jedem abgeschlossenen `Einkaufsvorgang`
  aus der Abhakreihenfolge eine paarweise Distanz zwischen Artikelkategorien je
  Geschäft (`WarengruppenDistanz`) und sortiert die Einkaufsliste danach dynamisch
  neu (Greedy-Nearest-Neighbor + 2-opt) — Details in
  `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`.
- **MilkForUsImportService**: importiert eine aus der Shopping-App "MilkForUs"
  exportierte Textdatei (Kategorien + Artikel) — Kategorie-Abgleich per exaktem
  Namenstreffer, sonst KI-Best-Match (`AISuggestionService.kategorieMatch`) gegen den
  bestehenden Kategoriebestand, sonst Vorschlag zur Neuanlage. Zwei Einstiegspunkte:
  manueller Datei-Picker (`MilkForUsImportView`, aus der Einkaufslisten-Verwaltung)
  und eine eigene Share Extension (`ShopWithMeShareExtension`) für die iOS-
  Teilen-Funktion. Details in `docs/MILKFORUS_IMPORT.md`.
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
- **DatabaseLeaseService**: koordiniert Mehrbenutzerzugriff auf einen geteilten
  Fileshare-Ordner über eine `NSFileCoordinator`-basierte Lock-Datei (Micro-Lease für
  diskrete Aktionen, Session-Lease für Bearbeitungs-Bildschirme) — siehe
  `docs/DATABASE_CONCURRENCY.md`.
- **DebugLogWriter**/**DatabaseDebugLogger**: optionaler, standardmäßig deaktivierter
  Diagnose-Logging-Mechanismus für den Mehrbenutzerzugriff (Rotation, `os.Logger`) —
  siehe `docs/LOGGING.md`.
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

Immer der SwiftData-Standardpfad im App-Container — es gibt keine Möglichkeit
mehr, die Store-Datei selbst an einen anderen Ort zu verlegen (das frühere
`DatabaseLocationService`, reine Dateiverlagerung ohne Sync-Zusatzcode für den
Einzelnutzer-Fall, wurde entfernt, GitHub #54). Der ältere, koordinierte
Mehrbenutzerzugriff direkt auf eine geteilte Store-Datei (Micro-/Session-Lease
über `NSFileCoordinator`/`NSFilePresenter`, dokumentiert in
`docs/DATABASE_CONCURRENCY.md`) ist für **gemeinsames Einkaufen mit mehreren
Personen** durch die event-basierte Synchronisation unten abgelöst; die
Lease-Mechanik selbst (`DatabaseLeaseService`) bleibt bestehen und schützt
weiterhin einzelne Schreibzugriffe innerhalb eines Geräts (siehe
`docs/DATABASE_CONCURRENCY.md`).

**Für gemeinsames Einkaufen (Mehrbenutzer):** event-basierte Synchronisation
über einen separat wählbaren, geteilten Sync-Ordner (`SyncOrdnerService`,
GitHub #39/#50/#52/#63) — jedes Gerät führt seine eigene, lokale, live genutzte
SwiftData-Datenbank am Standardpfad; ein zusätzliches, additives
`SyncEvent`-Modell samt Lamport-Uhr wird periodisch mit dem geteilten Ordner
abgeglichen (kein Wechsel der Persistenzschicht, kein aktiv aus mehreren
Geräten gleichzeitig beschriebener Store). Bewusst ohne den
MultipeerConnectivity-Kanal (WiFi/Bluetooth-Echtzeitaustausch im Laden, dafür
weiterhin Issue #49, an Bedingungen geknüpft). **Maßgebliche, aktuelle
Referenz für Architektur und Funktionsweise:** `docs/DATENSYNCHRONISATION.md`.
Entstehungsgeschichte, jeder Live-Test-Fund und jeder Bugfix (u.a. die
`offenerNachfolger`-Umleitung für per Event empfangenes Abhaken auf einen
zwischenzeitlich abgeschlossenen `Einkaufsvorgang`, die
`kategorieBesuchsIndex`-Sonderbehandlung fremd materialisierter Käufe, und
das Bereich-A-Sicherheitsnetz für bereits abgehakte Artikel) in
`docs/DATENSYNCHRONISATION_VERLAUF.md`.

## Builds, Versionierung & Migrationen

Checkliste für Checkpoints (Changelog, DocC, wann zusätzlich Doku aktualisiert wird),
Versionsschema und die Entscheidungsregel additiv-optional vs. strukturell für
SwiftData-Schemaänderungen: `docs/BUILD_WORKFLOW.md`.

Standardplan für Review-/Test-/Doku-Aufgaben bei jedem Minor- oder Major-
Versionssprung (Code-Review, Security-Check, Migrationscheck, Regressionstest
usw., gestaffelt nach Minor/Major): `docs/RELEASE_CHECKLIST.md`.
