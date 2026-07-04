# ShopWithMe — Produktspezifikation

> Diese Datei fasst die Anforderungen zusammen, wie sie in der Projekt-Kickoff-Unterhaltung
> festgelegt wurden. Sie dient als Gedächtnisstütze für künftige Sessions.

## Vision

Eine iOS-App (SwiftUI, kein macOS-Ziel) für den täglichen Einkauf, die Artikel,
Geschäfte und den Einkaufsvorgang selbst intelligent unterstützt.

## Kernkonzepte

- **Artikel**: hat Name, Symbol (SF Symbol), Farbe, und eine **Kategorie**, die bei der
  Anlage festgelegt wird und sich danach nicht mehr ändert.
- **Artikelkategorie**: z.B. Obst, Milchprodukte, Drogerieartikel. Kategorien sind global,
  nicht pro Geschäft.
- **Geschäft**: hat einen Typ (Lebensmittel, Drogerie, Baumarkt, Apotheke, …) sowie
  eigene **Kategorien** und (optional) eigene **Regale**. Kategorien sind wichtiger
  als Regale: ein Geschäft kann Kategorien direkt zugeordnet bekommen, ganz ohne ein
  Regal anzulegen — nur diese (bzw. über ein Regal zugeordneten) Kategorien werden
  beim Einkaufen für dieses Geschäft angezeigt.
- **Regal**: gehört zu genau einem Geschäft und ist rein optional. Jedem Regal können
  eine oder mehrere Artikelkategorien zugeordnet werden, die dadurch (falls nicht
  schon direkt zugeordnet) ebenfalls in diesem Geschäft verfügbar werden. Ein Regal
  dient in erster Linie dazu, die Reihenfolge beim Einkaufen zu organisieren — nicht
  der Verfügbarkeit an sich.

## Artikel-Anlage mit KI-Unterstützung

Beim Anlegen eines neuen Artikels schlägt eine lokale Apple-KI (FoundationModels /
"Apple Intelligence") automatisch ein passendes Symbol, eine Farbe, eine Kategorie und
ein Regal vor. Der Anwender kann die Vorschläge übernehmen oder überschreiben. Ist auf
dem Gerät keine Apple Intelligence verfügbar, wird die Funktion ausgeblendet — reine
manuelle Anlage bleibt immer möglich.

## Einkaufsvorgang

- Der Anwender kann pro Geschäft eine eigene Reihenfolge der Regale festlegen (der Weg,
  den er im Laden ablaufen möchte).
- Die App lernt automatisch aus vergangenen Einkäufen, in welcher Reihenfolge Regale
  typischerweise besucht werden, und schlägt nach ausreichend Trainingsdurchläufen eine
  automatische Reihenfolge vor. Die manuelle Reihenfolge bleibt bestehen, bis der
  Anwender die automatische explizit übernimmt.
- Die Einkaufsliste ist global und nicht von einem Geschäft abhängig. Optional kann der
  Anwender ein Geschäft wählen, wonach die Liste nach Regal in der gültigen Reihenfolge
  gruppiert wird. Artikel ohne Kategorie oder ohne Regal-Zuordnung im gewählten Geschäft
  (bzw. alle Artikel, wenn kein Geschäft gewählt ist) erscheinen dennoch, in einer
  eigenen „Sonstige“-Sektion.
- Ein Einkauf startet automatisch beim Öffnen des Einkaufen-Tabs (für das gewählte
  Geschäft, bzw. ohne Geschäft) — kein manueller „Start“ nötig.
- Pro Geschäft legt ``ArtikelFilterModus`` fest, ob beim Einkaufen nur dort verfügbare
  Artikel angezeigt werden (Standard) oder alle Artikel der Einkaufsliste unabhängig
  von der Verfügbarkeit. Verfügbarkeit ergibt sich entweder aus den Kategorien des
  Geschäfts oder — besitzt es keine eigenen Kategorien — aus der Kaufhistorie
  (``ArtikelVerfuegbarkeitService``): ein Artikel gilt als verfügbar, sobald er dort
  einmal gekauft wurde.
- Während eines laufenden Einkaufs kann der Anwender per Anzeige-Umschalter zwischen
  „Nur offene“, „Auch abgehakte Artikel“ und einem „Lernmodus“ (zeigt alle Artikel der
  Einkaufsliste, auch nicht als verfügbar geltende — zum Entdecken/Abhaken bislang
  unbekannter Artikel, wodurch sie für dieses Geschäft als verfügbar gelernt werden)
  wählen. Abgehakte Artikel bleiben im Modus „Auch abgehakte Artikel“ sichtbar
  (durchgestrichen) und lassen sich per Antippen wieder zurückholen, falls versehentlich
  abgehakt.
- Per Wischgeste kann ein bereits abgehakter Artikel dauerhaft aus der Ansicht dieses
  Einkaufs entfernt werden — anders als das normale Rückgängigmachen landet er dabei
  nicht wieder auf der offenen Liste.
- Ein Einkauf lässt sich jederzeit abschließen, auch wenn nicht alle Artikel abgehakt
  wurden — nicht gekaufte Artikel bleiben einfach auf der globalen Einkaufsliste.

## Standortbezug (zukünftig)

Über Standortdaten soll dem Anwender künftig automatisch die passende Einkaufsliste des
Geschäfts angezeigt werden, in dessen Nähe er sich befindet. **Nicht Teil der aktuellen
Umsetzung** — Datenmodell hält Lat/Long am Geschäft bereits vor, aber es gibt noch keine
Standort-Logik/Berechtigung.

## Belegscan / Preishistorie

Ein Kassenbon lässt sich an zwei Stellen scannen: nach einem Einkauf (Preise werden
den abgehakten Positionen zugeordnet) oder unabhängig davon direkt in der
Geschäfts-Detailansicht (jede erkannte Position wird als eigenständiger Eintrag
gespeichert — nützlich für ältere oder nachträglich gefundene Bons). Lokale KI
(Vision-OCR + FoundationModels; vorbereitet für zukünftige, speziellere
On-Device-APIs) extrahiert Geschäft, Einkaufsdatum, Artikel und Preise. Das erkannte
Datum ist vorbelegt, lässt sich vor der Übernahme aber jederzeit manuell korrigieren,
falls der Bon kein Datum erkennen ließ oder die Erkennung danebenlag. Kassenbons
weisen bei mehreren Stück oft nur einen Gesamtpreis aus — übernommen wird stets der
von der KI berechnete Einzelpreis, nicht die Menge. Vor der Übernahme kann der
Anwender jede erkannte Position prüfen, korrigieren oder löschen.

Ein generischer Artikel (z.B. "Zahnpasta") kann für unterschiedliche Marken/Produkte
stehen (Colgate, Elmex, Meridol, …). Benennt der Anwender eine erkannte Position auf
den Namen eines solchen generischen Artikels um, damit sie diesem zugeordnet wird,
bleibt der ursprünglich erkannte Produktname trotzdem erhalten — die Preishistorie
zeigt weiterhin den genauen Produktnamen an, nicht nur den generischen Artikelnamen,
sodass sich die Preise der einzelnen Produkte pro Geschäft getrennt nachverfolgen
lassen.

## Einstellungen

- Hilfe-/Anleitungstexte für die komplexeren Funktionen (Lern-Algorithmus,
  KI-Vorschläge, Belegscan, Datenbank-Speicherort).
- Datenbank-Speicherort: kann auf einen vom Anwender gewählten Ordner (z.B. lokal
  gespiegelter Cloud-Ordner) verlegt werden. **Ausdrücklich kein iCloud-Sync** in dieser
  Phase — reine Dateiverlagerung, kein Mehrgeräte-Konfliktmanagement.

## Nicht-Ziele (aktuell)

- Keine macOS-Version.
- Kein iCloud-Sync.
- Keine Standort-basierte automatische Ladenerkennung (nur Datenmodell vorbereitet).

Siehe [ARCHITECTURE.md](ARCHITECTURE.md) für die technische Umsetzung,
[ROADMAP.md](ROADMAP.md) für den Checkpoint-Plan und [DECISIONS.md](DECISIONS.md) für
Begründungen technischer Entscheidungen.
