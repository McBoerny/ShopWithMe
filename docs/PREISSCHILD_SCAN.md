# Preisschild-Scan

Der Preisschild-Scan fotografiert/lädt das Foto eines **einzelnen** Regal-Preisschilds,
erkennt Artikelname und Verkaufspreis per On-Device-KI und legt dafür sofort einen
`KaufEintrag` mit heutigem Datum an — unabhängig davon, ob der Artikel tatsächlich
gekauft wird. Anwendungsfall: Preisvergleich vor der Kaufentscheidung, ohne auf einen
späteren Kassenbon warten zu müssen.

Dieselbe technische Basis (Vision-OCR + FoundationModels) wie beim Belegscan, siehe
`docs/BELEGSCAN.md` für das ausführlichere, analoge Muster. Dieses Dokument beschreibt
nur die Unterschiede sowie das noch nicht umgesetzte Konzept für einen Mehrfach-
Regal-Scan.

## Beteiligte Dateien

- `ShopWithMe/Services/PriceTagScanService.swift` — OCR + KI-Extraktion
  (`VisionFoundationModelsPriceTagScanner`, `PreisschildErgebnis`).
- `ShopWithMe/Views/Einkaufen/PreisschildScanView.swift` — Aufnahme, Prüf-/Korrektur-UI,
  Übernahme als `KaufEintrag`.
- `ShopWithMe/Views/Geschaefte/GeschaeftDetailView.swift` — Einstiegspunkt „Preisschild
  scannen“ neben „Kaufbeleg scannen“ (mit bereits feststehendem Geschäft).
- `ShopWithMe/Views/Geschaefte/GeschaeftListView.swift` — zusätzlicher, geschäftsloser
  Einstiegspunkt (Toolbar-Menü „Scannen“) für nachträgliche Scans ohne vorherige
  Geschäftswahl.

## Unterschiede zum Belegscan

| | Belegscan (`ReceiptScanService`) | Preisschild-Scan (`PriceTagScanService`) |
| --- | --- | --- |
| Eingabe | Foto eines ganzen Kassenbons | Foto eines einzelnen Preisschilds |
| KI-Ergebnis | `BelegErgebnis` mit `[BelegPosition]` (Liste) | `PreisschildErgebnis` mit genau einem `artikelName`/`preis` |
| Menge | `menge: Double` pro Position (vom Bon erkannt) | keine — ein Preisschild zeigt keine Stückzahl |
| Datum | von der KI aus dem Bon erkannt, editierbar | immer der Scan-Zeitpunkt (`.now`), nicht editierbar |
| Kontext | `BelegScanKontext` (`.einkaufsvorgang`/`.geschaeft`/`.unbekannt`) | `vorgegebenesGeschaeft: Geschaeft?` — `nil` beim geschäftslosen Einstieg, sonst identisches Verhalten |
| Grundpreis | kommt auf Kassenbons praktisch nicht vor | Preisschilder zeigen oft zusätzlich einen Grundpreis (z.B. „1,99 € / 100g“) — die KI-Instruktion weist explizit an, ausschließlich den Verkaufspreis zurückzugeben, nicht den Grundpreis |
| Geschäftsname im Foto | auf Kassenbons meist vorhanden (Kopfzeile) | auf Preisschildern selten (nur bei mitfotografierter Regal-/Gang-Beschilderung) |

Mitlern-Logik (`KaufEintrag.gelernteZuordnung`), Artikel-Namensabgleich
(`passendesArtikel`) und `alternativerName`-Ableitung sind identisch zum Belegscan
übernommen (siehe `docs/BELEGSCAN.md` → „Mitlernen“/„Übernahme“). Ebenso der
automatische Geschäfts-Abgleich (`Geschaeft.passendes(fuerErkannterName:unter:)`,
`GeschaeftWahlSheet`, `Geschaeft.alternativenNamenLernen(_:)`) — siehe
`docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“, dort auch für den
Preisschild-Scan gültig (`PreisschildErgebnis.geschaeftName`).

## Zukünftige Erweiterung: Regal-Scan (Konzept, nicht umgesetzt)

Ziel: aus **einem** Foto eines ganzen Regals mehrere Preisschilder gleichzeitig
erkennen, statt jedes einzeln fotografieren zu müssen.

**Warum das kein triviales Ausweiten von `PriceTagScanService` ist:**

- Das on-device FoundationModels-Model ist **text-only** — es bekommt nie das Bild
  selbst, nur von Vision erkannten Rohtext (siehe oben). Die eigentliche
  Bild-/Layout-Analyse muss deshalb vollständig in Vision passieren, bevor überhaupt
  etwas an die KI geht.
- `VNRecognizeTextRequest` liefert bei einem Regalfoto ohnehin bereits **alle**
  lesbaren Textblöcke auf einmal (jede `VNRecognizedTextObservation` mit eigener
  `boundingBox`) — das Erkennen mehrerer Schilder in einem Bild ist also kein
  Problem. Das eigentliche Problem ist die **Zuordnung**: welche Textzeile gehört zu
  welchem Schild? `PriceTagScanService.erkenneText` wirft aktuell (wie beim
  Belegscan, wo das wegen des linear fließenden Bon-Layouts unproblematisch ist) alle
  Zeilen einfach zu einem String zusammen — bei einem Regalfoto mit mehreren
  räumlich verteilten Schildern geht dabei die Information verloren, welche Zeile zu
  welchem Preis gehört.

**Möglicher Ansatz für eine spätere Umsetzung:**

1. `boundingBox` je `VNRecognizedTextObservation` mitführen statt sie zu verwerfen.
2. Räumliches Clustering benachbarter Bounding-Boxes zu Schild-Gruppen (z.B. Zeilen,
   deren Boxen sich horizontal/vertikal überlappen oder nah beieinanderliegen, gehören
   zum selben Schild).
3. Optional `VNDetectRectanglesRequest` vorschalten, um Schild-Ränder direkt zu finden
   und das Clustering robuster zu machen — gerade bei unterschiedlichen Schildformen
   und Kamera-Perspektive im Regal.
4. Pro erkannter Gruppe den zusammengehörigen Text (statt des gesamten Bild-Texts) an
   `FoundationModels` übergeben und ein `PreisschildErgebnis` je Gruppe erzeugen —
   Analog zu `BelegErgebnis.positionen: [BelegPosition]` beim Belegscan, hier dann
   z.B. `RegalErgebnis.positionen: [PreisschildErgebnis]` plus einem einzelnen,
   fürs ganze Regalfoto gemeinsamen `geschaeftName: String` (ein Regal gehört immer
   zu genau einem Geschäft, anders als die Positionen).
5. UI: analog `BelegScanView.ErgebnisListe` (Liste editierbarer Positionen) statt der
   aktuellen Einzelposition-Ansicht in `PreisschildScanView` — inklusive derselben
   „Geschäft“-Zeile/`GeschaeftWahlSheet`-Anbindung, damit der automatische
   Geschäfts-Abgleich (siehe oben) unverändert wiederverwendet werden kann.

Deutlich größerer Aufwand als der Einzelschild-Scan, da Perspektivverzerrung,
unterschiedliche Schilddesigns je Geschäft und teilweise Verdeckung im Regalfoto reale
Fehlerquellen beim Clustering sind — anders als beim linear fließenden Kassenbon-Text.
Bis dahin bleibt `PreisschildScanView` auf ein Schild pro Foto beschränkt.
