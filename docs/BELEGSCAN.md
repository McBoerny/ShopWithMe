# Belegscan

Der Belegscan fotografiert/lädt einen Kassenbon, erkennt Positionen (Name, Menge,
Einzelpreis) per On-Device-KI und trägt daraus Preise in die Preishistorie ein. Dieses
Dokument beschreibt den gesamten Ablauf inkl. Datenmodell, die Alias-/Artikel-Zuordnung
pro Position, die Preisübersicht eines Geschäfts sowie das Mitlernen über mehrere
Belegscans hinweg.

## Beteiligte Dateien

- `ShopWithMe/Services/ReceiptScanService.swift` — OCR + KI-Extraktion.
- `ShopWithMe/Views/Einkaufen/BelegScanView.swift` — Aufnahme, Prüf-/Korrektur-UI,
  Übernahme in `KaufEintrag`e, Mitlern-Vorbelegung, automatischer
  Geschäfts-Abgleich (siehe unten).
- `ShopWithMe/Views/Einkaufen/PreisschildScanView.swift` — analoger, einzelner
  Preisschild-Scan (`docs/PREISSCHILD_SCAN.md`); funktioniert immer direkt für ein
  feststehendes Geschäft, **ohne** den automatischen Geschäfts-Abgleich unten.
- `ShopWithMe/Models/KaufEintrag.swift` — persistentes Ziel-Model, `anzeigeName`,
  `gelernteZuordnung(fuerErkannterName:in:)`.
- `ShopWithMe/Models/Geschaeft.swift` — `alternativeNamen`,
  `alternativenNamenLernen(_:)`, `passendes(fuerErkannterName:unter:)`.
- `ShopWithMe/Views/Geschaefte/GeschaeftWahlSheet.swift` — Geschäftsauswahl, falls
  der automatische Abgleich keinen Treffer findet.
- `ShopWithMe/Models/ArtikelPreisSpanne.swift` — Gruppierung nach Artikel + Preisspanne.
- `ShopWithMe/Views/Historie/PreisHistorieZeile.swift` — einzelne Zeile, öffnet die
  Zuordnen-Sheet.
- `ShopWithMe/Views/Historie/KaufEintragZuordnenSheet.swift` — Alias vergeben +
  Artikel zuordnen/neu anlegen.
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
- `ShopWithMeTests/ReceiptScanServiceTests.swift`, `ShopWithMeTests/ModelTests.swift`.

## Ablauf

1. **Aufnahme** (`AufnahmeAnsicht` in `BelegScanView.swift`): Foto per Kamera oder aus
   der Mediathek (`PhotosPicker`).
2. **OCR** (`VisionFoundationModelsReceiptScanner.erkenneText`): `VNRecognizeTextRequest`
   (Vision, `.accurate`, Sprachen `de-DE`/`en-US`) liefert pro Zeile Text **und**
   Position im Bild als `ErkannteZeile` (`text`, `boundingBox` — Visions
   normalisiertes Koordinatensystem, Ursprung unten links, 0–1). Grundlage für die
   Positions-Markierung im Original-Beleg (siehe „Originalbeleg anzeigen“ unten).
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
   verschwindet komplett, siehe „Dauerhaft ignorierte Artikel pro Geschäft“ unten),
   sonst `ArtikelZuordnungsService.zuordnen(...)` (siehe „Automatische
   Artikel-Zuordnung“ unten). Zusätzlich ermittelt
   `[ErkannteZeile].boundingBox(fuerArtikelName:)` per beidseitigem
   Teilstring-Abgleich die zur Position passende OCR-Zeile (`nil` ohne eindeutigen
   Treffer).
5. **Prüfen/Korrigieren** (`ErgebnisListe`/`PositionsZeile` in `BelegScanView.swift`):
   editierbare Kopie jeder Position (`BearbeitbarePosition`: `erkannterName`
   unveränderlich, `artikelName`/`preisText` editierbar, `zugeordneterArtikel` aus
   Schritt 4, `boundingBox` aus Schritt 4) plus editierbares `belegDatum` (vorbelegt
   aus `erkanntesDatum`, sonst Startzeit des Einkaufsvorgangs bzw. heute). Details
   zur Anzeige/Korrektur der Zuordnung siehe „Automatische Artikel-Zuordnung“ unten.
6. **Übernahme** (`BelegScanView.uebernehmen()`): abhängig vom `BelegScanKontext`,
   in allen drei Fällen mit `position.effektivZugeordneterArtikel` verknüpft (siehe
   „Automatische Artikel-Zuordnung“ unten):
   - `.einkaufsvorgang(Einkaufsvorgang)`: Preise werden nach Namensabgleich
     (`passtZu`) bereits abgehakten `KaufEintrag`en dieses Einkaufsvorgangs
     zugeordnet (dort bleibt eine bestehende `Artikel`-Verknüpfung unverändert,
     nur Preis/Datum/Alias werden aktualisiert). Ohne Treffer entsteht ein neuer,
     eigenständiger `KaufEintrag`.
   - `.geschaeft(Geschaeft)`: unabhängig von einem laufenden Einkauf, direkt aus der
     Geschäfts-Detailansicht. Jede Position wird als neuer `KaufEintrag` angelegt.
   - `.unbekannt`: geschäftsloser Scan (siehe „Automatischer Geschäfts-Abgleich“
     unten) — verhält sich sonst wie `.geschaeft`, nur dass das Geschäft erst nach
     dem Scan feststeht (`erkanntesGeschaeft` statt eines fest übergebenen Werts).
   - In allen Fällen: weicht der (ggf. korrigierte) Anzeigetext vom rohen erkannten
     Namen ab, wird er als `alternativerName` übernommen (`leiteAlternativenNamenAb`)
     — das ist zugleich die Quelle für das Mitlernen beim nächsten Scan.

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
sowie ein `.einkaufsvorgang` ohne gewähltes Geschäft (Picker-Option „Kein Geschäft“
in `EinkaufenView`) decken diesen Fall ab:

1. **Erkennung**: `ReceiptScanService` liefert zusätzlich zu den Positionen einen
   rohen `geschaeftName: String` sowie eine rohe `geschaeftAdresse: String` (beide
   auf einem Kassenbon meist in der Kopf-/Fußzeile vorhanden, sonst leerer String).
2. **Abgleich** (`BelegScanView.geschaeftAbgleichen(erkannterName:erkannteAdresse:)`):
   sucht per `Geschaeft.passendes(fuerErkannterName:erkannteAdresse:unter:)` unter
   allen vorhandenen Geschäften nach einem Treffer — sowohl gegen `Geschaeft.name`
   als auch gegen dessen gelernte `alternativeNamen` (beidseitiger
   `localizedCaseInsensitiveContains`-Abgleich, analog
   `KaufEintrag.gelernteZuordnung`). **Mehrere namensgleiche Geschäfte** (z.B. zwei
   „Rewe“-Filialen): die erkannte Adresse dient als automatischer Tie-Breaker
   (gleicher Abgleich gegen `Geschaeft.adresse`) — **ohne Rückfrage**. Bleibt danach
   mehr als ein Kandidat übrig oder wurde keine/keine passende Adresse erkannt,
   fällt die Funktion auf den ersten Namens-Kandidaten zurück (wie vor dieser
   Erweiterung), statt den Anwender zu unterbrechen.
3. **Kein Treffer → Anwenderauswahl** (`GeschaeftWahlSheet`): öffnet sich
   automatisch, sobald kein Treffer gefunden wurde. Bietet Suche unter
   bestehenden Geschäften, „Kein Geschäft“ (bewusstes Überspringen — die
   entstehenden `KaufEintrag`e bleiben dann ohne `geschaeft`, wie bisher) sowie
   „„<Suchtext>“ neu anlegen“ (öffnet `GeschaeftStammdatenEditView`, vorausgefüllt
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
   (relevant für `ShelfOrderLearningService`/`ArtikelVerfuegbarkeitService`).

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

1. **Gelernter Alias**: `KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)`
   (unverändert, siehe „Mitlernen zwischen Belegscans“ unten).
2. **Teilstring-Abgleich**: einfacher, beidseitiger
   `localizedCaseInsensitiveContains`-Vergleich gegen alle vorhandenen `Artikel`.
3. **KI-Best-Match** — nur falls Stufe 1+2 erfolglos **und** lokale KI verfügbar
   (`AISuggestionService.istVerfuegbar`): `AISuggestionService.artikelMatch(fuerName:bekannteArtikel:)`
   (`@Generable ArtikelMatchVorschlag`, exaktes Vorbild
   `AISuggestionService.kategorieMatch(fuerName:bekannteKategorien:)`, bereits
   identisch genutzt in `MilkForUsImportService`). Antwortet die KI mit einem
   leeren String oder einem Namen, der zu keinem `Artikel` exakt passt, gilt die
   Stufe als erfolglos.

Bleiben alle drei Stufen erfolglos, gilt die Position als **neu erkannt**.
`ArtikelZuordnungsService.textBasierteZuordnung(...)` bündelt Stufe 1+2 als
eigene, ohne KI direkt testbare Funktion (analog
`GeschaeftErkennungService.passendenVorschlag(...)`); `zuordnen(...)` ergänzt
Stufe 3 und ist die volle, von `BelegScanView.verarbeite(bild:)` genutzte
Pipeline. Ersetzt die frühere, nur für `.geschaeft`/`.unbekannt` beim **Speichern**
(nicht in der Prüf-Ansicht sichtbare) `passendesArtikel(fuer:)`-Methode — `.einkaufsvorgang`
bekam bislang gar keine Katalog-Zuordnung.

**Anzeige/Korrektur (`PositionsZeile`):**
- Das Artikel-Textfeld zeigt den gefundenen generischen Namen (`alias` bzw.
  `artikel.name`). Weicht das vom rohen Beleg-Text (`erkannterName`) ab, erscheint
  dieser zusätzlich klein darunter als „Original: „<Text>““ — beide Namen sind
  damit gleichzeitig sichtbar.
- Ein Status-Label darunter zeigt „Wird verknüpft mit „<Artikel>““ (Treffer) oder
  „Neu erkannt“ (keine Stufe erfolgreich).
- **`BearbeitbarePosition.effektivZugeordneterArtikel`**: liefert die automatische
  Zuordnung nur, solange der Text im Feld noch exakt zum zugeordneten Artikelnamen
  passt — bearbeitet der Nutzer das Feld frei weiter, ohne neu auszuwählen, gilt
  die Position wieder als „neu erkannt“, rein reaktiv ohne `onChange`-Seiteneffekt.
  Sowohl Anzeige als auch `BelegScanView.uebernehmen()` nutzen ausschließlich diese
  Property.
- **Inline-Autocomplete**: solange das Textfeld fokussiert ist, erscheinen bis zu 5
  nach Teilstring gefilterte Vorschläge aus allen vorhandenen `Artikel`n direkt
  darunter; Antippen übernimmt Name + Zuordnung. Passt der eingegebene Text zu
  keinem bestehenden Artikel, erscheint zusätzlich „„<Text>“ neu anlegen“ — öffnet
  `ArtikelEditView(artikel: entwurf, istNeu: true)` als Sheet (identisches Muster
  wie `KaufEintragZuordnenSheet.neuenArtikelAnlegen()`), übernimmt den neu
  gesicherten Artikel danach automatisch als Zuordnung.

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

## Datenmodell: `KaufEintrag`

Es gibt kein eigenes „Belegposition“-Model — erkannte Positionen landen direkt in
`KaufEintrag` (auch das Ziel für normale Einkaufslisten-Abhak-Käufe ohne Beleg):

| Feld | Bedeutung |
| --- | --- |
| `artikel: Artikel?` | Verknüpfter, übergreifender Artikel — gesetzt aus einer gelernten Zuordnung, per Namensabgleich, oder manuell über `KaufEintragZuordnenSheet`. `nil`, solange keine Zuordnung existiert oder der Artikel später gelöscht wurde. |
| `artikelNameSnapshot: String` | Name zum Kaufzeitpunkt, dauerhaft — Fallback, falls `artikel` fehlt/gelöscht ist. |
| `produktName: String?` | Genauer, vom Kassenbon erkannter Marken-/Produktname, falls er vom (ggf. generischen) `artikel` abweicht (z.B. „COL-ZAH“ bei `artikel.name == "Zahnpasta"`). Bleibt beim Umbenennen zwecks Zuordnung erhalten, damit unterschiedliche Marken desselben generischen Artikels in der Preishistorie unterscheidbar bleiben. `nil` bei normalen Einkaufslisten-Käufen ohne Belegscan. |
| `alternativerName: String?` | Alias für **genau diese eine Position** (z.B. „Colgate“) — vom Nutzer vergeben (`KaufEintragZuordnenSheet`) oder beim Belegscan aus einem korrigierten Namensfeld übernommen. Verändert `artikelNameSnapshot`/`produktName` nicht. Zentrale Grundlage für das Mitlernen (siehe unten). |
| `preis: Decimal?` | Bezahlter Einzelpreis; `nil`, solange noch kein Beleg dazu erfasst wurde. |
| `menge: Double` | Gekaufte Menge (Standard 1) — vom Belegscan nicht verändert. |
| `datum: Date` | Kaufdatum, aus dem Beleg erkannt oder manuell gesetzt. |
| `kategorie: ArtikelKategorie?` | Snapshot der Artikel-Kategorie zum Kaufzeitpunkt — wird bei Artikel-Zuordnung (Scan oder `KaufEintragZuordnenSheet`) auf `artikel?.kategorie` gesetzt. |

Alle Felder außer `id`, `artikelNameSnapshot`, `datum`, `preis`, `menge` sind optional;
`alternativerName` und `produktName` wurden beide additiv zu einem bereits
ausgelieferten Model ergänzt (rein optional → keine neue `SchemaVN`/`MigrationStage`
nötig, siehe `docs/DECISIONS.md`, „Duplicate version checksums“-Vorfall).

## Anzeige: `KaufEintrag.anzeigeName`

Zentrale Computed-Property, die alle Anzeigestellen statt eigener Priorisierungslogik
verwenden:

```swift
var anzeigeName: String {
    if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return alternativerName
    }
    let name = produktName ?? artikel?.name ?? artikelNameSnapshot
    return name.isEmpty ? "Unbekannter Artikel" : name
}
```

Priorität: **`alternativerName`** (Alias, falls gesetzt) → `produktName` (Original vom
Kassenbon) → `artikel?.name` → `artikelNameSnapshot`.

Verwendet in `PreisHistorieZeile`, angezeigt in:

- `GeschaeftPreisUebersichtView` — sowohl in der „Preisübersicht“ (aggregiert pro
  Artikel, siehe unten) als auch im Drill-down `ArtikelPreisVerlaufView` und im
  Abschnitt „Ohne Artikel-Zuordnung“ (`zeigeArtikel: true`)
- `ArtikelEditView` (Preishistorie-Sektion eines Artikels, `zeigeArtikel: false` — zeigt
  dort den Geschäftsnamen statt des Artikelnamens; `alternativerName` bleibt trotzdem
  am `KaufEintrag` gesetzt, ist dort nur nicht die sichtbare Spalte)

## Alias vergeben + Artikel zuordnen (UI): `KaufEintragZuordnenSheet`

`PreisHistorieZeile` bietet überall eine Wisch-Aktion „Zuordnen“ (führende Kante,
Tag-Symbol), die `KaufEintragZuordnenSheet` öffnet:

- **Alias-Textfeld**, vorbelegt mit `eintrag.alternativerName`. Leeres Feld beim
  Speichern → `alternativerName = nil` (fällt auf `produktName`/`artikel?.name`/
  `artikelNameSnapshot` zurück).
- **Artikel-Auswahl**: „Keine Zuordnung“, durchsuchbare Liste aller `Artikel` (analog
  `ArtikelHinzufuegenView`), oder „„<Suchtext>“ neu anlegen“, falls kein exakter Treffer
  existiert — öffnet `ArtikelEditView(artikel:istNeu:true)` und übernimmt den neu
  gesicherten Artikel automatisch als Auswahl (gleiches Muster wie
  `ArtikelHinzufuegenView.nachNeuanlageAufraeumen`).
- **Speichern** setzt `alternativerName`, `artikel` sowie — falls ein Artikel gewählt
  wurde — `kategorie = artikel.kategorie`, geschützt durch
  `DatabaseLeaseService.performMicroLease` (explizite Speicherung, da
  `ModelContext.autosaveEnabled == false`, siehe `docs/DATABASE_CONCURRENCY.md`).

Jede so gesetzte Alias-/Artikel-Kombination ist die Lerngrundlage für künftige
Belegscans desselben Produkts (Schritt 4 oben).

## Preisübersicht eines Geschäfts: `ArtikelPreisSpanne`

`GeschaeftPreisUebersichtView` (eigener View, aufrufbar über einen Eintrag in
`GeschaeftDetailView`, GitHub #20) zeigt statt einer flachen Liste aller
`KaufEintrag`e eine nach Artikel gruppierte **Preisübersicht**:

```swift
struct ArtikelPreisSpanne: Identifiable {
    let artikel: Artikel
    let eintraege: [KaufEintrag]
    var minimum: Decimal? { eintraege.compactMap(\.preis).min() }
    var maximum: Decimal? { eintraege.compactMap(\.preis).max() }
}
```

`ArtikelPreisSpanne.gruppieren(_:)` gruppiert alle `KaufEintrag`e eines Geschäfts nach
ihrem verknüpften `artikel` (Einträge ohne Verknüpfung werden ausgelassen) und liefert
pro Artikel eine Preisspanne, alphabetisch sortiert. Jede Zeile
(`ArtikelPreisSpanneZeile`) zeigt Artikel-Symbol, -Name und die Preisspanne
(„1,99 € – 2,49 €“, oder ein einzelner Preis, falls minimum == maximum). Ein
Antippen (Info-/Drill-down-Funktion über `NavigationLink`) öffnet
`ArtikelPreisVerlaufView`: eine eigene, live per `@Query` gefilterte Liste aller
`KaufEintrag`e dieses Artikels **in diesem Geschäft**, sortiert nach Datum absteigend
— die historische Kaufliste mit Einzelpreisen. Gibt es mindestens einen erfassten
Preis, zeigt ein `Charts`-Liniendiagramm zusätzlich den Preisverlauf chronologisch
aufsteigend (GitHub #21). Jede Position lässt sich per Wischgeste (Standard-Löschen,
`.onDelete`) dauerhaft entfernen — z.B. bei einer offensichtlich falsch erfassten
Position, die die Preisspanne verzerrt.

**Ohne Artikel-Zuordnung**: `KaufEintrag`e ohne `artikel` (z.B. weil beim Scan kein
Namensabgleich griff und noch keine manuelle Zuordnung erfolgte) erscheinen weiterhin
sichtbar in einem eigenen Abschnitt darunter, mit der bestehenden Wisch-Aktion
„Zuordnen“ zum Nachholen der Verknüpfung.

## Mitlernen zwischen Belegscans

`KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)` ist die zentrale, reine
(UI-unabhängige) Funktion dafür:

```swift
static func gelernteZuordnung(
    fuerErkannterName erkannterName: String,
    in verlauf: [KaufEintrag]
) -> (alias: String, artikel: Artikel?)?
```

Durchsucht `verlauf` (i.d.R. alle vorhandenen `KaufEintrag`e, absteigend nach `datum`)
nach dem jüngsten Eintrag mit gesetztem `alternativerName`, dessen
`produktName`/`artikelNameSnapshot` zum übergebenen `erkannterName` passt
(beidseitiger `localizedCaseInsensitiveContains`-Abgleich, wie auch an anderen Stellen
in `BelegScanView` üblich). Der jüngste Treffer gewinnt, damit eine spätere Korrektur
eine ältere Fehlzuordnung ersetzt.

`BelegScanView.verarbeite(bild:)` ruft diese Funktion für jede frisch erkannte Position
auf und übernimmt Alias (als Vorbelegung des Namensfelds) und `Artikel` (als
`gelernterArtikel`) in `BearbeitbarePosition`. Damit schließt sich der Kreis: Eine
einmal über `KaufEintragZuordnenSheet` (oder eine frühere manuelle Korrektur im
Scan-Dialog) gesetzte Alias-/Artikel-Kombination wird beim nächsten Scan desselben
Produkts automatisch vorgeschlagen und verknüpft, ohne dass der Nutzer erneut
zuordnen muss.

## Bewusst nicht umgesetzt

- **Kein Alias auf `Artikel`-Ebene**: Alias und Artikel-Zuordnung hängen an der
  einzelnen `KaufEintrag`-Position, nicht am übergreifenden `Artikel` selbst. Das
  erlaubt weiterhin, dass verschiedene Marken/Varianten (verschiedene `produktName`/
  `alternativerName`) demselben generischen `Artikel` zugeordnet sind, ohne dass ein
  Alias für eine bestimmte Marke versehentlich alle anderen überschreibt.
- **Kein Fuzzy-Vorschlag für die Artikel-Auswahl** in `KaufEintragZuordnenSheet` über
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
