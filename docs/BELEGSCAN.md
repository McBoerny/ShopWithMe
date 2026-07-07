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
- `ShopWithMe/Views/Geschaefte/GeschaeftDetailView.swift` — Preisübersicht-Sektion +
  `ArtikelPreisSpanneZeile`/`ArtikelPreisVerlaufView` (Drill-down).
- `ShopWithMe/Views/Geschaefte/GeschaeftListView.swift` — geschäftsloser
  Scan-Einstieg (Toolbar-Menü „Scannen“).
- `ShopWithMeTests/ReceiptScanServiceTests.swift`, `ShopWithMeTests/ModelTests.swift`.

## Ablauf

1. **Aufnahme** (`AufnahmeAnsicht` in `BelegScanView.swift`): Foto per Kamera oder aus
   der Mediathek (`PhotosPicker`).
2. **OCR** (`VisionFoundationModelsReceiptScanner.erkenneText`): `VNRecognizeTextRequest`
   (Vision, `.accurate`, Sprachen `de-DE`/`en-US`) liefert den rohen Zeilentext des Bons.
3. **Strukturextraktion** (`VisionFoundationModelsReceiptScanner.extrahiere`): Eine
   `LanguageModelSession` (FoundationModels, on-device) wandelt den OCR-Text in ein
   `@Generable`-Ergebnis um:
   - `BelegPosition`: `artikelName: String`, `menge: Double`, `einzelpreis: Decimal`.
     Bei Mehrfachpositionen mit nur einem Gesamtpreis auf dem Bon (z.B. „3 x 1.50 =
     4.50“) berechnet die KI den Einzelpreis (Gesamtpreis ÷ Menge) — übernommen wird
     später ausschließlich der Einzelpreis, nie die Menge.
   - `BelegErgebnis`: `geschaeftName`, `datum` (Format `JJJJ-MM-TT`, geparst über
     `erkanntesDatum: Date?`), `positionen: [BelegPosition]`.
   - Beide Typen sind reine, flüchtige KI-Transfertypen — **kein** eigenes
     SwiftData-Model für Belegpositionen.
4. **Mitlern-Vorbelegung** (`BelegScanView.verarbeite(bild:)`): für jede erkannte
   Position sucht `KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)` unter allen
   vorhandenen `KaufEintrag`en nach dem jüngsten, dessen erkannter Name
   (`produktName`/`artikelNameSnapshot`) zum aktuell erkannten Text passt und der
   bereits einen `alternativerName` (Alias) trägt. Treffer liefert Alias + den ggf.
   verknüpften `Artikel` — siehe „Mitlernen“ unten.
5. **Prüfen/Korrigieren** (`ErgebnisListe` in `BelegScanView.swift`): editierbare Kopie
   jeder Position (`BearbeitbarePosition`: `erkannterName` unveränderlich,
   `artikelName`/`preisText` editierbar, `gelernterArtikel` aus Schritt 4) plus
   editierbares `belegDatum` (vorbelegt aus `erkanntesDatum`, sonst Startzeit des
   Einkaufsvorgangs bzw. heute). War eine Position bereits bekannt, zeigt das
   Namensfeld direkt den Alias (statt „COL-ZAH“ z.B. „Colgate“) und ein Hinweis
   „Wird verknüpft mit „Zahnpasta““ erscheint darunter. Der Nutzer kann den Namen
   weiterhin frei korrigieren (z.B. OCR-Tippfehler).
6. **Übernahme** (`BelegScanView.uebernehmen()`): abhängig vom `BelegScanKontext`:
   - `.einkaufsvorgang(Einkaufsvorgang)`: Preise werden nach Namensabgleich
     (`passtZu`) bereits abgehakten `KaufEintrag`en dieses Einkaufsvorgangs
     zugeordnet (dort bleibt eine bestehende `Artikel`-Verknüpfung unverändert,
     nur Preis/Datum/Alias werden aktualisiert). Ohne Treffer entsteht ein neuer,
     eigenständiger `KaufEintrag`, direkt verknüpft mit `position.gelernterArtikel`
     (aus Schritt 4), falls vorhanden.
   - `.geschaeft(Geschaeft)`: unabhängig von einem laufenden Einkauf, direkt aus der
     Geschäfts-Detailansicht. Jede Position wird als neuer `KaufEintrag` angelegt,
     verknüpft mit `position.gelernterArtikel` — ansonsten sucht `passendesArtikel(fuer:)`
     per Namensabgleich unter allen `Artikel`n einen Treffer als Fallback.
   - `.unbekannt`: geschäftsloser Scan (siehe „Automatischer Geschäfts-Abgleich“
     unten) — verhält sich sonst wie `.geschaeft`, nur dass das Geschäft erst nach
     dem Scan feststeht (`erkanntesGeschaeft` statt eines fest übergebenen Werts).
   - In allen Fällen: weicht der (ggf. korrigierte) Anzeigetext vom rohen erkannten
     Namen ab, wird er als `alternativerName` übernommen (`leiteAlternativenNamenAb`)
     — das ist zugleich die Quelle für das Mitlernen beim nächsten Scan.

## Automatischer Geschäfts-Abgleich

Nur beim Belegscan relevant (siehe `docs/PREISSCHILD_SCAN.md` → „Kein
geschäftsloser Einstieg“ für die bewusste Abgrenzung zum Preisschild-Scan). Wird ein
Beleg nachträglich gescannt — z.B. zuhause, ohne vorher ein Geschäft auszuwählen —,
steht zum Scan-Zeitpunkt noch kein `Geschaeft` fest. `BelegScanKontext.unbekannt`
sowie ein `.einkaufsvorgang` ohne gewähltes Geschäft (Picker-Option „Kein Geschäft“
in `EinkaufenView`) decken diesen Fall ab:

1. **Erkennung**: `ReceiptScanService` liefert zusätzlich zu den Positionen einen
   rohen `geschaeftName: String` (auf einem Kassenbon meist in der Kopfzeile
   vorhanden).
2. **Abgleich** (`BelegScanView.geschaeftAbgleichen(erkannterName:)`): sucht per
   `Geschaeft.passendes(fuerErkannterName:unter:)` unter allen vorhandenen
   Geschäften nach einem Treffer — sowohl gegen `Geschaeft.name` als auch gegen
   dessen gelernte `alternativeNamen` (beidseitiger
   `localizedCaseInsensitiveContains`-Abgleich, analog
   `KaufEintrag.gelernteZuordnung`).
3. **Kein Treffer → Anwenderauswahl** (`GeschaeftWahlSheet`): öffnet sich
   automatisch, sobald kein Treffer gefunden wurde. Bietet Suche unter
   bestehenden Geschäften, „Kein Geschäft“ (bewusstes Überspringen — die
   entstehenden `KaufEintrag`e bleiben dann ohne `geschaeft`, wie bisher) sowie
   „„<Suchtext>“ neu anlegen“ (öffnet `GeschaeftStammdatenEditView`, vorausgefüllt
   mit dem erkannten Namen). Der Anwender kann das erkannte/gewählte Geschäft in
   der Ergebnisansicht jederzeit über die „Geschäft“-Zeile ändern.
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

- `GeschaeftDetailView` — sowohl in der „Preisübersicht“ (aggregiert pro Artikel, siehe
  unten) als auch im Drill-down `ArtikelPreisVerlaufView` und im Abschnitt
  „Ohne Artikel-Zuordnung“ (`zeigeArtikel: true`)
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

`GeschaeftDetailView` zeigt statt einer flachen Liste aller `KaufEintrag`e eine nach
Artikel gruppierte **Preisübersicht**:

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
— die historische Kaufliste mit Einzelpreisen.

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
