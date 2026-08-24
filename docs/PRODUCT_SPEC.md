# ShopWithMe — Produktspezifikation

> Diese Datei fasst die Anforderungen zusammen, wie sie in der Projekt-Kickoff-Unterhaltung
> festgelegt wurden. Sie dient als Gedächtnisstütze für künftige Sessions.

## Vision

Eine iOS-App (SwiftUI, kein macOS-Ziel) für den täglichen Einkauf, die Artikel,
Geschäfte und den Einkaufsvorgang selbst intelligent unterstützt.

## Kernkonzepte

- **Artikel**: hat Name, eine oder mehrere **Abteilungen** (jederzeit änderbar,
  Mehrfachauswahl) sowie **Menge** und **Einheit** (Gewicht: kg/g, Volumen: ltr/ml,
  oder Stück) — die beim Anlegen festgelegte Menge ist zugleich die
  Standard-Schrittweite für Erhöhen/Verringern auf der Einkaufsliste. Hat ein Artikel
  mehrere Abteilungen, erscheint er beim Einkaufen gleichzeitig in JEDEM zugehörigen
  Abschnitt (GitHub-Nachfolgefund zu #36 — vorherige Architektur-Revision entschied
  noch pro Geschäft eine einzelne „führende" Abteilung und duplizierte den Artikel
  bewusst nicht; das hing zusätzlich von der nicht ordnungsgarantierten
  `abteilungen`-Relationship ab und ließ den Artikel bei Sync-Zyklen sichtbar
  zwischen Abschnitten springen). Abgehakt wird er dabei überall zugleich; aus
  welchem Abschnitt tatsächlich abgehakt wurde, geht als Abteilung in den
  `KaufEintrag` ein — Grundlage dafür, dass `AbteilungsDistanzService` pro
  Geschäft lernt, in welcher der mehreren Abteilungen ein Artikel dort tatsächlich
  steht (z.B. Sojasauce bei Edeka unter „Soßen", bei Aldi unter „Asia"), statt einer
  global geratenen. `Artikel/fuehrendeAbteilung(inGeschaeft:context:)` bleibt als
  Fallback für Kontexte ohne konkret getappten Abschnitt (Belegscan,
  Preisschild-Scan, Sync-Import empfangener Events) — bevorzugt eine im Geschäft
  verfügbare Abteilung, sonst die erste (deterministisch nach `sortIndex`
  sortierte) zugeordnete. Symbol/Farbe existieren weiterhin als Datenfelder, werden
  aber in keiner UI mehr angezeigt oder vom Anwender/der KI gesetzt.
- **Abteilung**: z.B. Obst, Milchprodukte, Drogerieartikel. Abteilungen sind global,
  nicht pro Geschäft.
- **Geschäft**: hat einen oder mehrere Typen (Lebensmittel, Drogerie, Baumarkt,
  Apotheke, …, z.B. Drogerie + Lebensmittel bei einem dm) sowie eigene
  **Abteilungen**: ein Geschäft kann Abteilungen direkt zugeordnet bekommen — nur
  diese (bzw. über den Geschäftstyp automatisch verfügbaren) Abteilungen werden
  beim Einkaufen für dieses Geschäft angezeigt. Eine automatisch über den
  Geschäftstyp verfügbare Abteilung lässt sich zusätzlich für ein einzelnes
  Geschäft ausschließen (Negativliste), ohne sie generell vom Geschäftstyp zu
  entfernen (GitHub #43). Die Reihenfolge, in der sie beim Einkaufen erscheinen,
  wird nicht manuell festgelegt, sondern automatisch aus dem Abhakverhalten
  gelernt (siehe „Einkaufsvorgang“ unten).

## Artikel-Anlage mit KI-Unterstützung

Beim Anlegen eines neuen Artikels bestimmt eine lokale Apple-KI (FoundationModels /
"Apple Intelligence") automatisch eine passende Abteilung — ganz ohne manuellen
Anstoß: sobald der Anwender einen Namen eingibt (entprellt, damit nicht bei jedem
Tastenanschlag ein KI-Aufruf losgeschickt wird), wird die Abteilung vorgeschlagen,
sofern noch keine gewählt wurde. Eine bereits manuell gewählte Abteilung wird dabei
nie überschrieben. Ist auf
dem Gerät keine Apple Intelligence verfügbar, bleibt die Abteilung einfach leer (dann
"Sonstiges") — reine manuelle Auswahl bleibt immer möglich.

Artikel werden ausschließlich aus der Einkaufsliste-Ansicht heraus neu angelegt und
kommen dabei automatisch auf die Liste (siehe „Einkaufsvorgang“ unten); der
Artikel-Verwaltung (Einstellungen) dient primär dem Durchsuchen/Bearbeiten/Löschen,
legt aber ebenfalls einen „+“-Button zum Anlegen bereit (Artikel landen dabei nicht
automatisch auf der Liste).

## Menge, Einheit & Einkaufslisten-Interaktion

Jeder Artikel hat eine Einheit (Stück, Kilogramm, Gramm, Liter oder Milliliter) und
eine beim Anlegen festgelegte Standardmenge, die zugleich als Schrittweite dient. Auf
der Einkaufsliste:
- **Einfacher Tap** auf eine Zeile erhöht die Menge um die Schrittweite.
- **Doppel-Tap** verringert sie (nie unter die Schrittweite).
- **Langes Drücken** öffnet ein Sheet für eine exakte Menge und eine temporäre Notiz.
- **Abhaken** geschieht ausschließlich über eine eigenständige Checkbox am Zeilenende.

Menge und temporäre Notiz werden zurückgesetzt, sobald ein Artikel (neu oder erneut)
auf die Einkaufsliste kommt.

## Einkaufsvorgang

- Die App lernt automatisch aus dem Abhakverhalten vergangener Einkäufe, welche
  Abteilungen in einem Geschäft räumlich nah beieinanderliegen (paarweise
  Distanzmatrix, `AbteilungsDistanzService`), und sortiert die Einkaufsliste
  danach dynamisch — nach jeder Abhakung neu, ausgehend vom aktuellen (impliziten)
  Standort. Details in `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`.
- Die Einkaufsliste ist global und nicht von einem Geschäft abhängig. Optional kann der
  Anwender ein Geschäft wählen, wonach die Liste nach Abteilung gruppiert und
  sortiert wird.
- Ein Einkauf startet automatisch beim Öffnen des Einkaufen-Tabs (für das gewählte
  Geschäft, bzw. ohne Geschäft) — kein manueller „Start“ nötig.
- Beim Einkaufen werden standardmäßig nur die im gewählten Geschäft verfügbaren Artikel
  angezeigt. Verfügbarkeit ergibt sich entweder aus den Abteilungen des Geschäfts oder —
  besitzt es keine eigenen Abteilungen — aus der Kaufhistorie
  (``ArtikelVerfuegbarkeitService``): ein Artikel gilt als verfügbar, sobald er dort
  einmal gekauft wurde. Der Anwender kann diesen Filter jederzeit direkt im laufenden
  Einkauf per Umschalter übergehen, um alle Artikel der Einkaufsliste zu sehen — das
  ist eine reine Anzeigeentscheidung für diesen Einkauf, keine dauerhafte
  Geschäfts-Einstellung.
- Während eines laufenden Einkaufs bündelt eine Schnellauswahl neben „Einkauf
  abschließen“ zwei Anzeigeentscheidungen in einem Button: ein kurzer Tap blendet
  zusätzlich zu den offenen auch die bereits abgehakten Artikel ein (durchgestrichen,
  per Antippen wieder zurückholbar, falls versehentlich abgehakt). Ein langer Tap öffnet
  ein Kontextmenü zum Umschalten des Lernmodus, der alle Artikel der Einkaufsliste
  einblendet, auch bislang nicht als verfügbar geltende — zum Entdecken/Abhaken bislang
  unbekannter Artikel, wodurch sie für dieses Geschäft als verfügbar gelernt werden. Der
  Lernmodus ist nur verfügbar, wenn ein Geschäft gewählt ist.
- Per Wischgeste kann ein bereits abgehakter Artikel dauerhaft aus der Ansicht dieses
  Einkaufs entfernt werden — anders als das normale Rückgängigmachen landet er dabei
  nicht wieder auf der offenen Liste.
- Ein Einkauf lässt sich jederzeit abschließen, auch wenn nicht alle Artikel abgehakt
  wurden — nicht gekaufte Artikel bleiben einfach auf der globalen Einkaufsliste.

## Standortbezug

**Umgesetzt** (`GeschaeftErkennungService`, Details in `docs/GESCHAEFTSERKENNUNG.md`):
Beim Öffnen des Einkaufen-Tabs erkennt die App per einmaliger Standortabfrage („Bei
Nutzung“, kein Hintergrund-Tracking) über Apple Maps, ob sich der Anwender in der Nähe
eines Ladens befindet, und schlägt ihn in einem Banner vor — ein bereits angelegtes
Geschäft direkt zur Auswahl, ein noch unbekannter Laden zum Anlegen mit
vorausgefüllten Stammdaten. Ein Vorschlag lässt sich dauerhaft ignorieren; „Alle
Geschäfte in der Nähe“ zeigt zusätzlich alle Läden im 100m-Radius (inkl. ignorierter,
mit Möglichkeit zum Wiederaufnehmen). Ein neues Geschäft lässt sich davon unabhängig
weiterhin jederzeit rein manuell anlegen — die Standort-Erkennung ist nur eine
Ergänzung, nie der einzige Weg.

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

- Die App startet immer direkt mit der Einkaufsliste (kein eigener Artikel-/
  Geschäfte-Tab mehr) — Artikel- und Geschäfte-Verwaltung sind ausschließlich über
  die Einstellungen erreichbar.
- Hilfe-/Anleitungstexte für die komplexeren Funktionen (Lern-Algorithmus,
  KI-Vorschläge, Belegscan, Datenbank-Speicherort).
- Datenbank-Speicherort: kann auf einen vom Anwender gewählten Ordner (z.B. lokal
  gespiegelter Cloud-Ordner) verlegt werden. **Ausdrücklich kein iCloud-Sync** in dieser
  Phase — reine Dateiverlagerung, kein Mehrgeräte-Konfliktmanagement.

## Nicht-Ziele (aktuell)

- Keine macOS-Version.
- Kein iCloud-Sync.

Siehe [ARCHITECTURE.md](ARCHITECTURE.md) für die technische Umsetzung,
[ROADMAP.md](ROADMAP.md) für den Checkpoint-Plan und [DECISIONS.md](DECISIONS.md) für
Begründungen technischer Entscheidungen.
