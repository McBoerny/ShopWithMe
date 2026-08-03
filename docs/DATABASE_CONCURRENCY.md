# ShopWithMe — Mehrbenutzerzugriff auf die Datenbank (Datei-Lease-Verfahren)

Status: **Umgesetzt seit Build 30** (`DatabaseLeaseService.swift`,
`Views/SessionLeaseGate.swift`, Einbindung an allen Schreibstellen unten). Dieses
Dokument beschreibt den implementierten Prozess — siehe `docs/ROADMAP.md` für den
Checkpoint. Ein echter Live-Test mit mehreren Geräten gegen einen realen Cloud-Ordner
(Box Drive/OneDrive/Synology Drive/iCloud Drive) steht noch aus, siehe
„Bekannte Grenzen“ und `docs/LOGGING.md` für das dafür vorgesehene Diagnose-Logging.

**Nachtrag (GitHub #54):** `DatabaseLocationService` (siehe „Ausgangslage" unten)
wurde entfernt — die Store-Datei liegt seitdem immer am SwiftData-Standardpfad im
App-Container, nie mehr in einem geteilten Cloud-Ordner. Das hier beschriebene
Szenario „mehrere Geräte greifen direkt auf dieselbe Store-Datei zu" ist damit
nicht mehr herstellbar; **gemeinsames Einkaufen läuft ausschließlich über die
event-basierte Synchronisation** (`docs/DATENSYNCHRONISATION_VERLAUF.md`,
`SyncOrdnerService`). `DatabaseLeaseService` selbst bleibt aktiv und relevant —
es dient inzwischen als allgemeiner Schreibkoordinations-Mechanismus für explizite
Speicherpunkte (statt implizitem Autosave) innerhalb eines einzelnen Geräts, siehe
`ShopWithMeApp.swift`.

## Ausgangslage (historisch)

Der Nutzer konnte den SwiftData-Store per `.fileImporter` in einen beliebigen
Ordner verlegen (`DatabaseLocationService`, inzwischen entfernt, siehe Nachtrag
oben). In der Praxis war dieser Ordner oft ein **Fileshare, das über einen
Cloud-Dienst gehostet wird** (Box Drive, Synology Drive, iCloud Drive, OneDrive,
o.ä.) und von mehreren Geräten/Nutzern gleichzeitig eingebunden war — daraus
entstand der unten beschriebene Koordinationsbedarf.

**Bewusste Entscheidung (Nutzervorgabe):** Kein CloudKit/eigener Server — die
Cloud-Anbindung (echter Sync-Dienst) bleibt eine mögliche Zukunftsoption, ist aber
kein Ziel dieses Verfahrens. Stattdessen wird ausschließlich mit den **nativen
Datei-APIs unter iOS/macOS** gearbeitet (`NSFileCoordinator`, `NSFilePresenter`),
die alle genannten Anbieter über deren Files-App-/File-Provider-Integration
unterstützen.

**Risiko, das dieses Verfahren adressiert:** SQLite (die Basis von SwiftData) rät
ausdrücklich davon ab, eine offene Datenbankdatei unkoordiniert in einem
Sync-Ordner zu halten — ein Cloud-Client kann mitten in einer Transaktion
hochladen und die Datei beschädigen. Ohne Schutzmechanismus reicht bereits das
gleichzeitige schreibende Öffnen durch zwei Geräte, um Store, `-wal`- und
`-shm`-Sidecar-Dateien inkonsistent zu synchronisieren.

## Voraussetzung: explizite Speicherpunkte statt implizitem Autosave

**Wichtige Korrektur, die für das gesamte restliche Dokument gilt:** Eine
Code-Prüfung zeigt, dass es im gesamten Projekt **keinen einzigen expliziten
`context.save()`-Aufruf** gibt — auch nicht beim Artikel-Abhaken selbst
(`Einkaufsvorgang.artikelAbhaken(_:context:)`, `Models/Einkaufsvorgang.swift:45-52`).
Alle Schreibzugriffe (Artikel abhaken, Geschäfts-Bearbeitung, …) verlassen
sich bislang ausschließlich auf SwiftDatas **implizites Autosave**
(`ModelContext.autosaveEnabled`, Standardwert `true`), das opportunistisch bei
Leerlauf/Hintergrundwechsel/Teardown schreibt — nicht an einem klar
abgrenzbaren Punkt „eine Nutzeraktion = ein Speichervorgang".

Ein Lease (egal ob Micro- oder Session-Lease) kann aber nur schützen, was
tatsächlich innerhalb seines Haltefensters geschrieben wird. Ohne Eingriff
könnte das implizite Autosave jederzeit — auch außerhalb eines gehaltenen
Lease — ungeschützt in die geteilte Datei schreiben und damit genau das
Korruptionsrisiko wieder öffnen, das dieses ganze Verfahren verhindern soll.

**Konsequenz für die Implementierung (gilt für beide unten beschriebenen
Lease-Strategien):**

1. `ModelContext.autosaveEnabled = false` setzen, damit SwiftData nicht mehr
   unkontrolliert eigenständig speichert.
2. An jeder Stelle, die bisher auf Autosave vertraut hat, einen expliziten,
   Lease-geschützten `try context.save()`-Aufruf ergänzen — der genaue
   Zeitpunkt unterscheidet sich je nach Bearbeitungsmuster, siehe die zwei
   Strategien unten.

## Gewähltes Verfahren: Single-Writer-**Micro**-Lease + Datei-Koordination

**Revidiert gegenüber der ursprünglichen Fassung dieses Dokuments** (siehe
„Verworfene Zwischenstufe" unten): Statt den Schreib-Lease pro **Session** (App-Start
bis Hintergrund) zu vergeben, wird er nur für die **Dauer eines einzelnen
Speichervorgangs** gehalten (z.B. genau das Abhaken eines Artikels). Grund: das
Kernszenario ist, dass mehrere Personen **während desselben Einkaufs gleichzeitig**
Artikel abhaken — ein session-langer Lease hätte dabei fast permanent alle außer
einer Person auf Nur-Lesen-Modus gesperrt.

Echtes Row-Level-Locking (im Sinne eines Datenbank-Servers wie Postgres) ist mit
SQLite/SwiftData über einen asynchron gespiegelten Fileshare **nicht** möglich —
es gibt keine zentrale Instanz, die Sperren in Echtzeit an alle Geräte meldet. Das
Micro-Lease-Verfahren erreicht den praktisch relevanten Effekt trotzdem, indem es
die Sperrdauer auf Sekundenbruchteile reduziert, statt die Granularität (ganze
Datei vs. einzelner Datensatz) zu verändern.

### Bausteine

- **Lease-Lock-Datei** neben dem Store (z.B. `<StoreName>.lock.json`), Inhalt:
  Gerätename, Geräte-ID, `acquiredAt`.
- **`NSFileCoordinator`** für jeden Zugriff auf Store *und* Lock-Datei — das ist
  der Haken, über den File-Provider-Erweiterungen (Box/OneDrive/Synology
  Drive/iCloud Drive) von der Koordination erfahren und Uploads entsprechend
  timen.
- **`NSFilePresenter`** war als Baustein geplant, um externe Änderungen an
  Store/Lock-Datei aktiv (per Benachrichtigung statt Polling) zu erkennen —
  **nicht umgesetzt**: jeder Lease-Erwerb liest die Lock-Datei ohnehin frisch via
  `NSFileCoordinator`, ein zusätzlicher registrierter `NSFilePresenter` hätte für
  das aktuelle Micro-/Session-Lease-Verfahren keinen zusätzlichen Nutzen gebracht
  (kein UI-Zustand hängt an einer aktiven Änderungsbenachrichtigung). Bliebe als
  mögliche spätere Erweiterung, z.B. für ein Live-Update des
  Nur-Lesen-Banners in ``SessionLeaseGate``, ohne dass der Nutzer die Ansicht neu
  öffnen muss.

### Ablauf (pro Speichervorgang, nicht pro Session)

1. **Vor jedem `save()`** (z.B. Artikel abhaken): Lock-Datei koordiniert lesen.
   - Keine Lock-Datei oder `acquiredAt` älter als der Stale-Timeout → eigenen
     Lease schreiben.
   - Lock-Datei vorhanden und aktuell (anderes Gerät schreibt gerade) →
     **Nur-Lesen-Modus** für diesen Moment, Schreibaktion kurz zurückstellen/
     erneut versuchen (siehe unten).
2. **Direkt nach Lease-Erwerb, vor dem eigentlichen Schreiben:** idealerweise den
   lokalen `ModelContext` frisch von der Datei aktualisieren, da die lokale Kopie
   zwischenzeitlich veraltet sein kann. **Umsetzungsstand:** SwiftData bietet dafür
   keine direkte API (kein „Store neu einlesen" auf einem laufenden
   `ModelContainer` — ein Hot-Swap des Containers wurde in `docs/DECISIONS.md`
   bereits bewusst verworfen, siehe „Datenbank-Speicherort: reine Dateiverlagerung,
   kein Hot-Swap"). Dieser Schritt ist daher **nicht** als generischer
   Store-Reload umgesetzt — stattdessen übernimmt die in „Vollständiger
   Schreibvorgang-Katalog" beschriebene **Dedupe-Prüfung** (frischer `fetchCount`
   direkt vor dem Schreiben, siehe `Einkaufsvorgang.artikelAbhaken`) die praktisch
   relevante Absicherung für den einzigen Schreibpfad, bei dem das Fehlen eines
   echten Reloads zu einer sichtbaren Inkonsistenz (Doppel-Eintrag) führen könnte.
   Für andere Schreibvorgänge ist das Risiko vernachlässigbar, da unterschiedliche
   Objekte betroffen sind (kein Überschreiben fremder Änderungen). Muss beim
   geplanten Live-Test (siehe `docs/LOGGING.md`) beobachtet werden.
3. **Schreiben + Lease sofort freigeben — bewusst OHNE erzwungenen
   WAL-Checkpoint** (Korrektur gegenüber einer früheren Fassung dieses
   Dokuments, siehe „Datentransfer-Schätzung" unten: ein Checkpoint bei jedem
   Micro-Lease würde genau den Datentransfer verursachen, den dieser Abschnitt
   minimieren soll). Die gesamte Sequenz (1–3) läuft synchron im Rahmen der
   einzelnen UI-Aktion (z.B. Tap auf „abhaken"), nicht im Hintergrund über die
   App-Laufzeit verteilt.
4. **Lesen (Standardfall, keine Sperre nötig):** normales `@Query`/`ModelContext`-
   Lesen jederzeit möglich, unabhängig vom Lease-Zustand — nur das Schreiben ist
   koordiniert.

### Gewählte Parameter

| Parameter | Wert | Begründung |
|---|---|---|
| Lease-Granularität | **Pro Speichervorgang (Micro-Lease)**, nicht pro Session | Passt zum Szenario „mehrere Personen haken während desselben Einkaufs gleichzeitig Artikel ab" — Sperre wird nur für Sekundenbruchteile gehalten statt für die ganze Einkaufs-Session. |
| Verhalten bei belegtem Lock | **Nur Lesen / kurz zurückstellen** | Kein Datenverlust möglich; da der Lease nur Sekundenbruchteile gehalten wird, bedeutet „warten" in der Praxis eine kaum spürbare Verzögerung, kein Blockieren der ganzen App. |
| Stale-Timeout (Lease ohne Freigabe gilt als verwaist) | **2 Minuten** | Unverändert aus der ursprünglichen Entscheidung — deckt den Fall ab, dass eine App genau während eines Micro-Lease-Writes abstürzt (seltener Grenzfall, da der Lease normalerweise nur Sekundenbruchteile lebt). |
| Zusätzlicher UX-Marker „wird gerade bearbeitet" pro Artikel | **Nein** | Bewusst nicht ergänzt (Nutzervorgabe) — bei Sekundenbruchteile-Sperren wäre ein solcher Hinweis ohnehin fast nie sichtbar; das Restrisiko wird stattdessen technisch abgefangen (siehe „Restrisiko" unten). |

**Bewusst nicht gewählt:** eine Option zur erzwungenen Übernahme einer aktiven
Sperre durch den Nutzer — bei Micro-Leases im Sekundenbruchteil-Bereich ist das
ohnehin kaum relevant; der 2-Minuten-Stale-Timeout deckt den praktisch relevanten
Fehlerfall (Absturz während eines Writes) ab.

### Restrisiko: Sync-Latenz des Cloud-Anbieters (wichtig, auch bei Micro-Lease)

Die Lock-Datei selbst muss erst zum anderen Gerät synchronisiert werden, bevor
dieses sie berücksichtigen kann — bei Box Drive/OneDrive/Synology Drive/iCloud
Drive können dazwischen Sekunden bis Minuten liegen. Ein kurz gehaltener
Micro-Lease **verkleinert** das Kollisionsfenster gegenüber einem lang gehaltenen
Session-Lease, **eliminiert es aber nicht** — zwei Geräte können in seltenen
Fällen innerhalb desselben Sync-Latenz-Fensters beide einen Lease-Erwerb für
denselben Moment für gültig halten. Da dies bei häufigen kurzen Schreibvorgängen
(viele Abhak-Aktionen pro Einkauf) öfter vorkommen kann als bei einem einzigen
langen Session-Lease, braucht es einen technischen Auffangmechanismus statt
reiner Fenster-Minimierung:

- **Eindeutigkeits-/Dedupe-Prüfung** beim Anlegen eines `KaufEintrag`: pro
  (`Einkaufsliste`, `Artikel`) darf unter allen noch **offenen** Vorgängen nur
  ein aktiver Eintrag entstehen — bewusst listenweit, nicht nur pro
  `Einkaufsvorgang` (Live-Test-Fund, Nachtrag Session 2026-08-03: eine
  Prüfung nur pro Vorgang ließ denselben Artikel unter zwei unterschiedlichen,
  beide offenen Vorgängen — z.B. zwei Geschäften — unabhängig voneinander
  abhaken, was zwei Kaufeinträge erzeugte und den Artikel für ein einzelnes
  „Abwählen" scheinbar dauerhaft „abgehakt" hängen ließ). Haken zwei Geräte
  im seltenen Kollisionsfall denselben Artikel „gleichzeitig" ab, wird der
  zweite Schreibversuch beim Speichern als Duplikat erkannt und
  verworfen/zusammengeführt, statt einen inkonsistenten Doppel-Eintrag zu
  erzeugen. Das ist die eigentliche Absicherung gegen dieses Restrisiko — nicht
  die Lease an sich.
- Dieses Restrisiko betrifft ausschließlich das (unkritische) doppelte Abhaken
  desselben Artikels, nicht die Gefahr einer korrupten SQLite-Datei — letztere
  bleibt durch das Single-Writer-Prinzip (nur einer schreibt zur selben Zeit auf
  die Datei) abgedeckt, solange Schritt 2 (Refresh vor dem Schreiben)
  eingehalten wird.

### Verworfene Zwischenstufe: reine Lock-Datei pro Artikel

Vor der Micro-Lease-Entscheidung wurde geprüft, ob eine **eigene Lock-Datei pro
Artikel** (z.B. `Artikel-<uuid>.lock.json`) echtes Row-Level-Locking nachbilden
könnte. Verworfen, weil das dieselbe Sync-Latenz-Grundproblematik wie eine
Store-weite Lock-Datei hätte (siehe oben), zusätzliche Komplexität (viele kleine
Lock-Dateien anlegen/aufräumen) erzeugt, ohne das eigentliche Korruptionsrisiko
zu reduzieren — die Datei muss so oder so exklusiv für den Schreibmoment
reserviert sein. Die tatsächlich wirksame Verbesserung ist die **kurze
Haltedauer** (Micro-Lease), nicht die Sperr-Granularität.

## Zweite Lease-Strategie: Session-Lease für Bearbeitungs-Bildschirme

Das Micro-Lease-Verfahren oben passt zu **diskreten Einzelaktionen** (ein Tap
= ein abgeschlossener Zustandswechsel), wie beim Artikel-Abhaken. Für
**Geschäfte-Bearbeitung** trifft das nicht zu: Code-Prüfung zeigt,
dass diese Bildschirme (`GeschaeftStammdatenEditView`,
`GeschaeftDetailView` inkl. Kategorie-Zuordnung,
`KategorieHinzufuegenSheet`) per `@Bindable` **live und ungebündelt** an das
SwiftData-Modell binden — jeder Tastenanschlag, jeder Kategorie-Toggle, jede
Kategorie-Entfernen mutiert das Modell sofort, ohne natürlichen
Abschlusspunkt einzelner Aktionen. Ein Micro-Lease pro Tastenanschlag wäre
Overkill (ständiges Erwerben/Freigeben beim Tippen).

**Gewählt (Nutzervorgabe): Session-Lease nur für diese Bearbeitungs-Bildschirme.**
Der Lease wird beim Öffnen des jeweiligen Bildschirms (`onAppear`) geholt und
erst beim Verlassen (`onDisappear`/`dismiss()`) wieder freigegeben — samt dem
in „Voraussetzung" oben geforderten expliziten `try context.save()` an genau
diesem Freigabe-Zeitpunkt (statt auf Autosave zu vertrauen). Andere Geräte
sehen währenddessen (wie beim Micro-Lease) den Nur-Lesen-Modus, diesmal aber
für die gesamte Dauer der Bearbeitung — potenziell mehrere Minuten statt
Sekundenbruchteile.

**Begründung für diesen bewussten Unterschied zum Micro-Lease-Prinzip:**
gleichzeitige Bearbeitung *desselben* Geschäfts durch zwei Personen ist
ein seltener Vorgang (anders als gemeinsames Abhaken während eines Einkaufs,
wo Gleichzeitigkeit der Normalfall ist) — ein session-langer Lease ist hier
vertretbar und deutlich einfacher umzusetzen als ein Formular-Umbau auf
Entwurfs-Zustand oder ein entprellter (debounced) Save-Mechanismus (beide als
Alternativen geprüft, aber nicht gewählt).

**Betroffene Bildschirme (Session-Lease-Geltungsbereich):**
`GeschaeftDetailView` (inkl. Kategorie-Zuordnung direkt
auf dem Bildschirm), `GeschaeftStammdatenEditView`,
`KategorieHinzufuegenSheet`. `NeueKategorieSheet` ist bereits als Ausnahme mit
echtem Entwurfs-Zustand (lokale `@State`, erst bei „Sichern" per
`modelContext.insert(...)` übernommen) umgesetzt — hier reicht ein
Micro-Lease genau um diesen einen `insert`+Save-Moment, kein Session-Lease
nötig.

**Nebeneffekt (Bugfix):** Da bislang „Abbrechen" in `GeschaeftStammdatenEditView`
bereits getippte Änderungen nicht zurücknimmt (sie wurden schon live ins Modell
geschrieben), ändert sich das mit dem expliziten Save-am-Ende-der-Session-Ansatz
nicht automatisch — das bleibt ein separates, hier nicht behandeltes
UI-Verhalten, unabhängig vom Lease-Mechanismus.

## Vollständiger Schreibvorgang-Katalog

Vollständiger Code-Audit aller Stellen, die SwiftData-Modelle mutieren, damit
keine Schreibvorgänge unbeachtet bleiben. Zusätzlich zu den bereits genannten
Fällen (Artikel-Abhaken, Geschäfte-Bearbeitung):

**Dual-Mode-Views (Klarstellung, keine neue Entscheidung nötig):**
`ArtikelEditView` und `GeschaeftStammdatenEditView` werden sowohl fürs
**Anlegen** (Entwurf im Speicher, `modelContext.insert(...)` erst bei
„Sichern") als auch fürs **Bearbeiten bestehender Objekte** (Live-`@Bindable`,
siehe oben) verwendet. Beide Modi brauchen unterschiedliche Behandlung je
`istNeu`-Flag: Anlegen → Micro-Lease genau um den `insert`-Moment (wie
`NeueKategorieSheet`); Bearbeiten eines bestehenden Objekts → Session-Lease
wie oben beschrieben.

**Diskrete Einzelaktionen (Micro-Lease, konsistent mit Artikel-Abhaken):**
- `ArtikelListView.artikelLoeschen`, `GeschaeftListView.geschaeftLoeschen`
  (Swipe-Löschen).
- `ArtikelHinzufuegenView.hinzufuegen` (einzelne Eigenschafts-Änderung
  `istAufEinkaufsliste = true`).
- `Einkaufsvorgang.artikelAbwaehlen`, `Einkaufsvorgang.artikelDauerhaftEntfernen`
  — gleiche Kategorie wie das bereits behandelte `artikelAbhaken`.
- Einkaufsvorgang **starten** (`EinkaufenView.einkaufSicherstellen`, automatisch
  beim Betreten des Einkaufen-Bildschirms statt per Tap ausgelöst): fällt
  ebenfalls unter Micro-Lease — die automatische Auslösung ändert nichts an
  der Kürze/Diskretheit des Schreibvorgangs (Insert eines einzelnen neuen,
  leeren `Einkaufsvorgang`s). Bei einem seltenen Zusammentreffen mit einem
  fremden Micro-Lease gilt dieselbe „kurz zurückstellen"-Behandlung wie
  überall sonst.
- Kategorie-Einzelaktionen *innerhalb* von `GeschaeftDetailView`
  (`regalHinzufuegen`, `regalLoeschen`, `regalVerschieben`,
  `kategorieEntfernen`) benötigen **keine eigene** Lease-Behandlung — sie
  passieren, während die Session-Lease dieses Bildschirms ohnehin schon
  gehalten wird.
- `EinkaufenView.standortFuerGeschaeftUebernehmen`/`adresseGeocodierenUndUebernehmen`
  und `AdresseEingebenSheet.sichern` (Koordinaten/Adresse nachträglich an einem
  bereits bestehenden `Geschaeft` ergänzen, siehe `docs/GESCHAEFTSERKENNUNG.md` →
  „Standort nachträglich für ein bereits genutztes Geschäft ergänzen“) — gleiche
  Kategorie wie `ignorierenVorschlag`.
- `BelegScanView.artikelDauerhaftIgnorieren` (Wischen nach rechts auf einer
  Belegposition, siehe `docs/BELEGSCAN.md` → „Dauerhaft ignorierte Artikel pro
  Geschäft“) — gleiche Kategorie wie `ignorierenVorschlag`.

**Gebündelte Aktionen (teilen sich einen Lease statt einen eigenen zu bekommen):**
- Einkaufsvorgang **abschließen** (`endZeit` setzen) und der direkt im selben
  Tap ausgelöste Lernschritt (`WarengruppenDistanzService.verarbeiteEinkauf`)
  sind fachlich eine Aktion — ein Micro-Lease für
  beide zusammen, kein zweiter Erwerb für den Lernschritt.

### Gewählte Parameter (Zusatzfälle)

| Fall | Wert | Begründung |
|---|---|---|
| `BelegScanView.uebernehmen()` (mehrere Belegpositionen in einer Schleife, ein Tap „Preise übernehmen") | **Ein Micro-Lease um den gesamten Vorgang**, nicht pro Position | Fachlich eine einzige Aktion; mehrere kleinere Sperren pro Zeile hätten keinen Vorteil, da die ganze Aktion ohnehin kurz bleibt (Bruchteile bis wenige Sekunden je nach Beleglänge). |
| `SeedData.seedeStandarddatenFallsLeer` (Race bei zeitgleichem Erst-Start zweier Geräte gegen einen leeren, noch nicht synchronisierten Store) | **Nicht extra abgesichert** | Sehr seltener Randfall (setzt exakt zeitgleichen Erst-Start zweier Geräte gegen denselben leeren Ordner voraus). Folge wären rein kosmetische doppelte Standard-Kategorien, kein Datenverlust, keine Korruption — im Zweifel manuell löschbar. Zusatzaufwand steht in keinem Verhältnis zum Risiko. |

**Rein lesend, keine Lease-Betrachtung nötig:** `AISuggestionService` schreibt
nichts direkt — Vorschläge werden nur als In-Memory-Struct zurückgegeben, die
angewandte Änderung läuft über das bereits behandelte `ArtikelEditView`.

## Datentransfer-Schätzung

Zentrale Anforderung (Nutzervorgabe): minimaler Datentransfer pro Zugriff, da
Geschäfte oft schlechte Verbindungen haben. Antwort auf „muss jedesmal die ganze
Datenbank gelesen werden, oder reicht ein Fragment?": **es reicht ein Fragment —
aber nur, wenn der WAL-Checkpoint bewusst NICHT bei jedem Schreibvorgang erzwungen
wird** (siehe Korrektur in Schritt 3 oben).

**Grundmechanik:** SwiftData/SQLite nutzt bereits WAL-Modus (erkennbar an den
existierenden `-wal`/`-shm`-Sidecar-Dateien, die das frühere `DatabaseLocationService`
mitkopierte). Im WAL-Modus werden neue Schreibvorgänge zunächst nur an die
`-wal`-Datei angehängt; die (große, mit der Zeit wachsende) Haupt-`.sqlite`-Datei
bleibt unverändert, bis ein Checkpoint sie zurückschreibt. SQLite checkpointed
automatisch von selbst, sobald die WAL-Datei einen Schwellwert überschreitet
(Standard: ca. 1000 Seiten ≈ 4 MB) — dafür ist **keine eigene Logik nötig**,
solange kein zusätzlicher, expliziter Checkpoint pro Micro-Lease erzwungen wird.

**Daraus ergeben sich zwei sehr unterschiedliche Kostenfälle:**

| Fall | Was wird übertragen | Geschätzte Größe | Wie oft |
|---|---|---|---|
| Normaler Schreibvorgang (Artikel abhaken) | Nur der neu angehängte Teil der `-wal`-Datei | grob 10–30 KB (SQLite arbeitet seitenbasiert, ca. 4 KB pro berührter Seite × wenige berührte Tabellen/Indizes pro Schreibvorgang) | Bei jedem Abhaken |
| Erstmaliges/kaltes Öffnen eines Geräts ohne aktuelle lokale Kopie | Komplette Store-Dateien (`.sqlite` + `-wal` + `-shm`) | niedriger einstelliger MB-Bereich für ein typisches Haushalts-Nutzungsjahr (siehe unten) | Selten — nur bei erstem Zugriff oder nach langer Offline-Zeit/lokal geleertem Cache |
| Automatischer WAL-Checkpoint (SQLite-intern, ca. alle 4 MB WAL-Wachstum) | Komplette Haupt-Store-Datei | wächst mit der Zeit (siehe unten) | Selten (grob geschätzt alle paar Wochen bis Monate normaler Haushaltsnutzung, nicht pro Einkauf) |

**Warum die Datenbank klein bleibt:** Codeprüfung bestätigt, dass keine Fotos/Blobs
in der Datenbank gespeichert werden (`Models/` enthält keine `Data`-Attribute) —
der Belegscan speichert nur die daraus extrahierten Werte (Preis, Menge,
Produktname), nicht das Bild selbst. Bei realistischer Haushaltsnutzung (grob
geschätzt: einige hundert `Artikel`, ~20 abgehakte Positionen pro Einkauf, 1–3
Einkäufe/Woche) wächst die reine Zeilendatenmenge nur um überschlägig ein bis
wenige MB pro Jahr — auch der „teure" Fall (kompletter Re-Sync) bleibt damit
realistisch im Sekundenbereich selbst bei schwacher Verbindung.

**Wichtiger Vorbehalt (Schätzung, keine Messung):** Ob ein Cloud-Anbieter beim
Hochladen einer geänderten Datei tatsächlich nur die geänderten Bytes überträgt
(Block-Level-/Delta-Sync) oder die ganze (dann aber ohnehin kleine) `-wal`-Datei
komplett neu hochlädt, unterscheidet sich zwischen Box Drive/OneDrive/Synology
Drive/iCloud Drive und ist nicht einheitlich dokumentiert. Das Design verlässt
sich deshalb *nicht* auf Delta-Sync als Voraussetzung, sondern ausschließlich
darauf, dass die pro Schreibvorgang **geänderte Datei** (die kleine `-wal`-Datei)
klein bleibt — das ist unabhängig vom Delta-Sync-Verhalten des jeweiligen
Anbieters wirksam. Eine reale Messung mit einem tatsächlich installierten
Cloud-Client sollte vor dem produktiven Einsatz erfolgen, um diese Schätzung zu
verifizieren.

## Bekannte Grenzen

- **Kein Merge, kein echtes Mehrbenutzer-Schreiben gleichzeitig** — es handelt sich
  um ein Single-Writer-Verfahren mit koordiniertem Lesezugriff für alle anderen,
  nicht um verteilte Konfliktauflösung. Für zwei Personen, die abwechselnd an
  derselben Einkaufsliste arbeiten, ist das ausreichend; für viele gleichzeitig
  aktiv schreibende Nutzer wäre einer der ursprünglich verworfenen Ansätze
  (CloudKit-Sharing oder eigener Server) nötig.
- **`NSFileVersion`-Konflikterkennung** (Apples API für parallel entstandene
  Dateiversionen) funktioniert zuverlässig nur für echte iCloud-Drive-Items.
  Box Drive, OneDrive und Synology Drive lösen Schreibkonflikte außerhalb der
  Lease (z.B. durch einen Bug oder durch Offline-Bearbeitung auf zwei Geräten
  gleichzeitig) typischerweise über eigene „Konfliktkopie"-Dateien — das
  Lease-Verfahren verhindert diesen Fall im Normalbetrieb, ist aber kein Ersatz
  für eine Anbieter-eigene Versionsverwaltung.
- Sidecar-Dateien (`-wal`, `-shm`) müssen denselben Koordinations-Scope wie die
  Hauptdatei durchlaufen; das frühere `DatabaseLocationService.kopiereStoreDateien`
  kopierte diese bereits mit, das Lease-Verfahren muss beim Checkpoint/Schließen
  sicherstellen, dass sie in konsistentem Zustand sind, bevor der Lease
  freigegeben wird.
- **Kein echter „Refresh-before-write"**: SwiftData bietet keine API, einen
  laufenden `ModelContainer` gezielt neu von der Datei einlesen zu lassen (siehe
  Schritt 2 oben) — abgesichert ist nur der konkrete Schreibpfad, an dem das
  fehlende Reload zu einer sichtbaren Inkonsistenz führen könnte
  (`Einkaufsvorgang.artikelAbhaken`, per Dedupe-Prüfung). Dieses Verhalten sollte
  im geplanten Live-Test mit mehreren Geräten (siehe `docs/LOGGING.md`) beobachtet
  werden, bevor produktiv genutzt.

## Verworfene Alternativen

Vor dieser Entscheidung wurden folgende Ansätze für echten Mehrbenutzerzugriff
geprüft und vom Nutzer bewusst abgelehnt (Cloud-Anbindung soll optional für die
Zukunft bleiben, kein Server/CloudKit jetzt):

- SwiftData + CloudKit Sharing (`CKShare`) zwischen mehreren Apple-IDs.
- SwiftData + CloudKit private Database (nur eigene Geräte, ein Account).
- Eigener Backend-Server (REST/GraphQL + z.B. PostgreSQL).
- Backend-as-a-Service (z.B. Firebase/Supabase).

**Zwei Bugs rund um den Bereich-A/B-Import verschoben:** „Neu beigetretenes
Gerät synchronisiert keine Bestandsdaten" (GitHub #52) und „Langsamer
App-Start durch Sync-Zyklus" (GitHub #55) gehören thematisch zur
Datensynchronisation, nicht zur hier beschriebenen lokalen
Schreibkoordination — verschoben nach
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 22.

## Behobener Absturz: fehlende `inverse`-Deklarationen führen zu baumelnden Referenzen

Wiederkehrender Absturz direkt beim App-Start: `SwiftData/BackingData.swift:1039:
Fatal error: This model instance was invalidated because its backing data could
no longer be found in the store`, ausgelöst beim Zugriff auf `Geschaeft.id` in
`SyncSnapshotExportService.erstelleSnapshot`. Auffällig: derselbe
`PersistentIdentifier` (`Geschaeft/p9`) trat über mehrere Launches und
App-Versionen hinweg unverändert wieder auf — ein Hinweis darauf, dass es sich
nicht um eine flüchtige Race (siehe `GeschaeftErkennungService`-Fix in
`docs/GESCHAEFTSERKENNUNG.md`), sondern um **bereits dauerhaft im Store
gespeicherte, kaputte Daten** handelte.

**Ursache:** Acht Relationship-Eigenschaften im Datenmodell hatten keine
`@Relationship(inverse:)`-Deklaration auf der Gegenseite:
`Einkaufsvorgang.geschaeft`, `Einkaufsvorgang.einkaufsliste`,
`KaufEintrag.artikel`, `KaufEintrag.kategorie`, `WarengruppenDistanz.geschaeft`,
`WarengruppenDistanz.kategorieA`, `WarengruppenDistanz.kategorieB` und
`Geschaeft.ausgeschlosseneKategorien`. Ohne diese Deklaration entfernt/nullifiziert
SwiftData eine solche Relationship beim Löschen des referenzierten Objekts
**nicht zuverlässig** — die Referenz bleibt als "baumelnder" Verweis auf eine
nicht mehr existierende Store-Zeile bestehen. Jeder spätere Zugriff auf eine
Eigenschaft dieser Referenz (auch nur `.id`) stürzt dann mit dem oben genannten
Fatal Error ab; das Lesen der Relationship-Referenz selbst (z.B. `vorgang.geschaeft`)
ist dagegen unauffällig, da SwiftData sie zunächst nur als Fault-Proxy liefert.

**Fix, zweistufig:**

1. **Zukünftige Korruption verhindern:** Alle acht fehlenden `inverse:`-Paare in
   `Geschaeft.swift`, `Einkaufsliste.swift`, `Artikel.swift` und
   `ArtikelKategorie.swift` ergänzt, jeweils mit passendem `deleteRule`
   (`.nullify`, wo die referenzierende Historie erhalten bleiben soll, z.B.
   `Einkaufsvorgang` nach Löschen seines `Geschaeft`s; `.cascade`, wo der
   referenzierende Datensatz ohne sein Ziel bedeutungslos wird, z.B.
   `WarengruppenDistanz`).
2. **Bereits bestehende Korruption defensiv abfangen:** `SyncSnapshotExportService.erstelleSnapshot`
   las an mehreren Stellen ungeprüft `.geschaeft?.id`/`.artikel?.id`/etc. — der
   einzige Aufrufpfad im Code, der das tat, und zugleich der, der bei jedem
   App-Start sofort läuft (`SyncPollingService.starten` löst beim ersten Zyklus
   unmittelbar `exportiereSnapshot` aus). Die Funktion baut jetzt für jeden
   referenzierten Modelltyp vorab ein `Set<PersistentIdentifier>` aus einem
   eigenen Fetch und liest jede Fremdreferenz über eine kleine Hilfsfunktion
   (`sichereID`/`sichereIDs`), die zuerst `persistentModelID` (reines
   Identitäts-Metadatum, sicher lesbar auch auf einer baumelnden Referenz) gegen
   dieses Set prüft, bevor sie `.id` liest. Eine bereits verwaiste Referenz wird
   dadurch still zu `nil`/ausgelassen degradiert statt die App zum Absturz zu
   bringen — und über `SyncDebugLogger` (`sync_baumelnde_referenz_gefunden`,
   mit Modelltyp und `PersistentIdentifier`) protokolliert, sofern der
   Sync-Debug-Modus aktiv ist, um zukünftige Funde nachvollziehbar zu machen.

Punkt 2 repariert die schon vorhandenen kaputten Datensätze nicht rückwirkend
(sie bleiben als „still ignorierte" Referenzen im Store liegen), verhindert aber
zuverlässig den Absturz beim Export — die einzige Stelle, an der sie bisher
zum Problem wurden.

## Nachtrag: rückwirkende Reparatur bereits bestehender Korruption

Derselbe `Geschaeft/p9`-Datensatz tauchte trotz Punkt 2 weiter als Absturz auf —
nur an einer anderen, ungeschützten Stelle: `GeschaeftHaeufigkeitService.favoriten`
liest `lhs.geschaeft.name` direkt auf einer über `Einkaufsvorgang.geschaeft`
gehaltenen (baumelnden) Referenz, `KaufEintrag.anzeigeName`/`PreisHistorieZeile`
entsprechend über `.artikel?.name`/`.geschaeft?.name`. Da praktisch jeder
Lese-Pfad im Code auf dieselbe Weise verwundbar sein kann, ist eine
Einzelfall-Absicherung wie `sichereID` (Punkt 2) an jeder Stelle nicht
praktikabel — stattdessen wird die Korruption jetzt an der Quelle **rückwirkend
repariert**, statt nur an einzelnen Lesepfaden abgefangen zu werden.

**Zweistufiges Vorgehen** (mit dem Anwender abgestimmt — ein rein manuelles
Verfahren würde den Absturz nicht zuverlässig verhindern, da er auf dem
allerersten Bildschirm nach dem Start auftreten kann, bevor der Anwender je das
Debug-Menü öffnet):

1. **`DatenintegritaetsService.pruefe(context:)`** — läuft still bei jedem
   App-Start (`ShopWithMeApp.init()`, vor `SyncPollingService`). Baut wie
   `SyncSnapshotExportService` für jeden betroffenen Modelltyp ein
   `Set<PersistentIdentifier>` gültiger Objekte und **erkennt** jede baumelnde
   Referenz: `KaufEintrag.artikel`/`.geschaeft`/`.kategorie`/`.einkaufsvorgang`,
   `Einkaufsvorgang.geschaeft`/`.einkaufsliste`, `Artikel.kategorie`
   (veraltetes Einzelwert-Feld), `WarengruppenDistanz`.
2. **`DebuggingView` → Sektion „Datenintegrität"** — zeigt den beim letzten
   Start erzeugten Bericht (persistiert über `DatenintegritaetsService.letzterBericht`),
   erlaubt eine manuelle erneute Prüfung sowie den Export des vollständigen,
   dauerhaften Protokolls (`DatenintegritaetsLogger`, anders als
   `SyncDebugLogger`/`DatabaseDebugLogger` **nicht** an einen Debug-Schalter
   gekoppelt).

**Korrektur (wichtig):** Ursprünglich versuchte `pruefe` (damals
`repariereFallsNoetig`) jede erkannte baumelnde Referenz auch gleich zu nullen
(z.B. `eintrag.artikel = nil`) bzw. bei `WarengruppenDistanz` die ganze Zeile
zu löschen. Das verursachte selbst einen Absturz (`Artikel/p19` in
`KaufEintrag.artikel.setter`, Crash-Log `ShopWithMe-2026-07-30-000333.ips`) —
und zwar bei **jedem** App-Start deterministisch, da der Absturz vor
`context.save()` auftrat und daher nichts vom vorherigen Lauf übernommen wurde
(vollständiger Crash-Loop). Ursache: SwiftDatas Setter für eine Beziehung mit
`inverse:`-Deklaration muss beim Nullen die **alte** Gegenseite auffalten, um
sich selbst aus deren inversem Array zu entfernen (hier `Artikel.kaufEintraege`)
— ist genau diese alte Gegenseite die bereits baumelnde, stürzt exakt dort
derselbe Fatal Error, den die Reparatur beheben sollte. `persistentModelID`
bleibt zwar sicher lesbar (siehe `sichereID` oben), das schützt aber nur
Lesezugriffe — **jede** schreibende Operation auf eine bereits baumelnde
Beziehung ist über die normale SwiftData-Objektgraph-API unsicher, gerade WEIL
die `inverse:`-Deklaration (die künftige Korruption verhindert) hier existiert.
Eine echte rückwirkende Reparatur bräuchte einen direkten Zugriff auf die
SQLite-Datei unterhalb von SwiftData/CoreData (nicht trivial, noch nicht
umgesetzt) — bis dahin ist `pruefe` bewusst rein lesend.

**Bewusst nicht (weiterhin):** eine blockierende Bestätigung vor der Anzeige —
das würde den Start verzögern, ohne einen Absturz zu verhindern (es wird ja
nichts mehr automatisch verändert). Die eigentliche Absturz-Absicherung muss an
den einzelnen Lesepfaden erfolgen (siehe `GeschaeftHaeufigkeitService.favoriten`
oben) — nicht (mehr) durch Reparatur des zugrundeliegenden Datenbestands.

## Nachtrag: nebenläufige Löschung während eines Micro-Lease-Erwerbs

Ein weiterer Absturz (`Artikel/p19`, in `KaufEintrag.artikel.setter`) hatte
eine völlig andere Ursache als die beiden Punkte oben: keine fehlende
`inverse`-Deklaration, sondern ein **Nebenläufigkeits-Fenster**. Muster:

```swift
let artikel = ausgewaehlterArtikel   // lebendige Referenz, z.B. aus @State
Task {
    await DatabaseLeaseService.performMicroLease(context: modelContext) {
        eintrag.artikel = artikel    // Absturz, falls artikel inzwischen weg ist
    }
}
```

`performMicroLease` awaitet zuerst den Lease-Erwerb — währenddessen läuft
`SyncPollingService`s eigener Hintergrund-Timer unabhängig weiter (ebenfalls
MainActor, eigener `Task`) und kann in genau diesem Zeitfenster das erfasste
Objekt löschen (z.B. per Tombstone eines Peers, siehe „Behobener Absturz:
fehlende `inverse`-Deklarationen" oben). Wird die vor dem `await` erfasste
Referenz danach ungeprüft in eine Relationship geschrieben oder mit `delete()`
gelöscht, stürzt das mit demselben SwiftData-Fatal-Error ab.

**Fix, generisch statt Einzelfall-Patches** (mit dem Anwender abgestimmt):
neuer Typ `ModelReference<T: IdentifizierbaresModell>`
(`Models/ModelReference.swift`) hält nur die stabile `id: UUID` statt der
lebendigen Referenz und löst erst unmittelbar vor der Verwendung — innerhalb
des Lease-Blocks, der nicht mehr unterbrochen werden kann — über
`resolved(in:)` frisch auf; ist das Objekt inzwischen weg, liefert er `nil`
statt eine ungültige Referenz weiterzureichen. `IdentifizierbaresModell`
(`Models/IdentifizierbaresModell.swift`) ist das dafür promotete, vormals
private Protokoll aus `SyncSnapshotExportService` (`sichereID`/`sichereIDs`
nutzen jetzt denselben gemeinsamen Typ statt einer eigenen Kopie).

Angewendet an allen gefundenen Stellen, an denen eine vor einem
`performMicroLease`-Aufruf erfasste Fremdreferenz (nicht nur ein gerade neu
angelegtes eigenes Objekt) innerhalb des Lease-Blocks verwendet wird:
`KaufEintragZuordnenSheet.speichern()`, `BelegScanView.uebernehmen()`,
`PreisschildScanView.uebernehmen()`, `EinkaufenView.umschalten(_:)`,
`GeschaeftListView.geschaeftLoeschen(_:at:)`,
`ArtikelListView.artikelLoeschen(_:)`, `ArtikelHinzufuegenView.hinzufuegen(_:)`/
`.entfernen(_:)`, `MilkForUsImportService.uebernehmen(...)`,
`PreisHistorieBereinigungService.bereinigen(...)`. Stellen, die ausschließlich
neu angelegte, noch nicht eingefügte Objekte einfügen (`context.insert(neuesObjekt)`),
sind von diesem Risiko nicht betroffen und bleiben unverändert.

## Nachtrag: verbleibende ungeschützte Lesepfade auf `Geschaeft`/`Artikel`

Der `Geschaeft/p9`-Datensatz (siehe „Behobener Absturz" oben) stürzte trotz
aller vorherigen Maßnahmen weiter ab — der eigentliche Datenbestand war nie
repariert worden (siehe „Nachtrag: rückwirkende Reparatur", Korrektur-Abschnitt:
eine automatische Reparatur ist über die normale SwiftData-API nicht sicher
möglich), nur die Absturz-Ursache wechselte zwischen verschiedenen ungeschützten
Lesepfaden. Bestätigt betroffen und jetzt abgesichert:
`GeschaeftHaeufigkeitService.favoriten` (`lhs.geschaeft.name`),
`KaufEintrag.anzeigeName` (`artikel?.name`), `PreisHistorieZeile.geschaeftName`
(`eintrag.geschaeft?.name`), `BelegScanView` (Geschäftsname-Anzeige,
KI-Zuordnungsvorschlag, `passtZu`-Namensabgleich) und
`EinkaufenView.MengenNotizSheet` (Einheit/Name eines
`EinkaufslistenEintrag.artikel`).

**Fix, generisch statt Einzelfall-Patches**: neue
`ModelContext.existiertNochImStore(_:)` (`Models/IdentifizierbaresModell.swift`)
prüft wie `sichereID` nur `persistentModelID` gegen einen frischen Fetch, statt
gegen ein vorab gebautes Set (bei den hier typischen kleinen Kollektionen
unkritisch) — nutzbar direkt mit `self.modelContext` bzw. `eintrag.modelContext`
(sicher lesbar, solange `self`/`eintrag` selbst kein baumelnder Verweis ist).
Darauf aufbauend zwei neue, wiederverwendbare Eigenschaften auf `KaufEintrag`:
`artikelNameSicher`/`geschaeftNameSicher` — liefern den Live-Namen, falls das
Objekt noch existiert, sonst den bereits vorhandenen `...NameSnapshot`. Beide
ersetzen jetzt jedes vormals ungeschützte `artikel?.name ??
artikelNameSnapshot`-Muster zentral an einer Stelle.

**Bleibt offen:** eine vollständige, systematische Garantie, dass *jeder*
künftige Lesepfad automatisch geschützt ist, gibt es nicht — jede neue Stelle,
die `.geschaeft?.name`/`.artikel?.name` o.ä. direkt liest, muss weiterhin bewusst
`existiertNochImStore`/die `...Sicher`-Eigenschaften verwenden.

**Nachtrag: Reparaturweg ohne SQLite-Direktzugriff gefunden** (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 24) — die hier noch als
„nicht trivial, noch nicht umgesetzt" eingeschätzte rückwirkende Reparatur
existiert inzwischen: ``SyncErsetzenService/planeBereinigungBaumelnderReferenzen(context:)``
nutzt aus, dass ein frischer Export baumelnde Referenzen ohnehin zu `nil`
auflöst, und baut die Datenbank ausschließlich daraus neu auf.

**Der gescheiterte Versuch, den Store zur Laufzeit physisch zu ersetzen**
(Crash-Details, Ursache, Lehre) ist nach
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 13a verschoben — er betraf
konkret `SyncErsetzenService`, nicht das hier beschriebene Lease-Verfahren.

## Diagnose-Logging (DB-Debug-Modus)

Für den geplanten Live-Test mit mehreren Geräten ist ein optionaler,
standardmäßig deaktivierter Debug-Modus vorgesehen, der Probleme rund um
dieses Micro-Lease-Verfahren (Sync, Lock, Öffnen, Speichern) protokolliert.
Eigenständig dokumentiert in `docs/LOGGING.md` (Teil der projektweiten
Logging-/Debugging-Architektur, da weitere Diagnose-Mechanismen jenseits der
Datenbank absehbar sind) statt hier, um dieses Dokument auf das
Lease-Verfahren selbst fokussiert zu halten.

## Umsetzungsstand (Build 30)

Alle Punkte umgesetzt und per `xcodebuild build`/`test` verifiziert:

1. `ModelContext.autosaveEnabled = false` in `ShopWithMeApp.init()`.
2. `Services/DatabaseLeaseService.swift`: Lock-Datei-Erwerb/-Freigabe über
   `NSFileCoordinator`, Micro-Lease (`performMicroLease(context:mutate:)`) und
   Session-Lease (`DatabaseLeaseService.SessionLease`, referenzgezählt für
   verschachtelte Bearbeitungs-Bildschirme, mit 30-Sekunden-Heartbeat).
3. Explizite, Lease-geschützte `save()`-Aufrufe an allen Stellen aus
   „Vollständiger Schreibvorgang-Katalog" ergänzt (Micro-Lease-Callsites in
   `Einkaufsvorgang`/`EinkaufenView`/`BelegScanView`/`ArtikelListView`/
   `GeschaeftListView`/`ArtikelHinzufuegenView`/`NeueKategorieSheet`/
   `ArtikelEditView`/`GeschaeftStammdatenEditView`; Session-Lease über
   `Views/SessionLeaseGate.swift` in `GeschaeftDetailView`/
   `KategorieHinzufuegenSheet`/den Bearbeiten-Pfaden von `ArtikelEditView` und
   `GeschaeftStammdatenEditView`). `SeedData` erhielt ebenfalls einen expliziten
   `save()` (ohne Lease, siehe „Vollständiger Schreibvorgang-Katalog").
4. Dedupe-Prüfung in `Einkaufsvorgang.artikelAbhaken` (fetchCount vor dem
   Anlegen eines `KaufEintrag`).
5. `SessionLeaseGate` zeigt bei belegtem Lease ein Nur-Lesen-Banner und
   deaktiviert den Inhalt; Micro-Lease-Wartezeiten sind kurze, stille Retries
   ohne eigenen UI-Indikator (siehe Restrisiko-Abwägung oben).
6. Diagnose-Logging: siehe `docs/LOGGING.md` (`DebugLogWriter`,
   `DatabaseDebugLogger`, `DatabaseDebugSettingsView`) — Micro- und
   Session-Lease-Ereignisse teilen sich dieselben Ereignistypen mit einem
   `"micro"`/`"session"`-Suffix im Detail-Text statt eigener Ereignistypen.
7. Tests in `ShopWithMeTests/DatabaseLeaseServiceTests.swift` (Erwerb, Konflikt,
   Stale-Timeout-Übernahme, Verschachtelung) und die Dedupe-Prüfung in
   `EinkaufsvorgangTests.abhakenErstelltBeiWiederholtemAufrufKeinDuplikat`.

**Noch offen:** ein echter Live-Test mit mehreren physischen Geräten gegen einen
tatsächlich installierten Cloud-Provider (Box Drive/OneDrive/Synology Drive/iCloud
Drive) — insbesondere zur Überprüfung der Datentransfer-Schätzung und des unter
„Bekannte Grenzen" dokumentierten fehlenden Store-Reloads. Dafür ist der
DB-Debug-Modus (`docs/LOGGING.md`) vorgesehen.
