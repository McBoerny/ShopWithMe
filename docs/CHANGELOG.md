# Changelog

## v0.7 (Build 97) — Versions-Checkpoint: v0.6-Zyklus abgeschlossen

- Minor-Version auf `0.7` angehoben (Nutzervorgabe) — der `v0.6`-Zyklus (adaptive
  Warengruppen-Distanzmatrix, GitHub #36, sowie die darauf aufbauende Entfernung von
  `Regal`/`ShelfOrderLearningService`/`KategorieBesuchsStatistik`, GitHub #35) ist
  damit abgeschlossen.

## v0.6 (Build 96) — Regal entfernt: Warengruppen-Distanzmatrix ersetzt manuelle Sortierstruktur (GitHub #35)

- **`Regal`, `RegalSortierModus`, `RegalDetailView`, `ShelfOrderLearningService` und
  `KategorieBesuchsStatistik` entfernt.** Mit der in Build 95 eingeführten
  `WarengruppenDistanzService`-Sortierung (paarweise Distanzmatrix statt eines
  einzelnen Skalars je Kategorie) hatte die manuell zu pflegende Regal-Zwischenschicht
  keinen Zweck mehr, den die automatische Sortierung nicht feiner und ohne
  Pflegeaufwand abdeckt. Begründung und Umfang: [Issue #35](https://github.com/McBoerny/ShopWithMe/issues/35).
- `Geschaeft.verfuegbareKategorien` ist jetzt schlicht `kategorien.sorted { $0.sortIndex < $1.sortIndex }`
  (keine Regal-Vereinigung mehr); `Artikel.fuehrendeKategorie` verliert die
  Regal-Priorität; `ArtikelKategorie.regale` entfällt.
  `GeschaeftDetailView` verliert Regal-Sektion und `EditButton` (der zuvor nur für die
  manuelle Regal-Reihenfolge nötig war, GitHub #28); `EinkaufenView` gruppiert
  Einkaufslisten-Sektionen jetzt einheitlich nach Kategorie statt teils nach
  Regal/teils nach Kategorie (`Gruppe`/`sonstigeArtikel` entfallen).
- **Achtung Datenmigration:** Da `Regal` und `KategorieBesuchsStatistik` aus dem
  SwiftData-Schema entfernt wurden, verwirft die automatische Lightweight-Migration
  beim nächsten Start alle bisher gespeicherten Regal- und
  Kategorie-Besuchsstatistik-Datensätze unwiderruflich (Kategorie- und Geschäfts-Daten
  selbst bleiben erhalten). Die gelernte Sortierreihenfolge baut sich über die neue
  `WarengruppenDistanz`-Matrix aus künftigen Einkäufen neu auf.
- Betroffene Doku (`ARCHITECTURE.md`, `PRODUCT_SPEC.md`, `BEDIENUNGSANLEITUNG.md`,
  `DATABASE_CONCURRENCY.md`, `HelpView`) auf den Stand ohne Regal aktualisiert.

## v0.6 (Build 95) — Adaptive Einkaufslistenoptimierung (Warengruppen-Distanzmatrix)

- **`WarengruppenDistanz`** (neu): paarweise, ladenspezifisch gelernte Distanz
  zwischen zwei Artikelkategorien — Kernbaustein der adaptiven
  Einkaufslistenoptimierung nach `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`
  (GitHub #36).
- **`WarengruppenDistanzService`** (neu): lernt nach jedem abgeschlossenen
  Einkauf aus der Abhakreihenfolge (Positions- und Zeitdistanz, gleitender
  Durchschnitt) und erkennt mögliche Ladenumbauten (`Geschaeft/umbauVerdacht`).
  Sortiert die Warengruppen einer Einkaufsliste per Greedy-Nearest-Neighbor +
  2-opt und passt die Reihenfolge nach jeder Abhakung dynamisch an den
  aktuellen (impliziten) Standort an.
- `EinkaufenView` nutzt die neue Sortierung für Kategorien ohne Regal-Zuordnung
  (bisher nur ein einzelner Durchschnittswert je Kategorie) und zeigt einen
  Status-Hinweis („Lernt noch“/„Reihenfolge optimiert“) sowie einen Dialog bei
  erkanntem Ladenumbau.
- Die Regal-basierte Sortierung (``ShelfOrderLearningService``) bleibt vorerst
  unverändert bestehen — deren Ablösung ist als eigenes Vorhaben in
  [Issue #35](https://github.com/McBoerny/ShopWithMe/issues/35) vorgesehen.

## v0.6 (Build 93) — Geschäfte-Navigation: letzte beiden Ebenen ebenfalls auf wertbasiert umgestellt (GitHub #33 endgültig behoben)

- Nach Build 90–92 blieb die Fehlerklasse an zwei weiteren, noch weiter außen
  liegenden Stellen bestehen — dieselbe closure-basierte
  `NavigationLink { destination } label: {}`-Variante, die eine Ziel-View eager
  bei **jedem** Rendern der umgebenden Liste konstruiert statt erst beim
  tatsächlichen Antippen:
  - `GeschaeftListView` (Zeilen-Navigation zur Detailansicht): GitHub #13
    (Build 68) hatte diese Zeilen absichtlich von wertbasiertem
    `NavigationLink(value:)` auf die closure-basierte Variante umgestellt, um
    einen im Simulator nicht reproduzierbaren Navigations-Bug zu adressieren —
    genau das war rückblickend die eigentliche Ursache-Klasse. Da mehrere
    Zeilen gleichzeitig gerendert werden, registrierten mehrere
    `GeschaeftDetailView`-Instanzen (unterschiedlicher `geschaeft`-Werte)
    gleichzeitig `.navigationDestination(for: GeschaeftDetailNavigationsziel.self)`
    — ein Tap auf „Preisübersicht“ in der Detailansicht landete dadurch teils
    wieder auf der Detailansicht selbst statt auf `GeschaeftPreisUebersichtView`.
  - `SettingsView` (Zeilen-Navigation u.a. zu „Geschäfte“): dieselbe Ursache
    eine Ebene höher — sobald `GeschaeftListView` (eigenes `@Query` und, nach
    obigem Fix, eigenes `.navigationDestination(for: Geschaeft.self)`) darüber
    ebenfalls nur noch closure-basiert geöffnet wurde, verhinderte das
    eager-konstruierte Duplikat die Navigation von der Geschäfte-Liste zur
    Detailansicht vollständig (Tap auf ein Geschäft passierte nichts mehr).
  Beide Stellen jetzt auf `NavigationLink(value:)` +
  `.navigationDestination(for:)` umgestellt — `GeschaeftListView` direkt über
  `Geschaeft` als Wert, `SettingsView` über ein neues
  `SettingsNavigationsziel`-Enum (analog `GeschaeftDetailNavigationsziel`).
  Damit verwendet die komplette Navigationskette
  Einstellungen → Geschäfte → Geschäft-Detail → Preisübersicht → Artikel-Preishistorie
  durchgängig das wertbasierte Muster — keine closure-basierte
  `NavigationLink` mehr in diesem Pfad.

## v0.6 (Build 92) — Geschäft-Detail: auch äußere Preisübersicht-Navigation entschärft

- Build 91 behob die Endlosschleife nur auf einer Ebene — `GeschaeftDetailView`
  öffnete `GeschaeftPreisUebersichtView` (eigenes `@Query`) und
  `GeschaeftBesuchsProtokollView` ebenfalls noch über die ältere closure-basierte
  `NavigationLink { destination } label: {}`-Variante, die die Ziel-View eager bei
  jedem Rendern von `GeschaeftDetailView` neu konstruiert — dieselbe Ursache wie
  in Build 91, nur eine Ebene höher, und verschärfte das Problem nach dem
  inneren Fix zusätzlich (Rückmeldung: App hing danach schon vor dem Öffnen der
  Preisübersicht). Beide Zeilen nutzen jetzt `NavigationLink(value:)` mit einem
  eigenen `Hashable`-Navigationsziel-Enum statt eines Datenwerts, analog zum
  bereits bestehenden `Regal`-Muster (GitHub #33).

## v0.6 (Build 91) — Preisübersicht: Endlosschleife beim Navigieren behoben

- Auch der Fix aus Build 90 behob den Hänger noch nicht vollständig — mit
  gezielten temporären Debug-Ausgaben (auf Wunsch des Nutzers eingebaut, siehe
  GitHub #33) zeigte sich eine echte Endlosschleife: `GeschaeftPreisUebersichtView`
  nutzte für die „Preisspanne je Artikel“-Liste die ältere, closure-basierte
  `NavigationLink { destination } label: {}`-Variante — dabei konstruiert SwiftUI
  die Destination-View (inkl. eines eigenen `@Query`) **eager für jede Zeile der
  Liste**, nicht nur für die angetippte. Die wiederholte `@Query`-Neuanlage löste
  eine Rückkopplung mit dem `@Query` der Preisübersicht selbst aus — beide
  Views rendern sich seitdem endlos gegenseitig neu. Umgestellt auf das
  wertbasierte `NavigationLink(value:)` + `.navigationDestination(for:)`
  (das Muster, das an anderer Stelle im Code, z.B. für Regale, bereits
  konsequent verwendet wird) — die Destination wird jetzt nur noch für den
  tatsächlich angetippten Artikel konstruiert.

## v0.6 (Build 90) — Preisübersicht: tatsächliche Ursache des Hängers gefunden und behoben

- Der vorherige Fix (Build 89) behob eine potenzielle Schwachstelle, war aber
  nicht die tatsächliche Ursache. Ein vom Nutzer bereitgestelltes Debug-Protokoll
  zeigte den echten Grund: ein `_UISwipeActionPanGestureRecognizer` blockierte
  die App für über 78 Sekunden. Ursache: `PreisHistorieZeile` definierte eine
  eigene `.swipeActions(edge: .leading)`-Konfiguration („Zuordnen“), während
  `ArtikelPreisVerlaufView` zusätzlich ein externes `.onDelete` auf derselben
  Zeile anwendete — zwei unabhängige Swipe-Konfigurationen auf derselben Zeile
  brachten UIKits Swipe-Gesten-Erkennung durcheinander. `PreisHistorieZeile`
  übernimmt die Löschaktion jetzt selbst über einen optionalen `loeschen`-
  Parameter (eigenes `.swipeActions(edge: .trailing)`), statt sie extern per
  `.onDelete` zu überlagern (GitHub #33).

## v0.6 (Build 89) — Preisübersicht: Hänger beim Öffnen der Artikel-Preishistorie behoben

- Ein Antippen eines Artikels in der Preisübersicht eines Geschäfts konnte die
  App zum Hängen bringen. Ursache: ein live beobachtendes `@Query` mit einem
  zusammengesetzten `#Predicate` über zwei Beziehungen (`artikel` **und**
  `geschaeft`) — dieses Muster war im Code sonst nur für einmalige Fetches in
  Verwendung, nie für ein live `@Query`. Jetzt wird nur noch nach einer
  Beziehung live gefiltert, die zweite Filterbedingung läuft in Swift
  (GitHub #33).

## v0.6 (Build 88) — Einkaufsliste direkt in der Zeile umbenennen

- **Einkaufslisten-Verwaltung** (`EinkaufslistenVerwaltungView`): der
  Listenname lässt sich jetzt direkt in der Zeile per Textfeld umbenennen —
  kein eigener Bearbeiten-Bildschirm mehr nötig. Der `Bearbeiten`-Button im
  Toolbar entfällt, da Löschen bereits per Wischgeste funktioniert (GitHub #27).

## v0.6 (Build 87) — Einkauf-abschließen-Button zeigt Anzahl abgehakter Artikel

- Der „Einkauf abschließen“-Button zeigt jetzt die Anzahl bereits abgehakter
  Artikel im Label und wechselt von neutral zu akzentfarben, sobald mindestens
  ein Artikel abgehakt wurde (GitHub #26).

## v0.6 (Build 86) — Wischgesten-Hinweis korrigiert, Suchfeld startet inaktiv

- Der Hinweistext zum Zuordnen unzugeordneter Belegpositionen
  (`GeschaeftPreisUebersichtView`) nannte die falsche Wischrichtung („Nach
  links“ statt „Nach rechts“) — korrigiert (GitHub #22).
- `ArtikelHinzufuegenView` startet das Suchfeld jetzt explizit unfokussiert
  (`.searchable(isPresented:)`), damit es sich beim Öffnen nicht mehr
  automatisch aktiviert (GitHub #23).

## v0.6 (Build 85) — Geschäftstyp als eigenes, erweiterbares Modell

- **`GeschaeftTyp`** (neu): bisher ein festes `enum` (Lebensmittel, Drogerie, …),
  jetzt ein eigenständiges SwiftData-Modell. Der Anwender kann in
  `GeschaeftStammdatenEditView` und der neuen Typ-Verwaltung
  (`GeschaeftsTypenVerwaltungView`) jetzt auch eigene, benutzerdefinierte
  Geschäftstypen anlegen (GitHub #25) — die zehn bisherigen Typen bleiben als
  Vorauswahl beim ersten Start erhalten.
- Bestehende Geschäfte/Warengruppen mit dem alten enum-Rohwert werden beim
  App-Start automatisch einmalig auf die entsprechenden `GeschaeftTyp`-Objekte
  migriert (`Geschaeft.typenMigrierenFallsNoetig`,
  `ArtikelKategorie.geschaeftsTypenMigrierenFallsNoetig`) — additiv, ohne neue
  `VersionedSchema` (siehe `docs/DECISIONS.md`).
- `Geschaeft.typ` entfällt zugunsten von `Geschaeft.fuehrenderTyp` (führender,
  erster zugeordneter Typ).

## v0.6 (Build 84) — Geschäft anlegen: Standort per Karte, GPS oder Adresse

- **`Geschaeft.koordinate`** (neu): `CLLocationCoordinate2D`-Zugriff auf
  `breitengrad`/`laengengrad`.
- **`GeschaeftErkennungService.adresse(fuerKoordinaten:)`** (neu):
  Reverse-Geocoding (`MKReverseGeocodingRequest`) als Gegenstück zur
  bestehenden Vorwärts-Geokodierung.
- `GeschaeftStammdatenEditView` zeigt jetzt, sobald ein Standort gesetzt ist,
  eine Karte mit Pin — antippen setzt den Standort exakt. „Aktuellen Standort
  verwenden“ füllt Adresse und Koordinaten aus dem GPS-Standort; eine
  eingegebene Adresse wird beim Bestätigen automatisch geokodiert, solange
  noch kein Standort gesetzt ist — ein bereits manuell platzierter Pin wird
  dabei nie überschrieben (GitHub #24).

## v0.6 (Build 83) — Favoriten: meistgenutzte Geschäfte priorisiert

- **`GeschaeftHaeufigkeitService`** (neu): ermittelt die meistgenutzten
  Geschäfte anhand abgeschlossener `Einkaufsvorgang`e innerhalb eines
  konfigurierbaren Zeitfensters (Standard 30 Tage, Standard-Anzahl 5).
- `GeschaeftListView` (Einstellungen → Geschäfte) zeigt eine „Favoriten“-Sektion
  vor der vollständigen Liste, mit einem Stern-Button zum Einstellen von Anzahl
  und Zeitfenster.
- `EinkaufenView`s Geschäfts-Menü zeigt dieselben Favoriten priorisiert vor den
  übrigen Geschäften (GitHub #31).

## v0.6 (Build 82) — Besuchsprotokoll je Geschäft

- **`GeschaeftBesuchsProtokollView`** (neu, GitHub #32): listet alle
  abgeschlossenen Einkaufsbesuche eines Geschäfts mit Zeitpunkt und Dauer —
  ohne neues Datenmodell, direkt aus den ohnehin vorhandenen
  `Einkaufsvorgang.startZeit`/`endZeit` abgeleitet. Aufrufbar über einen
  neuen Eintrag in `GeschaeftDetailView`.

## v0.6 (Build 81) — Zähler für abgeschlossene Einkäufe je Geschäft

- **`Geschaeft.anzahlEinkaufsvorgaenge`** (neu): zählt, wie oft ein
  Einkaufsvorgang in diesem Geschäft abgeschlossen wurde
  (`Einkaufsvorgang.abschliessen(am:)` erhöht ihn) — unabhängig von der
  Preishistorie und deren Aufbewahrungsfrist. In
  `GeschaeftStammdatenEditView` sichtbar und manuell auf 0 zurücksetzbar,
  ohne die Kaufhistorie zu löschen (GitHub #30).

## v0.6 (Build 80) — Edit-Button in Geschäft-Detail nur bei echtem Nutzen

- `GeschaeftDetailView`: der Bearbeiten-Button oben rechts erscheint jetzt nur
  noch, wenn er tatsächlich etwas bewirkt — Zieh-Griffe zum manuellen
  Umsortieren von mindestens zwei Regalen im manuellen Sortiermodus. Löschen
  funktioniert bereits ohne Edit-Modus per Wischgeste; vorher wirkte der
  Button in allen anderen Fällen wirkungslos (GitHub #28).

## v0.6 (Build 79) — Geschäfte-Liste alphabetisch mit A-Z-Sprungleiste

- `GeschaeftListView` gruppiert die Geschäfte jetzt nach Anfangsbuchstaben
  (analog zur Artikelauswahl aus #8) — bei vielen Geschäften zeigt iOS dafür
  automatisch eine A–Z-Sprungleiste wie im Adressbuch (GitHub #29).

## v0.6 (Build 78) — Preisübersicht: eigener View, Diagramm, Einzelpreis löschen

- **`GeschaeftPreisUebersichtView`** (neu, GitHub #20): die Preisübersicht eines
  Geschäfts (Preisspanne je Artikel + Positionen ohne Artikel-Zuordnung) ist
  jetzt ein eigener View statt zwei Sektionen direkt in `GeschaeftDetailView`
  — aufrufbar über einen neuen „Preisübersicht“-Eintrag dort.
- **`ArtikelPreisVerlaufView`** (GitHub #21): zeigt den Preisverlauf eines
  Artikels in einem Geschäft jetzt zusätzlich als `Charts`-Liniendiagramm
  (chronologisch aufsteigend, nur bei mindestens einem erfassten Preis).
  Einzelne Positionen lassen sich per Standard-Wischgeste (`.onDelete`)
  dauerhaft löschen — z.B. bei einer offensichtlich falsch erfassten Position,
  die die Preisspanne verzerrt.
- `ArtikelPreisSpanneZeile`/`ArtikelPreisVerlaufView` sind dafür aus
  `GeschaeftDetailView.swift` in die neue Datei umgezogen.
- Nur per Build + Unit-Tests verifiziert, ohne manuellen Simulator-Durchlauf
  (siehe `ios-swift-engineering`-Skill, „Simulator-UI-Tests … optional“).

## v0.6 (Build 77) — Artikelauswahl: kompakter, alphabetisch, Sofort-Hinzufügen

- `ArtikelHinzufuegenView` grundlegend überarbeitet (GitHub #8):
  - **Sofort-Hinzufügen**: ein Tap auf einen Artikel fügt ihn direkt zur
    Einkaufsliste hinzu, statt ihn nur auszuwählen — das bisherige
    Mehrfachauswahl-Muster (markieren, dann per „Hinzufügen (N)“ übernehmen)
    entfällt vollständig, analog zum bereits bestehenden Verhalten neu
    angelegter Artikel (#6). Toolbar hat dafür nur noch einen „Fertig“-Button.
  - **Alphabetische Gruppierung**: Artikel erscheinen in Abschnitten nach
    Anfangsbuchstaben (``gruppierteArtikel``) — bei langen Listen zeigt iOS
    dafür automatisch eine A–Z-Sprungleiste wie im Adressbuch.
  - **Kompaktere Zeilen**: kleineres Kategorie-Icon, keine Kategorie-Unterzeile
    mehr, kein Auswahl-Indikator (entfällt mit dem Sofort-Hinzufügen).

## v0.6 (Build 76) — Belegscan: Geschäftserkennung über die Adresse

- **`Geschaeft.passendes(fuerErkannterName:erkannteAdresse:unter:)`** matcht
  jetzt auch **allein über die Adresse**, wenn der Name leer erkannt wurde
  oder zu keinem Geschäft passt — vorher lieferte die Funktion in diesem Fall
  sofort `nil`, ohne die Adresse überhaupt zu prüfen.
- **`BelegScanView.uebernehmen()`**: hat das zugeordnete Geschäft (automatisch
  oder manuell über `GeschaeftWahlSheet` gewählt) noch keine Adresse, wird die
  auf dem Beleg erkannte übernommen und geocodiert.
- **`GeschaeftWahlSheet`**: „neu anlegen“ bleibt jetzt auch bei einem exakt
  namensgleichen Geschäft verfügbar, sofern dessen Adresse von der erkannten
  abweicht — für eine zweite Filiale derselben Kette
  (``zweiteFilialeMoeglich``).
- GitHub #19.

## v0.6 (Build 75) — Kategorie-Editor zeigt zugeordnete Artikel

- `KategorieBearbeitenView` (Einstellungen → Kategorien → Kategorie antippen)
  zeigt jetzt eine Sektion „Artikel“ mit allen dieser Warengruppe
  zugeordneten Artikeln (``ArtikelKategorie/zugeordneteArtikel``) — per
  Wischgeste entfernbar, über die neue
  `ArtikelZuKategorieHinzufuegenSheet` (Suche + Sofort-Zuordnung beim
  Antippen) erweiterbar. Bislang musste man dafür jeden Artikel einzeln über
  `ArtikelEditView` öffnen (GitHub #15).

## v0.6 (Build 74) — Mengeneinheit im Mengen-Sheet änderbar

- `MengenNotizSheet` (Tap auf die Mengenangabe beim Einkaufen) bietet jetzt
  neben Menge und Notiz auch einen Picker für die Mengeneinheit an. Da
  ``Artikel/einheit`` (anders als Menge/Notiz) kein Feld von
  `EinkaufslistenEintrag` ist, wirkt sich eine Änderung hier wie in
  `ArtikelEditView` auf den Artikel insgesamt aus (GitHub #12).
- Nebenbei die Bedienungsanleitung korrigiert: sie beschrieb noch
  Tap/Doppel-Tap/Langes-Drücken-Gesten für die Menge, obwohl die App längst
  auf Wischgesten umgestellt ist (siehe #11) — jetzt aktualisiert.

## v0.6 (Build 73) — Geschäftstyp-Warengruppen: alphabetisch, Auswahl zuerst

- `GeschaeftsTypKategorienView` (neue `sortierteKategorien`-Property) zeigt die
  Warengruppen jetzt alphabetisch, mit den für den jeweiligen Geschäftstyp
  bereits ausgewählten zuerst — passt sich beim Umschalten sofort dynamisch
  an, statt fest nach `ArtikelKategorie.sortIndex` sortiert zu bleiben
  (GitHub #14).

## v0.6 (Build 72) — Belegscan: Preis-Markierung je Position korrigiert

- **`Array<ErkannteZeile>.boundingBox(fuerArtikelName:)`** (`ReceiptScanService.swift`):
  die umgekehrte Teilstring-Richtung (Artikelname enthält den OCR-Zeilentext)
  verlangt jetzt mindestens 3 Zeichen Zeilentext. Grund (GitHub #17): sehr
  kurze, generische OCR-Fragmente (einzelne Ziffern, Trennzeichen) matchten
  zuvor fast jeden Artikelnamen — `first { ... }` lieferte dadurch für jede
  Position dieselbe (meist erste) Zeile zurück, statt für jeden Preis die
  tatsächlich passende Stelle im Beleg-Foto zu markieren.

## v0.6 (Build 71) — Geschäftsname direkt neben dem Warenkorb-Icon

- `EinkaufslisteView` zeigte den Geschäftsnamen bislang als große Überschrift
  über der Liste (`.navigationTitle(geschaeft?.name ?? einkaufsliste.name)`),
  redundant zum bereits vorhandenen Geschäfts-Menü im `EinkaufenView`-Toolbar.
  Titel zeigt jetzt immer den Listennamen; das Menü daneben stellt Icon und
  Geschäftsname jetzt über ein explizites `HStack` statt `Label` dar, damit
  der Name zuverlässig sichtbar ist statt je nach Platz nur das Icon
  (GitHub #16).

## v0.6 (Build 70) — Belegscan-/Preisschild-Preise auf Cent gerundet

- **`Decimal.aufCentGerundet`** (neu, `Decimal+CentRundung.swift`): rundet
  über `NSDecimalRound` auf zwei Nachkommastellen. Grund: die lokale KI
  liefert bei Beleg-/Preisschild-Scans gelegentlich Preise mit
  Gleitkomma-Rundungsfehlern (z.B. `2.4900000000512` statt `2.49`), die
  bislang unverändert ins Bearbeiten-Textfeld übernommen wurden (GitHub #18).
  Angewandt in `BelegScanView` (`position.einzelpreis`) und
  `PreisschildScanView` (`ergebnis.preis`), jeweils direkt bei der Anzeige im
  editierbaren Preisfeld.

## v0.6 (Build 69) — Wischgeste zum Erhöhen ohne Bestätigung

- `ArtikelAbhakZeile` (`EinkaufenView.swift`): die Trailing-Swipe-Aktion
  „Menge erhöhen“ löst jetzt bei vollständigem Swipe direkt aus, analog zur
  bereits so funktionierenden Leading-Swipe-Aktion „Menge verringern“
  (GitHub #11). `allowsFullSwipe` ist jetzt an `dauerhaftEntfernen == nil`
  gekoppelt statt hart auf `false` — bei bereits abgehakten Artikeln (dort
  bietet dieselbe Trailing-Aktion zusätzlich destruktives „Dauerhaft
  entfernen“ an) bleibt die Sicherheitsbremse gegen versehentliches Löschen
  bei vollem Swipe bestehen.

## v0.6 (Build 68) — Geschäfte-Liste: NavigationLink vereinfacht

- `GeschaeftListView` nutzte für die Zeilen-Navigation das wertbasierte
  `NavigationLink(value:)` + `.navigationDestination(for: Geschaeft.self)` —
  umgestellt auf das im Rest der App übliche Closure-basierte
  `NavigationLink { GeschaeftDetailView(geschaeft:) }`. Grund: GitHub #13
  meldet, dass ein Tap auf ein Geschäft manchmal nicht zur Detailansicht
  navigiert. Die Navigation ließ sich im Simulator (einzelnes Geschäft,
  mehrere Geschäfte, direkt nach dem Anlegen, wiederholtes Antippen)
  durchgehend nicht reproduzieren — die Vereinfachung entfernt trotzdem eine
  Schicht (Hashable-basiertes Pfad-Matching), die in Edge-Cases fragiler ist
  als eine direkte Destination-Closure, und ist unabhängig vom Bug eine
  sinnvolle Angleichung an den Rest der Codebase.

## v0.6 (Build 67) — Geschäftstyp: Standard-Warengruppen

- **`ArtikelKategorie.geschaeftsTypen: [GeschaeftTyp]`** (neu): eine Kategorie
  kann als typische Warengruppe für einen oder mehrere Geschäftstypen markiert
  werden — verwaltet über die neue Einstellungen-Seite „Geschäftstypen“
  (`GeschaeftsTypenVerwaltungView`), inkl. optionalem KI-Vorschlag
  (`AISuggestionService.vorschlag(fuerGeschaeftsTyp:bekannteKategorien:)`,
  analog zum bestehenden Artikel-Kategorie-Vorschlag).
- **`Geschaeft.verfuegbareKategorien(alleKategorien:)`** (neu): ergänzt die
  bisherige, rein manuelle `verfuegbareKategorien` um automatisch aus den
  Geschäftstypen abgeleitete Kategorien — ein Geschäft mit passendem Typ macht
  diese Warengruppen verfügbar, ganz ohne sie manuell zuzuordnen. Genutzt von
  `ArtikelVerfuegbarkeitService`, `Artikel.fuehrendeKategorie` und
  `KategorieHinzufuegenSheet`; die parameterlose Variante bleibt unverändert
  für die rein manuelle Verwaltung in `GeschaeftDetailView` (Entfernen einer
  Kategorie darf nur dort greifen, wo sie tatsächlich zugeordnet ist).
- Migration rein additiv (`geschaeftsTypenRaw: [String]?`), keine neue
  `SchemaVN`/`MigrationStage` nötig.
- GitHub #5, Teilumsetzung: die Apple-Maps-Typerkennung beim Anlegen eines
  Geschäfts (`GeschaeftErkennungService.typVorschlag`) gab es bereits; die
  automatische Warengruppen-Vorfilterung beim Einkaufen ganz ohne
  Geschäftsauswahl ist bewusst nicht enthalten (separates Folge-Ticket).

## v0.6 (Build 66) — Neu angelegter Artikel landet sofort auf der Einkaufsliste

- Legt der Nutzer in `ArtikelHinzufuegenView` (Einkaufsliste → „Artikel
  hinzufügen“ → unbekannten Namen neu anlegen) einen Artikel neu an, wird er
  jetzt sofort über `Einkaufsliste.artikelHinzufuegen` auf die aktuelle
  Einkaufsliste übernommen, statt nur in der Auswahl zu landen — kein
  zusätzlicher Tap auf „Hinzufügen“ mehr nötig (GitHub #6). Die
  Bedienungsanleitung beschrieb dieses Verhalten bereits, bevor es tatsächlich
  umgesetzt war; jetzt stimmen Doku und Implementierung überein.

## v0.6 (Build 65) — Artikel kann mehreren Warengruppen angehören

- **`Artikel.kategorien: [ArtikelKategorie]`** (neu) ersetzt die bisherige
  Einzelauswahl — ein Artikel kann jetzt mehreren Kategorien gleichzeitig
  angehören (z.B. „Süßigkeiten“ und „Geschenke“). `ArtikelEditView` bietet dafür
  eine Mehrfachauswahl-Liste statt des bisherigen Pickers.
- **`Artikel.fuehrendeKategorie(inGeschaeft:context:)`** (neu): hat ein Artikel
  mehrere Kategorien, gilt pro Geschäft **eine** als führend für Regal-Zuordnung/
  Gruppierung beim Einkaufen und für den Regal-Lernalgorithmus — kein Duplizieren
  des Artikels über mehrere Regal-Bereiche. Priorität: Kategorie mit
  Regal-Zuordnung im Geschäft > im Geschäft verfügbare Kategorie > erste
  zugeordnete Kategorie. Genutzt in `EinkaufenView`, `Einkaufsvorgang.artikelAbhaken`,
  `BelegScanView`/`PreisschildScanView`/`KaufEintragZuordnenSheet`.
  `ArtikelVerfuegbarkeitService.istVerfuegbar` prüft dagegen bewusst **alle**
  Kategorien (ODER-Verknüpfung, keine „führende“ Auswahl nötig).
- Migration rein additiv (`kategorienRaw`-Relationship + Fallback auf das
  unverändert bestehende `kategorie`-Feld), keine neue `SchemaVN`/`MigrationStage`
  nötig. `kategorie` bleibt als führende (erste) Kategorie synchron.

## v0.6 (Build 64) — Geschäft: mehrere Typen möglich

- **`Geschaeft.typen: [GeschaeftTyp]`** (neu) ersetzt die bisherige
  Einzelauswahl — ein Geschäft kann jetzt mehrere Typen gleichzeitig haben (z.B.
  Drogerie + Lebensmittel bei einem dm). `GeschaeftStammdatenEditView` bietet dafür
  eine Mehrfachauswahl-Liste statt des bisherigen Pickers.
- Migration rein additiv (`typenRaw: [String]?`, Fallback auf das unverändert
  bestehende `typ`-Feld) — keine neue `SchemaVN`/`MigrationStage` nötig, gleiches
  Muster wie `regalSortierModus`. `typ` bleibt als führender (erster) Typ
  synchron, u.a. für die Icon-Anzeige.

## v0.6 (Build 63) — Automatische Artikel-Zuordnung im Belegscan, Inline-Autocomplete, dauerhaftes Ignorieren

- **Dreistufige automatische Artikel-Zuordnung** (neuer `ArtikelZuordnungsService`):
  gelernter Alias → Teilstring-Abgleich → nur bei Erfolglosigkeit + verfügbarer
  lokaler KI ein KI-Best-Match (`AISuggestionService.artikelMatch`, exaktes Vorbild
  `kategorieMatch`). Jetzt konsistent für alle drei `BelegScanKontext`e beim
  Einlesen angewandt (`.einkaufsvorgang` bekam bislang gar keine
  Katalog-Zuordnung); ersetzt die alte, nur zwei Kontexte abdeckende und erst beim
  Speichern wirkende `passendesArtikel(fuer:)`.
- **Simultane Anzeige** von generischem Artikelnamen und Original-Beleg-Text in
  `PositionsZeile`, plus Status-Label „Wird verknüpft mit …“/„Neu erkannt“.
- **Inline-Autocomplete**: Tippen ins Artikelfeld zeigt passende vorhandene Artikel
  zum Antippen sowie eine „neu anlegen“-Option (`ArtikelEditView`, wie in
  `KaufEintragZuordnenSheet`) — direkt im Scan-Review, ohne separaten Bildschirm.
- **Dauerhaft ignorierte Artikel pro Geschäft** (neues Modell `IgnorierterArtikel`):
  Wischen nach rechts auf einer Position blendet sie künftig bei Scans desselben
  Geschäfts automatisch aus. Wischen nach links (Löschen) bleibt unverändert nur
  für diesen einen Scan.
- **`BearbeitbarePosition.effektivZugeordneterArtikel`** (neu): Single Source of
  Truth für „ist zugeordnet“ zwischen Anzeige und Speichern — verwirft die
  automatische Zuordnung rein reaktiv, sobald der Nutzer den Namen frei
  weiterbearbeitet, ohne neu auszuwählen.

## v0.6 (Build 62) — Eigener Scannen-Tab

- **Neuer dritter Tab „Scannen“** (`RootView`, zwischen „Einkaufen“ und
  „Einstellungen“) bettet `BelegScanView` dauerhaft ein (`istEigenerTab: true`,
  immer im geschäftslosen `.unbekannt`-Kontext) — zusätzlich zu, nicht anstelle
  der bisherigen vier Sheet-Einstiegspunkte (alle bleiben unverändert bestehen,
  Nutzer-Entscheidung).
- **`BelegScanView.istEigenerTab`** (neu, Default `false`): Als Tab-Inhalt gibt es
  keine Präsentation, die `@Environment(\.dismiss)` schließen könnte — „Verwerfen“
  (ersetzt „Abbrechen“ im Tab-Kontext) und erfolgreiches Übernehmen setzen
  stattdessen über die neue `zuruecksetzen()` den kompletten Scan-Zustand zurück,
  der Tab ist danach sofort wieder bereit für den nächsten Scan.

## v0.6 (Build 61) — Belegscan: Abbrechen ohne Rückfrage, Beleg inline, Bounding-Box-Fix

- **Abbrechen ohne Rückfrage:** Der „Scan verwerfen?“-`confirmationDialog` beim
  Antippen von „Abbrechen“ in `BelegScanView` ist entfernt — schließt jetzt immer
  sofort.
- **Beleg inline statt eigener Bildschirm:** `ZoombareBildAnsicht` (Original-Foto,
  zoom-/schwenkbar) erscheint jetzt direkt als erste Section in `ErgebnisListe`,
  kein `.fullScreenCover`/Button „Beleg anzeigen“ mehr. `ZoombareBildAnsicht` wurde
  dafür von seiner bisherigen `NavigationStack`/Toolbar-Chrome befreit; die
  Zieh-Geste greift jetzt nur bei aktivem Zoom, damit das Scrollen der Liste bei
  Zoom 1 nicht blockiert wird. Das Lupen-Symbol je Position scrollt jetzt per
  `ScrollViewReader` zur Vorschau hoch, statt eine eigene Ansicht zu öffnen.
- **Bugfix: Bounding Boxes passten nicht zum Foto.** `VNImageRequestHandler` in
  `ReceiptScanService.erkenneText` berücksichtigte `UIImage.imageOrientation`
  nicht — Kamerafotos mit Rotations-Metadaten (statt physisch gedrehter Pixel)
  führten zu falsch positionierten Markierungen. Fix: `CGImagePropertyOrientation`
  aus `imageOrientation` ableiten und an Vision übergeben.

## v0.6 (Build 60) — Belegscan: Originalfoto zoombar prüfen

- **Neu: Originalbeleg anzeigen** (GitHub #2): In der Ergebnis-Prüfung nach einem
  Belegscan lässt sich über „Beleg anzeigen“ das Original-Foto in einer neuen
  zoombaren Vollbildansicht (`ZoombareBildAnsicht`, Pinch-to-Zoom + Schwenken)
  prüfen. Je Position mit eindeutig zuordenbarer OCR-Zeile öffnet ein
  Lupen-Symbol dieselbe Ansicht mit einer Markierung der erkannten Stelle —
  hilft, die KI-Erkennung visuell zu verifizieren. Kein automatisches
  Heran-Zoomen (bewusste Vereinfachung), das Foto wird ausschließlich in-memory
  für die Dauer der Prüfung gehalten, nie gespeichert.
- **`ReceiptScanService`**: OCR-Zeilen (`ErkannteZeile`) behalten jetzt ihre
  Position im Bild (Vision-Bounding-Box) statt nur den reinen Text — Grundlage für
  die neue Markierung.
- Details in `docs/BELEGSCAN.md`.

## v0.6 (Build 59) — App startet direkt mit der Einkaufsliste

- **`RootView`**: Nur noch zwei Tabs, „Einkaufen“ (immer der Start-Tab) und
  „Einstellungen“ — die bisherigen „Artikel“- und „Geschäfte“-Tabs entfallen
  (GitHub #1).
- **`SettingsView`**: neuer Eintrag „Artikel“ (analog zum bereits bestehenden
  „Geschäfte“-Eintrag) — beide verlinken direkt auf `ArtikelListView`/
  `GeschaeftListView`, die dafür jetzt konsistent keinen eigenen `NavigationStack`
  mehr anlegen, sondern den der Einstellungen nutzen.
- Bedienungsanleitung, In-App-Hilfe und Produktspezifikation an die neue
  Navigation angepasst (keine „Artikel-Tab“/„Geschäfte-Tab“-Verweise mehr).

## v0.6 (Build 58) — Belegscan: „Abbrechen“ statt „Fertig“, Rückfrage vor Verwerfen

- **`BelegScanView`/`PreisschildScanView`**: Der bisherige „Fertig“-Button in der
  Toolbar war irreführend benannt — er hat schon immer nur den Scan verworfen
  (`dismiss()`, kein Speichern), was für Anwender nicht von „Preise übernehmen“/
  „Preis übernehmen“ zu unterscheiden war (GitHub #3). Jetzt heißt er „Abbrechen“;
  sind bereits Positionen zur Prüfung vorhanden, fragt eine Bestätigung
  („Scan verwerfen?“) nach, bevor sie verloren gehen. In der reinen
  Aufnahme-Ansicht (noch nichts erkannt) bricht „Abbrechen“ weiterhin sofort ab.

## v0.6 (Build 57) — MilkForUs-Textimport (Datei-Import + Share Extension)

- **Neu: MilkForUs-Textimport** (`MilkForUsImportService`, `MilkForUsImportView`):
  importiert eine aus der Shopping-App "MilkForUs" exportierte Textdatei (Kategorien
  + Artikel) auf eine gewählte Einkaufsliste. Kategorie-Abgleich per exaktem
  Namenstreffer, sonst KI-Best-Match gegen den bestehenden Kategoriebestand (z.B.
  "Brot" → "Brot & Backwaren"), sonst Vorschlag zur Neuanlage — in der Vorschau pro
  Kategorie umstellbar auf eine andere bestehende Kategorie oder "Sonstiges".
  Bestehende Artikel gleicher Namen werden nur auf die Liste gesetzt, nie dupliziert.
  Einstiegspunkt: „MilkForUs importieren“ in der Einkaufslisten-Verwaltung.
- **Neu: `ShopWithMeShareExtension`** — dieselbe Import-Vorschau lässt sich jetzt auch
  direkt über die iOS-Teilen-Funktion anstoßen (z.B. eine per Chat empfangene
  MilkForUs-Datei). Die Extension selbst hat keinen Zugriff auf den SwiftData-Store,
  sie übergibt den geteilten Text nur über eine App-Group-Containerdatei an die
  Haupt-App, die den Import wie gewohnt öffnet (`shopwithme://milkforus-import`).
- Details, Ablauf und bewusste Einschränkungen in `docs/MILKFORUS_IMPORT.md`.

## v0.6 (Build 55) — Bedienungsanleitung eingeführt, Build-Workflow-Doku-Duplikat aufgelöst

- **Neu: `docs/BEDIENUNGSANLEITUNG.md`** — kompakte End-Nutzer-Anleitung, ein
  Abschnitt je Funktionsbereich. Maßgeblich gegenüber der kuratierten In-App-Hilfe
  (`HelpView.swift`). `README.md` verlinkt jetzt zusätzlich darauf sowie auf
  `docs/CHANGELOG.md`.
- **Skill-Aufräumung:** Die „Checkpoint-/Versionierungs-Workflow“-Sektion im
  projekteigenen Claude-Skill (`shopwithme-conventions`) duplizierte fast wortgleich
  `docs/BUILD_WORKFLOW.md` — jetzt aufgelöst, `docs/BUILD_WORKFLOW.md` bleibt die
  einzige maßgebliche Quelle, der Skill verweist nur noch darauf.
- **Neue generische Skill-Regel** (`ios-swift-engineering`): Nutzer-Bedienungsanleitungen
  werden künftig bei jedem Feature/jeder sichtbaren Funktionsänderung im selben
  Arbeitsschritt mitgepflegt, nicht nachträglich.

## v0.6 (Build 54) — Geschäftsadresse beim Belegscan erkennen, Kurzadresse bei Namensduplikaten

- **`ReceiptScanService`**: `BelegErgebnis` erkennt jetzt zusätzlich zum Namen auch
  die Adresse des Geschäfts vom Kassenbon (`geschaeftAdresse`).
- **`Geschaeft.passendes(fuerErkannterName:erkannteAdresse:unter:)`**: gibt es zum
  erkannten Namen mehrere Geschäfte (z.B. zwei Filialen derselben Kette), wird die
  erkannte Adresse automatisch als Tie-Breaker genutzt — ohne Rückfrage. Bleibt die
  Zuordnung mehrdeutig, Fallback auf den ersten Namens-Kandidaten wie bisher.
- **„neu anlegen“ in `GeschaeftWahlSheet`**: übernimmt jetzt automatisch die
  erkannte Adresse und geocodiert sie sofort zu Koordinaten
  (`GeschaeftErkennungService.koordinaten(fuerAdresse:)`) — bewusst nicht der
  aktuelle GPS-Standort des Anwenders.
- **Kurzadresse bei Namensduplikaten** (`Geschaeft.kurzeAdresse`,
  `Geschaeft.namenMitDuplikaten(unter:)`): `GeschaeftWahlSheet` und
  `GeschaeftListView` zeigen unter dem Namen zusätzlich die Adresse (Straße + Ort,
  ohne PLZ) in kleiner Schrift — nur bei tatsächlich namensgleichen Geschäften.

## v0.6 (Build 53) — Standort nachträglich für ein bereits genutztes Geschäft ergänzen

- **Nachfrage beim Auswählen eines Geschäfts ohne Koordinaten** (`EinkaufenView`,
  siehe `docs/GESCHAEFTSERKENNUNG.md`): „Aktuellen Standort verwenden“ oder
  „Adresse eingeben“ (neues `AdresseEingebenSheet`, geocodiert per
  `GeschaeftErkennungService.koordinaten(fuerAdresse:)`) — bzw. bei bereits
  hinterlegter Adresse „Aktuelle Position verwenden“ oder „Aus hinterlegter Adresse
  ermitteln“. Betrifft Geschäfte, die ohne Standortbezug angelegt wurden (z.B. über
  „Neues Geschäft hinzufügen“ oder beim Belegscan neu angelegt) und damit bislang
  dauerhaft unsichtbar für die automatische Ladenerkennung blieben.
- **`GeschaeftErkennungService.koordinaten(fuerAdresse:)`** (neu) nutzt
  `MKGeocodingRequest` (MapKit) statt des seit iOS 26 deprecateten `CLGeocoder`.
- **`GeschaeftErkennungService.koordinatenAusAktuellerPosition()`** (neu): dünner
  Wrapper um dieselbe private Standort-Hilfsfunktion wie
  `entwurfAusAktuellemStandort()` (dafür intern extrahiert), für die Verwendung an
  einem bereits bestehenden `Geschaeft`.
- `Geschaeft.adresse` bleibt bewusst optional — keine neue Pflichtangabe, nur
  opportunistisch über diese Nachfrage eingesammelt.

## v0.6 (Build 52) — Neues Geschäft ohne Apple-Maps-Treffer am aktuellen Ort protokollieren

- **`GeschaeftErkennungService.entwurfAusAktuellemStandort()`** (neu): baut einen
  leeren `Geschaeft`-Entwurf mit den Koordinaten des aktuellen Standorts, ganz ohne
  `MKMapItem` — für den Fall, dass Apple Maps den Laden nicht kennt.
- **Leer-Zustand „Keine Geschäfte gefunden“** in `GeschaeftAlleInDerNaeheSheet`
  (siehe `docs/GESCHAEFTSERKENNUNG.md`) bekommt einen Button „Diesen Ort als neues
  Geschäft anlegen“, der darüber den bestehenden `GeschaeftStammdatenEditView`-Anlage-
  Flow mit bereits gesetzten Koordinaten öffnet — die vorher nur standortunabhängig
  verfügbare manuelle Anlage funktioniert damit jetzt auch direkt am erkannten Ort,
  inkl. Koordinaten für künftiges Matching. Schlägt die Standortermittlung fehl, zeigt
  ein Alert statt eines stillen No-Ops.

## v0.6 (Build 51) — Release-Review: Matching-Logik konsolidiert, zwei Bugs behoben

Review vor dem Minor-Bump auf v0.6 (siehe `docs/RELEASE_CHECKLIST.md`) deckte zwei
echte Bugs in der v0.5-Ladenerkennung auf, beide jetzt behoben:

- **`GeschaeftErkennungService`**: `istBekannterTreffer(_:fuer:)`,
  `istIgnoriert(_:ignorierte:)`, `istSelberLaden(_:_:)` (Dedup) und
  `ignorierteEintraege(fuer:in:)` teilten sich vier fast identische Namens-/
  Koordinaten-Matching-Implementierungen, die dabei leicht auseinandergelaufen
  waren — nur `istBekannterTreffer` prüfte Namens-Teilstrings (z.B. Apple-Maps-
  „REWE“ vs. „Rewe am Markt“), die anderen drei nur exakte Gleichheit. Auf eine
  gemeinsame `istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:)` konsolidiert.
- **Bug behoben**: dadurch konnte ein manuell angelegtes Geschäft ohne gespeicherte
  Koordinaten nicht mit einem abweichend benannten Apple-Maps-Treffer für denselben
  Laden dedupliziert werden — „Alle Geschäfte in der Nähe“ listete ihn doppelt.
  Neuer Test `dedupliziertBekanntenTrefferOhneKoordinatenGegenUnbekanntenPerNamensTeilstring`.
- **Bug behoben**: „Wieder aufnehmen“ in `GeschaeftAlleInDerNaeheSheet` aktualisierte
  den lokal einmalig geladenen (`.task`, kein Live-`@Query`) Ignoriert-Status nicht —
  die Zeile blieb bis zum erneuten Öffnen fälschlich auf „Ignoriert“ stehen.
  `GeschaeftInDerNaeheEintrag.istIgnoriert` ist jetzt `var`, optimistisches lokales
  Update direkt nach dem Tap.
- `GeschaeftVorschlag.aktionsTitel` (neu) ersetzt zwei identische
  `aktionsTitel`-Computed-Properties in `GeschaeftVorschlagBanner` und
  `GeschaeftInDerNaeheZeile`.
- Dokumentationsabgleich (`ARCHITECTURE.md`, `ROADMAP.md`, `PRODUCT_SPEC.md`) für
  den gesamten v0.5-Zyklus, u.a. das veraltete „Standortbezug (zukünftig)“-Kapitel
  in `PRODUCT_SPEC.md` (Standort-basierte Ladenerkennung ist längst umgesetzt).

## v0.5 (Build 50) — Suchradius im Debug-Build testweise überschreibbar

- **`DebugEinstellungen`/`DebugEinstellungenView`** (neu, beide nur `#if DEBUG`):
  neuer Eintrag „Debug-Einstellungen“ in `SettingsView` (ebenfalls `#if DEBUG`)
  erlaubt es, den Suchradius von `GeschaeftErkennungService` (automatischer
  Einzelvorschlag + „Alle Geschäfte in der Nähe“) testweise auf 100–5000m zu
  erhöhen, ohne echte Nähe zu einem Apple-Maps-Laden zu benötigen.
  `suchradius`/`alleInDerNaeheRadius` sind dafür von `static let` zu `static var`
  geworden: in Debug-Builds `DebugEinstellungen.sucheRadiusUeberschreibung ??
  standardXYZ`, in Release-Builds unbedingt der feste Standardwert (150m/100m) —
  die Überschreibung ist in einem Release-Build gar nicht Teil des Binaries.

## v0.5 (Build 49) — Manuelles Geschäft-Hinzufügen im Einkaufen-Tab

- **„Neues Geschäft hinzufügen“** ergänzt im Geschäft-Menü (Toolbar, `EinkaufenView`):
  öffnet über einen leeren `Geschaeft`-Entwurf denselben
  `GeschaeftStammdatenEditView`-Anlage-Flow wie der Standort-Vorschlag, unabhängig von
  Standortberechtigung/Apple-Maps-Treffern — die automatische Ladenerkennung bleibt
  damit immer nur eine Ergänzung, nie der einzige Weg, ein Geschäft anzulegen.

## v0.5 (Build 48) — Duplikate in „Alle Geschäfte in der Nähe“ behoben

- **`GeschaeftErkennungService.dedupliziert(_:)`** (neu): Apple Maps liefert für
  denselben physischen Laden gelegentlich mehrere `MKMapItem`-Treffer — dadurch
  erschien z.B. ein ignoriertes Geschäft doppelt in der Liste „Alle Geschäfte in der
  Nähe“. `alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)` dedupliziert
  jetzt am Ende: gleiches `Geschaeft` bei zwei `.bekannt`-Treffern, sonst Namens- ODER
  Koordinatenübereinstimmung. `internal` statt `private`, direkt getestet.

## v0.5 (Build 47) — Verfügbarkeitsfilter direkt im Einkauf statt als Geschäfts-Einstellung

- **`Geschaeft.artikelFilterModus`/`ArtikelFilterModus` entfernt**: die Entscheidung
  „nur verfügbare Artikel“ vs. „alle Artikel“ war bislang eine persistente
  Geschäfts-Einstellung in `GeschaeftDetailView` — redundant, da der Anwender genau
  diese Entscheidung ohnehin bei Bedarf direkt beim Einkaufen trifft. Stattdessen neuer
  Umschalter (Listen-Icon) neben „Auch abgehakte Artikel“ in `EinkaufenView` — blendet
  für den laufenden Einkauf alle Artikel der Einkaufsliste ein, auch nicht als
  verfügbar geltende, unabhängig vom Verfügbarkeitsfilter. `ArtikelVerfuegbarkeitService`
  bleibt unverändert (weiterhin Grundlage der Verfügbarkeitsermittlung selbst).
- **Schnellauswahl statt drei Einzel-Buttons**: die vorherigen drei separaten
  Anzeige-Buttons in `EinkaufenView` sind zu einem einzigen `SchnellauswahlButton` in
  der Toolbar verschmolzen (neben „Artikel hinzufügen“, statt unten neben „Einkauf
  abschließen“): kurzer Tap schaltet zwischen „Nur offene“/„Auch abgehakte Artikel“
  um, langer Tap öffnet ein Menü zum Umschalten des Lernmodus (alle Artikel
  anzeigen). Implementiert über `Menu(primaryAction:)` statt `Button` +
  `.contextMenu` — Letzteres löste den langen Tap nicht zuverlässig aus, da der
  `.glass`-Stil ein `PrimitiveButtonStyle` mit eigener Gestenerkennung ist. „Einkauf
  abschließen“ nutzt jetzt `.buttonStyle(.glassProminent)`.
- **Standort-Vorschlag: „Ignorieren“ und „Alle Geschäfte in der Nähe“** (siehe
  `docs/GESCHAEFTSERKENNUNG.md`): neues Modell `IgnorierterGeschaeftsVorschlag`
  (additiv zu `SchemaV1.models`) merkt sich dauerhaft ignorierte
  Standort-Vorschläge. `GeschaeftVorschlagBanner` bekommt dafür ein „…“-Menü
  (Verwerfen/Ignorieren/Alle Geschäfte in der Nähe…). Neues
  `GeschaeftAlleInDerNaeheSheet` zeigt alle Läden im 100m-Radius
  (`GeschaeftErkennungService.alleInDerNaeheRadius`, enger als der 150m-Radius des
  automatischen Einzelvorschlags), inkl. ignorierter mit „Wieder aufnehmen“-Option —
  erreichbar über das Banner-Menü sowie dauerhaft über das Geschäft-Menü in der
  Toolbar.

## v0.5 (Build 42) — Standort-basierte Ladenerkennung, Geschäftsverwaltung, Preishistorie-Kaskade

- **`GeschaeftErkennungService`** (`Services/GeschaeftErkennungService.swift`, neu):
  erkennt per einmaliger Standortabfrage (`NSLocationWhenInUseUsageDescription`, kein
  Hintergrund-Tracking) und `MKLocalPointsOfInterestRequest`, ob sich der Nutzer in
  der Nähe eines bekannten Ladens (Apple Maps) befindet. `EinkaufenView` zeigt dafür
  ein neues `GeschaeftVorschlagBanner`, sobald sie geöffnet wird — nur, wenn
  tatsächlich ein relevanter Laden in der Nähe erkannt wurde (z.B. nicht zu Hause).
  Ein bereits angelegtes Geschäft lässt sich direkt übernehmen; ein noch unbekannter
  Laden lässt sich über den bestehenden `GeschaeftStammdatenEditView`-Anlage-Flow
  (neuer optionaler `onGespeichert`-Callback) mit vorausgefüllten Stammdaten
  hinzufügen. Details in `docs/GESCHAEFTSERKENNUNG.md`.
- **Geschäftsverwaltung in den Einstellungen**: neuer „Geschäfte“-Eintrag in
  `SettingsView`, verlinkt auf dieselbe `GeschaeftListView` wie der gleichnamige Tab
  (Bearbeiten/Anlegen/Löschen war dort bereits vorhanden). Dafür verliert
  `GeschaeftListView` ihren eigenen `NavigationStack` (verschachtelte
  `NavigationStack`s vermeiden) — `RootView` umschließt den Tab jetzt selbst damit.
- **Löschen eines Geschäfts löscht jetzt auch seine Preishistorie**: neue
  `@Relationship(deleteRule: .cascade, inverse: \KaufEintrag.geschaeft)` an
  `Geschaeft.kaufEintraege` — vorher blieben zugehörige `KaufEintrag`e beim Löschen
  eines Geschäfts verwaist bestehen.
- **Preisschild-Scan** (`Services/PriceTagScanService.swift`,
  `Views/Einkaufen/PreisschildScanView.swift`, neu): fotografiert ein einzelnes
  Regal-Preisschild (Vision-OCR + FoundationModels, dasselbe Muster wie der
  Belegscan) und legt Artikelname + Verkaufspreis direkt als `KaufEintrag` mit
  heutigem Datum an — unabhängig vom tatsächlichen Kauf, z.B. zum Preisvergleich vor
  der Kaufentscheidung. Neuer Button „Preisschild scannen“ in
  `GeschaeftDetailView` neben „Kaufbeleg scannen“. Details, Abgrenzung zum Belegscan
  und das noch nicht umgesetzte Regal-Mehrfach-Scan-Konzept in
  `docs/PREISSCHILD_SCAN.md`.
- **Automatischer Geschäfts-Abgleich beim Belegscan**: neues
  `Geschaeft.alternativeNamen: [String]` + `Geschaeft.passendes(fuerErkannterName:unter:)`
  ordnen einen aus einem Beleg erkannten Geschäftsnamen automatisch einem
  bekannten Geschäft zu — relevant, wenn ohne vorherige Geschäftswahl gescannt
  wird (z.B. nachträglich zuhause). Ohne Treffer fragt das neue `GeschaeftWahlSheet`
  nach (mit Möglichkeit, direkt ein neues Geschäft anzulegen);
  `Geschaeft.alternativenNamenLernen(_:)` merkt sich den erkannten Namen danach als
  Alias für künftige Scans. Neuer geschäftsloser Beleg-Scan-Einstieg (Toolbar-Button
  „Beleg scannen“ in `GeschaeftListView`) sowie neue Scan-Buttons (Beleg +
  Preisschild) direkt in `EinkaufenView`, sobald dort ein Geschäft gewählt ist. Ein
  `Einkaufsvorgang` ohne gewähltes Geschäft übernimmt das erkannte/gewählte
  Geschäft rückwirkend. Der Preisschild-Scan bleibt bewusst ohne geschäftslosen
  Einstieg (funktioniert immer nur direkt für ein bereits feststehendes Geschäft —
  ein Preisschild zeigt so gut wie nie den Geschäftsnamen). Details in
  `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“ und
  `docs/PREISSCHILD_SCAN.md` → „Kein geschäftsloser Einstieg“.
- **`docs/RELEASE_CHECKLIST.md`** (neu): gestaffelte Release-Checkliste für
  Minor-/Major-Versionssprünge (Code-Review, Security-Check, Build/Tests,
  Migrationscheck, Doku-Abgleich bei jedem Bump; zusätzlich voller
  Security-Review, Regressionstest, Accessibility-Vollcheck,
  App-Store/TestFlight-Vorbereitung nur bei Major-Bumps). Details siehe
  `docs/BUILD_WORKFLOW.md`.
- **`MKMapItem.placemark`-Deprecation behoben**: `GeschaeftErkennungService`
  nutzt jetzt die seit iOS 26 aktuelle `MKMapItem`-API (`location`,
  `address?.fullAddress`) statt des deprecated `placemark`.

## v0.4 (Build 40) — Automatische Bereinigung der Preishistorie

- **`PreisHistorieBereinigungService`** (`Services/PreisHistorieBereinigungService.swift`):
  löscht `KaufEintrag`e, die älter als eine vom Nutzer wählbare Aufbewahrungsfrist
  (30 Tage / 3 Monate / 6 Monate / 1 Jahr / eigene Anzahl Tage / „Nie“, Standard: „Nie“)
  sind. Läuft automatisch bei App-Start und beim Zurückkehren aus dem Hintergrund
  (`RootView`, mit 24h-Mindestintervall) sowie manuell über einen Button. Einträge
  eines noch nicht abgeschlossenen `Einkaufsvorgang`s bleiben davon immer unberührt.
- **`PreisHistorieSettingsView`** (`Views/Einstellungen/PreisHistorieSettingsView.swift`):
  neuer Einstellungen-Bildschirm zur Wahl der Aufbewahrungsfrist, zeigt Zeitpunkt der
  letzten Bereinigung und erlaubt manuelles Anstoßen.
- Details siehe `docs/PREISHISTORIE_BEREINIGUNG.md`.

## v0.3 (Build 38) — Artikel hinzufügen: Mehrfachauswahl

- **`ArtikelHinzufuegenView` neu gestaltet** (`Views/Einkaufen/ArtikelHinzufuegenView.swift`):
  ein Tap auf einen ganzen Artikeleintrag wählt ihn aus bzw. hebt die Auswahl wieder
  auf (gefüllter Haken statt leerem Kreis, Zeile farblich hervorgehoben); mehrere
  Artikel lassen sich so nacheinander markieren und erst über den Toolbar-Button
  "Hinzufügen (n)" gemeinsam auf die Einkaufsliste übernommen. "Abbrechen" verwirft
  die gesamte Auswahl. Artikel, die bereits auf der Liste stehen, zeigen statt der
  Auswahlmöglichkeit einen "Auf Liste"-Hinweis. Zeilen bekommen außerdem das
  Kategorie-Icon/Farbe über den gemeinsamen `GlassSymbolBadge`-Baustein.
- **Direktanlage landet jetzt in der Auswahl statt sofort zu committen**: legt man
  über "„X“ neu anlegen" einen neuen Artikel an, wird er nach dem Sichern automatisch
  ausgewählt (statt die Liste sofort zu schließen) — man kann direkt weitere Artikel
  dazu auswählen, bevor gemeinsam auf "Hinzufügen" getippt wird.
- **Bugfix beim Zusammenspiel mit `.sheet(item:)`**: SwiftUI setzt die an ein
  `sheet(item:)` gebundene Property bereits vor dem Aufruf von `onDismiss` auf `nil`
  zurück — das bisherige `nachNeuanlageAufraeumen` griff dadurch auf ein bereits
  geleertes Optional zu und der neu angelegte Artikel ging beim automatischen
  Übernehmen verloren. Behoben über eine separate, vom Sheet-Binding unabhängige
  Referenz auf den zuletzt angelegten Entwurf.

## v0.2 (Build 36) — Mehrere Einkaufslisten, Kategorien-Verwaltung, Artikel nach Kategorie sortierbar

- **Mehrere Einkaufslisten** (`Models/Einkaufsliste.swift`, `Models/EinkaufslistenEintrag.swift`):
  der Nutzer kann beliebig viele benannte Listen anlegen und beim Einkaufen auswählen,
  welche gerade genutzt wird — Menge/temporäre Notiz sind je Liste eigenständig, ein
  Artikel kann gleichzeitig auf mehreren Listen stehen. Ersetzt das bisherige globale
  `Artikel.istAufEinkaufsliste`/`menge`/`einkaufslistenNotiz`. `EinkaufenView` bekommt
  dafür einen zweiten Menü-Picker samt Schnellanlage; volle Verwaltung (Umbenennen/
  Löschen) über `EinkaufslistenVerwaltungView` in den Einstellungen. Details in
  `docs/EINKAUFSLISTEN.md`.
- **Kategorien-Verwaltung** (`KategorienVerwaltungView`, neu in den Einstellungen):
  Kategorien umbenennen, Symbol/Farbe ändern, Reihenfolge per Drag-Handle anpassen,
  anlegen/löschen — analog zur neuen Listen-Verwaltung. `ArtikelEditView` bekommt
  dafür ebenfalls eine "Neue Kategorie anlegen"-Schnellaktion.
- **Artikel-Liste nach Kategorie sortierbar** (`ArtikelListView`): Menü-Picker
  "Alphabetisch"/"Nach Kategorie" oben links, analog zur Einkaufsliste gruppiert und
  nach `ArtikelKategorie.sortIndex` sortiert.

## v0.2 (Build 35) — Einkaufsliste: Kategorie-Icon/Farbe, Sektions-Zähler, Menge vor der Checkbox

- **Kategorie-Icon/Farbe wieder sichtbar, jetzt in der Einkaufsliste** (`EinkaufenView`):
  jede Zeile zeigt ein `GlassSymbolBadge` mit `ArtikelKategorie.standardSymbol`/
  `standardFarbeHex` der effektiven Kategorie des Artikels (``Artikel/effektiveKategorie(context:)``) —
  die Felder existierten bereits am Modell, waren zuletzt aber in keiner Ansicht mehr
  zu sehen.
- **Sektions-Titel mit Zähler**: neue `EinkaufslistenSektionHeader`-Kopfzeile zeigt
  bei Regal- wie Kategorie-Sektionen `abgehakt/gesamt` an; bei Kategorie-Sektionen
  zusätzlich das Kategorie-Icon (Regal-Sektionen bleiben ohne Icon, da ein Regal
  mehrere Kategorien bündeln kann).
- **Zeilen-Layout überarbeitet**: unter dem Artikelnamen steht nur noch die
  optionale `einkaufslistenNotiz` des Nutzers (keine Mengenangabe mehr); Menge +
  Einheit stehen jetzt rechts direkt vor der Abhak-Checkbox.
- **Automatischer Wechsel zum nächsten Einkauf**: `EinkaufenView` reagiert jetzt per
  `onChange` auf die Anzahl offener `Einkaufsvorgang`e und legt sofort einen neuen
  an, sobald der aktuelle abgeschlossen wird — die abgehakten Artikel des beendeten
  Einkaufs verschwinden dadurch unmittelbar aus der Ansicht, statt bis zum nächsten
  Tab-Wechsel als leere `ProgressView` hängen zu bleiben.

## v0.2 (Build 33) — Artikel: automatische KI-Kategorie, Menge & Einheit, kein Icon/Farbe mehr

- **KI-Kategorie automatisch statt Button**: `ArtikelEditView` bestimmt die Kategorie
  eines neuen Artikels jetzt automatisch (entprellt per `.task(id: artikel.name)`),
  sobald Apple Intelligence verfügbar ist und noch keine Kategorie gesetzt wurde —
  kein manueller "Mit Apple Intelligence vorschlagen"-Button mehr.
  `AISuggestionService.ArtikelVorschlag` liefert entsprechend nur noch
  Kategorie-/Regalname (kein Symbol/Farbe mehr).
- **Kein Icon/keine Farbe mehr pro Artikel in der UI**: `Artikel.symbolName`/
  `farbeHex` bleiben als Modellfelder erhalten, werden aber in keiner Ansicht mehr
  angezeigt/editiert (Artikel-Tab, Einkaufsliste, Artikel-Suche, Preisübersicht,
  Belegscan-Zuordnung).
- **"Auf Einkaufsliste"-Toggle entfernt**: Artikel kommen nur noch automatisch auf
  die Liste, wenn sie aus der Einkaufsliste-Ansicht heraus (neu oder erneut)
  hinzugefügt werden (`Artikel.aufEinkaufslisteSetzen()`, neu).
- **Neue Attribute `Einheit`/`Menge`/`mengenSchritt`** (additiv-optional, keine neue
  Schema-Version): Einheit ist Stück, Kilogramm, Gramm, Liter oder Milliliter; die
  beim Anlegen festgelegte Standardmenge (`mengenSchritt`) dient als Schrittweite.
  `Einkaufsvorgang.artikelAbhaken` übernimmt die tatsächlich gewünschte Menge in den
  `KaufEintrag`.
- **Neue Einkaufslisten-Interaktion** (`EinkaufenView`): Abhaken nur noch über eine
  eigenständige Checkbox; ein Tap auf die Zeile erhöht die Menge um `mengenSchritt`,
  ein Doppel-Tap verringert sie (nie unter `mengenSchritt`), ein langer Druck öffnet
  ein neues `MengenNotizSheet` für exakte Menge + temporäre Notiz
  (`Artikel.einkaufslistenNotiz`).

## v0.2 (Build 31) — Belegscan: Artikel-Zuordnung, Preisübersicht + Mitlernen

- `KaufEintragZuordnenSheet` (neu, `Views/Historie/`): löst die bisherige
  Umbenennen-Alert ab — vergibt einen Alias (`KaufEintrag.alternativerName`) UND
  ordnet die Position einem übergreifenden `Artikel` zu, inkl. Neuanlage direkt im
  selben Dialog (`ArtikelEditView`, gleiches Muster wie `ArtikelHinzufuegenView`).
  Aufgerufen aus `PreisHistorieZeile` (Wisch-Aktion „Zuordnen“, jetzt überall statt
  nur in der Geschäfts-Ansicht).
- `Models/ArtikelPreisSpanne.swift` (neu): gruppiert `KaufEintrag`e nach `Artikel`
  und liefert je Preisspanne (min/max). `GeschaeftDetailView` zeigt statt der
  bisherigen flachen „Preishistorie“ jetzt eine „Preisübersicht“ pro Artikel; ein
  Antippen öffnet `ArtikelPreisVerlaufView` (Drill-down mit der historischen
  Kaufliste). Positionen ohne Artikel-Zuordnung erscheinen separat darunter.
- `KaufEintrag.gelernteZuordnung(fuerErkannterName:in:)` (neu): sucht den jüngsten
  historischen Eintrag mit passendem erkanntem Namen und gesetztem Alias.
  `BelegScanView` nutzt das beim Einlesen eines neuen Belegs, um bereits bekannte
  Produkte automatisch mit Alias vorzubelegen und dem gelernten `Artikel` zu
  verknüpfen — ohne dass der Nutzer erneut zuordnen muss.
- Architektur vollständig in `docs/BELEGSCAN.md` aktualisiert (Ablauf, Datenmodell,
  Preisübersicht, Mitlernen); `docs/ARCHITECTURE.md` entsprechend ergänzt.
- Neue Unit-Tests in `ModelTests.swift`: `gelernteZuordnung`-Matching (jüngster
  Treffer gewinnt, ignoriert Einträge ohne Alias/ohne passenden Namen) sowie
  `ArtikelPreisSpanne`-Gruppierung/Min-Max-Berechnung.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 36 Unit-Tests bestehen.

## v0.2 (Build 30) — Mehrbenutzerzugriff auf die Datenbank + DB-Debug-Logging

- `Services/DatabaseLeaseService.swift`: koordiniert Schreibzugriffe auf einen
  geteilten Fileshare-Ordner (Box Drive/OneDrive/Synology Drive/iCloud Drive)
  über eine `NSFileCoordinator`-basierte Lock-Datei. Micro-Lease für diskrete
  Einzelaktionen (Artikel abhaken, Löschen, Anlegen, Belegscan-Übernahme, …),
  Session-Lease (referenzgezählt, mit Heartbeat) für Bearbeitungs-Bildschirme
  (Geschäft/Regal/Kategorie, `Views/SessionLeaseGate.swift`). Details, gewählte
  Parameter und bekannte Grenzen in `docs/DATABASE_CONCURRENCY.md`.
- `ModelContext.autosaveEnabled = false`: alle Schreibzugriffe laufen jetzt über
  explizite, Lease-geschützte `save()`-Aufrufe statt über SwiftDatas implizites
  Autosave.
- `Einkaufsvorgang.artikelAbhaken`: Dedupe-Prüfung gegen doppelte `KaufEintrag`e
  bei seltenen Sync-Latenz-Kollisionen zwischen zwei Geräten.
- Optionaler, standardmäßig deaktivierter DB-Debug-Modus
  (`Services/DebugLogWriter.swift`, `Services/DatabaseDebugLogger.swift`,
  neue Einstellungen-Ansicht `DatabaseDebugSettingsView`) protokolliert
  Sync-/Lock-/Öffnen-/Speicher-Ereignisse lokal und im geteilten DB-Ordner, für
  die Auswertung nach einem künftigen Live-Test mit mehreren Geräten. Als
  projektweite Logging-Architektur in `docs/LOGGING.md` dokumentiert.
- Neue Tests: `DatabaseLeaseServiceTests`, `DebugLogWriterTests`, Dedupe-Test in
  `EinkaufsvorgangTests`.

## v0.2 (Build 29) — Belegscan-Doku konsolidiert

- `docs/BELEGSCAN_ALTERNATIVE_NAMEN.md` in eine neue, gemeinsame
  `docs/BELEGSCAN.md` überführt: beschreibt jetzt den kompletten Belegscan-Ablauf
  (OCR, KI-Extraktion, Übernahme in `KaufEintrag`, Preishistorie-Anzeige) inklusive
  des alternativen Anzeigenamens in einem Dokument statt in zwei getrennten. Verweise
  in `docs/ARCHITECTURE.md`, `Models/KaufEintrag.swift` und
  `Views/Historie/PreisHistorieZeile.swift` entsprechend angepasst.

## v0.2 (Build 28) — Belegscan: alternativer Anzeigename pro Kaufeintrag

- Neues optionales, additives Attribut `KaufEintrag.alternativerName`
  (`Models/KaufEintrag.swift`) sowie Computed-Property `KaufEintrag.anzeigeName`,
  das diesen Namen vor `produktName`/`artikel`/`artikelNameSnapshot` priorisiert.
  Keine neue `SchemaVN`/`MigrationStage` nötig (rein additiv-optional).
- `PreisHistorieZeile` zeigt jetzt `anzeigeName` statt die Priorisierung selbst
  nachzubilden und bietet in der Artikel-Spalte eine Wisch-Aktion „Umbenennen“
  (Alert mit Texteingabe, inkl. „Zurücksetzen“) zum dauerhaften Vergeben/Löschen
  eines alternativen Namens pro Position.
- Architektur/Design-Entscheidungen dazu neu dokumentiert in
  `docs/BELEGSCAN_ALTERNATIVE_NAMEN.md`, verlinkt aus `docs/ARCHITECTURE.md`.

## v0.2 (Build 25) — Kategorien wichtiger als Regale: Versions-Checkpoint

- Minor-Version auf `0.2` angehoben (Nutzervorgabe) — der bisherige `v0.1`-Zyklus
  (Build 17–24) ist damit abgeschlossen. Alle Änderungen dieses Zyklus sind zusätzlich
  konsolidiert in `docs/CHANGELOG_v0.2.md` festgehalten.
- `docs/ARCHITECTURE.md` aktualisiert: veraltete Verweise auf `RegalBesuchsStatistik`/
  `regalBesuchsIndex` (in v1.2 zu `KategorieBesuchsStatistik`/`kategorieBesuchsIndex`
  umbenannt) korrigiert; Datenmodell-Diagramm und Service-Liste um `Geschaeft.kategorien`,
  `ArtikelFilterModus`, `ArtikelVerfuegbarkeitService`, `KaufEintrag.produktName` ergänzt.
- Korrektur in diesem Changelog: der Build-24-Eintrag (reine Testabdeckung, siehe unten)
  fehlte — der Pre-Commit-Hook hatte die Build-Nummer mangels neuem Eintrag stattdessen
  fälschlich in die alte `v1.6`-Überschrift eingetragen. Beides korrigiert.

## v0.1 (Build 24) — Testabdeckung für direkte Geschäft-Kategorie-Zuordnung ohne Regal

- Neue Unit-Tests in `ArtikelVerfuegbarkeitServiceTests.swift` und `ModelTests.swift`
  belegen, dass Geschäfte ganz ohne Regal auskommen: direktes Zuordnen/Entfernen einer
  Kategorie am Geschäft sowie Deduplizierung, wenn eine Kategorie sowohl direkt als
  auch über ein Regal zugeordnet ist.

## v0.1 (Build 23) — Regale optional für Kategorie-Verfügbarkeit & Artikel-Filter beim Einkaufen

- `Models/Geschaeft.swift` / `Models/ArtikelKategorie.swift`: neue direkte
  Zuordnung `Geschaeft.kategorien` (Inverse: `ArtikelKategorie.geschaefte`) — ein
  Geschäft kann Kategorien jetzt direkt verfügbar machen, ganz ohne Regal.
  `Geschaeft.verfuegbareKategorien` ist die Vereinigung aus dieser direkten
  Zuordnung und den über Regale zugeordneten Kategorien; ein Regal ist damit nur
  noch für die Einkaufs-Reihenfolge relevant, nicht mehr Voraussetzung für
  Verfügbarkeit (Korrektur der ursprünglichen v0.3-Entscheidung, siehe
  `docs/DECISIONS.md`).
- Neues `ArtikelFilterModus`-Attribut an `Geschaeft` (`nurVerfuegbare`/`alle`,
  optionaler Rohwert nach dem etablierten Fallback-Pattern) + neuer
  `Services/ArtikelVerfuegbarkeitService.swift`: bestimmt, ob ein Artikel in einem
  Geschäft verfügbar ist — über die Kategorien des Geschäfts, oder (besitzt es
  keine eigenen Kategorien) gelernt aus der Kaufhistorie, sobald der Artikel dort
  einmal gekauft wurde.
- `Views/Einkaufen/EinkaufenView.swift`: der Einkauf startet jetzt automatisch beim
  Öffnen des Tabs (kein manueller „Start“ mehr). Der bisherige Zwei-Werte-Umschalter
  („Nur offene“/„Alle“) ist einem dritten „Lernmodus“ gewichen, der den
  Verfügbarkeitsfilter für diesen Einkauf übergeht — zum Abhaken bislang unbekannter
  Artikel, die dadurch für dieses Geschäft als verfügbar gelernt werden.
- `Views/Geschaefte/KategorieHinzufuegenSheet.swift`: Regal-Auswahl ist jetzt
  optional („Kein Regal“); eine Kategorie wird beim Hinzufügen immer direkt dem
  Geschäft zugeordnet, ein Regal zusätzlich nur zur Sortierung.
- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Segmented-Picker
  „Artikel beim Einkaufen“ für `ArtikelFilterModus`; „Kategorie hinzufügen“ ist
  nicht mehr auf Geschäfte mit mindestens einem Regal beschränkt.
- `docs/DECISIONS.md`, `docs/PRODUCT_SPEC.md`, `HelpView` entsprechend angepasst.
- Neue Unit-Tests `ArtikelVerfuegbarkeitServiceTests` (Kategorie- und
  Kaufhistorie-basierte Verfügbarkeit, geschäftsübergreifende Isolation).
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 19 Unit-Tests bestehen.

## v0.1 (Build 22) — Kategorien-Abschnitt in der Geschäft-Konfiguration

- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Abschnitt „Kategorien“
  neben „Regale“ — listet alle in diesem Geschäft verfügbaren Kategorien
  (`Geschaeft.verfuegbareKategorien`) mit dem Regal, dem sie zugeordnet sind.
  Wischen (bzw. „Bearbeiten“) entfernt eine Kategorie wieder aus ihrem Regal.
- Neu: `Views/Geschaefte/KategorieHinzufuegenSheet.swift` — Sheet zum
  Hinzufügen einer Kategorie zum Geschäft. Da Verfügbarkeit ausschließlich über
  die Regal-Zuordnung entsteht (siehe `docs/DECISIONS.md`), muss dabei ein
  Ziel-Regal gewählt werden; ohne Regal wird das erklärt statt eine (nutzlose)
  Auswahl anzubieten. Bietet ebenfalls „Neue Kategorie anlegen“ an.
- `Views/Geschaefte/NeueKategorieSheet.swift`: aus `RegalDetailView.swift`
  herausgelöst, damit sowohl die Regal-Bearbeitung als auch das neue
  Kategorie-Sheet dieselbe Erstellungs-UI (Name, Symbol & Farbe) nutzen.
- Neuer Unit-Test `kategorieEntfernenAusRegalMachtSieWiederNichtVerfuegbar` in
  `ModelTests.swift` deckt die Entfernen-Semantik ab.

## v0.1 (Build 21) — Kategorien-Konfiguration pro Regal

- `Models/Regal.swift`: neue Methode `auswaehlbareKategorien(aus:)` liefert die
  Kategorien, die einem Regal zugeordnet werden können — bereits diesem Regal
  zugeordnete sowie alle, die noch keinem anderen Regal desselben Geschäfts
  zugeordnet sind. Jede Kategorie soll innerhalb eines Geschäfts genau einem
  Regal angehören.
- `Views/Geschaefte/RegalDetailView.swift`: die Kategorienauswahl eines Regals
  nutzt jetzt `auswaehlbareKategorien(aus:)` statt aller Kategorien — bereits
  einem anderen Regal desselben Geschäfts zugeordnete Kategorien werden nicht
  mehr angeboten. Neu: „Neue Kategorie anlegen“ öffnet ein Sheet (Name, Symbol
  & Farbe wie bei Artikeln) und ordnet die neu angelegte Kategorie direkt dem
  aktuellen Regal zu.
- Neuer Unit-Test `auswaehlbareKategorienSchliessenAnderweitigVerwendeteAus` in
  `ModelTests.swift` deckt die Ausschluss-Logik ab.

## v0.1 (Build 20) — Belegscan: Einkaufsdatum & produktgenaue Preishistorie

- `Services/ReceiptScanService.swift`: `BelegErgebnis` erkennt jetzt zusätzlich das
  Einkaufsdatum (`datum`, KI-Format `JJJJ-MM-TT`) und liefert es über die neue
  Computed-Property `erkanntesDatum: Date?` geparst (`nil` bei leerem/ungültigem
  Text). Neuer Unit-Test `ReceiptScanServiceTests` deckt beide Fälle ab.
- `Views/Einkaufen/BelegScanView.swift`: die Ergebnisliste zeigt jetzt einen
  `DatePicker` für das (von der KI vorbelegte) Einkaufsdatum, das der Anwender vor
  der Übernahme korrigieren kann — angewendet auf alle übernommenen/aktualisierten
  `KaufEintrag`e in beiden Scan-Kontexten.
- `Models/KaufEintrag.swift`: neues optionales Attribut `produktName` hält den
  ursprünglich vom Beleg erkannten Produkt-/Markennamen fest (z.B. „Colgate Total“),
  auch wenn der Anwender die Position in `BelegScanView` zwecks Zuordnung auf einen
  bestehenden, generischeren `Artikel` umbenennt (z.B. „Zahnpasta“). So bleiben
  unterschiedliche Marken desselben generischen Artikels in der Preishistorie pro
  Geschäft unterscheidbar, statt beim Umbenennen verlorenzugehen.
- `Views/Historie/PreisHistorieZeile.swift`: zeigt bevorzugt `produktName`, fällt
  ansonsten wie bisher auf den (ggf. generischen) Artikelnamen zurück.
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- **SwiftData-Migrationslücke gefunden und korrigiert:** Der ursprüngliche Versuch,
  gemäß der bestehenden Regel in `Models/SchemaDefinition.swift` eine neue `SchemaV2`
  für dieses additive, optionale Attribut anzulegen, crashte reproduzierbar beim
  Öffnen des Stores (`NSInvalidArgumentException: Duplicate version checksums
  detected`) — weil `SchemaV1` und `SchemaV2` in diesem Projekt (flache Modell-Klassen
  ohne Versions-Verschachtelung) auf denselben lebenden Modell-Typ zeigen und damit
  identisch gehasht werden. Korrektur: für rein additive optionale Attribute bleibt
  es bei der einzigen `SchemaV1` (klassische automatische Lightweight-Migration);
  Details und Kriterien für echte `SchemaVN`-Bumps in `docs/DECISIONS.md` ergänzt.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 14 Unit-Tests bestehen.

## v0.1 (Build 19) — Anzeige-Umschalter & dauerhaftes Entfernen abgehakter Artikel

- `Models/Einkaufsvorgang.swift`: neue Methode `artikelDauerhaftEntfernen(_:context:)` —
  löscht den `KaufEintrag` eines bereits abgehakten Artikels, ohne ihn (anders als
  `artikelAbwaehlen`) wieder auf die Einkaufsliste zurückzusetzen.
- `Views/Einkaufen/EinkaufenView.swift`: Während eines laufenden Einkaufs kann per
  Menü-Picker („Nur offene“ / „Alle“) umgeschaltet werden, ob bereits abgehakte Artikel
  zusätzlich zu den offenen angezeigt werden. Abgehakte Artikel bleiben so sichtbar
  (durchgestrichen) und lassen sich durch erneutes Antippen zurückholen. Eine
  Wisch-Aktion („Dauerhaft entfernen“) auf abgehakten Artikeln entfernt sie endgültig aus
  dieser Ansicht.
- Dafür wurde die zugrunde liegende Artikel-Query von einer gefilterten
  (`istAufEinkaufsliste`) auf eine ungefilterte Abfrage umgestellt; offene/abgehakte
  Artikel werden jetzt in der View berechnet.
- `docs/PRODUCT_SPEC.md` entsprechend ergänzt.
- Klargestellt (kein Code-Fix nötig): Ein Einkauf konnte schon zuvor jederzeit
  abgeschlossen werden, auch ohne dass alle Artikel abgehakt sind.

## v0.1 (Build 18) — Kaufbeleg-Scan für Geschäfte & Einzelpreis-Erkennung

- `Services/ReceiptScanService.swift`: `BelegPosition` erkennt jetzt zusätzlich die
  auf dem Bon angegebene `menge` und liefert `einzelpreis` statt eines
  mehrdeutigen `preis`-Felds. Der FoundationModels-Prompt weist die KI explizit an,
  bei Mehrfachpositionen (z.B. „3 x 1.50 = 4.50“) den Gesamtpreis durch die Menge zu
  teilen, statt ihn unverändert zu übernehmen — übernommen wird ausschließlich der
  Einzelpreis, keine Mengenangabe.
- `Views/Einkaufen/BelegScanView.swift`: neuer `BelegScanKontext` (`.einkaufsvorgang`
  oder `.geschaeft`) — Beleg-Scan funktioniert jetzt auch unabhängig von einem
  laufenden Einkauf direkt für ein Geschäft. Im Geschäft-Kontext wird für jede
  erkannte Position ein eigenständiger `KaufEintrag` mit heutigem Datum angelegt;
  ein passender bestehender `Artikel` wird per Namensabgleich verknüpft, damit der
  Preis in dessen Preishistorie auftaucht.
- `Views/Geschaefte/GeschaeftDetailView.swift`: neuer Abschnitt „Kaufbeleg scannen“
  öffnet `BelegScanView` im Geschäft-Kontext — auch für Geschäfte ohne bisherige
  Preishistorie sichtbar.
- Die bestehende Prüfen/Korrigieren/Löschen-Liste vor der Preisübernahme
  (`ErgebnisListe`) gilt unverändert für beide Kontexte.
- Kamera-Unterstützung war bereits aktiv (`NSCameraUsageDescription`,
  `KameraAufnahmeView`) und wurde für diesen Checkpoint nicht verändert.
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 12 Unit-Tests bestehen.

## v0.1 (Build 17) — Neues Versionsschema: manuelle Major/Minor-Version, automatische Build-Nummer

- Ab sofort wird die Version als `vMajor.Minor (Build N)` geführt. `Major.Minor`
  (`MARKETING_VERSION` in `project.yml`, `VERSION`-Datei) wird nur noch manuell vom
  Nutzer festgelegt — die bisherige Automatik, die pro Checkpoint die erste
  Nachkommastelle erhöht hat, entfällt. `N` (`CURRENT_PROJECT_VERSION` in
  `project.yml`) ist die Build-Nummer und wird automatisch bei jedem Commit um 1
  erhöht.
- Neuer Git-Hook `.githooks/pre-commit`: erhöht `CURRENT_PROJECT_VERSION` in
  `project.yml` und trägt die neue Build-Nummer in die oberste Überschrift von
  `docs/CHANGELOG.md` ein (`## vX.Y (Build N) — ...`), damit jeder Commit
  nachvollziehbar auf seinen Changelog-Eintrag verweist. Aktiviert lokal über
  `git config core.hooksPath .githooks` (siehe `docs/DECISIONS.md`).
- Version mit diesem Commit auf `0.1` zurückgesetzt (Nutzervorgabe); die
  Build-Nummer knüpft an die bisherige Commit-Historie an.

## v1.6 (Build 26) — Explizite SwiftData-Migrationslogik (`SchemaMigrationPlan`)

- `Models/SchemaDefinition.swift`: neue `SchemaV1` (``VersionedSchema``, aktueller
  Modellstand) und `ShopWithMeMigrationPlan` (``SchemaMigrationPlan``, aktuell mit
  einer Version und ohne Stages). `SchemaDefinition.schema`/`.migrationPlan` liefern
  beides zentral für App-Start und `DatabaseLocationService`.
- `App/ShopWithMeApp.swift`: `ModelContainer` wird jetzt mit `migrationPlan:
  SchemaDefinition.migrationPlan` aufgebaut statt sich implizit auf SwiftDatas
  automatische Lightweight-Migration zu verlassen.
- Ausführliche DocC-Dokumentation an `ShopWithMeMigrationPlan` legt das Vorgehen für
  jede künftige Datenmodell-Änderung fest (neue `SchemaVN` + passende
  `MigrationStage`, `.lightweight` vs. `.custom`) — Hintergrund und Auslöser
  (v1.4→v1.5-Absturz) in `docs/DECISIONS.md` festgehalten.

## v1.5 (Build 27) — Absturz beim Öffnen eines Geschäfts nach v1.4-Update behoben

- `Models/Geschaeft.swift`: `regalSortierModus` (neu in v1.4) crashte für vor
  v1.4 angelegte Geschäfte, sobald die Detailansicht geöffnet wurde — SwiftData
  konnte den fehlenden Spaltenwert bestehender Datensätze nicht auf das
  nicht-optionale `RegalSortierModus`-Enum casten
  (`Could not cast value of type 'Swift.Optional<Any>' to 'RegalSortierModus'`).
  Reproduziert über ein eigenständiges Migrationsexperiment: Store mit altem
  Schema (ohne die Spalte) anlegen, mit neuem Schema erneut öffnen und den
  bestehenden Datensatz lesen — das löste den exakt gemeldeten Absturz aus.
  Behoben, indem der Rohwert jetzt optional (`regalSortierModusRaw: String?`)
  gespeichert wird; `regalSortierModus` ist ein Computed-Property darüber, das
  bei fehlendem/ungültigem Rohwert sicher auf `.manuell` zurückfällt.
- Neuer Unit-Test `regalSortierModusFaelltOhneGespeichertenRohwertAufManuellZurueck`
  (`ModelTests`) hält dieses Verhalten fest.

## v1.4 (Build 32) — Manuelle und automatische Regal-Reihenfolge als gleichberechtigte Alternativen

- `Models/Geschaeft.swift`: neues `RegalSortierModus`-Enum (`manuell`/`automatisch`)
  und neue Property `regalSortierModus` (Default `.manuell`) legen pro Geschäft fest,
  welche Regal-Reihenfolge tatsächlich verwendet wird.
- `Services/ShelfOrderLearningService.swift`: neue
  `automatischeReihenfolgeVerfuegbar(fuer:context:)` und
  `effektiveReihenfolge(fuer:context:)` — Letztere liefert je nach
  `regalSortierModus` entweder die manuelle (`Regal/sortIndex`) oder die gelernte
  Reihenfolge, ohne dass ein Moduswechsel die jeweils andere überschreibt.
- `Views/Geschaefte/GeschaeftDetailView.swift`: die bisherige einmalige
  „Automatische Reihenfolge übernehmen“-Aktion ist einem Segmented-Picker
  gewichen, mit dem der Anwender jederzeit zwischen „Manuell“ (Drag & Drop im
  Bearbeiten-Modus) und „Automatisch“ wechselt, sobald genug Einkäufe gelernt
  wurden. Der Picker erscheint nur, wenn genügend Statistiken vorliegen.
- `Views/Einkaufen/EinkaufenView.swift`: die Gruppierung der Einkaufsliste nach
  Regal folgt jetzt ebenfalls `effektiveReihenfolge(fuer:context:)` statt starr
  `Regal/sortIndex`.
- Neuer Unit-Test `automatischerModusUeberschreibtManuelleReihenfolgeNicht`
  (`ShelfOrderLearningServiceTests`) prüft, dass Hin- und Herschalten zwischen den
  Modi die manuelle Reihenfolge unangetastet lässt.

## v1.3 (Build 34) — Unkategorisierte Artikel fallen automatisch unter „Sonstiges“

- `Models/ArtikelKategorie.swift`: neue statische Methode `sonstige(context:)`
  findet die "Sonstiges"-Kategorie (normalerweise über `SeedData` angelegt) oder
  erzeugt sie defensiv, falls sie ausnahmsweise fehlt.
- `Models/Artikel.swift`: neue `effektiveKategorie(context:)` liefert `kategorie`,
  oder — falls keine gesetzt ist — automatisch "Sonstiges". Wird jetzt überall
  verwendet, wo bisher zwischen "hat Kategorie" und "hat keine Kategorie"
  unterschieden wurde.
- `Models/Einkaufsvorgang.swift`: `artikelAbhaken(_:context:)` nutzt
  `effektiveKategorie(context:)` — unkategorisierte Artikel teilen sich jetzt den
  `kategorieBesuchsIndex` mit explizit als "Sonstiges" kategorisierten Artikeln,
  statt separat gezählt zu werden. `naechsterKategorieBesuchsIndex` braucht damit
  keinen Sonderfall für `nil` mehr.
- `Views/Einkaufen/EinkaufenView.swift`: die bisherige separate „Ohne Kategorie“-
  Sektion entfällt; unkategorisierte Artikel landen jetzt in derselben Sektion wie
  Artikel mit expliziter "Sonstiges"-Kategorie, inklusive gelernter Sortierung.
- `Views/Artikel/ArtikelEditView.swift`: Kategorie-Auswahl ist beim Anlegen/
  Bearbeiten eines Artikels nicht mehr Pflicht — ohne Auswahl greift automatisch
  "Sonstiges" (Hinweistext in der Fußzeile ergänzt).
- Neue Unit-Tests: `unkategorisierterArtikelFaelltUnterSonstigesUndTeiltSichDenIndex`
  (`EinkaufsvorgangTests`) und `sonstigeKategorieWirdBeiBedarfAngelegtUndWiederverwendet`
  (`ModelTests`).
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 10 Unit-Tests bestehen.

## v1.2 (Build 38) — Lern-Algorithmus auf Artikelkategorie umgestellt

- `Models/KategorieBesuchsStatistik.swift` (neu) ersetzt `RegalBesuchsStatistik`:
  die gelernte Besuchsstatistik hängt jetzt an der ``ArtikelKategorie`` eines
  Artikels statt am ``Regal`` — Grundlage dafür, dass auch Geschäfte ohne Regale
  (seit v1.0 möglich) eine sinnvolle Sortierung bekommen.
- `Models/KaufEintrag.swift` / `Models/Einkaufsvorgang.swift`: `regal`/
  `regalBesuchsIndex` durch `kategorie`/`kategorieBesuchsIndex` ersetzt;
  `artikelAbhaken(_:context:)` leitet die Kategorie jetzt selbst vom Artikel ab
  (kein `regal`-Parameter mehr nötig).
- `Services/ShelfOrderLearningService.swift`: neue
  `kategoriePositionen(fuer:context:)` liefert die gelernten Kategorie-Positionen
  eines Geschäfts direkt — genutzt sowohl zur Regal-Reihenfolge (Durchschnitt über
  `Regal/kategorien`) als auch von `EinkaufenView` zur Sortierung der „Sonstige“-
  Sektion in Geschäften ohne Regal.
- Neuer Unit-Test `liefertKategorieReihenfolgeFuerLadenOhneRegal` verifiziert die
  Kategorie-Reihenfolge für ein Geschäft ganz ohne Regale.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 8 Unit-Tests bestehen.

## v1.1 (Build 39) — Artikel direkt aus der Einkaufsliste hinzufügen

- Neu: `Views/Einkaufen/ArtikelHinzufuegenView.swift` — Sheet mit Suchfeld über alle
  bereits angelegten Artikel, aufrufbar über den neuen „+“-Button in der
  Einkaufsliste (`Views/Einkaufen/EinkaufenView.swift`). Antippen eines
  Suchtreffers setzt den Artikel direkt auf die Einkaufsliste.
- Findet die Suche keinen exakten Namenstreffer, kann der Artikel per „„…“ neu
  anlegen“ sofort über die bestehende `ArtikelEditView` angelegt werden
  (inkl. Kategorie-Auswahl) und landet danach automatisch auf der Einkaufsliste.

## v1.0 (Build 41) — Globale Einkaufsliste & frei änderbare Kategorie

- `Views/Einkaufen/EinkaufenView.swift`: Die Einkaufsliste ist jetzt global und nicht
  mehr von einer Geschäftsauswahl abhängig. Der Geschäft-Picker bekommt eine „Kein
  Geschäft“-Option; ohne Geschäftsauswahl ist die Liste flach, mit Geschäftsauswahl
  weiterhin nach Regal gruppiert. Artikel ohne Kategorie oder ohne Regal-Zuordnung im
  gewählten Geschäft wurden bisher ausgeblendet — sie erscheinen jetzt in einer
  eigenen „Sonstige“-Sektion statt nur als Hinweistext gezählt zu werden.
- `Models/Artikel.swift` / `Views/Artikel/ArtikelEditView.swift`: die Kategorie eines
  Artikels ist nun auch nach dem Anlegen jederzeit änderbar (vorher nach dem ersten
  Speichern schreibgeschützt).
- `docs/PRODUCT_SPEC.md` entsprechend angepasst.
- Das in v0.9 vermerkte offene Problem behoben: `ShopWithMeTests` bekommt über
  `GENERATE_INFOPLIST_FILE: YES` (`project.yml`) ein automatisch generiertes
  Info.plist, wodurch Code-Signing für das Test-Target wieder funktioniert.
- Verifiziert: `xcodegen generate` + `xcodebuild build` + `xcodebuild test`
  (`iPhone 17` Simulator) laufen fehlerfrei durch, alle 7 Unit-Tests bestehen.

## v0.9 (Build 43) — Kamera-Funktion reaktiviert

- `NSCameraUsageDescription` wieder ergänzt (jetzt über `info.properties` in
  `project.yml`, da die App auf ein explizites `ShopWithMe/Info.plist` umgestellt
  wurde und nun mit `DEVELOPMENT_TEAM` code-signed wird).
- `Views/Einkaufen/BelegScanView.swift`: Kamera-Aufnahme (`KameraAufnahmeView`,
  `UIImagePickerController`) und der „Foto aufnehmen“-Button wieder hergestellt;
  Fotomediathek bleibt als Alternative bestehen.
- Hilfe-Eintrag in `HelpView` entsprechend zurückgesetzt.
- Verifiziert: Simulator-Build (`xcodegen generate` + `xcodebuild build`,
  `generic/platform=iOS Simulator`) läuft mit reaktivierter Kamera fehlerfrei durch.
- Verifiziert: echter code-signierter Geräte-Build (`generic/platform=iOS`,
  Team `CBYLYH36PT`) baut und signiert erfolgreich; das entstandene `.app`
  enthält gültige Entitlements (`application-identifier`,
  `com.apple.developer.team-identifier`). Ein vorheriger Versuch mit Team
  `BB7HRC29RE` scheiterte mit „No Account for Team“/fehlendem
  Provisioning-Profil, weil für diesen Team kein Account in Xcode hinterlegt
  war — kein Camera-spezifisches Problem, sondern ein Account-/Team-Mismatch,
  der sich mit dem Wechsel auf `CBYLYH36PT` erledigt hat.
- Separat aufgefallen (nicht durch diese Änderung verursacht): das
  `ShopWithMeTests`-Target hat inzwischen `CODE_SIGN_STYLE`/`DEVELOPMENT_TEAM`
  gesetzt, aber kein Info.plist-Setup, wodurch `xcodebuild test` aktuell mit
  „Cannot code sign because the target does not have an Info.plist file“
  fehlschlägt.

## v0.8 (Build 44) — Kamera-Funktion deaktiviert

- Das Camera-Entitlement (`NSCameraUsageDescription`) wird vom Apple-Developer-Account
  aktuell nicht unterstützt und wurde daher wieder entfernt (`project.yml`).
- `Views/Einkaufen/BelegScanView.swift`: Beleg-Erfassung nur noch über die
  Fotomediathek (`PhotosPicker`); die Kamera-Aufnahme (`UIImagePickerController`,
  `KameraAufnahmeView`) wurde entfernt.
- Hilfe-Eintrag „Belegscan & Preishistorie“ in `HelpView` an den Wegfall der
  Kamera-Option angepasst.

## v0.7 (Build 45) — Belegscan & Preishistorie

- `Services/ReceiptScanService.swift`: Protokoll + `VisionFoundationModelsReceiptScanner`
  (Vision-OCR + FoundationModels-Strukturextraktion) erkennt Artikel und Preise auf
  einem fotografierten Kassenbon.
- `Views/Einkaufen/BelegScanView.swift`: Foto aufnehmen (Kamera, falls verfügbar)
  oder aus der Fotomediathek wählen, erkannte Positionen prüfen/korrigieren und
  übernehmen. Nach „Einkauf abschließen“ bietet `EinkaufenView` den Scan aktiv an.
  Erkannte Positionen werden bestehenden `KaufEintrag`en zugeordnet (Namensabgleich)
  oder als eigenständiger Eintrag ohne Artikel-Verknüpfung gespeichert, damit keine
  erfassten Preise verloren gehen.
- `Views/Historie/PreisHistorieZeile.swift`: gemeinsame Zeilen-Ansicht für die
  Preishistorie, eingebunden in `ArtikelEditView` (pro Artikel) und
  `GeschaeftDetailView` (pro Geschäft).
- `NSCameraUsageDescription` in `project.yml` ergänzt.
- Hilfe-Eintrag „Belegscan & Preishistorie“ in `HelpView` ergänzt.

## v0.6 (Build 46) — KI-Vorschlag, Einstellungen & Datenbank-Speicherort

- `Services/AISuggestionService.swift`: FoundationModels-basierter Vorschlag
  (Symbol, Farbe, Kategorie, informativer Regal-Hinweis) beim Anlegen eines
  Artikels; blendet sich aus, wenn Apple Intelligence auf dem Gerät nicht
  verfügbar ist (`SystemLanguageModel.default.isAvailable`).
- `ArtikelEditView` bekommt einen „Mit Apple Intelligence vorschlagen“-Button
  (nur bei neuen Artikeln, nur wenn verfügbar).
- `Views/Einstellungen/SettingsView.swift` + `HelpView.swift`: Einstellungsmenü mit
  ausklappbaren Anleitungen zu Regal-Zuordnung, Lern-Algorithmus,
  KI-Vorschlägen und Datenbank-Speicherort.
- `Services/DatabaseLocationService.swift` + `DatabaseLocationSettingsView.swift`:
  erlaubt, die SwiftData-Datenbank in einen selbst gewählten Ordner zu verlegen
  (Security-Scoped-Bookmark, reine Dateiverlagerung, kein iCloud-Sync). Wirksam
  nach Neustart der App.
- `Models/SchemaDefinition.swift`: zentrale Schema-Definition, damit App-Start und
  Datenbank-Speicherort-Logik dieselbe Modell-Liste verwenden.
- Toter Platzhalter-Code in `RootView` entfernt, da alle vier Tabs jetzt echte
  Views zeigen.

## v0.5 (Build 56) — Lern-Algorithmus für Regal-Reihenfolge

- `Services/ShelfOrderLearningService.swift`: wertet abgeschlossene
  Einkaufsvorgänge aus, pflegt `RegalBesuchsStatistik` je Regal und leitet daraus
  eine vorgeschlagene Regal-Reihenfolge ab (ab 5 abgeschlossenen Einkäufen in einem
  Geschäft).
- `GeschaeftDetailView` zeigt den Vorschlag als Banner an, wenn er von der
  aktuellen manuellen Reihenfolge abweicht; der Anwender übernimmt ihn explizit
  über einen Button — die manuelle Reihenfolge wird nie automatisch überschrieben.
- `EinkaufenView` ruft `ShelfOrderLearningService.lernenAus(...)` beim Abschließen
  eines Einkaufs auf.
- Neuer Unit-Test `ShelfOrderLearningServiceTests` verifiziert, dass die gelernte
  Reihenfolge von einer bewusst falsch gewählten manuellen Reihenfolge abweichen
  und korrekt übernommen werden kann.

## v0.4 (Build 94) — Einkaufen-Flow

- `Views/Einkaufen/EinkaufenView.swift`: Geschäft wählen, Einkauf starten, nach Regal
  gruppierte Einkaufsliste abarbeiten (nur Kategorien, die diesem Geschäft über
  Regale zugeordnet sind), Einkauf abschließen.
- `Einkaufsvorgang.artikelAbhaken(_:regal:context:)` /
  `artikelAbwaehlen(_:context:)`: legen/löschen `KaufEintrag`e und pflegen
  `regalBesuchsIndex` (Rohdaten für den späteren Lern-Algorithmus, v0.5).
- `KaufEintrag.preis` ist jetzt optional (`Decimal?`) und `KaufEintrag.regal`
  wurde ergänzt — siehe `docs/DECISIONS.md`.
- `Geschaeft.regal(fuer:)`: liefert das Regal, dem eine Kategorie in diesem
  Geschäft zugeordnet ist.
- Neue Unit-Tests (`EinkaufsvorgangTests`) für Abhaken/Abwählen und
  Regal-Sequenz-Zuordnung — dabei einen Bug gefunden und behoben: `context.delete()`
  aktualisierte die In-Memory-Relationship nicht sofort, `artikelAbwaehlen` entfernt
  den Eintrag jetzt zusätzlich direkt aus `kaufEintraege`.

## v0.3 (Build 98) — Geschäfte-Verwaltung

- `Views/Geschaefte/GeschaeftListView.swift`: Geschäfte anlegen, bearbeiten, löschen.
- `Views/Geschaefte/GeschaeftStammdatenEditView.swift`: Name/Typ/Adresse-Formular.
- `Views/Geschaefte/GeschaeftDetailView.swift`: Regal-Verwaltung pro Geschäft
  (hinzufügen, umbenennen über Regal-Detail, löschen, manuelle Reihenfolge per
  Drag & Drop im Bearbeiten-Modus).
- `Views/Geschaefte/RegalDetailView.swift`: Kategorie-zu-Regal-Zuordnung — bestimmt
  automatisch die beim Einkaufen in diesem Geschäft verfügbaren Kategorien.
- Geschäfte-Tab in `RootView` verdrahtet.

## v0.2 — Artikel-Verwaltung

- `DesignSystem/GlassStyles.swift`: `glassCard`-Modifier und `GlassSymbolBadge` als
  wiederverwendbare Liquid-Glass-Bausteine.
- `DesignSystem/Color+Hex.swift`: Hex-String-Farbkonvertierung + Standardpalette.
- `DesignSystem/SymbolColorPicker.swift`: kuratierte SF-Symbol-Auswahl, Farbpalette und
  Freitext-Eingabe für eigene SF-Symbole.
- `Views/Artikel/ArtikelListView.swift` + `ArtikelEditView.swift`: Artikel anlegen,
  bearbeiten, löschen. Kategorie ist nach Anlage schreibgeschützt.
- Artikel-Tab in `RootView` verdrahtet.

## v0.1 — Projekt-Scaffold

- XcodeGen-Setup (`project.yml`), iOS-26-Target, Bundle-ID `com.made4me.ShopWithMe`.
- Doku-Grundgerüst: `PRODUCT_SPEC.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `DECISIONS.md`.
- Komplettes SwiftData-Datenmodell: `Artikel`, `ArtikelKategorie`, `Regal`, `Geschaeft`,
  `Einkaufsvorgang`, `KaufEintrag`, `RegalBesuchsStatistik` + Seed-Daten für Standard-
  Kategorien und Geschäftstypen.
- Leere App-Hülle, die kompiliert und den `ModelContainer` aufsetzt.
