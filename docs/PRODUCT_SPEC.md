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
- **Geschäft**: hat einen Typ (Lebensmittel, Drogerie, Baumarkt, Apotheke, …) und eigene
  **Regale**.
- **Regal**: gehört zu genau einem Geschäft. Jedem Regal sind eine oder mehrere
  Artikelkategorien zugeordnet. Aus dieser Zuordnung ergibt sich automatisch, welche
  Kategorien in diesem Geschäft überhaupt verfügbar sind — beim Einkaufen werden pro
  Geschäft nur die dort tatsächlich zugeordneten Kategorien angezeigt.

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
- Die Einkaufsliste pro Geschäft zeigt nur Artikel aus Kategorien, die diesem Geschäft
  zugeordnet sind, gruppiert nach Regal in der gültigen Reihenfolge.

## Standortbezug (zukünftig)

Über Standortdaten soll dem Anwender künftig automatisch die passende Einkaufsliste des
Geschäfts angezeigt werden, in dessen Nähe er sich befindet. **Nicht Teil der aktuellen
Umsetzung** — Datenmodell hält Lat/Long am Geschäft bereits vor, aber es gibt noch keine
Standort-Logik/Berechtigung.

## Belegscan / Preishistorie

Nach einem Einkauf kann der Anwender einen Kassenbon scannen. Lokale KI (Vision-OCR +
FoundationModels; vorbereitet für zukünftige, speziellere On-Device-APIs) extrahiert
Artikel und Preise und speichert sie als historische Preisübersicht (Datum, Kosten pro
Artikel, Geschäft).

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
