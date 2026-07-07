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
  scannen“ neben „Kaufbeleg scannen“.
- `ShopWithMe/Views/Einkaufen/EinkaufenView.swift` — weiterer Einstiegspunkt, sobald
  in der Einkaufen-Ansicht ein Geschäft gewählt ist.

Bewusst **kein** Einstiegspunkt in `GeschaeftListView` (anders als der geschäftslose
Beleg-Scan dort) — der Preisschild-Scan funktioniert immer nur direkt für ein bereits
feststehendes Geschäft, siehe „Kein geschäftsloser Einstieg“ unten.

## Unterschiede zum Belegscan

| | Belegscan (`ReceiptScanService`) | Preisschild-Scan (`PriceTagScanService`) |
| --- | --- | --- |
| Eingabe | Foto eines ganzen Kassenbons | Foto eines einzelnen Preisschilds |
| KI-Ergebnis | `BelegErgebnis` mit `[BelegPosition]` (Liste) | `PreisschildErgebnis` mit genau einem `artikelName`/`preis` |
| Menge | `menge: Double` pro Position (vom Bon erkannt) | keine — ein Preisschild zeigt keine Stückzahl |
| Datum | von der KI aus dem Bon erkannt, editierbar | immer der Scan-Zeitpunkt (`.now`), nicht editierbar |
| Kontext | `BelegScanKontext` (`.einkaufsvorgang`/`.geschaeft`/`.unbekannt`) | `geschaeft: Geschaeft` — immer feststehend, kein geschäftsloser Fall |
| Grundpreis | kommt auf Kassenbons praktisch nicht vor | Preisschilder zeigen oft zusätzlich einen Grundpreis (z.B. „1,99 € / 100g“) — die KI-Instruktion weist explizit an, ausschließlich den Verkaufspreis zurückzugeben, nicht den Grundpreis |

Mitlern-Logik (`KaufEintrag.gelernteZuordnung`), Artikel-Namensabgleich
(`passendesArtikel`) und `alternativerName`-Ableitung sind identisch zum Belegscan
übernommen (siehe `docs/BELEGSCAN.md` → „Mitlernen“/„Übernahme“).

## Kein geschäftsloser Einstieg (bewusste Entscheidung)

Der Belegscan kann ohne vorherige Geschäftswahl gestartet werden (z.B. nachträglich
zuhause) und erkennt das Geschäft danach automatisch anhand des auf dem Kassenbon
erkannten Namens (siehe `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“).
Für den Preisschild-Scan wurde das bewusst **nicht** übernommen: ein Preisschild zeigt
so gut wie nie den Geschäftsnamen (anders als ein Kassenbon mit fester Kopfzeile), ein
automatischer Abgleich hätte hier also fast immer ohnehin nur zur Anwenderauswahl
geführt. Der Preisschild-Scan funktioniert deshalb ausschließlich direkt für ein
bereits feststehendes Geschäft (`GeschaeftDetailView`/`EinkaufenView`) und ist —
anders als der Beleg-Scan — nicht im geschäftslosen Scan-Einstieg von
`GeschaeftListView` verlinkt.

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
   z.B. `RegalErgebnis.positionen: [PreisschildErgebnis]`.
5. UI: analog `BelegScanView.ErgebnisListe` (Liste editierbarer Positionen) statt der
   aktuellen Einzelposition-Ansicht in `PreisschildScanView`. Wie der Einzelschild-Scan
   funktioniert auch der Regal-Scan direkt für ein bereits feststehendes Geschäft, ohne
   geschäftslosen Einstieg (siehe „Kein geschäftsloser Einstieg“ oben) — auch ein
   ganzes Regalfoto zeigt in aller Regel keinen Geschäftsnamen.

Deutlich größerer Aufwand als der Einzelschild-Scan, da Perspektivverzerrung,
unterschiedliche Schilddesigns je Geschäft und teilweise Verdeckung im Regalfoto reale
Fehlerquellen beim Clustering sind — anders als beim linear fließenden Kassenbon-Text.
Bis dahin bleibt `PreisschildScanView` auf ein Schild pro Foto beschränkt.
