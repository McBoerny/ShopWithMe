# Belegscan

Der Belegscan fotografiert/lädt einen Kassenbon, erkennt Positionen (Name, Menge,
Einzelpreis) per On-Device-KI und trägt daraus Preise in die Preishistorie ein. Dieses
Dokument beschreibt den gesamten Ablauf inkl. Datenmodell, die Alias-/Artikel-Zuordnung
pro Position, die Preisübersicht eines Geschäfts sowie das Mitlernen über mehrere
Belegscans hinweg.

## Beteiligte Dateien

- `ShopWithMe/Services/ReceiptScanService.swift` — OCR + KI-Extraktion.
- `ShopWithMe/Views/Einkaufen/BelegScanView.swift` — Aufnahme, Prüf-/Korrektur-UI,
  Übernahme in `Preispunkt`e (operative `KaufEintrag`-Buchungszeile bei laufendem
  Einkauf unverändert), Mitlern-Vorbelegung, automatischer Geschäfts-Abgleich (siehe
  unten).
- `ShopWithMe/Views/Einkaufen/PreisschildScanView.swift` — analoger, einzelner
  Preisschild-Scan (`docs/PREISSCHILD_SCAN.md`); funktioniert immer direkt für ein
  feststehendes Geschäft, **ohne** den automatischen Geschäfts-Abgleich unten.
- `ShopWithMe/Models/Preispunkt.swift` — persistentes Preishistorie-Ziel-Model
  (GitHub #76, vormals Teil von `KaufEintrag`), `anzeigeName`.
- `ShopWithMe/Models/Produktname.swift` — geschäftsspezifische/-unabhängige
  Rohnamen eines Produkts, `passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`
  (GitHub #128, vormals `ArtikelAlias.passend`, siehe
  `docs/ARTIKEL_PRODUKT_MODELL.md`). `Artikel/alternativeNamen` deckt
  ergänzend generische, produktunabhängige Synonyme ab.
- `ShopWithMe/Services/PreispunktService.swift` — zentrale Schreiblogik: legt nur bei
  tatsächlicher Preisänderung einen neuen `Preispunkt` an; `vorhandenerPunktHeute(...)`/
  `ersetzeVorhandenenPunkt(...)` für die Tages-Kollisionsabfrage (siehe
  `docs/PREISHISTORIE_VERDICHTUNG.md`).
- `ShopWithMe/DesignSystem/TagesKollisionZeile.swift` — Inline-Hinweis samt
  Umschalt-Button, wenn für heute bereits ein abweichender Preis erfasst ist.
- `ShopWithMe/Models/KaufEintrag.swift` — operative Buchungszeile eines laufenden
  Einkaufsvorgangs (Dedupe, `kategorieBesuchsIndex`), seit GitHub #76 ohne Preisrolle.
- `ShopWithMe/Models/Geschaeft.swift` — `alternativeNamen`,
  `alternativenNamenLernen(_:)`, `passendes(fuerErkannterName:unter:)`.
- `ShopWithMe/Views/Geschaefte/GeschaeftWahlSheet.swift` — Geschäftsauswahl, falls
  der automatische Abgleich keinen Treffer findet.
- `ShopWithMe/Models/ArtikelPreisSpanne.swift` — Gruppierung nach Artikel + Preisspanne.
- `ShopWithMe/Views/Historie/PreisHistorieZeile.swift` — einzelne Zeile, öffnet die
  Zuordnen-Sheet.
- `ShopWithMe/Views/Historie/PreispunktZuordnenSheet.swift` — Alias vergeben +
  Artikel zuordnen/neu anlegen (vormals `KaufEintragZuordnenSheet`).
- `ShopWithMe/Views/Geschaefte/GeschaeftPreisUebersichtView.swift` — eigener View
  für die Preisübersicht (GitHub #20), `ArtikelPreisSpanneZeile`/
  `ArtikelPreisVerlaufView` (Drill-down mit Preisdiagramm, GitHub #21), aufrufbar
  über einen Eintrag in `GeschaeftDetailView.swift`.
- `ShopWithMe/Views/Geschaefte/GeschaeftListView.swift` — geschäftsloser
  Scan-Einstieg (Toolbar-Menü „Scannen“).
- `ShopWithMe/App/RootView.swift` — eigener „Scannen“-Tab, bettet `BelegScanView`
  dauerhaft ein (siehe „Eigener Scannen-Tab“ unten).
- `ShopWithMe/DesignSystem/ZoombareBildAnsicht.swift` — zoom-/schwenkbare,
  einbettbare Inhaltsansicht des Original-Belegs mit optionaler
  Positions-Markierung, inline in `ErgebnisListe` (siehe unten).
- `ShopWithMe/DesignSystem/DokumentScanView.swift` — dokumentenoptimierte
  Kamera-Aufnahme (VisionKit, `VNDocumentCameraViewController`) mit automatischer
  Kantenerkennung/Perspektivkorrektur, nur für `BelegScanView` (siehe „Aufnahme“
  unten) — für `PreisschildScanView` weiterhin ein rohes Kamerafoto
  (`UIImagePickerController`), da dessen Kantenerkennung auf seitenartige
  Dokumente ausgelegt ist, nicht auf ein einzelnes Regal-Preisschild.
- `ShopWithMeTests/ReceiptScanServiceTests.swift`, `ShopWithMeTests/ModelTests.swift`.
- `ShopWithMeTests/BelegScanIntegrationTests.swift` — Fixture-basierte Integrationstests
  (OCR-Stufe + vollständige Pipeline); Testdaten in `ShopWithMeTests/Belege/`
  (siehe „Test-Infrastruktur" unten).

## Ablauf

1. **Aufnahme** (`AufnahmeAnsicht` in `BelegScanView.swift`): Scan per
   `DokumentScanView` (VisionKit, `VNDocumentCameraViewController`) oder Foto aus
   der Mediathek (`PhotosPicker`). Der Dokumentenscanner erkennt automatisch die
   Kanten des Kassenbons, korrigiert die Perspektive und optimiert Kontrast/
   Belichtung, bevor das Bild überhaupt zur OCR geht — deutlich zuverlässiger als
   ein rohes Kamerafoto bei schräg gehaltenen, verknitterten oder schlecht
   beleuchteten Bons. Verfügbarkeit wird über
   `VNDocumentCameraViewController.isSupported` geprüft (im Simulator ohne Kamera
   `false`, dann bleibt nur die Mediathek-Auswahl).
2. **OCR** (`VisionFoundationModelsReceiptScanner.erkenneText`): `VNRecognizeTextRequest`
   (Vision, `.accurate`, Sprachen `de-DE`/`en-US`, `minimumTextHeight = 0.01` für
   kleine Thermodruck-Schrift) liefert pro Zeile Text **und** Position im Bild als
   `ErkannteZeile` (`text`, `boundingBox` — Visions normalisiertes
   Koordinatensystem, Ursprung unten links, 0–1). Die Zeilen werden vor der
   Weitergabe an das Sprachmodell per `[ErkannteZeile].sortiertInLeserichtung()`
   explizit von oben nach unten (bei gleicher Zeile links nach rechts) sortiert —
   Visions eigene Ausgabereihenfolge ist bei einer leicht schiefen Aufnahme nicht
   garantiert lesereihenfolge-treu, was Artikelname und Preis unterschiedlicher
   Zeilen fälschlich hätte zusammenführen können. Die `boundingBox`en bleiben
   zusätzlich Grundlage für die Positions-Markierung im Original-Beleg (siehe
   „Originalbeleg anzeigen“ unten).
3. **Strukturextraktion** (`VisionFoundationModelsReceiptScanner.extrahiere`): Eine
   `LanguageModelSession` (FoundationModels, on-device) bekommt nur die
   zusammengefügten Texte der `ErkannteZeile`n und wandelt sie in ein
   `@Generable`-Ergebnis um:
   - `BelegPosition`: `artikelName: String`, `menge: Double`, `einzelpreis: Decimal`.
     Bei Mehrfachpositionen mit nur einem Gesamtpreis auf dem Bon (z.B. „3 x 1.50 =
     4.50“) berechnet die KI den Einzelpreis (Gesamtpreis ÷ Menge) — übernommen wird
     später ausschließlich der Einzelpreis, nie die Menge.
   - `BelegErgebnis`: `geschaeftName`, `datum` (Format `JJJJ-MM-TT`, geparst über
     `erkanntesDatum: Date?`), `positionen: [BelegPosition]`.
   - Beide Typen sind reine, flüchtige KI-Transfertypen — **kein** eigenes
     SwiftData-Model für Belegpositionen. `auswerten(bild:)` liefert `BelegErgebnis`
     zusammen mit den `ErkannteZeile`n als `BelegScanErgebnis`.
4. **Ignorier-Filter + Artikel-Zuordnung** (`BelegScanView.verarbeite(bild:)`): pro
   erkannter Position erst `IgnorierterArtikel.istIgnoriert(...)` (Position
   verschwindet komplett, siehe „Dauerhaft ignorierte Artikel pro Geschäft” unten),
   sonst dreistufig (GitHub #123): (a) Text-Abgleich mit OCR-Text (Stufe 1+2,
   `ArtikelZuordnungsService.textBasierteZuordnung(...)`), (b) Klarname-Ableitung —
   bei Treffer aus dem Produktnamen, sonst KI-Vorschlag
   (`AISuggestionService.produktKlarname`), (c) KI-Artikel-Match
   (`AISuggestionService.artikelMatch`) auf Basis des Klarnamens statt des OCR-Texts
   (nur wenn Stufen 1+2 ohne Treffer). Zusätzlich ermittelt
   `[ErkannteZeile].boundingBox(fuerArtikelName:)` per beidseitigem
   Teilstring-Abgleich die zur Position passende OCR-Zeile (`nil` ohne eindeutigen
   Treffer).
5. **Prüfen/Korrigieren** (`ErgebnisListe`/`PositionsZeile` in `BelegScanView.swift`):
   editierbare Kopie jeder Position (`BearbeitbarePosition`: `erkannterName`
   unveränderlich, `artikelName`/`produktKlarname`/`preisText` editierbar,
   `zugeordneterArtikel` aus Schritt 4, `boundingBox` aus Schritt 4) plus
   editierbares `belegDatum`. Drei Namens-Ebenen pro Position (GitHub #121):
   - `erkannterName` (read-only): der rohe Bon-Text, z.B. „SEBAMED UR” — wird als
     `Preispunkt.produktName` und ggf. als geschäftsspezifischer `Produktname` gespeichert.
   - `artikelName` (editierbar): verknüpft die Position mit einem generischen `Artikel`
     (z.B. „Shampoo”) — zeigt nach erfolgreicher Zuordnung dessen Namen.
   - `produktKlarname` (editierbar, neu): menschenlesbarer Klarname (z.B. „Sebamed
     Urea 5%”), von der KI aus bestehenden Produkt-Klarnames vorbelegt oder neu
     generiert; leer gelassen → `erkannterName` dient als Produktidentität. Wird als
     `Produkt.name` und als `Preispunkt.alternativerName` übernommen.
   Details zur Anzeige/Korrektur der Zuordnung siehe „Automatische Artikel-Zuordnung” unten.
6. **Übernahme** (`BelegScanView.uebernehmen()`): abhängig vom `BelegScanKontext`,
   in allen drei Fällen mit `position.effektivZugeordneterArtikel` verknüpft (siehe
   „Automatische Artikel-Zuordnung” unten):
   - `.einkaufsvorgang(Einkaufsvorgang)`: die operative Buchungszeile (Namensabgleich
     `passtZu` gegen bereits abgehakte `KaufEintrag`e dieses Einkaufsvorgangs) bleibt
     bis auf das Datum unverändert (bzw. wird bei fehlendem Treffer neu, rein
     operativ ohne Preisfelder angelegt) — die Preisrolle übernimmt in **allen**
     drei Fällen ausschließlich `PreispunktService.erfassen(...)`.
   - `.geschaeft(Geschaeft)`: unabhängig von einem laufenden Einkauf, direkt aus der
     Geschäfts-Detailansicht. Jede Position erzeugt einen `Preispunkt`, keinen
     `KaufEintrag` (kein laufender Einkauf, also keine operative Rolle).
   - `.unbekannt`: geschäftsloser Scan (siehe „Automatischer Geschäfts-Abgleich”
     unten) — verhält sich sonst wie `.geschaeft`, nur dass das Geschäft erst nach
     dem Scan feststeht (`erkanntesGeschaeft` statt eines fest übergebenen Werts).
   - In allen Fällen: weicht `produktKlarname` vom rohen `erkannterName` ab, wird er
     als `alternativerName` auf dem `Preispunkt` übernommen (`leiteAlternativenNamenAb`).
     Zusätzlich legt `Produkt.aufgeloestesOderNeuesProdukt(...)` bei Bedarf einen
     `Produktname` an (sofern noch kein `Produkt` vorlag) — das ist die Quelle für
     das Mitlernen beim nächsten Scan (siehe „Mitlernen zwischen Belegscans” unten).
   - Existiert für Artikel+Geschäft bereits **heute** ein `Preispunkt` mit
     abweichendem Preis, zeigt die Prüf-Ansicht dafür einen Hinweis mit
     Umschalt-Button („wird ersetzt” ↔ „Bisherigen behalten”) — siehe
     `docs/PREISHISTORIE_VERDICHTUNG.md` → „Interaktive Tages-Kollisionsabfrage”.

## Originalbeleg anzeigen

**Status: Umgesetzt** (GitHub #2, seit 2026-07-21 inline statt als eigener
Bildschirm — siehe unten).

Solange die Ergebnis-Prüfung (`ErgebnisListe`) läuft, hält `BelegScanView` das
aufgenommene Foto zusätzlich in `erfasstesBild: UIImage?` — ausschließlich in-memory
für die Dauer dieser Ansicht, **nie auf Platte oder ins SwiftData-Model
geschrieben**; verschwindet mit dem Schließen des Sheets wie jeder andere
View-State auch.

- **Inline statt eigener Bildschirm:** `ZoombareBildAnsicht` erscheint direkt als
  erste Section von `ErgebnisListe` (feste Höhe 320pt), sobald ein Foto vorliegt —
  kein Button/Sheet/`.fullScreenCover` mehr nötig, das Original ist sofort
  sichtbar. `ZoombareBildAnsicht` selbst wurde dafür von der bisherigen
  `NavigationStack`/Toolbar/„Fertig“-Chrome befreit und ist jetzt eine reine,
  einbettbare Inhaltsansicht (weiterhin frei zoom-/schwenkbar per Pinch-/Drag-Geste,
  Doppel-Tap setzt zurück). Die Zieh-Geste greift dabei bewusst nur, solange
  tatsächlich gezoomt wurde (`aktuellerZoom > 1`, per `simultaneousGesture(_:including:)`)
  — bei Zoom 1 soll ein Ziehen stattdessen die umgebende Liste scrollen können,
  kein Gesten-Konflikt.
- Je Position mit ermittelter `boundingBox` (siehe Schritt 4 oben) erscheint ein
  Lupen-Symbol (`viewfinder`), das per `ScrollViewReader` zur Beleg-Vorschau
  hochscrollt und darin ein gelb hervorgehobenes Rechteck um die erkannte OCR-Zeile
  setzt (`ErgebnisListe.positionMarkieren(_:proxy:)`). Positionen ohne eindeutig
  zuordenbare Zeile zeigen bewusst **kein** Symbol, statt eine falsche Markierung
  zu raten.
- Kein automatisches Heran-Zoomen zur Markierung (bewusste Scope-Entscheidung,
  siehe „Bewusst nicht umgesetzt“) — der Anwender zoomt bei Bedarf selbst.
- `ZoombareBildAnsicht` (`ShopWithMe/DesignSystem/ZoombareBildAnsicht.swift`) ist
  weiterhin eine generische, wiederverwendbare Komponente, nicht Belegscan-spezifisch:
  rechnet Visions normalisierte Bounding-Box-Koordinaten (Ursprung unten links)
  unter Berücksichtigung des Aspect-Fit-Scalings in Bildschirmkoordinaten um.

**Bugfix (2026-07-21): Bounding Boxes passten nicht zum angezeigten Foto.**
`VisionFoundationModelsReceiptScanner.erkenneText` rief `VNImageRequestHandler`
bisher ohne `orientation`-Parameter auf — Vision interpretierte damit den rohen,
oft gedrehten Kamera-Pixelpuffer (`UIImage.imageOrientation` meist `.right` bei
Fotos aus `UIImagePickerController`), während `Image(uiImage:)` das Foto korrekt
orientiert anzeigt. Die berechneten `boundingBox`en passten dadurch nicht zur
sichtbaren Position. Fix: `CGImagePropertyOrientation(bild.imageOrientation)`
(manuelle Zuordnung statt `rawValue`-Cast, da die Rohwerte beider Enums nicht
übereinstimmen) wird jetzt an `VNImageRequestHandler` übergeben.

**Abbrechen ohne Rückfrage (seit 2026-07-21):** Der „Abbrechen“-Button schließt
`BelegScanView` jetzt immer sofort, auch wenn bereits Positionen zur Prüfung
vorliegen — die vorherige Rückfrage „Scan verwerfen?“ (`confirmationDialog`) wurde
auf Nutzerwunsch entfernt.

## Eigener Scannen-Tab

**Status: Umgesetzt (2026-07-21).** `BelegScanView` ist jetzt zusätzlich als
eigener, dritter Tab in `RootView` (zwischen „Einkaufen“ und „Einstellungen“,
`camera.viewfinder`) dauerhaft eingebettet — immer im
`BelegScanKontext/unbekannt`-Kontext (automatischer Geschäfts-Abgleich bzw.
`GeschaeftWahlSheet`, siehe unten), analog zum bisherigen geschäftslosen
Scan-Einstieg in `GeschaeftListView`. Alle vier bisherigen Sheet-Einstiegspunkte
(Einkaufen-Menü, nach Einkaufsabschluss, Geschäfts-Detail, Geschäfte-Liste) bleiben
unverändert bestehen — der Tab ist nur ein zusätzlicher, schnellerer Weg, keine
Ablösung (Nutzer-Entscheidung, siehe Rückfrage in `docs/CHANGELOG.md` v0.6).

**Technische Besonderheit:** Als Tab-Inhalt (statt Sheet/`.fullScreenCover`) gibt es
keine umgebende Präsentation, die sich per `@Environment(\.dismiss)` schließen
ließe — ein Aufruf würde ins Leere laufen. `BelegScanView.istEigenerTab` (Default
`false`, unverändert an allen bestehenden Sheet-Aufrufstellen) schaltet deshalb bei
`true` auf `zuruecksetzen()` um: sowohl nach „Verwerfen“ (ersetzt „Abbrechen“ im
Tab-Kontext, nur sichtbar solange Positionen vorliegen) als auch nach erfolgreichem
`uebernehmen()` wird der komplette Scan-Zustand (Foto, Positionen, erkanntes
Geschäft, Datum) zurückgesetzt, statt zu dismissen — der Tab ist danach sofort
wieder bereit für den nächsten Scan, ohne Tab-Wechsel.

## Automatischer Geschäfts-Abgleich

Nur beim Belegscan relevant (siehe `docs/PREISSCHILD_SCAN.md` → „Kein
geschäftsloser Einstieg“ für die bewusste Abgrenzung zum Preisschild-Scan). Wird ein
Beleg nachträglich gescannt — z.B. zuhause, ohne vorher ein Geschäft auszuwählen —,
steht zum Scan-Zeitpunkt noch kein `Geschaeft` fest. `BelegScanKontext.unbekannt`
sowie ein `.einkaufsvorgang` ohne gewähltes Geschäft decken diesen Fall ab.

**Geschäfts-Pflicht (GitHub #128):** Seit der Geschäfts-Pflicht bei `Preispunkt`
lässt sich „Preise übernehmen" nicht mehr betätigen, solange kein Geschäft
feststeht (`ErgebnisListe`-Button `.disabled(erkanntesGeschaeft == nil)`,
zusätzlicher Guard in `uebernehmen()`). Es gibt keine „Kein Geschäft"-Option
mehr — der Anwender muss ein bestehendes Geschäft wählen oder eines neu
anlegen (siehe Schritt 3 unten).

1. **Erkennung**: `ReceiptScanService` liefert zusätzlich zu den Positionen einen
   rohen `geschaeftName: String` sowie eine rohe `geschaeftAdresse: String` (beide
   auf einem Kassenbon meist in der Kopf-/Fußzeile vorhanden, sonst leerer String).
2. **Abgleich** (`BelegScanView.geschaeftAbgleichen(erkannterName:erkannteAdresse:)`):
   sucht per `Geschaeft.passendes(fuerErkannterName:erkannteAdresse:unter:)` unter
   allen vorhandenen Geschäften nach einem Treffer — sowohl gegen `Geschaeft.name`
   als auch gegen dessen gelernte `alternativeNamen` (beidseitiger
   `localizedCaseInsensitiveContains`-Abgleich, analog
   `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`).
   **Mehrere namensgleiche Geschäfte** (z.B. zwei
   „Rewe“-Filialen): die erkannte Adresse dient als automatischer Tie-Breaker
   (gleicher Abgleich gegen `Geschaeft.adresse`) — **ohne Rückfrage**. Bleibt danach
   mehr als ein Kandidat übrig oder wurde keine/keine passende Adresse erkannt,
   fällt die Funktion auf den ersten Namens-Kandidaten zurück (wie vor dieser
   Erweiterung), statt den Anwender zu unterbrechen.
3. **Kein Treffer → Anwenderauswahl** (`GeschaeftWahlSheet`): öffnet sich
   automatisch, sobald kein Treffer gefunden wurde. Bietet Suche unter
   bestehenden Geschäften sowie „„<Suchtext>“ neu anlegen“ (öffnet `GeschaeftStammdatenEditView`, vorausgefüllt
   mit dem erkannten Namen **und** der erkannten Adresse). Die Adresse wird dabei
   sofort über `GeschaeftErkennungService.koordinaten(fuerAdresse:)` geocodiert und
   die ermittelten Koordinaten am Entwurf gesetzt — bewusst **nicht** der aktuelle
   GPS-Standort des Anwenders (unverändert gegenüber der Entscheidung, den Standort
   nie automatisch beim Belegscan zu erfassen, siehe „Standort nachträglich für ein
   bereits genutztes Geschäft ergänzen“ in `docs/GESCHAEFTSERKENNUNG.md`); schlägt
   das Geocoding fehl, öffnet sich der Entwurf trotzdem, nur ohne Koordinaten. Der
   Anwender kann das erkannte/gewählte Geschäft in der Ergebnisansicht jederzeit
   über die „Geschäft“-Zeile ändern.
4. **Mitlernen** (`Geschaeft.alternativenNamenLernen(_:)`, aufgerufen in
   `uebernehmen()`): der rohe erkannte Name wird als zusätzlicher
   `alternativeNamen`-Eintrag des (automatisch erkannten oder manuell gewählten)
   Geschäfts gespeichert — sofern er weder dem `name` noch einem bereits bekannten
   Alias entspricht. Künftige Scans desselben Geschäfts (z.B. mit
   Filial-Zusatz „REWE Center Musterstadt“ statt nur „Rewe“) werden dadurch
   automatisch erkannt, ohne dass der Anwender erneut auswählen muss.
5. **Rückwirkende Zuordnung**: steht ein `.einkaufsvorgang` ohne Geschäft dahinter,
   wird `einkaufsvorgang.geschaeft` beim Übernehmen auf das erkannte/gewählte
   Geschäft gesetzt — der gesamte Einkauf gilt rückwirkend als dort getätigt
   (relevant für `AbteilungsDistanzService`/`ArtikelVerfuegbarkeitService`).

Bei `.geschaeft(Geschaeft)` (Scan direkt aus der Geschäfts-Detailansicht) entfällt
dieser gesamte Abgleich — das Geschäft steht bereits fest, die „Geschäft“-Zeile
erscheint dort nicht.

## Kurzadresse bei namensgleichen Geschäften

**Status: Umgesetzt** (`Geschaeft.kurzeAdresse`, `Geschaeft.namenMitDuplikaten(unter:)`).

Da es mehrere Geschäfte mit demselben Namen geben kann (s.o.), zeigen sowohl
`GeschaeftWahlSheet` (Geschäftsauswahl beim Belegscan-Abgleich) als auch
`GeschaeftListView` (allgemeine Geschäfteliste) unter dem Namen zusätzlich
`Geschaeft.kurzeAdresse` in kleiner, sekundärer Schrift — **aber nur**, wenn der
Name laut `Geschaeft.namenMitDuplikaten(unter:)` (einmal pro Ansicht berechnete,
kleingeschriebene Menge mehrfach vorkommender Namen) tatsächlich mehrdeutig ist;
bei eindeutigen Namen bleibt die Zeile unverändert einzeilig.

`kurzeAdresse` ist Straße + Ort ohne Postleitzahl (z.B. „Marktstraße 1,
Musterstadt“ aus „Marktstraße 1, 12345 Musterstadt“) — der Teil vor dem ersten
Komma bleibt unverändert, die vierstellige (AT) oder fünfstellige (DE)
Postleitzahl danach wird per Regex entfernt. Enthält `adresse` kein Komma, wird
sie unverändert zurückgegeben; ohne hinterlegte `adresse` liefert die Property
`nil` (Zeile bleibt einzeilig, auch bei Namensduplikat).

## Automatische Artikel-Zuordnung

**Status: Umgesetzt** (`ArtikelZuordnungsService.swift`, `PositionsZeile` in
`BelegScanView.swift`).

Jeder auf einem Kassenbon erkannte Artikelname ist die Original-Bezeichnung des
Händlers (oft abgekürzt, z.B. „COL-ZAH“) — er wird konsistent über alle drei
`BelegScanKontext`e (vorher inkonsistent, siehe unten) beim Einlesen einem
bestehenden, generischen `Artikel` zugeordnet, dreistufig:

1. **Gelernter Produktname**: `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`
   (siehe „Mitlernen zwischen Belegscans“ unten) — sucht zuerst geschäftsspezifisch,
   dann geschäftsunabhängig.
2. **Teilstring-Abgleich**: einfacher, beidseitiger
   `localizedCaseInsensitiveContains`-Vergleich gegen alle vorhandenen `Artikel`
   (sowohl `Artikel.name` als auch dessen `alternativeNamen`).
3. **KI-Best-Match** — nur falls Stufe 1+2 erfolglos **und** lokale KI verfügbar
   (`AISuggestionService.istVerfuegbar`): `AISuggestionService.artikelMatch(fuerName:bekannteArtikel:)`
   (`@Generable ArtikelMatchVorschlag`, exaktes Vorbild
   `AISuggestionService.kategorieMatch(fuerName:bekannteKategorien:)`, bereits
   identisch genutzt in `MilkForUsImportService`). Antwortet die KI mit einem
   leeren String oder einem Namen, der zu keinem `Artikel` exakt passt, gilt die
   Stufe als erfolglos.

Liefert nur der Artikel einen Treffer (Stufe 2/3, oder eine manuelle
Zuweisung/Neuanlage in der Prüf-Ansicht), ohne dass bereits ein passender
``Produktname`` bekannt ist, legt `BelegScanView.uebernehmen()` automatisch ein
neues, eigenständiges ``Produkt`` an (ein Stufe-1-Treffer bringt dagegen schon
ein ``Produkt`` mit — meist das Standard-Produkt des Artikels, sofern der
gelernte `Produktname` selbst darauf zeigt) — siehe
`docs/ARTIKEL_PRODUKT_MODELL.md` → „Automatische Neuanlage beim Belegscan“ für
die Namensfindung und Duplikat-Vermeidung.

Bleiben alle drei Stufen erfolglos, gilt die Position als **neu erkannt**.
`ArtikelZuordnungsService.textBasierteZuordnung(...)` bündelt Stufe 1+2 als
eigene, ohne KI direkt testbare Funktion (analog
`GeschaeftErkennungService.passendenVorschlag(...)`); `zuordnen(...)` ergänzt
Stufe 3 und ist die volle, von `BelegScanView.verarbeite(bild:)` genutzte
Pipeline. Ersetzt die frühere, nur für `.geschaeft`/`.unbekannt` beim **Speichern**
(nicht in der Prüf-Ansicht sichtbare) `passendesArtikel(fuer:)`-Methode — `.einkaufsvorgang`
bekam bislang gar keine Katalog-Zuordnung.

**Anzeige/Korrektur (`PositionsZeile`, GitHub #123):** Zwei Elemente pro Position:

- **Produktname-Feld** (`produktKlarname`, dominant): das primäre Textfeld, von der
  KI vorbelegt (aus einem bekannten Produktnamen oder neu generiert), direkt editierbar. Weicht
  der Klarname vom rohen `erkannterName` ab oder ist er leer, erscheint darunter
  „Erkannt auf Bon: „<Text>”” in kleiner Schrift.
- **Artikel-Button** (`artikelName`): tappbarer Button darunter — zeigt
  „Artikel: <Name>” (sekundär) bei erfolgreicher Zuordnung oder
  „Neu erkannt – Artikel zuordnen” (orange) ohne Treffer. Antippen öffnet
  `ArtikelAuswahlSheet` (selbe Komponente wie `NeuesProduktSheet`, GitHub #123):
  durchsuchbare Liste aller Artikel; erscheint im Suchfeld ein Name ohne exakten
  Treffer, öffnet sich zusätzlich ein „<Text> neu anlegen”-Button, der
  `ArtikelEditView(istNeu:true)` direkt aus dem Sheet heraus öffnet. Nach
  Auswahl oder Neuanlage schließt das Sheet und die Zuweisung wird übernommen.
- **`BearbeitbarePosition.effektivZugeordneterArtikel`**: liefert die Zuordnung nur,
  solange `artikelName` noch exakt zum Namen des `zugeordneterArtikel` passt —
  rein reaktiv, kein `onChange`-Seiteneffekt. Sowohl Anzeige als auch
  `BelegScanView.uebernehmen()` nutzen ausschließlich diese Property.

## Dauerhaft ignorierte Artikel pro Geschäft

**Status: Umgesetzt** (`IgnorierterArtikel.swift`).

Wischen auf einer Position in `ErgebnisListe`:
- **Nach links** (`.onDelete`, unverändert): löscht die Position nur für diesen
  einen Scan.
- **Nach rechts**: „Dauerhaft ignorieren“ — legt einen `IgnorierterArtikel`
  (`erkannterName`, `geschaeft: erkanntesGeschaeft`) an; künftige Scans desselben
  Geschäfts filtern passende Positionen bereits in `verarbeite(bild:)` heraus
  (`IgnorierterArtikel.istIgnoriert(...)`, Namensgleichheit ODER beidseitiger
  Teilstring, analog den übrigen Namens-Abgleichen im Projekt), noch bevor sie in
  der Prüf-Ansicht erscheinen. Nur sichtbar, solange `erkanntesGeschaeft` gesetzt
  ist — ohne Geschäft gibt es keine sinnvolle Skalierung.

**Bewusst pro Geschäft, nicht global**: Artikelbezeichnungen auf Kassenbons sind je
Geschäft unterschiedlich formatiert (anders als bei
`IgnorierterGeschaeftsVorschlag`, das mangels Relationship auch noch unbekannte
Läden abdecken muss, referenziert `IgnorierterArtikel.geschaeft` eine echte,
bereits persistierte `Geschaeft`-Relationship — zum Zeitpunkt des Ignorierens
steht das Geschäft immer schon fest). Cascade-Delete: Wird das Geschäft gelöscht,
verschwinden auch seine Ignorier-Einträge (`Geschaeft.ignorierteArtikel`).

## Datenmodell: `Preispunkt`

**Seit GitHub #76** gibt es kein eigenes „Belegposition“-Model, aber zwei getrennte
Ziel-Typen statt eines: `Preispunkt` trägt die Preishistorie-Rolle, `KaufEintrag`
bleibt die rein operative Buchungszeile eines laufenden Einkaufsvorgangs (Dedupe,
`kategorieBesuchsIndex` für `AbteilungsDistanzService`, keine Preisfelder mehr).
Grund für die Trennung: die beiden Rollen wuchsen unterschiedlich (jeder Kauf vs. nur
echte Preisänderungen) und ein Preisschild-Scan hat ohnehin nie einen
Einkaufsvorgang — siehe `docs/ROADMAP.md`/Issue #76 für die volle Herleitung.

**Produkt-Pflicht:** ein `Preispunkt` hängt nie direkt an einem `Artikel`, sondern
immer an einem konkreten `Produkt` — `artikel` ist nur noch eine abgeleitete,
read-only Computed-Property (`produkt?.artikel`), kein eigenes gespeichertes Feld
mehr. Ohne auflösbares `Produkt` (z.B. Scan-Position ohne Artikel-Treffer) entsteht
seither gar kein `Preispunkt` mehr — der frühere Freitext-Fall „Ohne
Artikel-Zuordnung" (siehe unten) entfällt.

| Feld | Bedeutung |
| --- | --- |
| `produkt: Produkt?` | Der eigentliche Preisträger — gesetzt aus einer gelernten Zuordnung, per Namensabgleich, oder manuell über `PreispunktZuordnenSheet`. Fachlich verpflichtend (Service-Ebene erzwingt ein aufgelöstes `Produkt`), im Modell technisch weiter optional (SwiftData-Relationships sind auf Storage-Ebene immer nullable). |
| `produktName: String?` | Genauer, vom Kassenbon/Preisschild erkannter Marken-/Produktname, falls er vom (ggf. generischen) `artikel` abweicht (z.B. „COL-ZAH“ bei `artikel?.name == "Zahnpasta"`). Bleibt beim Umbenennen zwecks Zuordnung erhalten, damit unterschiedliche Marken desselben generischen Artikels in der Preishistorie unterscheidbar bleiben. |
| `alternativerName: String?` | Alias für **genau diesen einen Preispunkt** (z.B. „Colgate“) — vom Nutzer vergeben (`PreispunktZuordnenSheet`) oder beim Scan aus einem korrigierten Namensfeld übernommen. Verändert `produktName` nicht. |
| `preis: Decimal` | Beobachteter Einzelpreis — nicht optional, ein `Preispunkt` entsteht nur, wenn tatsächlich ein Preis erfasst wurde. |
| `datum: Date` | Beobachtungsdatum, aus dem Beleg erkannt oder manuell gesetzt. |

Nur bei tatsächlicher Preisänderung entsteht ein neuer `Preispunkt`
(`PreispunktService.erfassen(...)`, Slowly-Changing-Dimension-Muster): ist der
Preis gegenüber dem zuletzt bekannten `Preispunkt` desselben (`produkt`,
`geschaeft`)-Paars unverändert, wird nur dessen `datum` aktualisiert statt ein
Duplikat anzulegen. Reines Abhaken auf der Einkaufsliste ohne Beleg erzeugt gar
keinen `Preispunkt`.

`Produkt → Preispunkt` ist kaskadierend: wird ein Produkt gelöscht, verschwindet
auch seine Preishistorie (anders als früher, wo sie über `artikelNameSnapshot`
erhalten blieb) — `Artikel → Produkt` kaskadiert bereits seit GitHub #47, die
Kette ist damit durchgängig konsistent. `Preispunkt.geschaeftNameSnapshot` bleibt
dagegen unverändert bestehen, siehe `docs/DATENSYNCHRONISATION.md` §4.5 für den
strukturellen (nicht durch Löschreihenfolge behebbaren) Grund im Peer-Sync.

## Anzeige: `Preispunkt.anzeigeName`

Zentrale Computed-Property, die alle Anzeigestellen statt eigener Priorisierungslogik
verwenden:

```swift
var anzeigeName: String {
    if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return alternativerName
    }
    let name = produktName ?? produktNameSicher
    return name.isEmpty ? "Unbekannter Artikel" : name
}
```

Priorität: **`alternativerName`** (Alias, falls gesetzt) → `produktName` (Original vom
Kassenbon) → `produkt?.name` (sofern noch existent, sonst `produktName`-Fallback über
`produktNameSicher`).

Verwendet in `PreisHistorieZeile`, angezeigt in:

- `GeschaeftPreisUebersichtView` — der „Preisübersicht“ (aggregiert pro Artikel,
  siehe unten) sowie im Drill-down `ArtikelPreisVerlaufView`
- `ArtikelEditView` (Preishistorie-Sektion eines Artikels, `zeigeArtikel: false` — zeigt
  dort den Geschäftsnamen statt des Artikelnamens; `alternativerName` bleibt trotzdem
  am `Preispunkt` gesetzt, ist dort nur nicht die sichtbare Spalte)

## Alias vergeben + Artikel zuordnen (UI): `PreispunktZuordnenSheet`

`PreisHistorieZeile` bietet überall eine Wisch-Aktion „Zuordnen“ (führende Kante,
Tag-Symbol), die `PreispunktZuordnenSheet` öffnet:

- **Anzeigename-Textfeld**, vorbelegt mit `eintrag.alternativerName`. Leeres Feld beim
  Speichern → `alternativerName = nil` (fällt auf `produktName`/`produktNameSicher`
  zurück).
- **Artikel-Auswahl**: durchsuchbare Liste aller `Artikel` (analog
  `ArtikelHinzufuegenView`), oder „„<Suchtext>“ neu anlegen“, falls kein exakter Treffer
  existiert — öffnet `ArtikelEditView(artikel:istNeu:true)` und übernimmt den neu
  gesicherten Artikel automatisch als Auswahl (gleiches Muster wie
  `ArtikelHinzufuegenView.nachNeuanlageAufraeumen`). Seit der Produkt-Pflicht keine
  „Keine Zuordnung“-Option mehr — „Speichern“ ist deaktiviert, solange kein Artikel
  gewählt ist.
- **Speichern** setzt `alternativerName`/`produkt` auf dem `Preispunkt`, geschützt
  durch `DatabaseLeaseService.performMicroLease` (explizite Speicherung, da
  `ModelContext.autosaveEnabled == false`, siehe `docs/DATABASE_CONCURRENCY.md`), und
  löst über `Produkt.aufgeloestesOderNeuesProdukt(klarname:erkannterName:artikel:geschaeft:context:)`
  das `Produkt`/einen `Produktname` auf/legt sie an (GitHub #128, ersetzt das
  frühere separate `ArtikelAlias.lernen(...)`) — Lerngrundlage für künftige Scans.

Jede so gesetzte Anzeigename-/Artikel-Kombination ist die Lerngrundlage für künftige
Belegscans desselben Produkts (Schritt 4 oben).

## Preisübersicht eines Geschäfts: `ArtikelPreisSpanne`

`GeschaeftPreisUebersichtView` (eigener View, aufrufbar über einen Eintrag in
`GeschaeftDetailView`, GitHub #20) zeigt statt einer flachen Liste aller
`Preispunkt`e eine nach Artikel gruppierte **Preisübersicht**:

```swift
struct ArtikelPreisSpanne: Identifiable {
    let artikel: Artikel
    let eintraege: [Preispunkt]
    var minimum: Decimal? { eintraege.map(\.preis).min() }
    var maximum: Decimal? { eintraege.map(\.preis).max() }
}
```

`ArtikelPreisSpanne.gruppieren(_:)` gruppiert alle `Preispunkt`e eines Geschäfts nach
ihrem verknüpften `artikel` (Einträge ohne Verknüpfung werden ausgelassen) und liefert
pro Artikel eine Preisspanne, alphabetisch sortiert. Jede Zeile
(`ArtikelPreisSpanneZeile`) zeigt Artikel-Symbol, -Name und die Preisspanne
(„1,99 € – 2,49 €“, oder ein einzelner Preis, falls minimum == maximum). Ein
Antippen (Info-/Drill-down-Funktion über `NavigationLink`) öffnet
`ArtikelPreisVerlaufView`: eine eigene, live per `@Query` gefilterte Liste aller
`Preispunkt`e dieses Artikels **in diesem Geschäft**, sortiert nach Datum absteigend
— die historische Preisliste. Gibt es mindestens einen Punkt, zeigt ein
`Charts`-Liniendiagramm zusätzlich den Preisverlauf chronologisch aufsteigend
(GitHub #21). Jede Position lässt sich per Wischgeste (Standard-Löschen, `.onDelete`)
dauerhaft entfernen — z.B. bei einer offensichtlich falsch erfassten Position, die die
Preisspanne verzerrt.

**Ohne Artikel-Zuordnung (entfallen):** früher erschienen `Preispunkt`e ohne
`artikel` (z.B. weil beim Scan kein Namensabgleich griff) in einem eigenen
Abschnitt darunter. Seit der Produkt-Pflicht entsteht ein solcher Preispunkt gar
nicht mehr — findet Beleg- oder Preisschildscan keine Artikel-Zuordnung, wird die
betroffene Position übersprungen statt als freitextiger Preispunkt gespeichert.
`PreispunktZuordnenSheet`/die Wisch-Aktion „Zuordnen“ dienen seither nur noch der
nachträglichen Korrektur einer bereits bestehenden Zuordnung.

## Mitlernen zwischen Belegscans

**Seit GitHub #128** übernimmt `Produktname` (geschäftsspezifisch oder bei
`geschaeft == nil` geschäftsunabhängig) diese Rolle — vormals ein eigenes,
dediziertes `ArtikelAlias`-Modell (GitHub #76, siehe `docs/ARTIKEL_PRODUKT_MODELL.md`
für die Herleitung des Umbaus). `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`
ist die zentrale, reine (UI-unabhängige) Lookup-Funktion:

```swift
static func passend(
    fuerErkannterName erkannterName: String,
    bevorzugtesGeschaeft: Geschaeft?,
    in alle: [Produktname]
) -> Produktname?
```

Sucht zuerst einen exakten (case-insensitiven) Treffer mit `geschaeft == bevorzugtesGeschaeft`,
dann mit `geschaeft == nil` (die frühere `ArtikelAlias`-Rolle) — jeweils vor einem
beidseitigen `localizedCaseInsensitiveContains`-Abgleich. Das eigentliche Lernen
läuft nicht mehr über einen expliziten `lernen(...)`-Aufruf, sondern automatisch
über `Produkt.aufgeloestesOderNeuesProdukt(klarname:erkannterName:artikel:geschaeft:context:)`
(`Models/Produkt.swift`, siehe `docs/ARTIKEL_PRODUKT_MODELL.md` → „Automatische
Neuanlage beim Belegscan“) — aufgerufen sowohl aus
`BelegScanView.uebernehmen()`/`PreisschildScanView.uebernehmen()` (automatisches
Lernen aus einer geänderten Namenszuordnung) als auch aus
`PreispunktZuordnenSheet.speichern()` (manuelle Korrektur).

`BelegScanView.verarbeite(bild:)`/`PreisschildScanView.verarbeite(bild:)` rufen
`Produktname.passend(...)` (bzw. `ArtikelZuordnungsService.textBasierteZuordnung(...)`,
das dieselbe Funktion intern nutzt) für jede frisch erkannte Position auf und
übernehmen den gefundenen Produktnamen (als Vorbelegung des Namensfelds) und
`Artikel` (als `gelernterArtikel`) in die jeweilige `Bearbeitbare...Position`.
Damit schließt sich der Kreis: Eine einmal gesetzte Namens-/Artikel-Kombination
wird beim nächsten Scan desselben Produkts automatisch vorgeschlagen und
verknüpft, ohne dass der Nutzer erneut zuordnen muss.

Für generische, produktunabhängige Synonyme (z.B. „Zahncreme“ für „Zahnpasta“,
ohne Bezug zu einer bestimmten Marke) gibt es zusätzlich `Artikel.alternativeNamen`
— frei gepflegt über `ArtikelEditView`, fließt in die Artikel-Substring-Matchstufe
von `ArtikelZuordnungsService` ein (siehe „Automatische Artikel-Zuordnung“ oben).

## Bewusst nicht umgesetzt

- **Kein Fuzzy-Vorschlag für die Artikel-Auswahl** in `PreispunktZuordnenSheet` über
  den bereits erkannten Namen hinaus — die Suche ist bewusst eine einfache
  Teilstring-Suche wie in `ArtikelHinzufuegenView`, kein KI-Vorschlag.
- **Ablösen von `ReceiptScanService`/`VisionFoundationModelsReceiptScanner`** durch
  eine spätere, spezifischere On-Device-Scan-API ist als offene Idee in
  `docs/ROADMAP.md` vermerkt, noch nicht umgesetzt.
- **Kein automatisches Heran-Zoomen** zur Positions-Markierung im Originalbeleg —
  bewusst einfacher gehalten, der Anwender zoomt selbst per Pinch-Geste (siehe
  „Originalbeleg anzeigen“ oben).
- **Keine Übertragung auf `PreisschildScanView`** — die Originalfoto-Anzeige ist
  bislang nur für den Belegscan umgesetzt (GitHub #2 nannte nur diesen Fall).

## Test-Infrastruktur

**Status: Umgesetzt (2026-08-14).** Echte Kassenbons als Testfälle statt Mock-Objekte.

### Aufbau

`ShopWithMeTests/Belege/` (Ordner-Referenz im Test-Bundle) enthält pro Testfall:

- `<name>.jpg` (oder `.jpeg`/`.png`) — Foto eines echten Kassenbons
- `<name>.json` — Soll-Zustand (`BelegFixture`)

`BelegTestfall.ladeAlle()` findet alle gültigen Bild+JSON-Paare automatisch —
neue Testfälle einfach in den Ordner legen, kein Code ändern. Fehlt der Ordner
oder sind keine Paare vorhanden, laufen die Tests 0-mal ohne Fehler.

### Zwei Teststufen

**1. OCR-Test** (`ocrErkenntPositionen`) — deterministisch, läuft auf Simulator + Gerät:

Prüft pro Soll-Position, ob ihr Artikelname **oder** ihr Preis irgendwo in den
Vision-OCR-Zeilen auftaucht (Teilstring-Abgleich, `de-DE`/`en-US`). Sichert,
dass der Bon grundsätzlich lesbar ist, bevor die KI-Extraktion greift.
`VisionFoundationModelsReceiptScanner.erkenneText(in:)` ist dafür `internal`
statt `private` (testbar via `@testable import`).

**2. Vollständiger Scan** (`vollstaendigerScanErreichtMindestTrefferquote`) — Apple Intelligence erforderlich:

Läuft die komplette Pipeline (`auswerten(bild:)`) und vergleicht:
- **Datum**: exakter String-Abgleich (falls im Soll angegeben)
- **Geschäftsname**: Teilstring-Abgleich in beide Richtungen (falls angegeben)
- **Positionen**: Preis-exakt (Cent) **oder** Namens-Teilstring;
  erkannte Positionen ÷ Soll-Positionen ≥ `mindestPositionenTrefferQuote`

Ohne Apple Intelligence (`AISuggestionService.istVerfuegbar == false`) wird
der Test still übersprungen — nicht als Fehler gewertet.

### JSON-Format

```json
{
  "beschreibung": "REWE Markt, 2026-03-24 — 12 Positionen",
  "sollErgebnis": {
    "geschaeftName": "REWE",
    "geschaeftAdresse": "Marktstrasse 1, Musterstadt",
    "datum": "2026-03-24",
    "positionen": [
      { "artikelName": "Vollmilch 3,5%", "einzelpreis": "1.29" },
      { "artikelName": "Butter mild", "einzelpreis": "1.99" },
      { "artikelName": "Milch", "einzelpreis": "1.50", "menge": 3 }
    ]
  },
  "mindestPositionenTrefferQuote": 0.75
}
```

Alle Felder: `geschaeftName`, `geschaeftAdresse`, `datum` können leer bleiben (`""`)
— sie werden dann nicht geprüft. `menge` kann weggelassen oder `null` sein — ebenfalls
nicht geprüft. `menge` ist besonders relevant bei Gesamtpreiszeilen auf dem Bon
(z.B. „3 x Milch 4.50"), wo die KI die Menge für die Einzelpreisberechnung benötigt:
ein Fehler dort führt zu einem falschen `einzelpreis`, der den Preis-Test dann
indirekt aufdeckt — `menge` macht den Fehler explizit sichtbar. `einzelpreis`
verwendet `.` als Dezimaltrennzeichen (POSIX-Format). Ausführliche Hinweise zum
Datenschutz: `ShopWithMeTests/Belege/README.md`.
