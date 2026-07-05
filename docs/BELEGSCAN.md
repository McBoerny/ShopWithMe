# Belegscan

Der Belegscan fotografiert/lädt einen Kassenbon, erkennt Positionen (Name, Menge,
Einzelpreis) per On-Device-KI und trägt daraus Preise in die Preishistorie ein. Dieses
Dokument beschreibt den gesamten Ablauf inkl. Datenmodell sowie den vom Nutzer
vergebbaren alternativen Anzeigenamen pro Position.

## Beteiligte Dateien

- `ShopWithMe/Services/ReceiptScanService.swift` — OCR + KI-Extraktion.
- `ShopWithMe/Views/Einkaufen/BelegScanView.swift` — Aufnahme, Prüf-/Korrektur-UI,
  Übernahme in `KaufEintrag`e.
- `ShopWithMe/Models/KaufEintrag.swift` — persistentes Ziel-Model.
- `ShopWithMe/Views/Historie/PreisHistorieZeile.swift` — Anzeige in der Preishistorie
  + Umbenennen-UI für den alternativen Namen.
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
4. **Prüfen/Korrigieren** (`ErgebnisListe` in `BelegScanView.swift`): editierbare Kopie
   jeder Position (`BearbeitbarePosition`: `erkannterName` unveränderlich,
   `artikelName`/`preisText` editierbar) plus editierbares `belegDatum`
   (vorbelegt aus `erkanntesDatum`, sonst Startzeit des Einkaufsvorgangs bzw. heute).
   Der Nutzer kann hier eine Position umbenennen, um sie einem bestehenden,
   ggf. generischeren `Artikel` zuzuordnen (z.B. „Colgate Total“ → „Zahnpasta“) — der
   ursprünglich erkannte Name geht dabei nicht verloren, siehe `produktName` unten.
5. **Übernahme** (`BelegScanView.uebernehmen()`): abhängig vom `BelegScanKontext`:
   - `.einkaufsvorgang(Einkaufsvorgang)`: Preise werden nach Namensabgleich
     (`passtZu`) bereits abgehakten `KaufEintrag`en dieses Einkaufsvorgangs
     zugeordnet; ohne Treffer entsteht ein neuer, eigenständiger `KaufEintrag`
     **ohne** `Artikel`-Verknüpfung.
   - `.geschaeft(Geschaeft)`: unabhängig von einem laufenden Einkauf, direkt aus der
     Geschäfts-Detailansicht. Jede Position wird als neuer `KaufEintrag` angelegt;
     `passendesArtikel(fuer:)` sucht per Namensabgleich unter allen `Artikel`n einen
     Treffer und verknüpft ihn, falls gefunden (inkl. dessen `kategorie`).

## Datenmodell: `KaufEintrag`

Es gibt kein eigenes „Belegposition“-Model — erkannte Positionen landen direkt in
`KaufEintrag` (auch das Ziel für normale Einkaufslisten-Abhak-Käufe ohne Beleg):

| Feld | Bedeutung |
| --- | --- |
| `artikel: Artikel?` | Verknüpfter, übergreifender Artikel — optional, heuristisch per Namensabgleich gesetzt, `nil` falls kein Treffer oder der Artikel später gelöscht wurde. |
| `artikelNameSnapshot: String` | Name zum Kaufzeitpunkt, dauerhaft — Fallback, falls `artikel` fehlt/gelöscht ist. |
| `produktName: String?` | Genauer, vom Kassenbon erkannter Marken-/Produktname, falls er vom (ggf. generischen) `artikel` abweicht (z.B. „Colgate Total“ bei `artikel.name == "Zahnpasta"`). Bleibt beim Umbenennen zwecks Zuordnung erhalten, damit unterschiedliche Marken desselben generischen Artikels in der Preishistorie unterscheidbar bleiben. `nil` bei normalen Einkaufslisten-Käufen ohne Belegscan. |
| `alternativerName: String?` | Vom Nutzer frei vergebener, dauerhafter Anzeigename für **genau diese eine Position** — siehe unten. Verändert `artikelNameSnapshot`/`produktName` nicht. |
| `preis: Decimal?` | Bezahlter Einzelpreis; `nil`, solange noch kein Beleg dazu erfasst wurde. |
| `menge: Double` | Gekaufte Menge (Standard 1) — vom Belegscan nicht verändert, siehe Schritt 3. |
| `datum: Date` | Kaufdatum, aus dem Beleg erkannt oder manuell gesetzt. |
| `kategorie: ArtikelKategorie?` | Snapshot der Artikel-Kategorie zum Kaufzeitpunkt. |

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

Priorität: **`alternativerName`** (falls gesetzt, nicht nur Leerzeichen) → `produktName`
(Original vom Kassenbon) → `artikel?.name` → `artikelNameSnapshot`.

Verwendet in `PreisHistorieZeile`, angezeigt in:

- `GeschaeftDetailView` (Preishistorie-Sektion eines Geschäfts, `zeigeArtikel: true`)
- `ArtikelEditView` (Preishistorie-Sektion eines Artikels, `zeigeArtikel: false` — zeigt
  dort den Geschäftsnamen statt des Artikelnamens; `alternativerName` bleibt trotzdem
  am `KaufEintrag` gesetzt, ist dort nur nicht die sichtbare Spalte)

Der Matching-Abgleich beim Übernehmen neuer Belegpositionen
(`BelegScanView.passtZu`/`passendesArtikel`) bleibt bewusst auf
`artikel?.name`/`artikelNameSnapshot` bezogen — der alternative Anzeigename
beeinflusst nur die Darstellung, nicht die Zuordnungslogik beim Scannen.

## Alternativen Namen vergeben (UI)

`PreisHistorieZeile` bietet in der Artikel-Ansicht (`zeigeArtikel == true`) eine
Wisch-Aktion „Umbenennen“ (führende Kante, Stift-Symbol), die einen Alert mit
Texteingabe öffnet:

- **Speichern** setzt `eintrag.alternativerName` auf den (getrimmten) eingegebenen
  Text, oder `nil`, falls das Feld leer gelassen wurde.
- **Zurücksetzen** (nur sichtbar, wenn bereits ein alternativer Name gesetzt ist)
  löscht `alternativerName` wieder — die Anzeige fällt dann zurück auf
  `produktName`/`artikel?.name`/`artikelNameSnapshot`.
- **Abbrechen** verwirft die Eingabe.

Die Änderung wirkt sich sofort auf alle Anzeigen dieser Position aus (SwiftData
persistiert die Mutation über den üblichen Autosave-Mechanismus, kein expliziter
Save-Aufruf nötig — siehe bestehende Mutationsstellen wie
`Einkaufsvorgang.artikelAbhaken`).

## Bewusst nicht umgesetzt

- **Kein Alias auf `Artikel`-Ebene**: Der alternative Name hängt an der einzelnen
  `KaufEintrag`-Position, nicht am übergreifenden `Artikel`. Ein Alias auf
  `Artikel.name` selbst (der dann für *alle* zukünftigen Belege desselben Artikels
  gelten würde) ist eine andere, größere Änderung (u.a. Auswirkung auf
  `ArtikelListView`, `EinkaufenView`, KI-Vorschläge) und nicht Teil dieser Iteration.
- **Kein Rename-Einstieg direkt im Belegscan-Dialog** (`BelegScanView`/
  `ErgebnisListe`): Dort lässt sich der erkannte Name vor dem Übernehmen weiterhin nur
  zwecks Artikel-Zuordnung überschreiben (bestehendes Verhalten, wird als
  `produktName` archiviert). Der alternative Name wird bewusst erst *nach* dem
  Übernehmen, in der Preishistorie, vergeben — dort ist bereits klar, ob/welchem
  `Artikel` die Position zugeordnet wurde.
- **Ablösen von `ReceiptScanService`/`VisionFoundationModelsReceiptScanner`** durch
  eine spätere, spezifischere On-Device-Scan-API ist als offene Idee in
  `docs/ROADMAP.md` vermerkt, noch nicht umgesetzt.
