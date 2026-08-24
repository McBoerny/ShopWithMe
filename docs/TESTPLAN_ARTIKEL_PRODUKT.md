# GUI-Testplan: Artikel → Produkt → Produktname (GitHub #47)

Manueller GUI-Testplan für das komplette GitHub #47-Feature (Artikel →
Produkt → Produktname, umgesetzt in 5 Schritten: #112–#116, v0.14).
Vollständiges Konzept: [ARTIKEL_PRODUKT_MODELL.md](ARTIKEL_PRODUKT_MODELL.md).
Alle Unit-Tests (360, Stand v0.14) sind grün — dieser Plan deckt das ab, was
Unit-Tests nicht prüfen können: tatsächliches Bedienverhalten, visuelle
Darstellung, Interaktion mehrerer Views miteinander.

**Durchführung:** manuell im iOS-Simulator oder auf einem echten Gerät.
Checkboxen abhaken, Abweichungen dokumentieren (z.B. als Notiz unter dem
jeweiligen Punkt oder als Kommentar in GitHub #117).

Quelle: [GitHub #117](https://github.com/McBoerny/ShopWithMe/issues/117).

## Testdaten-Setup (einmalig, Voraussetzung für die meisten Fälle unten)

- [ ] Artikel **"Zahnpasta"** anlegen (Einstellungen → Artikel → „+"), falls
  nicht schon vorhanden.
- [ ] In der Zahnpasta-Bearbeitung, Sektion "Produkte": zwei Produkte
  anlegen — **"Odol"** und **"Paradontol Zahncreme"**.
- [ ] Geschäft **"Rewe"** anlegen (Einstellungen → Geschäfte → „+"), falls
  nicht schon vorhanden.
- [ ] Im Produkt "Paradontol Zahncreme" (über die Produkte-Sektion antippen)
  einen Produktnamen hinzufügen: Geschäft "Rewe", Name **"Parad Zahncr"**.
- [ ] Einen zweiten Artikel **ohne** zusätzliche Produkte (z.B.
  "Vollmilch") für die Regressionstests unter Abschnitt F bereithalten.

## A. `ArtikelEditView` — Sektion "Produkte"

- [ ] **A1** — Artikel "Zahnpasta" öffnen: Sektion "Produkte" zeigt "Odol"
  und "Paradontol Zahncreme" alphabetisch sortiert, jeweils mit Chevron
  (`>`) rechts.
- [ ] **A2** — Tap auf "Odol" öffnet `ProduktEditView` für Odol (Titel
  "Odol").
- [ ] **A3** — "Neues Produkt anlegen" (Button mit „+") öffnet ein neues
  Sheet ("Neues Produkt"); "Abbrechen" verwirft es folgenlos (Produkt taucht
  danach NICHT in der Liste auf).
- [ ] **A4** — Ein Produkt per Swipe-nach-links löschen, dann per
  "Abbrechen" den `ArtikelEditView` verlassen und erneut öffnen: Löschung
  bleibt bestehen (kein Zurücksetzen durch Abbrechen der Artikel-Bearbeitung
  selbst — nur die Produkt-Löschung ist bereits sofort wirksam, nicht Teil
  des Abbrechen-Zustands).
- [ ] **A5** — Artikel ohne Produkte (z.B. "Vollmilch"): Sektion "Produkte"
  ist vorhanden, aber leer (nur "+"-Button), kein Absturz/keine leere
  Sektion mit Fehlermeldung.
- [ ] **A6** — Neuer, noch nicht gesicherter Artikel (`istNeu == true`):
  Sektion "Produkte" erscheint NICHT (erst nach dem ersten Sichern
  verfügbar).

## B. `ProduktEditView`

- [ ] **B1** — In "Paradontol Zahncreme": Name-Feld zeigt "Paradontol
  Zahncreme", editierbar.
- [ ] **B2** — Sektion "Produktnamen je Geschäft" zeigt "Parad Zahncr" /
  "Rewe" (Name oben, Geschäft klein darunter).
- [ ] **B3** — Neuen Produktnamen hinzufügen: Geschäft-Picker zeigt alle
  vorhandenen Geschäfte, "Hinzufügen" ist deaktiviert, solange kein
  Geschäft gewählt ODER das Textfeld leer ist. Nach Auswahl + Text +
  Hinzufügen erscheint der neue Eintrag sofort in der Liste, Textfeld/Picker
  werden zurückgesetzt.
- [ ] **B4** — Denselben Produktnamen (Name + Geschäft identisch, Groß-/
  Kleinschreibung egal) nochmal hinzufügen versuchen: Fehlermeldung „… ist
  für … bereits hinterlegt", kein Duplikat in der Liste.
- [ ] **B5** — Produktnamen per Swipe löschen: verschwindet sofort aus der
  Liste.
- [ ] **B6** — Neues Produkt (`istNeu == true`, über A3 geöffnet): Sektion
  "Produktnamen je Geschäft" und "Preishistorie" erscheinen NICHT (erst nach
  dem ersten Sichern).
- [ ] **B7** — Falls für ein Produkt bereits Preispunkte existieren (siehe
  Abschnitt E): Sektion "Preishistorie" zeigt sie mit Geschäftsname + Datum
  + Preis, analog der bestehenden Ansicht in `ArtikelEditView`.

## C. `ArtikelHinzufuegenView` — Produktwahl beim Hinzufügen

- [ ] **C1** — Einkaufsliste öffnen → Artikel hinzufügen → nach "Zahnpasta"
  suchen: Zeile zeigt zusätzlich einen Chevron-Button (Kreis mit Pfeil)
  rechts neben dem Abhak-Symbol, da "Zahnpasta" zwei Produkte hat.
  "Vollmilch" (ohne zusätzliche Produkte) zeigt **keinen** Chevron.
- [ ] **C2** — Tap auf die "Zahnpasta"-Zeile selbst (NICHT den Chevron):
  fügt "Zahnpasta" sofort ohne Produktwahl hinzu, exakt wie vor #47 (GitHub
  #6/#45 unverändert) — kein Sheet öffnet sich.
- [ ] **C3** — Tap auf den Chevron bei "Zahnpasta": öffnet Sheet "Produkt
  wählen" mit Titel-Zusatz "Zahnpasta", Optionen "Kein bestimmtes Produkt",
  "Odol", "Paradontol Zahncreme".
- [ ] **C4** — Im Sheet "Paradontol Zahncreme" wählen: Sheet schließt,
  "Zahnpasta" ist (falls noch nicht auf der Liste) jetzt drauf.
- [ ] **C5** — Direkt danach erneut den Chevron bei "Zahnpasta" antippen und
  diesmal "Odol" wählen: vorheriger Eintrag wird auf "Odol" aktualisiert
  (kein zweiter, doppelter Listeneintrag für "Zahnpasta").
- [ ] **C6** — "Kein bestimmtes Produkt" wählen: Produkt-Zuordnung des
  Eintrags wird wieder entfernt.

## D. `EinkaufenView` — Anzeige auf der Einkaufsliste

- [ ] **D1** — Nach C4 (Produkt "Paradontol Zahncreme" gewählt): "Zahnpasta"
  erscheint auf der Liste mit "Paradontol Zahncreme" als kleine graue Zeile
  darunter (gleiche Optik wie eine Notiz).
- [ ] **D2** — Nach C6 ("Kein bestimmtes Produkt"): keine zusätzliche Zeile
  mehr unter "Zahnpasta".
- [ ] **D3** — Menge erhöhen/verringern (Swipe) und Abhaken funktionieren
  für einen Eintrag mit gewähltem Produkt unverändert wie für einen ohne.
- [ ] **D4** — Ein Artikel mit gesetzter, temporärer Notiz UND gewähltem
  Produkt: beide Zeilen (Produktname, dann Notiz) erscheinen untereinander,
  keine überlappt die andere.

## E. `BelegScanView` — automatische Produkterkennung beim Scannen

**Hinweis:** Diese Stufe greift nur, wenn der auf dem Bon per OCR erkannte
Rohtext tatsächlich zum hinterlegten `Produktname` passt (Teilstring,
case-insensitive) UND das erkannte Geschäft mit dem des Produktnamens
übereinstimmt — bei echten Kassenbons abhängig von OCR-Qualität. Am
zuverlässigsten testbar mit einem selbst geschriebenen/gedruckten Zettel mit
klarem Text statt einem echten, ggf. schwer lesbaren Bon.

- [ ] **E1** — Bei "Rewe" scannen (Kontext `.geschaeft`/`.unbekannt` oder
  laufender Einkauf bei Rewe), Beleg-Position mit Text, der "Parad Zahncr"
  enthält (z.B. "PARAD ZAHNCR 75ML 2,49"): Position wird automatisch
  "Zahnpasta" zugeordnet UND zeigt zusätzlich klein "Erkanntes Produkt:
  Paradontol Zahncreme".
- [ ] **E2** — Übernehmen: Preispunkt landet bei "Paradontol Zahncreme"
  (per B7/Preishistorie in `ProduktEditView` nachprüfbar), NICHT beim
  automatischen Platzhalter-Produkt "Zahnpasta".
- [ ] **E3** — Dieselbe Bon-Zeile bei einem ANDEREN Geschäft (nicht Rewe)
  gescannt: Produkterkennung greift NICHT (Geschäftsbindung), Position wird
  höchstens über den generischen Artikel-Teilstring-Abgleich zugeordnet,
  ohne "Erkanntes Produkt"-Zeile.
- [ ] **E4** — Manuelles Ändern des Artikel-Namensfelds einer erkannten
  Position auf einen komplett anderen Artikel: "Erkanntes Produkt"-Zeile
  verschwindet (Absicherung `effektivZugeordnetesProdukt`, siehe #116).
- [ ] **E5** — `PreisschildScanView` (Preisschild-Scan, nicht Kassenbon):
  bewusst **kein** Produkt-Erkennungsverhalten erwarten — dieser Scan-Weg
  nutzt eine eigene, unveränderte Zuordnungslogik (siehe
  [ARTIKEL_PRODUKT_MODELL.md](ARTIKEL_PRODUKT_MODELL.md)).

## F. Regressionstests (bestehendes Verhalten darf unverändert sein)

- [ ] **F1** — Alias-Namen (GitHub #111) weiterhin nutzbar: in
  `ArtikelEditView` einen Alias-Namen zu einem Artikel hinzufügen, in
  `ArtikelHinzufuegenView` danach suchen — Artikel wird gefunden.
  Alias-Sektion ist von der neuen Produkte-Sektion optisch klar getrennt.
- [ ] **F2** — `GeschaeftPreisUebersichtView` (Preisübersicht eines
  Geschäfts): zeigt weiterhin korrekte Preisspannen pro Artikel,
  unabhängig davon, ob mehrere Produkte dahinterstehen (`ArtikelPreisSpanne`
  bewusst unverändert, siehe #114).
- [ ] **F3** — Artikel ohne jegliches Produkt-Setup (frisch angelegt, nie
  im Umgang mit #47-UI berührt): Einkaufen, Abhaken, Preisschild scannen —
  alles funktioniert exakt wie vor v0.14.
- [ ] **F4** — App-Start nach dem Update (bzw. nach `xcodegen generate` +
  Neuinstallation aus altem Zustand, falls verfügbar): kein Absturz, alte
  Preishistorie bleibt sichtbar und korrekt (Migration aus #112).

## G. Migration / Bestandsdaten (best effort)

Ohne einen echten, vor v0.14 angelegten Gerätezustand nur eingeschränkt
nachstellbar — `ProduktMigrationTests.swift` deckt dies bereits
automatisiert mit einem echten On-Disk-Vorab-Store ab (siehe #112). Falls
ein Testgerät mit Alt-Stand verfügbar ist:

- [ ] **G1** — Nach dem Update: bestehende Artikel mit Preishistorie zeigen
  in `ArtikelEditView` weiterhin ihre komplette Preishistorie an.
- [ ] **G2** — Sektion "Produkte" ist für einen migrierten Artikel leer
  (das automatisch angelegte Platzhalter-Produkt ist absichtlich
  unsichtbar, siehe #115).

## H. Sync (optional, zwei Geräte/Simulatoren mit geteiltem Sync-Ordner nötig)

- [ ] **H1** — Auf Gerät A ein Produkt + Produktname anlegen, Sync-Zyklus
  abwarten: erscheint auf Gerät B in derselben `ArtikelEditView`/
  `ProduktEditView`.
- [ ] **H2** — Auf beiden Geräten unabhängig je ein Produkt mit demselben
  Namen für denselben Artikel anlegen (z.B. beide legen "Sensitiv" für
  "Zahnpasta" an): nach dem Sync existiert nur EIN "Sensitiv"-Produkt
  (Namens-Matching, siehe #113), keine Dublette.

## Bekannte Einschränkungen beim manuellen Testen

- Abschnitt E ist OCR-abhängig — ein Fehlschlag kann an der
  Texterkennung liegen, nicht zwingend an der Zuordnungslogik selbst.
- Abschnitt G lässt sich ohne einen echten Alt-Gerätezustand nicht exakt
  nachstellen; die automatisierte Abdeckung dafür ist
  `ProduktMigrationTests.swift`.
- Abschnitt H braucht zwei Geräte/Simulatoren mit demselben, geteilten
  Sync-Ordner — ohne diesen Aufbau überspringen.

## Ergebnis

Noch nicht durchgeführt. Nach Abschluss hier Datum, Ergebnis (alle Punkte
grün / gefundene Abweichungen) und Testumgebung (Simulator/Gerät, iOS-
Version) eintragen.
