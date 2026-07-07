# Changelog

## v0.6 (Build 51) — Release-Review: Matching-Logik konsolidiert, zwei Bugs behoben

Review vor dem Minor-Bump auf v0.6 (siehe `docs/RELEASE_CHECKLIST.md`) deckte zwei
echte Bugs in der v0.5-Ladenerkennung auf, beide jetzt behoben:

- **`GeschaeftErkennungService`**: `istBekannterTreffer(_:fuer:)`,
  `istIgnoriert(_:ignorierte:)`, `istSelberLaden(_:_:)` (Dedup) und
  `ignorierteEintraege(fuer:in:)` teilten sich vier fast identische Namens-/
  Koordinaten-Matching-Implementierungen, die dabei leicht auseinandergelaufen
  waren — nur `istBekannterTreffer` prüfte Namens-Teilstrings (z.B. Apple-Maps-
  „REWE“ vs. „Rewe am Markt“), die anderen drei nur exakte Gleichheit. Auf eine
  gemeinsame `istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:)` konsolidiert.
- **Bug behoben**: dadurch konnte ein manuell angelegtes Geschäft ohne gespeicherte
  Koordinaten nicht mit einem abweichend benannten Apple-Maps-Treffer für denselben
  Laden dedupliziert werden — „Alle Geschäfte in der Nähe“ listete ihn doppelt.
  Neuer Test `dedupliziertBekanntenTrefferOhneKoordinatenGegenUnbekanntenPerNamensTeilstring`.
- **Bug behoben**: „Wieder aufnehmen“ in `GeschaeftAlleInDerNaeheSheet` aktualisierte
  den lokal einmalig geladenen (`.task`, kein Live-`@Query`) Ignoriert-Status nicht —
  die Zeile blieb bis zum erneuten Öffnen fälschlich auf „Ignoriert“ stehen.
  `GeschaeftInDerNaeheEintrag.istIgnoriert` ist jetzt `var`, optimistisches lokales
  Update direkt nach dem Tap.
- `GeschaeftVorschlag.aktionsTitel` (neu) ersetzt zwei identische
  `aktionsTitel`-Computed-Properties in `GeschaeftVorschlagBanner` und
  `GeschaeftInDerNaeheZeile`.
- Dokumentationsabgleich (`ARCHITECTURE.md`, `ROADMAP.md`, `PRODUCT_SPEC.md`) für
  den gesamten v0.5-Zyklus, u.a. das veraltete „Standortbezug (zukünftig)“-Kapitel
  in `PRODUCT_SPEC.md` (Standort-basierte Ladenerkennung ist längst umgesetzt).

## v0.5 (Build 50) — Suchradius im Debug-Build testweise überschreibbar

- **`DebugEinstellungen`/`DebugEinstellungenView`** (neu, beide nur `#if DEBUG`):
  neuer Eintrag „Debug-Einstellungen“ in `SettingsView` (ebenfalls `#if DEBUG`)
  erlaubt es, den Suchradius von `GeschaeftErkennungService` (automatischer
  Einzelvorschlag + „Alle Geschäfte in der Nähe“) testweise auf 100–5000m zu
  erhöhen, ohne echte Nähe zu einem Apple-Maps-Laden zu benötigen.
  `suchradius`/`alleInDerNaeheRadius` sind dafür von `static let` zu `static var`
  geworden: in Debug-Builds `DebugEinstellungen.sucheRadiusUeberschreibung ??
  standardXYZ`, in Release-Builds unbedingt der feste Standardwert (150m/100m) —
  die Überschreibung ist in einem Release-Build gar nicht Teil des Binaries.

## v0.5 (Build 49) — Manuelles Geschäft-Hinzufügen im Einkaufen-Tab

- **„Neues Geschäft hinzufügen“** ergänzt im Geschäft-Menü (Toolbar, `EinkaufenView`):
  öffnet über einen leeren `Geschaeft`-Entwurf denselben
  `GeschaeftStammdatenEditView`-Anlage-Flow wie der Standort-Vorschlag, unabhängig von
  Standortberechtigung/Apple-Maps-Treffern — die automatische Ladenerkennung bleibt
  damit immer nur eine Ergänzung, nie der einzige Weg, ein Geschäft anzulegen.

## v0.5 (Build 48) — Duplikate in „Alle Geschäfte in der Nähe“ behoben

- **`GeschaeftErkennungService.dedupliziert(_:)`** (neu): Apple Maps liefert für
  denselben physischen Laden gelegentlich mehrere `MKMapItem`-Treffer — dadurch
  erschien z.B. ein ignoriertes Geschäft doppelt in der Liste „Alle Geschäfte in der
  Nähe“. `alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)` dedupliziert
  jetzt am Ende: gleiches `Geschaeft` bei zwei `.bekannt`-Treffern, sonst Namens- ODER
  Koordinatenübereinstimmung. `internal` statt `private`, direkt getestet.

## v0.5 (Build 47) — Verfügbarkeitsfilter direkt im Einkauf statt als Geschäfts-Einstellung

- **`Geschaeft.artikelFilterModus`/`ArtikelFilterModus` entfernt**: die Entscheidung
  „nur verfügbare Artikel“ vs. „alle Artikel“ war bislang eine persistente
  Geschäfts-Einstellung in `GeschaeftDetailView` — redundant, da der Anwender genau
  diese Entscheidung ohnehin bei Bedarf direkt beim Einkaufen trifft. Stattdessen neuer
  Umschalter (Listen-Icon) neben „Auch abgehakte Artikel“ in `EinkaufenView` — blendet
  für den laufenden Einkauf alle Artikel der Einkaufsliste ein, auch nicht als
  verfügbar geltende, unabhängig vom Verfügbarkeitsfilter. `ArtikelVerfuegbarkeitService`
  bleibt unverändert (weiterhin Grundlage der Verfügbarkeitsermittlung selbst).
- **Schnellauswahl statt drei Einzel-Buttons**: die vorherigen drei separaten
  Anzeige-Buttons in `EinkaufenView` sind zu einem einzigen `SchnellauswahlButton` in
  der Toolbar verschmolzen (neben „Artikel hinzufügen“, statt unten neben „Einkauf
  abschließen“): kurzer Tap schaltet zwischen „Nur offene“/„Auch abgehakte Artikel“
  um, langer Tap öffnet ein Menü zum Umschalten des Lernmodus (alle Artikel
  anzeigen). Implementiert über `Menu(primaryAction:)` statt `Button` +
  `.contextMenu` — Letzteres löste den langen Tap nicht zuverlässig aus, da der
  `.glass`-Stil ein `PrimitiveButtonStyle` mit eigener Gestenerkennung ist. „Einkauf
  abschließen“ nutzt jetzt `.buttonStyle(.glassProminent)`.
- **Standort-Vorschlag: „Ignorieren“ und „Alle Geschäfte in der Nähe“** (siehe
  `docs/GESCHAEFTSERKENNUNG.md`): neues Modell `IgnorierterGeschaeftsVorschlag`
  (additiv zu `SchemaV1.models`) merkt sich dauerhaft ignorierte
  Standort-Vorschläge. `GeschaeftVorschlagBanner` bekommt dafür ein „…“-Menü
  (Verwerfen/Ignorieren/Alle Geschäfte in der Nähe…). Neues
  `GeschaeftAlleInDerNaeheSheet` zeigt alle Läden im 100m-Radius
  (`GeschaeftErkennungService.alleInDerNaeheRadius`, enger als der 150m-Radius des
  automatischen Einzelvorschlags), inkl. ignorierter mit „Wieder aufnehmen“-Option —
  erreichbar über das Banner-Menü sowie dauerhaft über das Geschäft-Menü in der
  Toolbar.

## v0.5 (Build 42) — Standort-basierte Ladenerkennung, Geschäftsverwaltung, Preishistorie-Kaskade

- **`GeschaeftErkennungService`** (`Services/GeschaeftErkennungService.swift`, neu):
  erkennt per einmaliger Standortabfrage (`NSLocationWhenInUseUsageDescription`, kein
  Hintergrund-Tracking) und `MKLocalPointsOfInterestRequest`, ob sich der Nutzer in
  der Nähe eines bekannten Ladens (Apple Maps) befindet. `EinkaufenView` zeigt dafür
  ein neues `GeschaeftVorschlagBanner`, sobald sie geöffnet wird — nur, wenn
  tatsächlich ein relevanter Laden in der Nähe erkannt wurde (z.B. nicht zu Hause).
  Ein bereits angelegtes Geschäft lässt sich direkt übernehmen; ein noch unbekannter
  Laden lässt sich über den bestehenden `GeschaeftStammdatenEditView`-Anlage-Flow
  (neuer optionaler `onGespeichert`-Callback) mit vorausgefüllten Stammdaten
  hinzufügen. Details in `docs/GESCHAEFTSERKENNUNG.md`.
- **Geschäftsverwaltung in den Einstellungen**: neuer „Geschäfte“-Eintrag in
  `SettingsView`, verlinkt auf dieselbe `GeschaeftListView` wie der gleichnamige Tab
  (Bearbeiten/Anlegen/Löschen war dort bereits vorhanden). Dafür verliert
  `GeschaeftListView` ihren eigenen `NavigationStack` (verschachtelte
  `NavigationStack`s vermeiden) — `RootView` umschließt den Tab jetzt selbst damit.
- **Löschen eines Geschäfts löscht jetzt auch seine Preishistorie**: neue
  `@Relationship(deleteRule: .cascade, inverse: \KaufEintrag.geschaeft)` an
  `Geschaeft.kaufEintraege` — vorher blieben zugehörige `KaufEintrag`e beim Löschen
  eines Geschäfts verwaist bestehen.
- **Preisschild-Scan** (`Services/PriceTagScanService.swift`,
  `Views/Einkaufen/PreisschildScanView.swift`, neu): fotografiert ein einzelnes
  Regal-Preisschild (Vision-OCR + FoundationModels, dasselbe Muster wie der
  Belegscan) und legt Artikelname + Verkaufspreis direkt als `KaufEintrag` mit
  heutigem Datum an — unabhängig vom tatsächlichen Kauf, z.B. zum Preisvergleich vor
  der Kaufentscheidung. Neuer Button „Preisschild scannen“ in
  `GeschaeftDetailView` neben „Kaufbeleg scannen“. Details, Abgrenzung zum Belegscan
  und das noch nicht umgesetzte Regal-Mehrfach-Scan-Konzept in
  `docs/PREISSCHILD_SCAN.md`.
- **Automatischer Geschäfts-Abgleich beim Belegscan**: neues
  `Geschaeft.alternativeNamen: [String]` + `Geschaeft.passendes(fuerErkannterName:unter:)`
  ordnen einen aus einem Beleg erkannten Geschäftsnamen automatisch einem
  bekannten Geschäft zu — relevant, wenn ohne vorherige Geschäftswahl gescannt
  wird (z.B. nachträglich zuhause). Ohne Treffer fragt das neue `GeschaeftWahlSheet`
  nach (mit Möglichkeit, direkt ein neues Geschäft anzulegen);
  `Geschaeft.alternativenNamenLernen(_:)` merkt sich den erkannten Namen danach als
  Alias für künftige Scans. Neuer geschäftsloser Beleg-Scan-Einstieg (Toolbar-Button
  „Beleg scannen“ in `GeschaeftListView`) sowie neue Scan-Buttons (Beleg +
  Preisschild) direkt in `EinkaufenView`, sobald dort ein Geschäft gewählt ist. Ein
  `Einkaufsvorgang` ohne gewähltes Geschäft übernimmt das erkannte/gewählte
  Geschäft rückwirkend. Der Preisschild-Scan bleibt bewusst ohne geschäftslosen
  Einstieg (funktioniert immer nur direkt für ein bereits feststehendes Geschäft —
  ein Preisschild zeigt so gut wie nie den Geschäftsnamen). Details in
  `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“ und
  `docs/PREISSCHILD_SCAN.md` → „Kein geschäftsloser Einstieg“.
- **`docs/RELEASE_CHECKLIST.md`** (neu): gestaffelte Release-Checkliste für
  Minor-/Major-Versionssprünge (Code-Review, Security-Check, Build/Tests,
  Migrationscheck, Doku-Abgleich bei jedem Bump; zusätzlich voller
  Security-Review, Regressionstest, Accessibility-Vollcheck,
  App-Store/TestFlight-Vorbereitung nur bei Major-Bumps). Details siehe
  `docs/BUILD_WORKFLOW.md`.
- **`MKMapItem.placemark`-Deprecation behoben**: `GeschaeftErkennungService`
  nutzt jetzt die seit iOS 26 aktuelle `MKMapItem`-API (`location`,
  `address?.fullAddress`) statt des deprecated `placemark`.

## v0.4 (Build 40) — Automatische Bereinigung der Preishistorie

- **`PreisHistorieBereinigungService`** (`Services/PreisHistorieBereinigungService.swift`):
  löscht `KaufEintrag`e, die älter als eine vom Nutzer wählbare Aufbewahrungsfrist
  (30 Tage / 3 Monate / 6 Monate / 1 Jahr / eigene Anzahl Tage / „Nie“, Standard: „Nie“)
  sind. Läuft automatisch bei App-Start und beim Zurückkehren aus dem Hintergrund
  (`RootView`, mit 24h-Mindestintervall) sowie manuell über einen Button. Einträge
  eines noch nicht abgeschlossenen `Einkaufsvorgang`s bleiben davon immer unberührt.
- **`PreisHistorieSettingsView`** (`Views/Einstellungen/PreisHistorieSettingsView.swift`):
  neuer Einstellungen-Bildschirm zur Wahl der Aufbewahrungsfrist, zeigt Zeitpunkt der
  letzten Bereinigung und erlaubt manuelles Anstoßen.
- Details siehe `docs/PREISHISTORIE_BEREINIGUNG.md`.

## v0.3 (Build 38) — Artikel hinzufügen: Mehrfachauswahl

- **`ArtikelHinzufuegenView` neu gestaltet** (`Views/Einkaufen/ArtikelHinzufuegenView.swift`):
  ein Tap auf einen ganzen Artikeleintrag wählt ihn aus bzw. hebt die Auswahl wieder
  auf (gefüllter Haken statt leerem Kreis, Zeile farblich hervorgehoben); mehrere
  Artikel lassen sich so nacheinander markieren und erst über den Toolbar-Button
  "Hinzufügen (n)" gemeinsam auf die Einkaufsliste übernommen. "Abbrechen" verwirft
  die gesamte Auswahl. Artikel, die bereits auf der Liste stehen, zeigen statt der
  Auswahlmöglichkeit einen "Auf Liste"-Hinweis. Zeilen bekommen außerdem das
  Kategorie-Icon/Farbe über den gemeinsamen `GlassSymbolBadge`-Baustein.
- **Direktanlage landet jetzt in der Auswahl statt sofort zu committen**: legt man
  über "„X“ neu anlegen" einen neuen Artikel an, wird er nach dem Sichern automatisch
  ausgewählt (statt die Liste sofort zu schließen) — man kann direkt weitere Artikel
  dazu auswählen, bevor gemeinsam auf "Hinzufügen" getippt wird.
- **Bugfix beim Zusammenspiel mit `.sheet(item:)`**: SwiftUI setzt die an ein
  `sheet(item:)` gebundene Property bereits vor dem Aufruf von `onDismiss` auf `nil`
  zurück — das bisherige `nachNeuanlageAufraeumen` griff dadurch auf ein bereits
  geleertes Optional zu und der neu angelegte Artikel ging beim automatischen
  Übernehmen verloren. Behoben über eine separate, vom Sheet-Binding unabhängige
  Referenz auf den zuletzt angelegten Entwurf.

## v0.2 (Build 36) — Mehrere Einkaufslisten, Kategorien-Verwaltung, Artikel nach Kategorie sortierbar

- **Mehrere Einkaufslisten** (`Models/Einkaufsliste.swift`, `Models/EinkaufslistenEintrag.swift`):
  der Nutzer kann beliebig viele benannte Listen anlegen und beim Einkaufen auswählen,
  welche gerade genutzt wird — Menge/temporäre Notiz sind je Liste eigenständig, ein
  Artikel kann gleichzeitig auf mehreren Listen stehen. Ersetzt das bisherige globale
  `Artikel.istAufEinkaufsliste`/`menge`/`einkaufslistenNotiz`. `EinkaufenView` bekommt
  dafür einen zweiten Menü-Picker samt Schnellanlage; volle Verwaltung (Umbenennen/
  Löschen) über `EinkaufslistenVerwaltungView` in den Einstellungen. Details in
  `docs/EINKAUFSLISTEN.md`.
- **Kategorien-Verwaltung** (`KategorienVerwaltungView`, neu in den Einstellungen):
  Kategorien umbenennen, Symbol/Farbe ändern, Reihenfolge per Drag-Handle anpassen,
  anlegen/löschen — analog zur neuen Listen-Verwaltung. `ArtikelEditView` bekommt
  dafür ebenfalls eine "Neue Kategorie anlegen"-Schnellaktion.
- **Artikel-Liste nach Kategorie sortierbar** (`ArtikelListView`): Menü-Picker
  "Alphabetisch"/"Nach Kategorie" oben links, analog zur Einkaufsliste gruppiert und
  nach `ArtikelKategorie.sortIndex` sortiert.

## v0.2 (Build 35) — Einkaufsliste: Kategorie-Icon/Farbe, Sektions-Zähler, Menge vor der Checkbox

- **Kategorie-Icon/Farbe wieder sichtbar, jetzt in der Einkaufsliste** (`EinkaufenView`):
  jede Zeile zeigt ein `GlassSymbolBadge` mit `ArtikelKategorie.standardSymbol`/
  `standardFarbeHex` der effektiven Kategorie des Artikels (``Artikel/effektiveKategorie(context:)``) —
  die Felder existierten bereits am Modell, waren zuletzt aber in keiner Ansicht mehr
  zu sehen.
- **Sektions-Titel mit Zähler**: neue `EinkaufslistenSektionHeader`-Kopfzeile zeigt
  bei Regal- wie Kategorie-Sektionen `abgehakt/gesamt` an; bei Kategorie-Sektionen
  zusätzlich das Kategorie-Icon (Regal-Sektionen bleiben ohne Icon, da ein Regal
  mehrere Kategorien bündeln kann).
- **Zeilen-Layout überarbeitet**: unter dem Artikelnamen steht nur noch die
  optionale `einkaufslistenNotiz` des Nutzers (keine Mengenangabe mehr); Menge +
  Einheit stehen jetzt rechts direkt vor der Abhak-Checkbox.
- **Automatischer Wechsel zum nächsten Einkauf**: `EinkaufenView` reagiert jetzt per
  `onChange` auf die Anzahl offener `Einkaufsvorgang`e und legt sofort einen neuen
  an, sobald der aktuelle abgeschlossen wird — die abgehakten Artikel des beendeten
  Einkaufs verschwinden dadurch unmittelbar aus der Ansicht, statt bis zum nächsten
  Tab-Wechsel als leere `ProgressView` hängen zu bleiben.

## v0.2 (Build 33) — Artikel: automatische KI-Kategorie, Menge & Einheit, kein Icon/Farbe mehr

- **KI-Kategorie automatisch statt Button**: `ArtikelEditView` bestimmt die Kategorie
  eines neuen Artikels jetzt automatisch (entprellt per `.task(id: artikel.name)`),
  sobald Apple Intelligence verfügbar ist und noch keine Kategorie gesetzt wurde —
  kein manueller "Mit Apple Intelligence vorschlagen"-Button mehr.
  `AISuggestionService.ArtikelVorschlag` liefert entsprechend nur noch
  Kategorie-/Regalname (kein Symbol/Farbe mehr).
- **Kein Icon/keine Farbe mehr pro Artikel in der UI**: `Artikel.symbolName`/
  `farbeHex` bleiben als Modellfelder erhalten, werden aber in keiner Ansicht mehr
  angezeigt/editiert (Artikel-Tab, Einkaufsliste, Artikel-Suche, Preisübersicht,
  Belegscan-Zuordnung).
- **"Auf Einkaufsliste"-Toggle entfernt**: Artikel kommen nur noch automatisch auf
  die Liste, wenn sie aus der Einkaufsliste-Ansicht heraus (neu oder erneut)
  hinzugefügt werden (`Artikel.aufEinkaufslisteSetzen()`, neu).
- **Neue Attribute `Einheit`/`Menge`/`mengenSchritt`** (additiv-optional, keine neue
  Schema-Version): Einheit ist Stück, Kilogramm, Gramm, Liter oder Milliliter; die
  beim Anlegen festgelegte Standardmenge (`mengenSchritt`) dient als Schrittweite.
  `Einkaufsvorgang.artikelAbhaken` übernimmt die tatsächlich gewünschte Menge in den
  `KaufEintrag`.
- **Neue Einkaufslisten-Interaktion** (`EinkaufenView`): Abhaken nur noch über eine
  eigenständige Checkbox; ein Tap auf die Zeile erhöht die Menge um `mengenSchritt`,
  ein Doppel-Tap verringert sie (nie unter `mengenSchritt`), ein langer Druck öffnet
  ein neues `MengenNotizSheet` für exakte Menge + temporäre Notiz
  (`Artikel.einkaufslistenNotiz`).

## v0.2 (Build 31) — Belegscan: Artikel-Zuordnung, Preisübersicht + Mitlernen

- `KaufEintragZuordnenSheet` (neu, `Views/Historie/`): löst die bisherige
  Umbenennen-Alert ab — vergibt einen Alias (`KaufEintrag.alternativerName`) UND
  ordnet die Position einem übergreifenden `Artikel` zu, inkl. Neuanlage direkt im
  selben Dialog (`ArtikelEditView`, gleiches Muster wie `ArtikelHinzufuegenView`).
  Aufgerufen aus `PreisHistorieZeile` (Wisch-Aktion „Zuordnen“, jetzt überall statt
  nur in der Geschäfts-Ansicht).
- `Models/ArtikelPreisSpanne.swift` (neu): gruppiert `KaufEintrag`e nach `Artikel`
  und liefert je Preisspanne (min/max). `GeschaeftDetailView` zeigt statt der
  bisherigen flachen „Preishistorie“ jetzt eine „Preisübersicht“ pro Artikel; ein
  Antippen öffnet `ArtikelPreisVerlaufView` (Drill-down mit der historischen
  Kaufliste). Positionen ohne Artikel-Zuordnung erscheinen separat darunter.
- `KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)` (neu): sucht den jüngsten
  historischen Eintrag mit passendem erkanntem Namen und gesetztem Alias.
  `BelegScanView` nutzt das beim Einlesen eines neuen Belegs, um bereits bekannte
  Produkte automatisch mit Alias vorzubelegen und dem gelernten `Artikel` zu
  verknüpfen — ohne dass der Nutzer erneut zuordnen muss.
- Architektur vollständig in `docs/BELEGSCAN.md` aktualisiert (Ablauf, Datenmodell,
  Preisübersicht, Mitlernen); `docs/ARCHITECTURE.md` entsprechend ergänzt.
- Neue Unit-Tests in `ModelTests.swift`: `gelernteZuordnung`-Matching (jüngster
  Treffer gewinnt, ignoriert Einträge ohne Alias/ohne passenden Namen) sowie
  `ArtikelPreisSpanne`-Gruppierung/Min-Max-Berechnung.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 36 Unit-Tests bestehen.

## v0.2 (Build 30) — Mehrbenutzerzugriff auf die Datenbank + DB-Debug-Logging

- `Services/DatabaseLeaseService.swift`: koordiniert Schreibzugriffe auf einen
  geteilten Fileshare-Ordner (Box Drive/OneDrive/Synology Drive/iCloud Drive)
  über eine `NSFileCoordinator`-basierte Lock-Datei. Micro-Lease für diskrete
  Einzelaktionen (Artikel abhaken, Löschen, Anlegen, Belegscan-Übernahme, …),
  Session-Lease (referenzgezählt, mit Heartbeat) für Bearbeitungs-Bildschirme
  (Geschäft/Regal/Kategorie, `Views/SessionLeaseGate.swift`). Details, gewählte
  Parameter und bekannte Grenzen in `docs/DATABASE_CONCURRENCY.md`.
- `ModelContext.autosaveEnabled = false`: alle Schreibzugriffe laufen jetzt über
  explizite, Lease-geschützte `save()`-Aufrufe statt über SwiftDatas implizites
  Autosave.
- `Einkaufsvorgang.artikelAbhaken`: Dedupe-Prüfung gegen doppelte `KaufEintrag`e
  bei seltenen Sync-Latenz-Kollisionen zwischen zwei Geräten.
- Optionaler, standardmäßig deaktivierter DB-Debug-Modus
  (`Services/DebugLogWriter.swift`, `Services/DatabaseDebugLogger.swift`,
  neue Einstellungen-Ansicht `DatabaseDebugSettingsView`) protokolliert
  Sync-/Lock-/Öffnen-/Speicher-Ereignisse lokal und im geteilten DB-Ordner, für
  die Auswertung nach einem künftigen Live-Test mit mehreren Geräten. Als
  projektweite Logging-Architektur in `docs/LOGGING.md` dokumentiert.
- Neue Tests: `DatabaseLeaseServiceTests`, `DebugLogWriterTests`, Dedupe-Test in
  `EinkaufsvorgangTests`.

## v0.2 (Build 29) — Belegscan-Doku konsolidiert

- `docs/BELEGSCAN_ALTERNATIVE_NAMEN.md` in eine neue, gemeinsame
  `docs/BELEGSCAN.md` überführt: beschreibt jetzt den kompletten Belegscan-Ablauf
  (OCR, KI-Extraktion, Übernahme in `KaufEintrag`, Preishistorie-Anzeige) inklusive
  des alternativen Anzeigenamens in einem Dokument statt in zwei getrennten. Verweise
  in `docs/ARCHITECTURE.md`, `Models/KaufEintrag.swift` und
  `Views/Historie/PreisHistorieZeile.swift` entsprechend angepasst.

## v0.2 (Build 28) — Belegscan: alternativer Anzeigename pro Kaufeintrag

- Neues optionales, additives Attribut `KaufEintrag.alternativerName`
  (`Models/KaufEintrag.swift`) sowie Computed-Property `KaufEintrag.anzeigeName`,
  das diesen Namen vor `produktName`/`artikel`/`artikelNameSnapshot` priorisiert.
  Keine neue `SchemaVN`/`MigrationStage` nötig (rein additiv-optional).
- `PreisHistorieZeile` zeigt jetzt `anzeigeName` statt die Priorisierung selbst
  nachzubilden und bietet in der Artikel-Spalte eine Wisch-Aktion „Umbenennen“
  (Alert mit Texteingabe, inkl. „Zurücksetzen“) zum dauerhaften Vergeben/Löschen
  eines alternativen Namens pro Position.
- Architektur/Design-Entscheidungen dazu neu dokumentiert in
  `docs/BELEGSCAN_ALTERNATIVE_NAMEN.md`, verlinkt aus `docs/ARCHITECTURE.md`.

## v0.2 (Build 25) — Kategorien wichtiger als Regale: Versions-Checkpoint

- Minor-Version auf `0.2` angehoben (Nutzervorgabe) — der bisherige `v0.1`-Zyklus
  (Build 17–24) ist damit abgeschlossen. Alle Änderungen dieses Zyklus sind zusätzlich
  konsolidiert in `docs/CHANGELOG_v0.2.md` festgehalten.
- `docs/ARCHITECTURE.md` aktualisiert: veraltete Verweise auf `RegalBesuchsStatistik`/
  `regalBesuchsIndex` (in v1.2 zu `KategorieBesuchsStatistik`/`kategorieBesuchsIndex`
  umbenannt) korrigiert; Datenmodell-Diagramm und Service-Liste um `Geschaeft.kategorien`,
  `ArtikelFilterModus`, `ArtikelVerfuegbarkeitService`, `KaufEintrag.produktName` ergänzt.
- Korrektur in diesem Changelog: der Build-24-Eintrag (reine Testabdeckung, siehe unten)
  fehlte — der Pre-Commit-Hook hatte die Build-Nummer mangels neuem Eintrag stattdessen
  fälschlich in die alte `v1.6`-Überschrift eingetragen. Beides korrigiert.

## v0.1 (Build 24) — Testabdeckung für direkte Geschäft-Kategorie-Zuordnung ohne Regal

- Neue Unit-Tests in `ArtikelVerfuegbarkeitServiceTests.swift` und `ModelTests.swift`
  belegen, dass Geschäfte ganz ohne Regal auskommen: direktes Zuordnen/Entfernen einer
  Kategorie am Geschäft sowie Deduplizierung, wenn eine Kategorie sowohl direkt als
  auch über ein Regal zugeordnet ist.

## v0.1 (Build 23) — Regale optional für Kategorie-Verfügbarkeit & Artikel-Filter beim Einkaufen

- `Models/Geschaeft.swift` / `Models/ArtikelKategorie.swift`: neue direkte
  Zuordnung `Geschaeft.kategorien` (Inverse: `ArtikelKategorie.geschaefte`) — ein
  Geschäft kann Kategorien jetzt direkt verfügbar machen, ganz ohne Regal.
  `Geschaeft.verfuegbareKategorien` ist die Vereinigung aus dieser direkten
  Zuordnung und den über Regale zugeordneten Kategorien; ein Regal ist damit nur
  noch für die Einkaufs-Reihenfolge relevant, nicht mehr Voraussetzung für
  Verfügbarkeit (Korrektur der ursprünglichen v0.3-Entscheidung, siehe
  `docs/DECISIONS.md`).
- Neues `ArtikelFilterModus`-Attribut an `Geschaeft` (`nurVerfuegbare`/`alle`,
  optionaler Rohwert nach dem etablierten Fallback-Pattern) + neuer
  `Services/ArtikelVerfuegbarkeitService.swift`: bestimmt, ob ein Artikel in einem
  Geschäft verfügbar ist — über die Kategorien des Geschäfts, oder (besitzt es
  keine eigenen Kategorien) gelernt aus der Kaufhistorie, sobald der Artikel dort
  einmal gekauft wurde.
- `Views/Einkaufen/EinkaufenView.swift`: der Einkauf startet jetzt automatisch beim
  Öffnen des Tabs (kein manueller „Start“ mehr). Der bisherige Zwei-Werte-Umschalter
  („Nur offene“/„Alle“) ist einem dritten „Lernmodus“ gewichen, der den
  Verfügbarkeitsfilter für diesen Einkauf übergeht — zum Abhaken bislang unbekannter
  Artikel, die dadurch für dieses Geschäft als verfügbar gelernt werden.
- `Views/Geschaefte/KategorieHinzufuegenSheet.swift`: Regal-Auswahl ist jetzt
  optional („Kein Regal“); eine Kategorie wird beim Hinzufügen immer direkt dem
  Geschäft zugeordnet, ein Regal zusätzlich nur zur Sortierung.
- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Segmented-Picker
  „Artikel beim Einkaufen“ für `ArtikelFilterModus`; „Kategorie hinzufügen“ ist
  nicht mehr auf Geschäfte mit mindestens einem Regal beschränkt.
- `docs/DECISIONS.md`, `docs/PRODUCT_SPEC.md`, `HelpView` entsprechend angepasst.
- Neue Unit-Tests `ArtikelVerfuegbarkeitServiceTests` (Kategorie- und
  Kaufhistorie-basierte Verfügbarkeit, geschäftsübergreifende Isolation).
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 19 Unit-Tests bestehen.

## v0.1 (Build 22) — Kategorien-Abschnitt in der Geschäft-Konfiguration

- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Abschnitt „Kategorien“
  neben „Regale“ — listet alle in diesem Geschäft verfügbaren Kategorien
  (`Geschaeft.verfuegbareKategorien`) mit dem Regal, dem sie zugeordnet sind.
  Wischen (bzw. „Bearbeiten“) entfernt eine Kategorie wieder aus ihrem Regal.
- Neu: `Views/Geschaefte/KategorieHinzufuegenSheet.swift` — Sheet zum
  Hinzufügen einer Kategorie zum Geschäft. Da Verfügbarkeit ausschließlich über
  die Regal-Zuordnung entsteht (siehe `docs/DECISIONS.md`), muss dabei ein
  Ziel-Regal gewählt werden; ohne Regal wird das erklärt statt eine (nutzlose)
  Auswahl anzubieten. Bietet ebenfalls „Neue Kategorie anlegen“ an.
- `Views/Geschaefte/NeueKategorieSheet.swift`: aus `RegalDetailView.swift`
  herausgelöst, damit sowohl die Regal-Bearbeitung als auch das neue
  Kategorie-Sheet dieselbe Erstellungs-UI (Name, Symbol & Farbe) nutzen.
- Neuer Unit-Test `kategorieEntfernenAusRegalMachtSieWiederNichtVerfuegbar` in
  `ModelTests.swift` deckt die Entfernen-Semantik ab.

## v0.1 (Build 21) — Kategorien-Konfiguration pro Regal

- `Models/Regal.swift`: neue Methode `auswaehlbareKategorien(aus:)` liefert die
  Kategorien, die einem Regal zugeordnet werden können — bereits diesem Regal
  zugeordnete sowie alle, die noch keinem anderen Regal desselben Geschäfts
  zugeordnet sind. Jede Kategorie soll innerhalb eines Geschäfts genau einem
  Regal angehören.
- `Views/Geschaefte/RegalDetailView.swift`: die Kategorienauswahl eines Regals
  nutzt jetzt `auswaehlbareKategorien(aus:)` statt aller Kategorien — bereits
  einem anderen Regal desselben Geschäfts zugeordnete Kategorien werden nicht
  mehr angeboten. Neu: „Neue Kategorie anlegen“ öffnet ein Sheet (Name, Symbol
  & Farbe wie bei Artikeln) und ordnet die neu angelegte Kategorie direkt dem
  aktuellen Regal zu.
- Neuer Unit-Test `auswaehlbareKategorienSchliessenAnderweitigVerwendeteAus` in
  `ModelTests.swift` deckt die Ausschluss-Logik ab.

## v0.1 (Build 20) — Belegscan: Einkaufsdatum & produktgenaue Preishistorie

- `Services/ReceiptScanService.swift`: `BelegErgebnis` erkennt jetzt zusätzlich das
  Einkaufsdatum (`datum`, KI-Format `JJJJ-MM-TT`) und liefert es über die neue
  Computed-Property `erkanntesDatum: Date?` geparst (`nil` bei leerem/ungültigem
  Text). Neuer Unit-Test `ReceiptScanServiceTests` deckt beide Fälle ab.
- `Views/Einkaufen/BelegScanView.swift`: die Ergebnisliste zeigt jetzt einen
  `DatePicker` für das (von der KI vorbelegte) Einkaufsdatum, das der Anwender vor
  der Übernahme korrigieren kann — angewendet auf alle übernommenen/aktualisierten
  `KaufEintrag`e in beiden Scan-Kontexten.
- `Models/KaufEintrag.swift`: neues optionales Attribut `produktName` hält den
  ursprünglich vom Beleg erkannten Produkt-/Markennamen fest (z.B. „Colgate Total“),
  auch wenn der Anwender die Position in `BelegScanView` zwecks Zuordnung auf einen
  bestehenden, generischeren `Artikel` umbenennt (z.B. „Zahnpasta“). So bleiben
  unterschiedliche Marken desselben generischen Artikels in der Preishistorie pro
  Geschäft unterscheidbar, statt beim Umbenennen verlorenzugehen.
- `Views/Historie/PreisHistorieZeile.swift`: zeigt bevorzugt `produktName`, fällt
  ansonsten wie bisher auf den (ggf. generischen) Artikelnamen zurück.
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- **SwiftData-Migrationslücke gefunden und korrigiert:** Der ursprüngliche Versuch,
  gemäß der bestehenden Regel in `Models/SchemaDefinition.swift` eine neue `SchemaV2`
  für dieses additive, optionale Attribut anzulegen, crashte reproduzierbar beim
  Öffnen des Stores (`NSInvalidArgumentException: Duplicate version checksums
  detected`) — weil `SchemaV1` und `SchemaV2` in diesem Projekt (flache Modell-Klassen
  ohne Versions-Verschachtelung) auf denselben lebenden Modell-Typ zeigen und damit
  identisch gehasht werden. Korrektur: für rein additive optionale Attribute bleibt
  es bei der einzigen `SchemaV1` (klassische automatische Lightweight-Migration);
  Details und Kriterien für echte `SchemaVN`-Bumps in `docs/DECISIONS.md` ergänzt.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 14 Unit-Tests bestehen.

## v0.1 (Build 19) — Anzeige-Umschalter & dauerhaftes Entfernen abgehakter Artikel

- `Models/Einkaufsvorgang.swift`: neue Methode `artikelDauerhaftEntfernen(_:context:)` —
  löscht den `KaufEintrag` eines bereits abgehakten Artikels, ohne ihn (anders als
  `artikelAbwaehlen`) wieder auf die Einkaufsliste zurückzusetzen.
- `Views/Einkaufen/EinkaufenView.swift`: Während eines laufenden Einkaufs kann per
  Menü-Picker („Nur offene“ / „Alle“) umgeschaltet werden, ob bereits abgehakte Artikel
  zusätzlich zu den offenen angezeigt werden. Abgehakte Artikel bleiben so sichtbar
  (durchgestrichen) und lassen sich durch erneutes Antippen zurückholen. Eine
  Wisch-Aktion („Dauerhaft entfernen“) auf abgehakten Artikeln entfernt sie endgültig aus
  dieser Ansicht.
- Dafür wurde die zugrunde liegende Artikel-Query von einer gefilterten
  (`istAufEinkaufsliste`) auf eine ungefilterte Abfrage umgestellt; offene/abgehakte
  Artikel werden jetzt in der View berechnet.
- `docs/PRODUCT_SPEC.md` entsprechend ergänzt.
- Klargestellt (kein Code-Fix nötig): Ein Einkauf konnte schon zuvor jederzeit
  abgeschlossen werden, auch ohne dass alle Artikel abgehakt sind.

## v0.1 (Build 18) — Kaufbeleg-Scan für Geschäfte & Einzelpreis-Erkennung

- `Services/ReceiptScanService.swift`: `BelegPosition` erkennt jetzt zusätzlich die
  auf dem Bon angegebene `menge` und liefert `einzelpreis` statt eines
  mehrdeutigen `preis`-Felds. Der FoundationModels-Prompt weist die KI explizit an,
  bei Mehrfachpositionen (z.B. „3 x 1.50 = 4.50“) den Gesamtpreis durch die Menge zu
  teilen, statt ihn unverändert zu übernehmen — übernommen wird ausschließlich der
  Einzelpreis, keine Mengenangabe.
- `Views/Einkaufen/BelegScanView.swift`: neuer `BelegScanKontext` (`.einkaufsvorgang`
  oder `.geschaeft`) — Beleg-Scan funktioniert jetzt auch unabhängig von einem
  laufenden Einkauf direkt für ein Geschäft. Im Geschäft-Kontext wird für jede
  erkannte Position ein eigenständiger `KaufEintrag` mit heutigem Datum angelegt;
  ein passender bestehender `Artikel` wird per Namensabgleich verknüpft, damit der
  Preis in dessen Preishistorie auftaucht.
- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Abschnitt „Kaufbeleg scannen“
  öffnet `BelegScanView` im Geschäft-Kontext — auch für Geschäfte ohne bisherige
  Preishistorie sichtbar.
- Die bestehende Prüfen/Korrigieren/Löschen-Liste vor der Preisübernahme
  (`ErgebnisListe`) gilt unverändert für beide Kontexte.
- Kamera-Unterstützung war bereits aktiv (`NSCameraUsageDescription`,
  `KameraAufnahmeView`) und wurde für diesen Checkpoint nicht verändert.
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 12 Unit-Tests bestehen.

## v0.1 (Build 17) — Neues Versionsschema: manuelle Major/Minor-Version, automatische Build-Nummer

- Ab sofort wird die Version als `vMajor.Minor (Build N)` geführt. `Major.Minor`
  (`MARKETING_VERSION` in `project.yml`, `VERSION`-Datei) wird nur noch manuell vom
  Nutzer festgelegt — die bisherige Automatik, die pro Checkpoint die erste
  Nachkommastelle erhöht hat, entfällt. `N` (`CURRENT_PROJECT_VERSION` in
  `project.yml`) ist die Build-Nummer und wird automatisch bei jedem Commit um 1
  erhöht.
- Neuer Git-Hook `.githooks/pre-commit`: erhöht `CURRENT_PROJECT_VERSION` in
  `project.yml` und trägt die neue Build-Nummer in die oberste Überschrift von
  `docs/CHANGELOG.md` ein (`## vX.Y (Build N) — ...`), damit jeder Commit
  nachvollziehbar auf seinen Changelog-Eintrag verweist. Aktiviert lokal über
  `git config core.hooksPath .githooks` (siehe `docs/DECISIONS.md`).
- Version mit diesem Commit auf `0.1` zurückgesetzt (Nutzervorgabe); die
  Build-Nummer knüpft an die bisherige Commit-Historie an.

## v1.6 (Build 26) — Explizite SwiftData-Migrationslogik (`SchemaMigrationPlan`)

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

## v1.5 (Build 27) — Absturz beim Öffnen eines Geschäfts nach v1.4-Update behoben

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

## v1.4 (Build 32) — Manuelle und automatische Regal-Reihenfolge als gleichberechtigte Alternativen

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

## v1.3 (Build 34) — Unkategorisierte Artikel fallen automatisch unter „Sonstiges“

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

## v1.2 (Build 38) — Lern-Algorithmus auf Artikelkategorie umgestellt

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

## v1.1 (Build 39) — Artikel direkt aus der Einkaufsliste hinzufügen

- Neu: `Views/Einkaufen/ArtikelHinzufuegenView.swift` — Sheet mit Suchfeld über alle
  bereits angelegten Artikel, aufrufbar über den neuen „+“-Button in der
  Einkaufsliste (`Views/Einkaufen/EinkaufenView.swift`). Antippen eines
  Suchtreffers setzt den Artikel direkt auf die Einkaufsliste.
- Findet die Suche keinen exakten Namenstreffer, kann der Artikel per „„…“ neu
  anlegen“ sofort über die bestehende `ArtikelEditView` angelegt werden
  (inkl. Kategorie-Auswahl) und landet danach automatisch auf der Einkaufsliste.

## v1.0 (Build 41) — Globale Einkaufsliste & frei änderbare Kategorie

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

## v0.9 (Build 43) — Kamera-Funktion reaktiviert

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

## v0.8 (Build 44) — Kamera-Funktion deaktiviert

- Das Camera-Entitlement (`NSCameraUsageDescription`) wird vom Apple-Developer-Account
  aktuell nicht unterstützt und wurde daher wieder entfernt (`project.yml`).
- `Views/Einkaufen/BelegScanView.swift`: Beleg-Erfassung nur noch über die
  Fotomediathek (`PhotosPicker`); die Kamera-Aufnahme (`UIImagePickerController`,
  `KameraAufnahmeView`) wurde entfernt.
- Hilfe-Eintrag „Belegscan & Preishistorie“ in `HelpView` an den Wegfall der
  Kamera-Option angepasst.

## v0.7 (Build 45) — Belegscan & Preishistorie

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

## v0.6 (Build 46) — KI-Vorschlag, Einstellungen & Datenbank-Speicherort

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
