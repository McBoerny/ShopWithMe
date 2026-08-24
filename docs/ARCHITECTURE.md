# ShopWithMe — Architektur

## Stack

- **SwiftUI**, iOS-only (kein macOS/Catalyst-Target), min. Deployment-Target iOS 26.0.
- **SwiftData** für Persistenz (kein Core Data, kein iCloud/CloudKit).
- **FoundationModels** (Apple Intelligence, on-device) für automatische
  Abteilung-Vorschläge beim Artikel-Anlegen und für die Beleg-Extraktion.
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
                               # PriceTagScanService, AbteilungsDistanzService,
                               # SyncOrdnerService, MilkForUsImportService
    DesignSystem/              # Liquid-Glass-Wrapper, Symbol/Farb-Picker,
                               # ChipFlowLayout (Flow-Layout für Chip-Darstellung)
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
Abteilung                     GeschaeftTyp               Geschaeft
────────────────                     ────────────               ─────────
id: UUID                             id: UUID                   id: UUID
name: String                         name: String               name: String
standardSymbol: String               symbolName: String         typenModelle: [GeschaeftTyp]
standardFarbeHex: String             sortIndex: Int              (→ typen, fuehrenderTyp = typen.first)
sortIndex: Int                       geschaefte: [Geschaeft]     adresse: String?
┌─geschaeftsTypModelle:               standardAbteilungen:         breitengrad/laengengrad: Double?
│  [GeschaeftTyp] (→geschaeftsTypen)   [Abteilung]          abteilungen: [Abteilung]
└─geschaefte: [Geschaeft]                                         alternativeNamenRaw: String?
  (many-to-many, direkt)                                          anzahlEinkaufsvorgaengeRaw: Int?
                                                                   umbauVerdachtRaw: Bool?
                                                                   unauffaelligeEinkaeufeInFolgeRaw: Int?
                                                                   kaufEintraege: [KaufEintrag]
                                                                     (cascade — siehe unten)
                                                                   preispunkte: [Preispunkt]
                                                                     (cascade)

Artikel                              Einkaufsvorgang            KaufEintrag (operativ, kein Preis mehr —
───────                              ───────────────            ───────────  seit GitHub #76, siehe Preispunkt)
id: UUID                             id: UUID                   id: UUID
name: String                         geschaeft: Geschaeft?      artikel: Artikel?
symbolName: String (UI-los)          einkaufsliste: Einkaufsliste? einkaufsvorgang: Einkaufsvorgang?
farbeHex: String (UI-los)            startZeit: Date            geschaeft: Geschaeft?  (denormalisiert)
abteilung: Abteilung? (führend) endZeit: Date?           datum: Date
abteilungenRaw: [Abteilung] (→abteilungen)                  menge: Double
erstelltAm: Date                     kaufEintraege: [KaufEintrag]  abteilungBesuchsIndex: Int?
notiz: String?                                                     ursprungsGeraeteID: String?
                                                                      (nil = lokal, GitHub #68)
einheitRaw: String?                  Preispunkt (GitHub #76 — Preishistorie, unabhängig vom Einkaufsvorgang)
mengenSchrittRaw: Double?            ──────────
┌einkaufslistenEintraege:            id: UUID
│ [EinkaufslistenEintrag]            artikel: Artikel?  (nullify, weiterhin gepflegt)
│                                    produkt: Produkt?  (GitHub #47, seit v0.14)
├preispunkte: [Preispunkt]           geschaeft: Geschaeft  (cascade, non-optional seit GitHub #128)
│ (nullify)                          preis: Decimal
├produkte: [Produkt]                 datum: Date
│ (cascade, GitHub #47, seit v0.14)  produktName/alternativerName: String?
├alternativeNamenRaw: String?
│ (→ alternativeNamen, GitHub #111/#128 —
│  Mitlernen, vormals eigenes ArtikelAlias-Modell)
Einkaufsliste                        EinkaufslistenEintrag
─────────────                        ─────────────────────
id: UUID                             id: UUID
name: String                         einkaufsliste: Einkaufsliste?
erstelltAm: Date                     artikel: Artikel? ─────────────┘
└eintraege: [EinkaufslistenEintrag]  produkt: Produkt? (seit v0.14)
                                      menge: Double
                                      notiz: String?
                                      erstelltAm: Date

Produkt (GitHub #47, seit v0.14)          Produktname (GitHub #47, seit v0.14)
────────                                  ───────────
id: UUID                                  id: UUID
name: String                              name: String  (geschäftsabhängig)
artikel: Artikel?  (cascade)              produkt: Produkt?
elternProdukt: Produkt?  (rekursiv,       geschaeft: Geschaeft?
  z.B. Packungsgrößen)
┌unterProdukte: [Produkt] (cascade)
├produktnamen: [Produktname] (cascade)
├preispunkte: [Preispunkt] (nullify)
├alternativeKlarnamenRaw: String?
│ (→ alternativeKlarnamen, GitHub #128)
istStandard: Bool  (automatisch angelegter
  Platzhalter, siehe standardProdukt(fuer:context:))

WarengruppenDistanz                       IgnorierterGeschaeftsVorschlag
───────────────────                       ──────────────────────────────
id: UUID                                  name: String
geschaeft: Geschaeft?                     breitengrad/laengengrad: Double?
abteilungA: Abteilung?             ignoriertAm: Date
abteilungB: Abteilung?             (keine Relationship zu Geschaeft —
distanz: Double (0=nah, 1=fern)            Name/Koordinaten genügen für den
                                            Abgleich, siehe unten)

ArtikelGeschaeftVerfuegbarkeit             GeschaeftBesuch (seit v0.12, siehe
(seit v0.12, siehe                         docs/GESCHAEFTS_AGGREGATE.md)
docs/GESCHAEFTS_AGGREGATE.md)              ───────────────
─────────────────────────────             id: UUID (= id des ursprünglichen
id: UUID                                    Einkaufsvorgang)
artikel: Artikel?                         geschaeft: Geschaeft?
geschaeft: Geschaeft?                     startZeit/endZeit: Date
(reine Existenz-Tatsache, kein Zähler)     anzahlProdukte: Int
```

**`Produkt`/`Produktname` (GitHub #47, Schritt 1/5, v0.14):** ursprünglich
über die erste echte strukturelle SwiftData-Migration dieses Projekts
eingeführt. **Historisch** — die gesamte `VersionedSchema`-Migrationshistorie
wurde am 2026-08-22 zurückgesetzt (Entwicklungsphase, Store neu angelegt,
siehe `docs/ARTIKEL_PRODUKT_MODELL.md` „Schema-Historie zurückgesetzt" und
`docs/DECISIONS.md`); `Produkt`/`Produktname` sind seither einfach von Anfang
an Teil des frischen `SchemaV1`-Ausgangspunkts (`Models/SchemaDefinition.swift`),
keine Migration nötig. Seit Schritt 2/5 auch
Teil der Datensynchronisation (`SyncSnapshot`-Version 8, siehe
`docs/DATENSYNCHRONISATION.md` Abschnitt 4.2/4.6) — `mergeProdukte` matcht
namensbasiert **innerhalb desselben Artikels**, bewusst ohne die bei
Artikel/Geschäft vorhandene Ambiguitäts-Rückstellung. Seit Schritt 4/5 erste
sichtbare UI: `ArtikelEditView` (Sektion "Produkte") → `ProduktEditView`
(Name, Produktnamen je Geschäft, eigene Preishistorie); bei mehreren eigenen
Produkten bekommt die Zeile in `ArtikelHinzufuegenView` zusätzlich einen
Chevron zur Produktwahl — der etablierte Sofort-Tap (GitHub #6/#45) bleibt
unverändert. Seit Schritt 5/5 (Feature komplett) erkennt
`ArtikelZuordnungsService` beim Belegscan zusätzlich `Produktname`-Treffer
innerhalb des erkannten Geschäfts; `PreispunktService` führt seitdem pro
Produkt (nicht mehr nur pro Artikel) eine eigene Slowly-Changing-Dimension-
Preishistorie. **`PreisschildScanView` bewusst unangetastet** — nutzt
`ArtikelZuordnungsService` bereits seit vor diesem Feature nicht (eigene,
parallele Zuordnungslogik), wäre ein eigener, unabhängiger Aufräum-Schritt.
Vollständiges Konzept: `docs/ARTIKEL_PRODUKT_MODELL.md`.

**`Einkaufsvorgang.einkaufsliste` seit v0.12 `cascade`** (vormals `nullify`,
siehe `docs/GESCHAEFTS_AGGREGATE.md`): Löschen einer `Einkaufsliste` löscht
jetzt auch ihre `Einkaufsvorgang`e/`KaufEintrag`e vollständig — sicher, weil
`ArtikelGeschaeftVerfuegbarkeit`/`GeschaeftBesuch` die beiden dauerhaft
wertvollen Ableitungen bereits beim Abhaken/Abschließen unabhängig von der
Liste festschreiben.

Design-Entscheidung (siehe `docs/DECISIONS.md`): Ein `Geschaeft` bekommt
`Abteilung`en direkt zugeordnet (`Geschaeft.abteilungen`) — das ist der einzige
Weg, eine Abteilung verfügbar zu machen. Die Reihenfolge beim Einkaufen ist keine
manuell gepflegte Struktur (früher: `Regal`), sondern wird von
`AbteilungsDistanzService` aus dem Abhakverhalten gelernt (paarweise Distanz je
Abteilung-Paar und Geschäft, siehe
`docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`).

Ein Artikel mit mehreren Abteilungen erscheint beim Einkaufen zunächst
gleichzeitig in JEDEM zugehörigen Abschnitt (`EinkaufenView.abteilungGruppen(fuer:)`,
v0.9, GitHub-Nachfolgefund zu #36) — keine Duplizierung mehr vermeidende
Einzelauswahl. Abgehakt wird überall zugleich (ein `KaufEintrag`); die
Abteilung des tatsächlich getappten Abschnitts wird explizit an
`Einkaufsvorgang.artikelAbhaken(_:context:abteilung:)` übergeben und im
`KaufEintrag` gespeichert.

Seit v0.11 (GitHub #93) wertet `AbteilungsDistanzService.gelernteAbteilung(fuer:in:context:)`
genau diese Historie aus: liegen für (Artikel, Geschäft) mindestens 5 Käufe mit
mindestens 80% Mehrheit für eine Abteilung vor (z.B. Sojasauce bei Edeka unter
„Soßen", bei Aldi unter „Asia"), zeigt `EinkaufenView` (über
`abteilungenFuerAnzeige(_:)`) nur noch diese eine Abteilung statt aller
zugeordneten — die Mehrfachanzeige bleibt der Fallback für noch nicht
eindeutig gelernte Artikel, die geschäftsunabhängige Ansicht, sowie den
aktiven Lernmodus (`zeigeAlleArtikel`, bewusst immer ungefiltert, damit eine
falsch gelernte Zuordnung sichtbar korrigierbar bleibt). Details inkl. der
statistischen Herleitung der Schwellenwerte:
`docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md` Abschnitt 14.
`Artikel.fuehrendeAbteilung(inGeschaeft:context:)` nutzt dieselbe gelernte
Abteilung jetzt ebenfalls als Top-Priorität, bevor sie auf den
deterministisch sortierten Fallback für Kontexte ohne konkret getappten
Abschnitt zurückfällt (Belegscan, Preisschild-Scan, Sync-Import).

## Services

- **AISuggestionService**: prüft `SystemLanguageModel.default.availability`; nutzt bei
  Verfügbarkeit `LanguageModelSession` mit einem `@Generable`-Ergebnistyp, um eine
  Abteilung vorzuschlagen. Bekommt bestehende Abteilungsnamen als Kontext, damit
  bevorzugt bestehende Werte wiederverwendet werden. Wird in `ArtikelEditView`
  automatisch (entprellt per `.task(id: artikel.name)`) aufgerufen, sobald ein neuer
  Artikel noch keine Abteilung hat — kein manueller Button mehr.
- **ReceiptScanService** (Protokoll): Implementierung `VisionFoundationModelsReceiptScanner`
  kombiniert Vision-OCR mit FoundationModels-Extraktion. Als Protokoll gekapselt, damit
  eine spätere, spezifischere On-Device-API (z.B. eine künftige System-Beleg-Scan-API)
  ohne UI-Änderungen eingesetzt werden kann. Erkannte Preise landen seit GitHub #76 in
  einem eigenständigen `Preispunkt` (nicht mehr in `KaufEintrag`, siehe Datenmodell
  oben) — `Preispunkt.anzeigeName` priorisiert einen optionalen, vom Nutzer pro Punkt
  vergebenen `alternativerName` (Alias) vor dem erkannten `produktName`/`produkt`
  (Produkt-Pflicht — `artikel` ist nur noch davon abgeleitet, siehe
  `docs/ARTIKEL_PRODUKT_MODELL.md`); `PreispunktZuordnenSheet` lässt Alias und `Artikel`-Zuordnung
  (inkl. Neuanlage) gemeinsam pflegen. `ArtikelPreisSpanne.gruppieren(_:)` aggregiert
  die Preisübersicht eines Geschäfts pro Artikel; `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`
  (GitHub #128, vormals `ArtikelAlias.passend`) schlägt beim nächsten Scan bereits
  bekannte Namens-/Artikel-Kombinationen automatisch vor — Details in `docs/BELEGSCAN.md`.
- **PriceTagScanService** (Protokoll): dasselbe Vision-OCR-+-FoundationModels-Muster wie
  `ReceiptScanService`, hier auf ein einzelnes fotografiertes Preisschild statt einen
  ganzen Kassenbon angewendet. Legt direkt einen `Preispunkt` mit heutigem Datum an,
  unabhängig vom tatsächlichen Kauf. Funktioniert immer direkt für ein bereits
  feststehendes `Geschaeft` (kein geschäftsloser Einstieg, siehe unten). Details,
  Abgrenzung zum Belegscan und das (noch nicht umgesetzte) Konzept für einen
  Mehrfach-Regal-Scan in `docs/PREISSCHILD_SCAN.md`.
- **Automatischer Geschäfts-Abgleich beim Belegscan** (nur dort, nicht beim
  Preisschild-Scan — siehe `docs/PREISSCHILD_SCAN.md` → „Kein geschäftsloser
  Einstieg"): `Geschaeft.passendes(fuerErkannterName:unter:)` ordnet einen aus einem
  Beleg erkannten Geschäftsnamen einem bekannten `Geschaeft` zu (Name oder gelernte
  `alternativeNamen`); ohne Treffer fragt `GeschaeftWahlSheet` nach.
  `Geschaeft.alternativenNamenLernen(_:)` merkt sich den erkannten Namen danach als
  Alias für künftige Scans. Greift nur, wenn der Scan-Kontext noch kein Geschäft
  feststehend mitbringt (z.B. nachträglich zuhause gescannter Beleg) — Details in
  `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich".
- **AbteilungsDistanzService**: lernt nach jedem abgeschlossenen `Einkaufsvorgang`
  aus der Abhakreihenfolge eine paarweise Distanz zwischen Abteilungen je
  Geschäft (`WarengruppenDistanz`) und sortiert die Einkaufsliste danach dynamisch
  neu (Greedy-Nearest-Neighbor + 2-opt) — Details in
  `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`.
- **MilkForUsImportService**: importiert eine aus der Shopping-App "MilkForUs"
  exportierte Textdatei (Abteilungen + Artikel) — Abteilung-Abgleich per exaktem
  Namenstreffer, sonst KI-Best-Match (`AISuggestionService.abteilungMatch`) gegen den
  bestehenden Abteilungsbestand, sonst Vorschlag zur Neuanlage. Zwei Einstiegspunkte:
  manueller Datei-Picker (`MilkForUsImportView`, aus der Einkaufslisten-Verwaltung)
  und eine eigene Share Extension (`ShopWithMeShareExtension`) für die iOS-
  Teilen-Funktion. Details in `docs/MILKFORUS_IMPORT.md`.
- **ArtikelVerfuegbarkeitService**: bestimmt, ob ein `Artikel` in einem `Geschaeft`
  verfügbar ist — über `Geschaeft.verfuegbareAbteilungen`, oder (besitzt das Geschäft
  keine eigenen Abteilungen) gelernt aus `ArtikelGeschaeftVerfuegbarkeit` (seit v0.12
  ein eigenes, dauerhaftes Aggregat statt eines Live-Scans über `KaufEintrag`, siehe
  `docs/GESCHAEFTS_AGGREGATE.md`). Grundlage für den Verfügbarkeitsfilter beim
  Einkaufen, den der Anwender per Umschalter direkt im laufenden Einkauf übergehen
  kann (siehe `EinkaufenView`) — keine persistente Geschäfts-Einstellung.
- **GeschaeftBesuchService** (seit v0.12): schreibt bei jedem abgeschlossenen
  `Einkaufsvorgang` einen dauerhaften `GeschaeftBesuch` (Zeitpunkt, Dauer,
  Produktanzahl) — Grundlage für `GeschaeftBesuchsProtokollView`, unabhängig davon,
  ob die zugehörige `Einkaufsliste` später gelöscht wird. Details in
  `docs/GESCHAEFTS_AGGREGATE.md`.
- **Einkaufsliste — Interaktionsmodell**: Tap auf die Mengenangabe öffnet direkt das
  Sheet für exakte Menge + Notiz; Swipe links/rechts erhöht/verringert die Menge;
  Sektions-Header ohne Fortschrittszähler — Details in
  `docs/EINKAUFSLISTE_INTERAKTION.md`.
- **Konfigurierbare Listendarstellung** (v0.15): `EinkaufslisteDarstellungsView`
  als modularer Dispatcher vor `EinkaufslisteView` — wählt je nach
  `@AppStorage(DarstellungsKey.modus)` zwischen `ListenInhaltView` (klassisch,
  Chips groß/klein — optional Akkordeon/Fortschrittsbalken/Farbstreifen) und
  `KachelInhaltView` (2- oder 3-spaltiges Raster, optional Abteilung-Farbhintergrund).
  `ChipFlowLayout: Layout` als shared Flow-Layout in `DesignSystem/`. Neue
  Einstellungsseite `EinkaufslisteDarstellungsSettingsView` über
  `SettingsNavigationsziel.listendarstellung`. Vollständiges Design:
  `docs/LISTENDARSTELLUNG.md`.
- **Artikel-Alias-Namen** (GitHub #111, v0.13; seit GitHub #128 `Artikel.alternativeNamen`
  statt eines eigenen `ArtikelAlias`-Modells): manuell in `ArtikelEditView`
  gepflegte, generische Synonyme (`Artikel.alternativenNamenLernen(_:)`), reine
  `[String]`-Liste ohne geräteweite Eindeutigkeitsprüfung (anders als vormals
  `ArtikelAlias.manuellHinzufuegen`, das bei Namenskollision mit einem anderen
  Artikel blockierte). `ArtikelHinzufuegenView.gefilterteArtikel` durchsucht
  neben `Artikel.name` auch `alternativeNamen` — derselbe Artikel bleibt dabei
  einmalig im Ergebnis. Abgrenzung zum Artikel→Produkt→Produktname-Konzept
  (`docs/ARTIKEL_PRODUKT_MODELL.md`): ein alternativer Name ist reine
  Textsuche für denselben Artikel, kein eigenständiges Produkt mit eigenem
  Preis — die Rohtext-Rolle beim Scan (vormals ebenfalls `ArtikelAlias`) trägt
  seit #128 stattdessen `Produktname` (mit `geschaeft == nil` als
  geschäftsunabhängiger Fall).
- **Artikel hinzufügen — Mehrfachauswahl**: Tap auf eine ganze Zeile in
  `ArtikelHinzufuegenView` wählt sie aus/ab (statt sofort zu übernehmen); „Hinzufügen
  (n)" committet die gesamte Auswahl auf einmal; ein per Direktanlage neu erstellter
  Artikel landet automatisch in der Auswahl — Details (inkl. einer SwiftUI-
  Sheet-Dismiss-Falle) in `docs/ARTIKEL_HINZUFUEGEN_INTERAKTION.md`.
- **Mehrere Einkaufslisten**: der Nutzer kann beliebig viele benannte `Einkaufsliste`n
  anlegen und beim Einkaufen auswählen, welche gerade genutzt wird — Menge/Notiz sind
  dabei je Liste eigenständig (`EinkaufslistenEintrag`). Details, insbesondere die
  Ablösung des früheren globalen `Artikel.istAufEinkaufsliste`, in
  `docs/EINKAUFSLISTEN.md`.
- **GeschaeftErkennungService**: erkennt per einmaliger `CLLocationManager`-
  Standortabfrage (nur „Bei Nutzung", kein Hintergrund-Tracking) und
  `MKLocalPointsOfInterestRequest`, ob sich der Nutzer in der Nähe eines bekannten
  Ladens befindet — schlägt ihn dafür in `EinkaufenView` vor (bereits angelegtes
  `Geschaeft` oder neuer, von Apple Maps bekannter Laden zum Hinzufügen). Details in
  `docs/GESCHAEFTSERKENNUNG.md`.
- **DatabaseLeaseService**: koordiniert Mehrbenutzerzugriff auf einen geteilten
  Fileshare-Ordner über eine `NSFileCoordinator`-basierte Lock-Datei (Micro-Lease für
  diskrete Aktionen, Session-Lease für Bearbeitungs-Bildschirme) — siehe
  `docs/DATABASE_CONCURRENCY.md`.
- **Peer-Lebenszyklus** (`SyncOrdnerService.binIchNochMitglied(in:)`/`entfernePeer(_:in:context:)`,
  `SyncPeerInfo.istWahrscheinlichTot`, `SyncSnapshotImportService.aktuellerAufraeumWasserstand(in:)`):
  erkennt beim Start, ob der eigene Peer-Ordner von der Gruppe entfernt wurde, und trennt
  sich in diesem Fall sofort vom Sync-Ordner (nach lokalem Backup); macht lange nicht
  gesehene Peers sichtbar und lässt sie bestätigt entfernen; trägt damit die
  Sicherheits-Garantie für einen dynamischen, sich selbst nachführenden
  Aufbewahrungs-Wasserstand für Sync-Events/`SyncTombstone` (ersetzt vorher feste
  Fristen). Details in `docs/PEER_LEBENSZYKLUS.md`.
- **DebugLogWriter**/**DatabaseDebugLogger**: optionaler, standardmäßig deaktivierter
  Diagnose-Logging-Mechanismus für den Mehrbenutzerzugriff (Rotation, `os.Logger`) —
  siehe `docs/LOGGING.md`.
- **PreisHistorieBereinigungService**: löscht alte `Preispunkt`e (echte Preishistorie,
  siehe Datenmodell oben) anhand einer vom Nutzer gewählten, standardmäßig
  deaktivierten Aufbewahrungsfrist, automatisch bei App-Start/Vordergrund-Wechsel
  oder manuell.
- **KaufEintragBereinigungService** (GitHub #76, Phase 2): löscht abgeschlossene,
  operative `KaufEintrag`e (keine Preisrolle mehr) und dadurch leer gewordene
  `Einkaufsvorgang`e — immer aktiv, ohne Nutzer-Einstellung, feste kurze Karenzzeit
  (48h) statt der langen, nutzerkonfigurierbaren Preishistorie-Frist, da ein
  `KaufEintrag` nach Abschluss seines Einkaufsvorgangs fachlich keine Funktion mehr
  hat. Lässt Einträge eines laufenden `Einkaufsvorgang`s dabei immer unangetastet.
  Details zu beiden Services in `docs/PREISHISTORIE_BEREINIGUNG.md`.
- **PreispunktVerdichtungService** (GitHub #76-Folgearbeit): verdichtet statt zu
  löschen — reduziert alte `Preispunkt`e stufenweise auf gröbere Auflösung
  (täglich → wöchentlich → monatlich, jeweils den höchsten Preis behaltend), läuft
  automatisch für alle Nutzer, Schwellwerte im Debug-Menü einstellbar. Ergänzt um
  eine interaktive Tages-Kollisionsabfrage direkt beim Scannen
  (`BelegScanView`/`PreisschildScanView`, `TagesKollisionZeile`). Details in
  `docs/PREISHISTORIE_VERDICHTUNG.md`.

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
Geräten gleichzeitig beschriebener Store). Zusätzlich ein rein
beschleunigender MultipeerConnectivity-Kanal (WiFi/Bluetooth-Echtzeitaustausch
im Laden, `MultipeerSyncService`, GitHub #49, seit v0.12) — additiv neben dem
Ordner-Kanal, der die verlässliche Zustellung bleibt. **Maßgebliche, aktuelle
Referenz für Architektur und Funktionsweise:** `docs/DATENSYNCHRONISATION.md`.
Entstehungsgeschichte, jeder Live-Test-Fund und jeder Bugfix (u.a. die
`offenerNachfolger`-Umleitung für per Event empfangenes Abhaken auf einen
zwischenzeitlich abgeschlossenen `Einkaufsvorgang`, die
`abteilungBesuchsIndex`-Sonderbehandlung fremd materialisierter Käufe, und
das Bereich-A-Sicherheitsnetz für bereits abgehakte Artikel) in
`docs/DATENSYNCHRONISATION_VERLAUF.md`.

**Geplante Auskopplung des Transports hinter einen `SyncConnector`:** die
Merge-/Konfliktauflösungslogik oben ist bereits transport-unabhängig
implementiert, nur nicht formal hinter einem Protokoll gekapselt. Ziel ist
keine Migration, sondern eine Connector-Registry: SwiftData bleibt in jedem
Fall die interne Persistenz, mehrere Transport-Connectors (Dateiordner
weiterhin als Referenz, dazu künftig datenbankgestützt bzw. CloudKit)
existieren nebeneinander, der Anwender wählt zur Laufzeit den aktiven. Review,
Schnitt-Vorschlag und eine Machbarkeitsbewertung (inkl. cr-sqlite, das dafür
nur als privater Sidecar-Connector infrage kommt, da SwiftData/Core Data die
rohe `sqlite3`-Verbindung nicht exponiert) in `docs/SYNC_CONNECTOR_ARCHITEKTUR.md`.
Klassifizierung aller 19 Merge-Funktionen nach CRDT-Strategie (Vorarbeit für #75):
`docs/SYNC_MERGE_STRATEGIEN.md`.

## Builds, Versionierung & Migrationen

Checkliste für Checkpoints (Changelog, DocC, wann zusätzlich Doku aktualisiert wird),
Versionsschema und die Entscheidungsregel additiv-optional vs. strukturell für
SwiftData-Schemaänderungen: `docs/BUILD_WORKFLOW.md`.

Standardplan für Review-/Test-/Doku-Aufgaben bei jedem Minor- oder Major-
Versionssprung (Code-Review, Security-Check, Migrationscheck, Regressionstest
usw., gestaffelt nach Minor/Major): `docs/RELEASE_CHECKLIST.md`.
