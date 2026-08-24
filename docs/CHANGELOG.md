# Changelog

## v0.17 (Build 355) — Performance: Sync-Merge-Batching (#155, #159, #160)

Zweiter Batch der Performance-Aufarbeitung (#152–#164). Sync-Merge-Pfade, die
bisher pro Remote-Eintrag/Event einen eigenen SwiftData-Fetch auslösten, statt
vorhandene Batch-Muster derselben Datei wiederzuverwenden:

- **#155:** `SyncPeerZaehlerStand`/`WarengruppenDistanzPeerZaehlerStand`
  (G-Counter-Peerzähler) laden ihre Zeilen jetzt einmal pro Merge-Lauf
  (`mergeGeschaefte`/`mergeWarengruppenDistanzen`) in ein Dictionary vor,
  analog dem bereits vorhandenen `LokalerBestandCache`-Muster.
- **#160:** `mergeArtikelGeschaeftVerfuegbarkeiten` nutzt jetzt ein
  vorgeladenes Set aus (Artikel, Geschäft)-Paaren statt eines linearen
  `contains(where:)`-Scans pro Remote-Eintrag.
- **#159:** Der Bereich-A-Event-Replay (`SyncImportService.importiereNeueEvents`)
  nutzt für das `ArtikelListenKauf`-Sicherheitsnetz-Faktum jetzt denselben
  einmal geladenen Batch-Cache statt bei jedem Event auf den teuren
  Namens-Scan-Fallback zurückzufallen — neue `...AlsEventReplay`-Schreibpfade
  auf `Einkaufsliste`/`Einkaufsvorgang`, die sich die komplette
  Dedupe-/KaufEintrag-Logik mit den bestehenden Funktionen teilen (Single
  Source of Truth, kein Duplikat). Bewusst NICHT für den
  Multipeer-Einzelevent-Pfad geändert, wo ein Vorab-Laden sich nie amortisiert.

**#153 zurückgestellt:** der naheliegende Fix (Fetch+Mapping beim
Sync-Snapshot-Export überspringen, wenn sich seit dem letzten Zyklus nichts
geändert hat) wurde vor der Umsetzung verifiziert und dabei als auf Basis von
`LamportClock` unsicher erkannt — die Bereich-C/D-Merge-Pfade (Käufe, Preise,
Besuche) bumpen diesen Zähler nicht, ein darauf basierender Skip hätte echte
lokale Änderungen fälschlich nicht an Dritt-Peers weitergereicht. Finding
dokumentiert in GitHub #153, keine Umsetzung ohne sichere Grundlage.

## v0.17 (Build 354) — Performance: App-Start und Einkaufen-Hauptscreen entlastet (#152, #154)

Erster Batch einer mehrteiligen Aufarbeitung von 13 Performance-Issues
(#152–#164, KI-gestützte Review vom 2026-08-24): die beiden mit Abstand
heißesten Pfade der App.

- **#154:** `KaufEintrag.preisverlaufMigrierenFallsNoetig` fetchte bei jedem
  App-Start die komplette `KaufEintrag`-Tabelle, obwohl nach der einmaligen
  Migration nichts mehr zu tun ist — jetzt per `#Predicate` auf `preis != nil`
  eingeschränkt. `DatenintegritaetsService.pruefe()` und
  `migriereGeschaeftsAggregateFallsNoetig` fetchten `Einkaufsvorgang`
  mehrfach unabhängig voneinander innerhalb derselben Funktion — auf je einen
  gemeinsamen Fetch konsolidiert.
- **#152:** `EinkaufenView` wertete beim Rendern jeder sichtbaren Zeile die
  Mehrfachkategorisierung eines Artikels (inkl. SwiftData-Fetches) ein
  zweites Mal aus, obwohl die bereits berechnete Abteilungs-Gruppierung
  dieselbe Information enthält — jetzt einmal pro Render aus dieser Gruppierung
  abgeleitet. `ArtikelVerfuegbarkeitService.istVerfuegbar` fetchte `Abteilung`
  pro Listenelement neu statt einmal pro Aufruf des Aufrufers.

## v0.17 (Build 353) — Minor-Versionssprung: Sync-Diagnose & Sicherheitsnetz-Härtung gegen wiederbelebte Käufe

Bündelt die vorangegangenen v0.16-Änderungen dieser Session zu einem
Versionssprung: die neue Sync-Status-Übersicht in `DebuggingView`
(bekannte Peers, ausstehende Events, Multipeer-Catch-up-Status, letzter
voller Sync-Zyklus) sowie zwei zusammenhängende Live-Funde, bei denen das
Sicherheitsnetz gegen wiederbelebte Käufe (GitHub #99) einen Bereich-A-
Event-Replay-Pfad nicht abdeckte (Listen-Eintrag-Resurrektion sowie falsches
`KaufEintrag.datum`) — beide behoben und live über zwei unabhängige
Zwei-Geräte-Reproduktionen verifiziert.

Der obligatorische Testlauf für diesen Versionssprung (`docs/RELEASE_CHECKLIST.md`)
fing dabei selbst einen Regressionsfund ab: die erste Fassung des Listen-
Eintrag-Fixes blockte wegen einer falsch verstandenen `istOffen`-Randbedingung
JEDES `artikelHinzugefuegt`-Event, nicht nur die tatsächlich betroffenen —
vier automatisierte Tests schlugen sofort fehl und deckten es vor jeder
Freigabe auf. Details: `docs/DATENSYNCHRONISATION.md` §4.7.

## v0.16 (Build 352) — KaufEintrag-Datum bei Bereich-A-Event-Replay korrigiert

Direkter Folgefund zum vorigen Sicherheitsnetz-Fix: `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`
(genutzt von `SyncImportService.materialisiere`s `.artikelAbgehakt`-Zweig)
nahm keinen Zeitpunkt-Parameter entgegen — jeder per Bereich-A-Event-Replay
materialisierte `KaufEintrag` bekam dadurch den aktuellen Import-Zeitpunkt
statt des tatsächlichen historischen Kaufdatums, live bestätigt nach einem
Geräte-Neuaufbau. Verfälschte sowohl die Kaufhistorie-/Preishistorie-Anzeige
als auch den `zuletztAbgehaktAm`-Vergleichswert des Sicherheitsnetzes selbst
(macht dessen Prüfung höchstens zu konservativ, unterläuft sie aber nicht).
Neuer optionaler `am:`-Parameter (Default weiterhin `Date()` für lokales
Abhaken), analog dem bereits bestehenden Pendant bei `artikelHinzugefuegt` —
`SyncImportService.materialisiere` übergibt jetzt den ursprünglichen
Event-`wallClock`. Details: `docs/DATENSYNCHRONISATION.md` §4.7.

## v0.16 (Build 351) — Sicherheitsnetz gegen wiederbelebte Käufe auf Bereich-A-Event-Replay ausgeweitet

Live-Fund: Nach einem Geräte-Neuaufbau spielte der Datei-Kanal die komplette
historische Bereich-A-Event-Datei erneut ab — inklusive `artikelHinzugefuegt`-
Events für Artikel, die zwischenzeitlich (auf einem anderen Gerät) bereits
gekauft waren. Das Sicherheitsnetz gegen wiederbelebte Käufe (GitHub #99,
`docs/DATENSYNCHRONISATION.md` §4.7) deckte bisher nur den Bereich-B-Snapshot-
Merge ab, nicht diese direkte Event-Materialisierung — zwei unabhängige
Live-Reproduktionen zeigten 22 Artikel, die Sekunden nach einem korrekten
Snapshot-Merge (der sie zurecht ausschloss) durch den nachfolgenden
Event-Replay dauerhaft zurück auf die offene Liste sprangen, ohne
Selbstheilung. `SyncImportService.materialisiere` prüft im
`.artikelHinzugefuegt`-Zweig jetzt denselben zeitstempel-basierten Vergleich
(`ArtikelListenKaufService.istOffen`) wie der Snapshot-Merge. Details:
`docs/DATENSYNCHRONISATION.md` §4.7.

## v0.16 (Build 350) — Sync-Status-Übersicht: Live-Diagnose für Peers, ausstehende Events und Multipeer-Catch-up

Neue Sektion in `DebuggingView` (Einstellungen → Debugging): zeigt live (alle
5s, solange der Bildschirm offen ist) die Anzahl bekannter Peers, je Peer
noch nicht importierte Event-Dateien, ob der letzte empfangene
Multipeer-Catch-up (Bereich B/C/D) tatsächlich angewendet oder wegen eines
gleichzeitig laufenden Datei-Zyklus übersprungen wurde, sowie den Zeitpunkt
des letzten vollständig erfolgreichen Sync-Zyklus. Live-Fund, der diese
Sektion motiviert hat: ein stabiler, mehrere Minuten unveränderter
Sicherheitsnetz-Stillstand (`docs/DATENSYNCHRONISATION.md` §4.7) war aus den
bisherigen Log-Dateien allein nur mühsam von einem noch laufenden Nachhol-Sync
zu unterscheiden — "0 ausstehende Events, trotzdem Divergenz" macht diesen
Fall jetzt auf einen Blick sichtbar. `MultipeerSyncService` bekam dafür einen
neuen `@Published`-Zustand (`letzterCatchUpVersuch`), `SyncImportService` eine
neue rein lesende Zählfunktion (`ausstehendeEventAnzahlJePeer`).

## v0.16 (Build 348) — Mögliche Duplikate: aktive Rückfrage statt passivem Badge

Die "N mögliche Duplikate prüfen"-Warteschlange (`SyncAbgleichKandidat`) war
bisher nur eine unscheinbare Zeile in Einstellungen → Sync-Ordner, ohne
Badge/Push — im vorigen Live-Fund (siehe Eintrag unten) blieb sie dadurch
unbemerkt, während unentschiedene Kandidaten die Listen sichtbar divergieren
ließen. `RootView` fragt jetzt bei jedem Vordergrund-Wechsel aktiv nach
(analog dem bestehenden "Gerät seit langem nicht gesehen"-Dialog), solange
noch Kandidaten offen sind — "Jetzt prüfen" öffnet direkt die
Duplikate-Auflösung, "Später erinnern" verschiebt auf den nächsten
Vordergrund-Wechsel. `AbgleichKandidatenSheet`/`AbgleichAnzeige` dafür aus
`SyncOrdnerSettingsView.swift` in eine eigene, gemeinsam genutzte Datei
ausgelagert. Details: `docs/DATENSYNCHRONISATION.md` §4.2.

## v0.16 (Build 347) — Ambiguitäts-Rückstellung: Selbst-Kollision innerhalb eines Batches behoben

Nutzerbericht: nach Beitritt eines komplett leeren Geräts zu einem Sync-Ordner
wichen die Einträge einer großen Einkaufsliste dauerhaft zwischen den Geräten
ab (~240 Artikel betroffen). Ursache: `LokalerBestandCache` (verwendet von
`mergeGeschaefte`/`mergeArtikel`/`mergeEinkaufslisten`) führte neu angelegte
Objekte per `nachfuehren` sofort in denselben Cache nach, den die
Ambiguitäts-Prüfung (Teilstring-/Koordinaten-Rückstellung, `SyncAbgleichKandidat`)
für nachfolgende Einträge desselben Batches abfragte — zwei voneinander
unabhängige, aber zufällig namensähnliche Objekte aus DEMSELBEN Peer-Snapshot
(z.B. „Milch"/„H-Milch") kollidierten dadurch fälschlich miteinander, obwohl
kein echter lokaler Altbestand existierte. Reproduzierbar auf einem leeren
Gerät, deterministisch bei jedem erneuten Import (keine Race Condition). Fix:
neues `LokalerBestandCache.lokalerBestand` (nur der ursprüngliche Fetch, nicht
per `nachfuehren` erweitert) — die drei Ambiguitäts-Prüfungen vergleichen jetzt
ausschließlich dagegen; der exakte Namenstreffer-Zweig (Schutz gegen doppelt
im selben Batch referenzierte Einträge, GitHub #105) bleibt bewusst gegen den
vollen, batch-inklusiven Bestand. Details: `docs/DATENSYNCHRONISATION.md` §4.2.

## v0.16 (Build 346) — Multipeer-Catch-up: erster Absturz-Fix reichte nicht, jetzt mit nonisolated-Methode behoben

Derselbe Absturz aus dem letzten Eintrag (`dispatch_assert_queue`-Fail im
`sendResource`-Completion-Handler) trat nach dem ersten Fix-Versuch
unverändert erneut auf, erneut mit Stacktrace belegt. Ursache des
Fehlschlags: der Handler wurde nur als lokaler, `@Sendable`-typisierter Wert
deklariert — `@Sendable` und Aktor-Isolation sind aber orthogonal, ein
innerhalb einer `@MainActor`-Methode geschriebenes Closure-Literal bleibt
trotz `@Sendable`-Typannotation weiterhin `MainActor`-isoliert. Tatsächlicher
Fix: eine echte `nonisolated static`-Methode
(`sendeCatchUpDateiUndBereinige`) — nur `nonisolated`-Methoden gehören zu
keinem Aktor und erzeugen Closures ganz ohne Aktor-Zugehörigkeit. Details:
`docs/DATENSYNCHRONISATION.md` §4.8.

## v0.16 (Build 345) — Multipeer-Catch-up: harter Absturz im sendResource-Completion-Handler behoben

Nutzerbericht mit Stacktrace: Absturz auf `com.apple.MCSession.callbackQueue`
(`dispatch_assert_queue`-Fail, `_swift_task_checkIsolatedSwift`) direkt beim
Abschluss des Catch-up-`sendResource`-Transfers (GitHub #125). Ursache: der
inline geschriebene Completion-Handler-Closure erbte automatisch
`MainActor`-Isolation von der umgebenden Methode, `MCSession` ruft ihn aber
nachweislich auf einer eigenen internen Queue auf — Swift erzwingt dafür zur
Laufzeit eine Isolationsprüfung, die hart abbricht. Fix: Completion-Handler
jetzt ein explizit als `@Sendable`, nicht-isolierter Funktionstyp deklarierter
lokaler Wert (Muster bereits an anderer Stelle in `MultipeerSyncService`
korrekt verwendet, `invitationHandler`). Details:
`docs/DATENSYNCHRONISATION.md` §4.8.

## v0.16 (Build 344) — Multipeer-Catch-up: UI-Blockade auf dem MainActor behoben

Nutzerbericht: App wurde auf einem frisch aus einem Peer-Snapshot befüllten
Gerät mit größerer Kaufhistorie direkt beim ersten Multipeer-`.connected`-
Event unresponsive (kein Absturzbericht, Konsolen-Log brach mittendrin ab —
typisches Bild eines Main-Thread-Hängers statt eines Signal-Crashs). Ursache:
der Catch-up-Sende-Pfad (GitHub #125) kodierte/hashte den kompletten
Bereich-B/C/D/Kaufhistorie-Zustand synchron auf dem `MainActor`, zusätzlich
einmal je verbundenem Peer wiederholt. Fix: der SwiftData-Fetch bleibt auf
dem `MainActor` (Vorgabe), läuft aber nur noch einmal pro Prüfung statt
einmal je Peer; Encoding/Hashing/Datei-Schreiben laufen jetzt per
`Task.detached` abseits des `MainActor`. Details:
`docs/DATENSYNCHRONISATION.md` §4.8.

## v0.16 (Build 341) — Multipeer-Catch-up-Sync für Bereich B/C/D (GitHub #125)

Ein per Multipeer verbundener Peer, der länger offline war, musste bisher für
Stammdaten/Kaufhistorie/Lerndaten trotzdem auf den nächsten dateibasierten
Sync-Zyklus (5s/60s) warten — nur Bereich A (Listen-Events) wurde bereits
sofort gespiegelt. `MultipeerSyncService` löst jetzt zusätzlich einen
Bereich-B/C/D-Catch-up aus, additiv zum unverändert als Quelle der Wahrheit
bleibenden Dateikanal: bei jedem Connect-Event UND periodisch (alle 20s)
während einer bestehenden Verbindung wird geprüft, ob sich der eigene Stand
seit dem letzten Versand an genau diesen Peer geändert hat (SHA256-
Fingerabdruck über den normalisierten Zustand, wiederverwendet aus dem
bestehenden Datei-Kanal-Mechanismus) — nur bei Abweichung wird das volle
Paket per `MCSession.sendResource` übertragen. Anwendung über dieselbe,
bereits idempotente Merge-Funktion wie der Datei-Import
(`SyncSnapshotImportService.mergePaket`), jetzt unter demselben
Re-Entranz-Schutz wie der Datei-Zyklus. Details:
`docs/DATENSYNCHRONISATION.md` §4.8.

## v0.16 (Build 339) — Sync-Ordner ließ sich nicht mehr setzen (doppelter `.fileImporter`-Konflikt)

Seit dem Hinzufügen von "Backup importieren…" (`.fileImporter`) reagierte der
ursprüngliche "Sync-Ordner"-`.fileImporter` auf derselben View beim Antippen
gar nicht mehr — kein Dialog, keine Fehlermeldung (bekanntes SwiftUI-Problem
bei mehreren `.fileImporter`/`.fileExporter`-Modifiern an derselben View).
Beide Importe teilen sich jetzt einen einzigen `.fileImporter`, gesteuert über
einen Typ-State (`aktiverDateiImport`). Ein erster Fix-Versuch koppelte diesen
Typ-State direkt an `isPresented`, was einen Folge-Bug erzeugte (Ordner
wählbar, aber Auswahl wurde nicht übernommen, da der Typ beim Schließen des
Sheets teils schon auf `nil` zurückgesetzt war, bevor die `completion`-Closure
ihn auswertete) — behoben durch Trennung von "Sheet sichtbar"
(`zeigeDateiImporter`) und "welcher Import war aktiv" (`aktiverDateiImport`).

## v0.16 (Build 338) — Vier Design-Konventionen umgesetzt (GitHub #141/#142/#143/#144)

- Einkaufslisten-Verwaltung: Zeilen ohne führendes Checklist-Icon (#141).
- Artikelliste: Sortierung aus eigenem Toolbar-Picker ins "…"-Menü verschoben (#143).
- Geschäfts-Vorschlags-Card: Location-Icon in Textfarbe statt Akzentblau (#142).
- Artikelliste: eigenes Suchfeld durch `.searchable(...)` ersetzt, analog
  `ProduktVerwaltungView` (#144).

Zwei neue Konventionen im `shopwithme-conventions`-Skill verankert:
Suchleisten-Konvention (`.searchable` als Standard, begründete Ausnahmen erlaubt)
und Icon-Farben-Konvention (Content-Icons in Textfarbe, Ausnahme bei fachlich
vorgegebener Farbe/Statusbedeutung).

## v0.16 (Build 337) — `ArtikelKategorie` → `Abteilung`, vollständige Modell-Umbenennung (GitHub #88)

Der `@Model`-Typ `ArtikelKategorie` sowie alle davon persistierten Relationship-/
Attributnamen heißen jetzt `Abteilung` (GUI-Text war bereits seit #62 auf
"Warengruppe" umgestellt — nur der Code-Begriff fehlte noch). Betrifft 89 Dateien:
Modell selbst (`ArtikelKategorie.swift` → `Abteilung.swift`), alle referenzierenden
Relationships in `Artikel`/`Geschaeft`/`KaufEintrag`/`WarengruppenDistanz`/
`GeschaeftTyp`, Sync-Snapshot/-Merge-Layer, Services, Views, Tests und Doku.

**Ohne SwiftData-Migration** — bewusste Nutzervorgabe, da die App noch in
Entwicklung ist und nur ein eigenes Gerät mit Testdaten betroffen war;
möglich, weil `SchemaV1` seit dem Schema-Reset vom 2026-08-22 (#128/#129)
ohnehin keinen Migrationsplan mehr hat. Sync-Wire-Format bewusst mitgebrochen
(`SyncEntitaetsArt`-String, `SyncSnapshot`-Feldnamen) statt CodingKeys-
Kompatibilitätslayer. Details/Begründung: `docs/DECISIONS.md`.

Volle Suite grün bis auf die vorbestehende, dokumentiert nicht-deterministische
OCR-Fixture-Drift in `BelegScanIntegrationTests` (unabhängig von dieser Änderung).

## v0.16 (Build 336) — MilkForUs-Import: Produktabgleich, Direkteinstieg, Haken-Button; Einkaufsliste ganze Zeile abhakbar (GitHub #139, #138, #140, #137)

- **#139 (Bug):** `MilkForUsImportService.uebernehmen` glich importierte Namen bisher
  nur gegen `Artikel.name` ab — ein importierter, konkreter Produktname erzeugte
  fälschlich einen doppelten, neuen generischen `Artikel` statt an das bestehende
  `Produkt` anzudocken. Gleicht jetzt zusätzlich (O(1)-indiziert) gegen `Produktname`
  ab und übergibt das gefundene `Produkt` an `Einkaufsliste.artikelHinzufuegen`.
  Vorschau-Badges ("vorhanden"/"neu") berücksichtigen Produktnamen ebenfalls.
- **#138:** MilkForUs-Import jetzt auch direkt aus einer geöffneten Einkaufsliste
  heraus startbar (`EinkaufenView.EinkaufslisteView`), nicht mehr nur über die
  Einkaufslisten-Verwaltung in den Einstellungen — Zielliste dabei fest auf die
  gerade geöffnete Liste vorbelegt (`MilkForUsImportView.vorbelegteZielliste`).
- **#140:** Der "Importieren"-Bestätigungsbutton zeigt jetzt ein Haken-Icon statt
  Text (Buttons mit reiner Bestätigungswirkung).
- **#137:** In der Einkaufsliste lässt sich jetzt die ganze Zeile (nicht mehr nur die
  kleine Checkbox) zum Abhaken antippen — die Mengenangabe bleibt als einzige
  Ausnahme über eine höherpriorisierte Geste ausgenommen.

Volle Suite grün bis auf die vorbestehende, dokumentiert nicht-deterministische
OCR-Fixture-Drift in `BelegScanIntegrationTests` (unabhängig von diesen Änderungen).

## v0.16 (Build 335) — EinkaufslistenAnzeigeService extrahiert (GitHub #110, schließt #107)

Letzter Baustein von #107: `EinkaufenView.swift`s private `EinkaufslisteView`
enthielt drei Anzeige-Entscheidungsmethoden (`verfuegbarkeitsgefiltert`,
`kategorienFuerAnzeige`, `kategorieGruppen`) — welche Artikel als "verfügbar"
gelten, unter welcher(n) Kategorie(n) ein Artikel angezeigt wird, wie die
Kategorie-Abschnitte sortiert werden (inkl. `AbteilungsDistanzService`-
gelernter Reihenfolge). Anders als Schritt 1/2 kein historischer
Live-Test-Bug — reiner Testbarkeits-/Struktur-Gewinn. Extrahiert nach
demselben Muster in `EinkaufslistenAnzeigeService`; die drei View-Methoden
sind jetzt dünne Call-Sites. 9 neue Tests in
`EinkaufslistenAnzeigeServiceTests`. Volle Suite weiterhin grün bis auf die
vorbestehende OCR-Fixture-Drift in `BelegScanIntegrationTests`.

Damit ist GitHub #107 (EinkaufenView/BelegScanView vermischen UI und
Domänenlogik) vollständig umgesetzt — alle drei Schritte extrahiert
(`EinkaufsvorgangAbschlussService`, `BelegUebernahmeService`,
`EinkaufslistenAnzeigeService`).

## v0.16 (Build 334) — BelegUebernahmeService extrahiert (GitHub #109, #107 Schritt 2/3)

`BelegScanView.uebernehmen()` (~160 Zeilen) war die letzte komplett
ungetestete Persistenz-Orchestrierung nach einem Kassenbon-Scan — entscheidet
je nach `BelegScanKontext`, ob ein `KaufEintrag` oder nur ein `Preispunkt`
entsteht, löst Artikel/Produkt pro Position auf (inkl. automatischer
Produkt-Neuanlage) und behandelt Tages-Preis-Kollisionen (GitHub
#76-Folgearbeit). Reines Struktur-Refactoring nach demselben Muster wie
Schritt 1 (`EinkaufsvorgangAbschlussService`): neuer stateloser
`BelegUebernahmeService` (`@MainActor`, da er `PreispunktService`/
`Produkt.aufgeloestesOderNeuesProdukt` aufruft), `BelegScanView.uebernehmen()`
bleibt dünne Call-Site (baut weiterhin die `ModelReference`s vor jedem
`await`, siehe kritische Randbedingung unten). `BearbeitbarePosition` ist
jetzt `internal` statt `private`, damit der Service sie referenzieren kann.

**Kritisch unverändert:** die `ModelReference`s werden weiterhin GANZ AM
ANFANG von `uebernehmen()` gebaut, vor dem Geocoding-`await` und dem
Lease-Erwerb-`await` — sonst droht bei einer zwischenzeitlich per
Sync-Tombstone gelöschten Referenz derselbe SwiftData-Fatal-Error wie bei
GitHub #100.

10 neue Tests in `BelegUebernahmeServiceTests` (alle drei
`BelegScanKontext`-Verzweigungen, beide Tages-Kollisions-Pfade, automatische
vs. bereits zugeordnete Produkt-Auflösung, Adress-/Alias-Lernen,
Regressionsschutz für einen zwischenzeitlich gelöschten Einkaufsvorgang).
Volle Testsuite grün bis auf die bereits vorbestehenden, unabhängigen
OCR-Fixture-Abweichungen in `BelegScanIntegrationTests` (KI-Modell-Drift
gegenüber den Fixture-Sollwerten, siehe `shopwithme-conventions`-Skill →
„Belegscan-Integrationstests" — nicht Gegenstand dieser Änderung).

## v0.16 (Build 333) — Einkaufsliste: offene Artikel löschen, Produktname statt Artikelname anzeigen

GitHub #136: In der laufenden Einkaufsliste (`EinkaufenView`) gab es für noch
offene (nicht abgehakte) Einträge keine Möglichkeit, sie per Wischgeste von
der Liste zu entfernen — nur „Menge verringern“/„Menge erhöhen“. Der
vorhandene „Dauerhaft entfernen“-Papierkorb-Swipe wirkte ausschließlich auf
bereits abgehakte (gekaufte) Artikel. Neue Methode
`EinkaufenView.entferneVonListe(_:)` nutzt dafür das bereits bestehende
`Einkaufsliste.artikelEntfernen(_:produkt:context:)` (gleiches Muster wie
`ArtikelHinzufuegenView.entfernen(_:)`) und wird für offene Zeilen jetzt
ebenfalls als Trailing-Swipe-Aktion angeboten — Beschriftung „Löschen“
(destructive), getrennt von „Dauerhaft entfernen“ bei bereits abgehakten
Zeilen. „Menge erhöhen“ bleibt wie bisher die per vollem Swipe auslösbare
Standardoption.

GitHub #135: Wurde beim Hinzufügen ein konkretes Produkt statt nur des
generischen Artikels gewählt, zeigte `ArtikelAbhakZeile` bisher trotzdem den
Artikelnamen als Titel und den Produktnamen zusätzlich in einer eigenen
Zeile vor der Notiz. Der Titel zeigt jetzt `eintrag?.produkt?.name ?? artikel.name`
— die zweite Zeile ist damit wieder ausschließlich der Notiz vorbehalten.

## v0.16 — MilkForUs-Import: schneller bei großen Listen, Fortschrittsanzeige, Importieren-Button oben rechts

Nutzerbericht 2026-08-24: der Import sehr großer MilkForUs-Listen dauerte lange,
ohne dass währenddessen sichtbar war, was passiert.

**Performance** (siehe `docs/MILKFORUS_IMPORT.md` → „Performance bei sehr großen
Listen“ für Details): der KI-Kategorieabgleich lief vorher streng nacheinander,
läuft jetzt mit bis zu 4 Kategorien gleichzeitig; die Artikel-Zuordnung beim
Übernehmen durchsuchte vorher für jeden importierten Artikel linear den kompletten
bestehenden Bestand, ist jetzt nach kleingeschriebenem Namen indiziert.

**Fortschrittsanzeige:** `ArtikelHinzufuegenService.gruppenMitVorschlag`/
`uebernehmen` melden optional `(erledigt, gesamt)` — `uebernehmen` läuft dafür
zusätzlich in Chunks à 25 Artikeln (je ein eigener kurzer Micro-Lease, statt
eines einzigen langen Schreibvorgangs ohne Zwischen-Renders). `MilkForUsImportView`
zeigt in beiden Phasen einen Balken mit Zähler statt nur eines unbestimmten
Spinners.

**„Importieren“-Button** sitzt jetzt in der Navigationsleiste oben rechts
(`.confirmationAction`), nicht mehr als großer Button am unteren Bildschirmrand.

Neue Regressionstests in `MilkForUsImportServiceTests` (Chunk-Verarbeitung legt
Kategorie nur einmal an, Fortschritts-Meldungen vollständig).

## v0.16 — Fix: gesamte Zeile in „Artikel hinzufügen“ tappbar zum An-/Abwählen

In `ArtikelHinzufuegenView` reagierte nur der tatsächlich sichtbare Inhalt
(Badge + Name) einer Zeile auf Tap, nicht die leere Fläche bis zum Haken
rechts — `.frame(maxWidth: .infinity)` allein macht diesen Bereich in SwiftUI
noch nicht tappbar. Alle drei betroffenen Zeilen-Buttons (Artikel-Hauptzeile,
„Kein bestimmtes Produkt", Produkt-Unterzeile) haben jetzt zusätzlich
`.contentShape(Rectangle())`, damit die komplette Zeilenbreite zum An-/
Abwählen reagiert.

## v0.16 — Fix: Absturz beim Hinzufügen, wenn eine andere Liste einen bereits gelöschten Artikel referenzierte

`ArtikelListenKaufService.bestehenderEintragNamensgleich` durchsucht beim
Hinzufügen/Abhaken eines Artikels alle `ArtikelListenKauf`-Zeilen derselben
Liste nach einem namensgleichen Artikel. `ArtikelListenKauf.artikel` ist
(dokumentiert, analog `ArtikelGeschaeftVerfuegbarkeit`) ohne `inverse`
referenziert — wurde der referenzierte Artikel andernorts (typischerweise per
Sync-Merge eines Peers) gelöscht, blieb die Zeile mit einer baumelnden
`Artikel`-Referenz bestehen. Der Code las `$0.artikel?.name` ungeprüft, was
bei genau so einer Zeile mit dem bekannten SwiftData-Fatal-Error „This model
instance was invalidated because its backing data could no longer be found
in the store" abstürzte (Nutzerbericht 2026-08-24, Absturz beim Hinzufügen
eines Artikels über `ArtikelHinzufuegenView`). Jetzt wird — wie an allen
anderen Stellen dieser Datei bereits gehandhabt — vorab die Menge tatsächlich
noch existierender Artikel-IDs eingesammelt und jeder Kandidat per
`persistentModelID` dagegen geprüft, bevor `.name` gelesen wird. Neuer
Regressionstest `vermerkeHinzugefuegtStuerztBeiBaumelnderNachbarzeileNichtAb`
in `ArtikelListenKaufServiceTests`.

## v0.16 — Fix (Folgefund): wiederholte `Locale`-Neukonstruktion bei Artikel-Sortierung/-Suche

Nach dem ersten Performance-Fix (unten) blieb die Suche in
`ArtikelHinzufuegenView` bei ca. 1200 Artikeln weiter spürbar langsam.
`String.vergleicheAlphabetisch(mit:)` (app-weit für locale-bewusste
Sortierung genutzt, u.a. beim Gruppieren der Suchtreffer) und
`String.diakritikGefaltet` (Singular/Plural-Suche) erzeugten bei **jedem**
Aufruf ein neues `Locale(identifier: "de_DE")` — `vergleicheAlphabetisch`
läuft beim Sortieren von n Artikeln n·log(n)-mal, bei 1200 Artikeln also
mehrere Tausend Locale-Neukonstruktionen pro Tastendruck. Beide nutzen jetzt
ein einmalig angelegtes `static let`-`Locale`; `diakritikGefaltet` cacht
zusätzlich (wie zuvor schon `lemma`) den gefalteten Wortstamm pro
Eingabe-String.

## v0.16 — Fix: Artikel-hinzufügen-Suche bei >1000 Artikeln praktisch unbenutzbar

`ArtikelHinzufuegenView.gefilterteArtikel` filterte für **jeden** Artikel erneut
über die komplette `alleProdukte`-Liste (`alleProdukte.contains { $0.artikel ==
artikel ... }`), ebenso `produkte(fuer:)` — zusammen O(Artikel × Produkte) statt
O(Artikel + Produkte). Jetzt werden Top-Level-Produkte einmal pro `body`-Durchlauf
per `Dictionary(grouping:)` nach `Artikel.id` gruppiert (``produkteNachArtikelID``)
und beide Stellen schlagen dort nur noch nach.

Zusätzlich rief `String.passtAlsSingularPluralZu(_:)` (Singular/Plural-unabhängige
Suche, GitHub #44) bei jedem Nicht-Treffer der schnellen Heuristik ein
`NLTagger`-Lemma **neu** ab — auch für den Suchtext, der über einen kompletten
Filterdurchlauf unverändert bleibt. `String.lemma` cacht das Ergebnis jetzt nach
Eingabe-String (``String+SingularPlural.lemmaCache``).

Nutzerbericht 2026-08-24: bei ca. 1200 Artikeln schränkte das Suchfeld beim
Hinzufügen von Artikeln zu einer Einkaufsliste die Trefferliste nur noch extrem
langsam ein, ein Artikel ließ sich praktisch nicht mehr hinzufügen (jeder Tap löst
über `@Query` einen vollen Re-Render mit denselben teuren Berechnungen aus).

## v0.16 (Build 332) — Artikel manuell als Produkt/Alias eines anderen Artikels zusammenführen

`ArtikelEditView` hat eine neue Sektion „Zusammenführen" (nur bei bestehendem,
nicht bei neu angelegtem Artikel): „Als Produkt eines anderen Artikels
übernehmen" und „Als Alias zu einem anderen Artikel hinzufügen" öffnen jeweils
die bestehende ``ArtikelAuswahlSheet``-Zielartikel-Auswahl (dafür um einen
optionalen `ausschluss`-Parameter erweitert, damit der gerade bearbeitete
Artikel nicht sich selbst als Ziel wählen kann) und nach Bestätigung eines
erklärenden Alerts den bereits bestehenden `ArtikelZusammenfuehrungsService`
(`alsProduktKonvertieren`/`alsAliasAufloesen`, bisher nur aus der KI-
Dublettenerkennung erreichbar, siehe GitHub #133). Der Produkt-Merge bei
„Als Alias" war dort bereits eingebaut, keine weitere Logik nötig — nur der
manuelle Einstiegspunkt ist neu. Der aktuell bearbeitete Artikel wird durch
den Merge gelöscht, die Detailansicht schließt sich danach automatisch.

## v0.16 — Dauerhaftes Suchfeld in der Artikelliste, Dubletten-Übernahme-Crash behoben, Fortschrittsanzeige bei KI-Suche

`ArtikelListView` (Einstellungen → Artikel) hat das kollabierende
`.searchable(...)`-Suchfeld aus Build 328 durch ein dauerhaft sichtbares
Textfeld direkt unter der Navigationsleiste ersetzt — bewusst abweichend vom
sonstigen `.searchable`-Muster (``ProduktVerwaltungView``,
``AbteilungenVerwaltungView``), weil hier sofort beim Öffnen gesucht werden
soll, ohne erst per Pull-to-Search den Titel wegzuscrollen.

`ArtikelZusammenfuehrungsService.referenzenUmhaengen` griff beim „Übernehmen"
eines Dublettenvorschlags in `ArtikelDuplikatVorschlaegeView` auf `.id` und
`.enthaelt(...)` einer möglicherweise bereits baumelnden `Einkaufsliste`-
Referenz zu (`EinkaufslistenEintrag.einkaufsliste`/`ArtikelListenKauf.einkaufsliste`
sind ohne `inverse` deklariert) — stürzte ab, wenn eine referenzierte Liste
zwischenzeitlich (z.B. durch einen nebenläufigen Sync-Zyklus) bereits gelöscht
wurde. Jetzt wird vorab einmal die Menge tatsächlich noch existierender
Einkaufslisten-IDs eingesammelt und jede Referenz per `persistentModelID`
dagegen geprüft, bevor eine andere Eigenschaft gelesen wird (Muster wie
`ArtikelListenKauf.alleEintraege(context:)`).

`ArtikelDuplikatVorschlaegeView` zeigt während der kategorieweisen KI-Suche
jetzt einen Fortschrittsbalken („X von Y Kategorien") statt nur eines
unbestimmten Spinners.

## v0.16 (Build 331) — PreispunktZuordnenSheet auf ArtikelAuswahlSheet umgestellt (GitHub #130)

Letzter Baustein des #130-Rollouts: `PreispunktZuordnenSheet` hatte noch eine
eigene, handgeschriebene Suchliste zur Artikel-Auswahl — jetzt stattdessen
eine Zeile, die `ArtikelAuswahlSheet` als verschachteltes Sheet öffnet
(exakt das Muster aus `ProduktEditView`s "Artikel neu zuordnen"). Bewusst
NICHT umgestellt: `ArtikelHinzufuegenView` — dessen Toggle-ohne-Dismiss-
Verhalten, aufklappbare Produkt-Unterzeilen und Mengen-Badges passen nicht
zum generischen `AuswahlSheet`-Modell (dokumentierte Ausnahme, analog
`GeschaeftWahlSheet`, siehe `AuswahlSheet`-Typ-Doku).

## v0.16 (Build 330) — Artikel-Dubletten per KI erkennen und auflösen (GitHub #133)

Neuer „Dubletten finden"-Knopf in der Artikelliste (Einstellungen → Artikel,
nur bei verfügbarer Apple Intelligence): erkennt potenzielle Duplikate/
Varianten kategorieweise per KI (`AISuggestionService.artikelBeziehungsVorschlaege`)
und zeigt sie in `ArtikelDuplikatVorschlaegeView` zur Bestätigung. Der neue
`ArtikelZusammenfuehrungsService` löst einen Artikel entweder als Alias
(`alsAliasAufloesen`, mergt Namen über `Artikel.alternativenNamenLernen`) oder
als konkretes Produkt eines anderen Artikels auf (`alsProduktKonvertieren`) —
beide hängen Käufe, Einkaufslisten-Einträge, Verfügbarkeits-/Listen-Fakten
um und registrieren vor dem Tombstone-Löschen einen `SyncEntitaetsAlias`,
damit Peers, die die alte ID noch referenzieren, korrekt auflösen.

## v0.16 (Build 329) — Belegscan erkennt mehrere Geschäftsadressen (GitHub #132)

`BelegErgebnis.geschaeftAdresse: String` → `geschaeftAdressen: [String]` — viele
Bons drucken sowohl eine Filial- als auch eine Betreiber-/Zentraladresse im
Kleingedruckten. `Geschaeft.passendes(fuerErkannterName:erkannteAdressen:unter:context:)`
(neuer async Wrapper neben der unveränderten Einzeladress-Funktion) probiert
zunächst pro Adresse den bestehenden KI-freien Teilstring-Tie-Break, bevor bei
Uneindeutigkeit ein neuer KI-Ähnlichkeitsabgleich (`AISuggestionService.adressMatch`)
versucht wird, der auch OCR-Erkennungsfehler toleriert. `GeschaeftWahlSheet` zeigt
bei mehr als einer erkannten Adresse eine Auswahlliste für die Neuanlage.

## v0.16 (Build 328) — Suchfeld für Artikelliste (Einstellungen) ergänzt (GitHub #134)

Die Artikelliste unter Einstellungen → Artikel hatte als einzige der
vergleichbaren Verwaltungslisten (Produkte, Abteilungen) noch kein Suchfeld.
Jetzt `.searchable(...)` analog `ProduktVerwaltungView`, wirkt in beiden
Sortiermodi (alphabetisch und nach Abteilung).

## v0.16 — Preisscan/-schild: Preis-Ein-/Ausgabe folgt jetzt dem Locale (GitHub #131)

Preise wurden beim Belegscan/Preisschild-Scan bisher per direkter
`Decimal`-String-Interpolation angezeigt (immer „.“ als Dezimaltrennzeichen,
unabhängig vom Gerätelocale) und beim Speichern per manueller
Komma-durch-Punkt-Ersetzung geparst — inkonsistent mit der Anzeige, die nie
ein Komma erzeugte. Neu: `PreisEingabeFormat` (`Services/Decimal+PreisEingabeFormat.swift`)
formatiert/parst den Preistext beider Scan-Flows locale-bewusst (z.B. „3,10“
unter Deutsch) über einen gemeinsamen `NumberFormatter`.

## v0.16 (Build 327) — Fix (eigentliche Ursache): AuswahlSheet schloss sich beim allerersten Öffnen sofort wieder

Der vorherige Fix (siehe unten, „AuswahlSheet flackerten auf/zu") behob eine
reale Nebenwirkung, war aber nicht die eigentliche Ursache — der genauere
Live-Fund: `AbteilungHinzufuegenSheet` öffnete sich und schloss sich beim
**allerersten** Mal sofort wieder, ab dem zweiten Öffnen blieb es stabil
offen. Ursache: ``AuswahlSheet``s Suchfeld hing bislang bedingt an der
Eintragsanzahl (`.searchable(...)` nur ab 8 Einträgen). Startet das
zugrunde liegende `@Query` beim allerersten Öffnen eines frischen Sheets
kurzzeitig leer (0 Einträge, kein Suchfeld) und befüllt sich dann
innerhalb der ersten Renderdurchläufe auf die tatsächliche Anzahl, kippt
diese Bedingung mitten in der ersten Darstellung — ein `.searchable(...)`
strukturell dynamisch an-/abzuhängen ist eine bekannte SwiftUI-Stolperfalle
für genau solche Navigationsartefakte (das ganze präsentierte Sheet wirkt
dann wie geschlossen). Fix: Suchfeld ist jetzt immer eingeblendet,
unabhängig von der Eintragsanzahl.

## v0.16 (Build 326) — Fix: Abteilung/Artikel hinzufügen-Sheets flackerten auf/zu

Live-Fund direkt nach der #130-Umstellung: `AbteilungHinzufuegenSheet`,
`KategorieHinzufuegenSheet` und `ArtikelZuAbteilungHinzufuegenSheet`
verarbeiteten die SwiftData-Modellzuordnung bislang synchron im Setter des
an ``AuswahlSheet`` übergebenen Mehrfachauswahl-Bindings — führte dazu, dass
das Sheet beim Antippen eines Eintrags wiederholt auf- und zuflackerte
(vermutlich re-entrante Zustandsänderung mitten in der SwiftUI-Transaktion).
Die Zuordnung läuft jetzt stattdessen verzögert über `.onChange(of:)` auf
echtem `@State`, danach wird die Auswahlmenge sofort zurückgesetzt.

## v0.16 (Build 325) — AuswahlSheet auf drei weitere Abteilungs-/Artikel-Zuordnungssheets ausgeweitet

GitHub #130 (Folgeschritt): `AbteilungHinzufuegenSheet` (Geschäft →
Abteilung), `KategorieHinzufuegenSheet` (Artikel → Abteilung, in
`ArtikelEditView.swift`) und `ArtikelZuAbteilungHinzufuegenSheet` (Abteilung
→ Artikel, in `AbteilungenVerwaltungView.swift`) nutzen jetzt ebenfalls
``AuswahlSheet`` statt eigener Listen-Implementierung. Alle drei folgen dem
„sofortige Mehrfachzuordnung"-Muster (Tippen ordnet sofort zu, Eintrag
verschwindet aus der Liste, Haken-Button oben rechts schließt) — dafür neue
``AuswahlSheet``-Optionen: optionales Icon je Zeile, eine „+"-Neuanlage-Zeile
unabhängig vom Suchtext (`neuAnlegenNurBeiFehlendemTreffer`), sowie
anpassbarer Leerzustand-Text. `AbteilungHinzufuegenSheet` hat dadurch neu
auch ein Suchfeld (vorher keins). Verhalten für Anwender ansonsten
unverändert.

## v0.16 (Build 324) — Generisches AuswahlSheet für reine Listenauswahl-Sheets

GitHub #130: neue, wiederverwendbare Komponente ``AuswahlSheet`` (`Views/Components/AuswahlSheet.swift`)
für Sheets, die ausschließlich eine Auswahl aus einer Liste anbieten (bewusst
nicht für Sheets mit Sonderlogik wie Geocoding/Duplikat-Behandlung, z.B.
`GeschaeftWahlSheet`). Deckt ab: ganze Zeile auswählbar, Suchfeld ab
konfigurierbarer Mindestanzahl, alphabetische Schnellnavigation an der
rechten Kante ab 100 Einträgen (SwiftUI-Nachbau des `UITableView`-
Sektionsindex, den es dort nativ nicht gibt), Einfach- oder Mehrfachauswahl
(bei Mehrfachauswahl ein Haken-Button oben rechts zum Schließen — bei
Einfachauswahl schließt bereits der Zeilen-Tap), sowie eine optionale
„+"-Neuanlage-Zeile mit vom Aufrufer gelieferter Neuanlage-Ansicht.
``ArtikelAuswahlSheet`` (GitHub #123) als erster Verwender umgestellt,
Verhalten für Anwender unverändert.

## v0.16 (Build 323) — Multipeer-Vertrauensmodell gehärtet (Challenge-Response statt Klartext-Gruppenschlüssel)

GitHub #97: der Gruppen-Schlüssel für den Multipeer-Beschleunigungskanal
(`MultipeerSyncService`) wanderte bisher als fester, wiederverwendbarer
Hash-Wert im Klartext über Bonjour `discoveryInfo` bzw. den
Einladungs-Kontext — ein passiver Mitschnitt in Funkreichweite hätte damit
dauerhaft in eine fremde Einkaufsgruppe eintreten können. Ersetzt durch ein
Challenge-Response-Verfahren: der Advertiser broadcastet pro
Advertising-Session nur einen neuen Zufalls-Nonce, ein browsender Peer sendet
statt des Schlüssels selbst nur einen daraus und aus seiner eigenen
`MCPeerID` gebildeten HMAC-SHA256-Nachweis, den der Advertiser konstant-zeitig
verifiziert (`HMAC<SHA256>.isValidAuthenticationCode`). Das Schlüsselmaterial
selbst geht dadurch nie mehr über das Netz. Das TLS-Zertifikat selbst wird wie
zuvor ungeprüft akzeptiert — Vertrauen kommt weiterhin aus dem
Gruppenschlüssel-Abgleich, nicht aus einer PKI (dokumentierte Restlücke,
siehe Issue #97 sowie Typ-Doku `MultipeerSyncService.swift`).

## v0.16 (Build 322) — Mehrere Backup-Versionen, Löschen, Export/Import ins Dateisystem

Backup-Funktion erweitert (Nutzerwunsch): statt eines einzigen, bei jedem
„Ersetzen" überschriebenen Backups verwaltet die App jetzt bis zu 10
gleichzeitige Backup-Versionen (Einstellungen → „Synchronisation" →
„Backups"). Jeder Eintrag zeigt Datum, Größe und Anlass; antippen stellt ihn
wieder her, nach links wischen löscht ihn, nach rechts wischen exportiert ihn
als Datei in die Dateien-App/iCloud Drive. Neu: „Backup jetzt erstellen"
(manuell, jederzeit) und „Backup importieren…" (übernimmt eine zuvor
exportierte Backup-Datei, z.B. von einem anderen Gerät). Details siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 62.

## v0.16 (Build 318) — Solo-Peer-Aufräumen (Kaeufe-Dateien sofort, Events/Tombstones per Bestätigung)

GitHub-Bug-Report: auf einem Gerät, das aktuell der einzige Peer im Sync-Ordner
ist, blieben Sync-Event-Dateien, `SyncTombstone`-Einträge und
`kaeufe/{id}.json`-Dateien dauerhaft liegen (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt „Solo-Gerät räumt
Events/Tombstones/Kaeufe-Dateien nie auf"). Zwei unabhängige Ursachen: (1) der
dynamische Aufräum-Wasserstand liefert ohne bekannten anderen Peer bewusst
`nil`, was jeden automatischen Lauf sofort abbrechen ließ — neuer, manuell zu
bestätigender Weg in `DebuggingView` („Ich bin sicher, dass ich der einzige
Peer bin"). (2) `artikelAbwaehlen`/`artikelDauerhaftEntfernen` löschten einen
`KaufEintrag`, ohne die zugehörige exportierte Datei mitzulöschen — räumen
jetzt sofort selbst auf; der manuelle „KaufEintraege jetzt bereinigen"-Button
räumt zusätzlich bereits vorhandene Altlasten dieser Art mit auf.

## v0.16 (Build 315) — Multipeer-Sync abschaltbar, Menü umbenannt in „Synchronisation"

GitHub #127: neuer Schalter „Multipeer-Sync" in den Sync-Einstellungen
(`MultipeerSyncService.vonNutzerAktiviert`, UserDefaults-backed, Default an) —
`EinkaufenView` aktiviert den Nahbereich-Kanal beim Betreten des
Einkaufen-Bildschirms nur noch, wenn der Schalter an ist; wird er während eines
laufenden Einkaufs ausgeschaltet, trennt sich die Verbindung sofort. Der
Menüpunkt/Titel „Datensynchronisation" heißt jetzt „Synchronisation", da er
inzwischen mehrere Kanäle (Datei + Multipeer) bündelt.

## v0.16 (Build 308) — Sync „Ersetzen"/„Wiederherstellen" läuft jetzt live, ohne App-Neustart

Zweiter Anlauf (der erste, Build 138/139, stürzte auf einem echten Gerät ab —
siehe `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 50): neuer
`ModelContainerController` hält den `ModelContainer` austauschbar. Jeder
Austausch legt den Ersatz-Store an einem frischen, nie zuvor verwendeten
Dateinamen an statt die noch offene alte Datei wiederzuverwenden — genau das
war die Ursache des ursprünglichen Absturzes, nicht der Container-Tausch
selbst (laut Apple-DTS offiziell unterstützt). Die verwaiste alte Datei wird
erst beim nächsten Kaltstart aufgeräumt. Betrifft „Ersetzen durch Peer" beim
Sync-Beitritt, „Backup wiederherstellen", „Baumelnde Referenzen bereinigen"
sowie den automatischen Voll-Abgleich nach 30 Tagen Inaktivität
(`RootView.vollAbgleichAusloesen`) — alle vier liefen bisher über den
Neustart-Mechanismus aus `SyncErsetzenService`, der als Fallback (GitHub #119:
unlesbarer Store beim Boot) unverändert bestehen bleibt.

## v0.16 (Build 307) — Tombstone bei artikelAbwaehlen/-dauerhaftEntfernen verhindert Phantom-Käufe

`KaufEintrag` wurde beim Rückgängig-Machen eines Abhakens gelöscht, ohne
einen `SyncTombstone` anzulegen. Lief bei einem Peer der periodische
Bereich-C-Export zufällig in dem kurzen Fenster vor der Rücknahme, holte ein
anderes Gerät den längst zurückgenommenen Kauf per Union-by-ID-Merge
dauerhaft zurück — der Artikel erschien gleichzeitig als gekauft und
weiterhin offen auf der Liste (GitHub #126, Live-Vorfall mit 3 Geräten per
Multipeer-Sync).

## v0.16 (Build 305) — Sync-Aufräumen: Catch-all für verwaiste `kaeufe/`-Dateien

`SyncKaeufeExportService.raeumeVerwaisteDateienAuf(context:)`: löscht täglich
(aus `KaufEintragBereinigungService.automatischBereinigenFallsFaellig`) eigene
`kaeufe/`-Dateien, deren UUID keinem lokalen `KaufEintrag` mehr entspricht und
die älter als `karenzzeit` sind — Netz falls die reguläre Einzel-Löschung
fehlschlug. `ModellIDDuplikatSection` (GitHub #102, abgeschlossen) aus
`DebuggingView` entfernt. „Baumelnde Referenzen bereinigen"-Footer präzisiert.
`FileShareSyncConnector`-Diagnosezähler-Aufrufstelle korrigiert; `BelegScanView`
schreibt Artikel-Zuweisung jetzt atomar (vermeidet Stale-Capture-Race im
custom Binding).

## v0.16 (Build 304) — DebuggingView: Peer-Verwaltung → Datensynchronisation

`BekannteSyncPeersSection` aus `DebuggingView` in `SyncOrdnerSettingsView`
verschoben (passt thematisch zur Sync-Konfiguration). `AufraeumWasserstandSection`
erhält „Jetzt aufräumen"-Button, der die 24h-Sperre umgeht und Tombstones/
Event-Dateien sofort bereinigt.

## v0.16 (Build 303) — ProduktEditView: Akkordeon + Barcode + Preisdiagramm (#123)

Bekannte Namen je Geschäft jetzt als Akkordeon (Titel zeigt Anzahl der
Geschäfte) inkl. Barcode-Anzeige. Preishistorie als Liniendiagramm plus
„Datenpunkte"-Sheet mit Einzellöschung per Wischen.

## v0.16 (Build 302) — Preispunkte in ProduktEditView/ArtikelEditView einzeln löschbar

`PreisHistorieZeile` hatte den `loeschen`-Parameter bereits, wurde aber
nirgends übergeben — nachgezogen. Wischen nach links löscht den Eintrag
direkt im `ModelContext`.

## v0.16 (Build 301) — ProduktVerwaltungView: Wischen löscht Produkt; Artikel neu zuordbar

Swipe-to-delete (trailing edge) in `ProduktVerwaltungView` mit Micro-Lease.
`ProduktEditView`: antippbarer Button mit `ArtikelAuswahlSheet` ersetzt die
bisherige statische Artikel-Anzeige.

## v0.16 (Build 299–300) — BelegScanView: dreistufige KI-Artikel-Zuordnung (#123)

Text-Abgleich (Stufen 1+2) über `ArtikelZuordnungsService`, danach
Klarname-Ableitung aus Produkt-/Aliasname oder KI-Vorschlag, schließlich
KI-Artikel-Match auf Klarname-Basis (Stufe 3). `PositionsZeile`:
Klarname-`TextField` primär, Artikel als Button mit `ArtikelAuswahlSheet`.
Bugfix: `onSelect`-Callback feuert synchron vor `dismiss()` (SwiftUI-Timing).

## v0.16 (Build 298) — ArtikelHinzufuegenView: Menge anzeigen und per Tap verfeinern (#124)

Mengenanzeige links vom Haken für bereits hinzugefügte Artikel/ausgewählte
Produktzeilen; Tap öffnet `MengenNotizSheet` (wie in der Einkaufsansicht).
Preise aus der Artikelauswahlliste entfernt.

## v0.16 (Build 296–297) — Produkte: Neuanlage per „+"-Button, Artikel-Auswahl per Such-Sheet

„+"-Button in `ProduktVerwaltungView` (Einstellungen → Produkte) legt neue
Produkte direkt an — Artikel-Auswahl und Namenseingabe im selben Sheet, per
Such-Sheet statt Dropdown (`NeuesProduktSheet`).

## v0.16 (Build 295) — EinkaufenView: mehrere Produkte desselben Artikels als eigene Einträge

Lockert den Invariant von `(Einkaufsliste, Artikel)` auf `(Einkaufsliste,
Artikel, Produkt)`: z.B. Sebamed und Garnier können gleichzeitig unter
„Shampoo" stehen, als separate Zeilen unabhängig abhakbar. `SchemaV3` als
aktuelle Version etabliert (`SchemaV2Frozen` eingefroren).

## v0.16 (Build 294) — GeschaeftStammdatenEditView: Adresse per Karten-Tap entfernt (Issue #120)

Antippen der Standort-Karte befüllt das Adressfeld nicht mehr — Adresse ist
nur noch per Texteingabe oder Belegscan setzbar. Adress-Eingabe geokodiert
und zentriert die Karte jetzt immer, auch wenn bereits eine Koordinate
gesetzt war. Karte nutzt eine gebundene `MapCameraPosition` statt
`initialPosition`, bleibt aber frei zoom-/verschiebbar (GitHub #42).

## v0.16 (Build 293) — ArtikelHinzufuegenView: mehrere Produkte eines Artikels gleichzeitig auf die Einkaufsliste

Jedes `(Artikel, Produkt)`-Paar ist jetzt ein unabhängiger
`EinkaufslistenEintrag` — Produkt-Sub-Zeilen schalten ihren Eintrag an/ab
statt das Produkt am nil-Eintrag zu ersetzen. Abhaken im `EinkaufenView`
löscht alle Einträge des Artikels.

## v0.16 (Build 292) — Geschäfte: Filialen & Markenname

`Geschaeft.markenname: String?` gruppiert Filialen derselben Kette in der
Geschäfte-Liste (Einstellungen): Marken mit >1 Filialen werden als aufklappbare
`DisclosureGroup` angezeigt. Neues Textfeld „Marke / Kette" in
`GeschaeftStammdatenEditView`. `GeschaeftListEintrag`-Enum löst `AlphabetischeListenSektion`
in `GeschaeftListView` ab. Sync-Serialisierung (`GeschaeftSnapshot.markenname`) und
-Import (`mergeGeschaefte`) ergänzt. Additiv-optional — kein neues SchemaVN nötig.

## v0.16 (Build 283) — Fixture-basierte Belegscan-Integrationstests

`BelegScanIntegrationTests` + `ShopWithMeTests/Belege/`-Ordner: echte Kassenbon-Fotos
mit JSON-Soll-Zustand als Testfälle. Zwei Teststufen: OCR (deterministisch,
Simulator + Gerät) prüft ob Namen/Preise im Vision-Text auftauchen;
vollständige Pipeline (Apple Intelligence erforderlich) prüft Datum, Geschäftsname
und Positions-Trefferquote gegen den Soll-Zustand. Neue Testfälle: Bild + JSON in
`Belege/` ablegen, kein Code-Änderung nötig. `VisionFoundationModelsReceiptScanner
.erkenneText(in:)` von `private` auf `internal` für `@testable`-Zugriff. Dokumentation:
`docs/BELEGSCAN.md` → „Test-Infrastruktur", `ShopWithMeTests/Belege/README.md`.

## v0.16 (Build 282) — Minor-Versionssprung: konfigurierbare Listendarstellung

Enthält alle Änderungen aus v0.15 (SyncConnector-Abstraktionsschicht,
konfigurierbare Listendarstellung).

## v0.15 (Build 281) — Konfigurierbare Listendarstellung (Liste / Chips / Kacheln)

Hardcodierter `List/Section/ArtikelAbhakZeile`-Block in `EinkaufslisteView`
ersetzt durch modulares `EinkaufslisteDarstellungsView`-System: klassische Liste
(wahlweise Akkordeon, Fortschrittsbalken, Kategorie-Farbstreifen), Chips groß/klein
(`ChipFlowLayout`, Akkordeon, kein Icon bei groß) und Kacheln (2 oder 3 Spalten,
optional Kategorie-Farbhintergrund). Einstellungen -> "Listendarstellung"; alle
Optionen via `@AppStorage(DarstellungsKey.*)` persistiert. `ChipFlowLayout` aus
`EinkaufslisteDesignVarianten.swift` extrahiert und in `DesignSystem/` zentralisiert.

## v0.15 (Build 280) — SyncConnector-Abstraktionsschicht eingeführt

`SyncConnector`-Protokoll + `FileShareSyncConnector` als erste Implementierung
trennen den Dateitransport von der Merge-Logik. Mehrere Connectors können
gleichzeitig registriert sein; der Anwender wählt per Einstellung, welcher aktiv
ist (SwiftData bleibt in jedem Fall die interne Persistenz). Neue
Mehrgeräte-Szenariensimulator-Tests. Design-Varianten für EinkaufenView
und Einkaufsliste als Xcode-Previews hinzugefügt.

## v0.14 (Build 279) — `syncZyklus()` gegen sich selbst abgesichert (Re-Entranz-Schutz)

Direkter Folgefund zum Architektur-Review unten (Nutzerbericht 2026-08-11):
derselbe Live-Test, der `zuletztHinzugefuegtAm` bestätigte, zeigte danach
einen neuen Effekt — auf Bernhard verschwanden nach einer erneuten
Synchronisation mit Backup drei tatsächlich noch offene Artikel spurlos aus
der Liste (4 von 10 → 4 von 7 auf beiden Geräten). Diesmal keine
Merge-Logik-Ursache: `SyncOrdnerZugriffsDiagnose` protokollierte
`gleichzeitigOffen=importiereSnapshots` — zwei nebenläufige, unkoordinierte
Durchläufe von `SyncSnapshotImportService.importiereSnapshots(context:)`
gegen denselben `ModelContext`. Ursache: `SyncPollingService.syncZyklus()`
hat vier voneinander unabhängige Auslöser (Polling-Loop,
`SyncICloudAenderungsBeobachter`-Callback — spawnt bei jeder
Fremdänderungs-Benachrichtigung einen frischen `Task`,
`RootView.vollAbgleichAusloesen()`, `SyncOrdnerSettingsView.jetztSynchronisieren()`)
ohne jede gegenseitige Koordination; `@MainActor` verhindert nur echte
Parallelität, nicht das Überlappen zweier async-Aufrufe an deren
`await`-Punkten. Ein frischer Geräte-Neuaufbau mit großem Nachhol-Volumen
(viele schnelle Datei-Schreibvorgänge, viele iCloud-Benachrichtigungen)
macht diesen Überlapp praktisch wahrscheinlich.

Fix: neues `SyncImportService.vollstaendigerZyklusLaeuft` (analog zum
bestehenden `batchZyklusLaeuft`, das denselben Schutz bereits enger für den
Bereich-A-Batch bot) — `syncZyklus()` erwirbt es als erste Anweisung, ein
überlappender zweiter Aufruf überspringt seinen gesamten Durchlauf statt
einen konkurrierenden Merge-Pass zu starten. `MultipeerSyncService`s
Einzel-Event-Pfad prüft jetzt beide Sperren.

**Architektur-Audit auf Systemik geprüft** (dieselbe Frage wie beim
Review unten): drei weitere unabhängige Auslöser von `syncZyklus()`
identifiziert und mitabgesichert (nicht nur der eine beobachtete). Bereits
vorhandene Präzedenzfälle für dieselbe Grundursache
(`SyncPollingService`s unkoordinierter Hintergrund-Timer) bestätigt:
`ModelReference<T>` (Absturz durch nebenläufige Löschung einer erfassten
Referenz) und `SyncErsetzenService`s Verschiebung der eigentlichen
Store-Ersetzung auf den Kaltstart (schließt diese Klasse Wettlaufsituation
strukturell aus, statt sie zu jagen) — beide bereits gelöst, nur die
`syncZyklus()`-Selbstüberlappung war der verbleibende, noch offene Fall.
Details: `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: `syncZyklus()` konnte
sich selbst überlappen".

## v0.14 (Build 278) — Architektur-Review: robustes, additiv gemergtes Gegenstück zu `zuletztAbgehaktAm`

Nach drei aufeinanderfolgenden Live-Test-Funden am selben Symptom-Cluster
(„kurzzeitiges Flackern der Liste", dann „ein Artikel verschwindet trotzdem
noch einmal") ein Schritt zurück statt einer vierten Einzelpatch: die
eigentliche Root Cause war eine strukturelle Asymmetrie, kein weiterer
Randfall.

**Befund:** Die „schon gekauft"-Seite hatte mit `ArtikelListenKauf.zuletztAbgehaktAm`
bereits ein robustes, additiv gemergtes, monoton nur vorwärts laufendes
Faktum (G-Counter-artig, geräteübergreifend sicher). Die „hinzugefügt"-Seite
hatte KEIN Äquivalent — `EinkaufslistenEintrag.erstelltAm` sieht wie eine
Vergleichsbasis aus, ist aber keine: die Zeile wird beim Abhaken gelöscht und
beim erneuten Hinzufügen neu angelegt, und der Sicherheitsnetz-Merge übernimmt
dabei bewusst den ORIGINAL-Zeitpunkt des sendenden Geräts (verhindert
künstlich „frisch" aussehende Artikel nach einem Neuaufbau) — der kann
seinerseits von einem dritten Gerät geerbt, beliebig oft weitergereicht sein,
ohne jede monotone Absicherung. Jeder Vergleich gegen diesen unprotected
Rohwert blieb dadurch strukturell fragil.

**Fix:** neues, additiv-optionales Feld `ArtikelListenKauf.zuletztHinzugefuegtAm`
— exakt dieselbe Monotonie-Zusicherung wie `zuletztAbgehaktAm`, gepflegt an
beiden Stellen, an denen ein Artikel auf eine Liste kommt
(`Einkaufsliste.artikelHinzufuegenOhneEventAufzeichnung`, inkl. Durchreichen
des ursprünglichen `SyncEvent.wallClock` für den Bereich-A-Ereignis-Pfad statt
des lokalen Verarbeitungszeitpunkts; `mergeEinkaufslistenEintraege`). Beide
bisherigen Vergleichsstellen (`istBereitsAbgehakt`, `mergeKaufEintraege`s
Lösch-Entscheidung) nutzen jetzt dieselbe einheitliche Regel
`ArtikelListenKaufService.istOffen(hinzugefuegtAm:abgehaktAm:)` statt zweier
unabhängiger, teils fragiler Ad-hoc-Vergleiche. Zusätzlich direkt über den
eigenen `ArtikelListenKauf`-Sync-Kanal repliziert (`ArtikelListenKaufSnapshot`),
rückwirkend für Bestandsdaten befüllt
(`DatenintegritaetsService.migriereArtikelListenKaeufeFallsNoetig`).

**Regressionsfund während der Umsetzung:** die naive erste Fassung des Gates
in `istBereitsAbgehakt` (`if let bekannterEintrag`) behandelte eine Zeile, die
NUR wegen des eigenen `vermerkeHinzugefuegtFallsNoetig`-Aufrufs für DIESEN
Merge-Durchlauf frisch entstand (kein Kauf jemals bekannt), fälschlich wie
einen bekannten Kauf und blockierte dadurch ein legitimes Erst-Hinzufügen auf
einem Gerät ohne jede Kauf-Historie. Aufgedeckt durch
`vonSicherheitsnetzGeerbterEintragTaeuschtBeiWeitergabeKeineFrischeVor()`
(bewusst über zwei ECHTE, getrennte `ModelContext`s statt hartcodierter
Zeitstempel, siehe Test-Doku) — Fix: das Gate prüft jetzt gezielt
`bekannterEintrag?.zuletztAbgehaktAm != nil`, nicht die bloße Existenz der
Zeile.

**Architektur-Audit:** alle 19 `mergeX`-Funktionen in
`SyncSnapshotImportService` durchgesehen — dieselbe Asymmetrie (robustes
additiv gemergtes Faktum auf einer Seite, unprotected Rohwert auf der
anderen) kommt sonst nirgends vor. Die übrigen Merges folgen bereits
durchgängig sicheren Mustern: Union-nach-ID für unveränderliche Historie
(`KaufEintrag`, `Preispunkt`, `GeschaeftBesuch`), „nur fehlende Werte
ergänzen, nie überschreiben" für optionale Skalare, Mengen-Vereinigung für
Relationships, G-Counter (eigener-Beitrag-pro-Peer) für Zähler, gewichteter
Zuwachs-seit-zuletzt-gesehen für `WarengruppenDistanz.distanz`, Tombstones für
Löschungen.

Details: `docs/DATENSYNCHRONISATION_VERLAUF.md`.

## v0.14 (Build 277) — Sync-übernommener Einkaufsabschluss schließt jetzt auch andere offene Vorgänge derselben Liste mit

Bugfix (Nutzerbericht 2026-08-10: Backup schließt einen Einkauf ab, das
kommt auf Bernhard aber nie an — obwohl das Diagnose-Protokoll
`sync_einkaufsvorgang_abschluss_uebernommen` die korrekt übernommene
`endZeit` bestätigte, sogar über einen App-Neustart hinweg). Ursache: Bernhard
hatte NEBEN dem per ID getroffenen Vorgang noch einen zweiten, unabhängig
offenen Vorgang für dieselbe Liste (Diagnose-Zusatz bestätigte
`andereOffeneVorgaengeDerListe=2`) — genau an dem hing
`EinkaufenView/aktuellerEinkauf`. `mergeEinkaufsvorgaenge` übernahm bisher nur
die `endZeit` des per ID getroffenen Vorgangs, ließ den zweiten aber offen:
der Einkauf erschien auf dem Bildschirm trotz erfolgreich übernommener
`endZeit` weiterhin als aktiv, mit denselben abgehakten Artikeln. Fix: analog
zum lokalen „Einkauf abschließen"-Button
(`EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten`) schließt der
Sync-Merge jetzt alle plausibel gleichzeitigen (`startZeit <= remoteEndZeit`,
dasselbe Zeit-Gate wie beim `offenerTreffer`-Matching) offenen Vorgänge
derselben Liste mit — mit `zaehleAlsBesuch: false`, damit
`Geschaeft.eigeneAnzahlEinkaufsvorgaenge` nicht doppelt zählt. Neuer
Regressionstest `andererOffenerVorgangDerselbenListeWirdBeiSyncAbschlussMitgeschlossen`;
das Zeit-Gate verhindert nachweislich (bestehender Test
`mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert`),
dass ein historischer Catch-up-Import einen frisch danach angelegten
Platzhalter fälschlich mitschließt.

Zusätzlich Diagnose-Logging für einen zweiten, im selben Nutzerbericht
beobachteten Befund (Backup: Einkauf schließt ab, aber abgehakte Artikel
bleiben auf der offenen Liste stehen) —
`sync_kaufeintrag_merge_listeneintrag_entfernt` protokolliert bei
`mergeKaufEintraege`, ob der zugehörige `EinkaufslistenEintrag` beim
Peer-Snapshot-Merge tatsächlich gefunden und gelöscht wurde.

## v0.14 — `mergeKaufEintraege` löscht keine erneut hinzugefügten Listen-Einträge mehr

Bugfix (Nutzerbericht 2026-08-10, Folgetest zu obigem Fix: „während des
erneuten Syncs von Backup hat sich die Liste von Bernhard kurzfristig
verändert, bevor sich alles wieder eingependelt hat"). Live per Log bestätigt:
Bernhards `Einkaufsliste`-Zähler fiel binnen eines Zyklus von 5 auf 1 (Backups
eigener sogar auf 0), bevor er sich Zyklen später von selbst wieder auf den
korrekten Wert korrigierte. Ursache: `mergeKaufEintraege` (Bereich C) löschte
den zu einem frisch aus einem Peer-Snapshot übernommenen `KaufEintrag`
passenden offenen `EinkaufslistenEintrag` bisher bedingungslos — auch wenn
dieser `KaufEintrag` ein längst historischer Nachzügler aus einem großen
Nachhol-Merge war (z.B. beim Beitritt eines lange nicht synchronisierten
Geräts) und der Artikel als wiederkehrender Artikel NACH diesem alten Kauf
erneut auf die Liste gesetzt wurde. Ein Nachhol-Merge mehrerer solcher
Alt-Einträge in einem Zyklus konnte dadurch mehrere frisch erneut
hinzugefügte, eigentlich noch offene Listen-Einträge auf einen Schlag
entfernen — der Fehler heilte sich erst über das separate `listen`-
Sicherheitsnetz (`istBereitsAbgehakt`, siehe Build 274) in einem späteren
Zyklus wieder aus, aber bis dahin war die Liste sichtbar (und mit zwei
Geräten unterschiedlich) falsch. Fix: derselbe Zeit-Vergleich wie im
`listen`-Sicherheitsnetz — nur löschen, wenn `EinkaufslistenEintrag.erstelltAm`
NACHWEISLICH vor (oder zum selben Zeitpunkt wie) `KaufEintrag.datum` liegt,
der Kauf den Listen-Eintrag als offene Anfrage also tatsächlich erklären
kann. Neuer Regressionstest
`mergeKaufEintragLoeschtNichtErneutHinzugefuegtenListenEintragEinesAelterenKaufs`.
Das Diagnose-Ereignis `sync_kaufeintrag_merge_listeneintrag_entfernt` trägt
jetzt zusätzlich `entfernt=true/false`, um beide Fälle im Log zu
unterscheiden.

## v0.14 — Entfernen bekannter Geräte übersteht jetzt einen Neustart

Bugfix (Nutzerbericht: unter Debugging gelöschte bekannte Geräte waren nach
einem Neustart der App wieder da). Ursache: `SyncOrdnerService.entfernePeer`
löschte den lokalen `SyncPeerInfo`-Merkposten bisher nur im laufenden
`ModelContext`, ohne je `context.save()` aufzurufen — bei
`autosaveEnabled = false` (`docs/DATABASE_CONCURRENCY.md`) blieb das Löschen
rein im Speicher und ging verloren, sobald die App beendet wurde, bevor ein
unabhängiger späterer Save (z.B. der nächste Sync-Zyklus) es zufällig
mitschrieb. Betraf sowohl die manuelle Liste in `DebuggingView` als auch den
proaktiven „Gerät seit langem nicht gesehen"-Dialog (`RootView`), da beide
über `entfernePeer` laufen. Fix: das Löschen läuft jetzt wie überall sonst im
Projekt über `DatabaseLeaseService.performMicroLease`, das Mutation und Save
gemeinsam Lease-geschützt durchführt. Neuer Regressionstest
`entfernePeerUeberlebtNeustart` öffnet dazu einen zweiten `ModelContainer` auf
demselben dateibasierten Store, um einen echten App-Neustart nachzubilden
(die bisherige In-Memory-Prüfung im selben, weiterhin offenen Context hätte
den Fehler nicht erkannt).

## v0.14 (Build 276) — `mergeKaufEintraege` entfernt den offenen Listen-Eintrag jetzt

Bugfix (Nutzerbericht: nach einem Sync zeigte Backup „2 von 8" statt der
erwarteten „2 von 6" — zwei bereits auf Bernhard abgehakte Artikel standen
auf Backup weiterhin offen auf der Liste). Ursache: anders als das lokale
Abhaken löschte `mergeKaufEintraege` (Bereich C) den zugehörigen
`EinkaufslistenEintrag` nie, wenn es einen `KaufEintrag` direkt aus einem
Peer-Snapshot anlegte — ein Artikel blieb dadurch dauerhaft gleichzeitig
„offen" und „abgehakt". `EinkaufenView` filtert diesen Zustand seit GitHub
#52 zwar aus der Anzeige, aber die verwaiste Zeile blähte weiterhin den
Gesamtwert im Listentitel auf. Fix: der passende Listen-Eintrag wird jetzt
beim Merge mitgelöscht. Details: `docs/DATENSYNCHRONISATION_VERLAUF.md`
Abschnitt 57.

## v0.14 (Build 275) — `erstelltAm` wird beim Sicherheitsnetz-Import jetzt weitergegeben

Bugfix (eigener Code-Review-Fund direkt nach Build 274, noch vor dem
nächsten Nutzertest). `mergeEinkaufslistenEintraege` legte neue, über das
Sicherheitsnetz nachgeholte `EinkaufslistenEintrag`-Zeilen bisher immer mit
`erstelltAm = Date()` (lokaler Import-Zeitpunkt) an, statt den vom Peer
gemeldeten, tatsächlichen Zeitpunkt zu übernehmen — obwohl Build 274 genau
diesen Wert dafür extra exportierte. Bei jedem Geräte-Neuaufbau „alterte"
ein so nachgeholter Artikel künstlich auf „gerade eben hinzugefügt" zurück;
gab dieses Gerät seinen Bestand später an ein drittes Gerät weiter, das den
Artikel zwischenzeitlich selbst gekauft hatte, täuschte das eine Frische
vor und das Sicherheitsnetz holte ihn fälschlich zurück auf die offene
Liste — beobachtet als von „Backup" wiederbelebte, auf „Bernhard" bereits
abgehakte und abgeschlossene Artikel. Fix: der Peer-Zeitpunkt wird jetzt
explizit auf die neu angelegte Zeile übertragen. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 56.

## v0.14 (Build 274) — Sicherheitsnetz lässt erneutes Hinzufügen wiederkehrender Artikel wieder durch

Bugfix (Bestätigung des Verdachts aus Build 273 durch das neue
Diagnose-Protokoll — live bestätigt für mehrere real wiederkehrende Artikel
nach einem frischen Geräte-Neuaufbau). `ArtikelListenKauf` bekommt ein neues
additiv-optionales Feld `zuletztAbgehaktAm`, `EinkaufslistenEintragSnapshot`
symmetrisch `erstelltAm` (spiegelt das bereits lokal vorhandene, bisher nie
exportierte Feld). `istBereitsAbgehakt` lässt einen vom Peer gemeldeten
Listen-Eintrag jetzt durch, wenn dessen `erstelltAm` nachweislich NACH dem
letzten bekannten Kauf liegt — ein legitimes erneutes Hinzufügen statt einer
stale Resurrektion (der ursprüngliche GitHub-#99-Fall bleibt dabei
unverändert abgesichert, mit Regressionstest belegt). `zuletztAbgehaktAm`
wird geräteübergreifend additiv als Maximum gemergt. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 55.

## v0.14 (Build 273) — Diagnose-Protokoll für stumm übersprungene Listen-Einträge im Sicherheitsnetz

Diagnose (Nutzerbericht: Vorgangs-Abschluss synchronisiert jetzt sauber,
aber ein Artikel fehlte nach frischem Neuaufbau — Sync-Kanal selbst gezielt
gegengeprüft und für in Ordnung befunden). Verdacht: das
`EinkaufslistenEintrag`-Sicherheitsnetz (`mergeEinkaufslistenEintraege`)
verwirft einen vom Peer aktuell gemeldeten Eintrag bedingungslos, sobald
`ArtikelListenKauf` diesen Artikel auf dieser Liste bereits als „jemals
gekauft" führt — anders als der ältere Fallback direkt darunter prüft dieser
neuere Zweig `istAusDerZeitGefallen` nicht, obwohl die Typ-Doku genau das
voraussetzt. Bisher komplett stumm, daher noch keine Verhaltensänderung:
neues Protokollereignis `sync_listeneintrag_sicherheitsnetz_uebersprungen`
macht sichtbar, ob dieser Zweig im konkreten Fall tatsächlich zuschlägt,
bevor die bewusst scharf gezogene Schutzregel (GitHub #99) angetastet wird.
Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 54.

## v0.14 (Build 272) — Kanonisches Vorgangs-startZeit wandert mit dem frühesten bekannten Beginn

Bugfix (Folgefund direkt nach Build 271, Nutzerbericht: Gerät war während
der Änderungen des Peers komplett offline, danach blieben dessen bereits
abgehakte Artikel trotzdem aktiv/„Einkauf abschließen" wartend). Ursache:
ein Gerät, das eine Weile offline war, legt beim Wiedereinstieg zwangsläufig
einen eigenen Platzhalter-Vorgang mit einem `startZeit` NACH dem
tatsächlichen, auf der Gegenseite längst laufenden Einkauf an — die
Plausibilitätsprüfung aus Build 271 verglich einen kurz danach eintreffenden
Abschluss weiterhin gegen dieses zu späte eigene `startZeit`, obwohl der
Vorgang über `offenerTreffer` bereits korrekt als derselbe reale Einkauf
erkannt war. Fix: sobald ein Vorgang aufgelöst ist, wandert sein `startZeit`
auf das Minimum aus bisherigem und neu bekanntem Wert (nur nach früher, nie
zurück) — analog zum bereits bestehenden „ältester startZeit gewinnt"-
Tiebreaker in `Einkaufsvorgang.kanonischer(unter:)`. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 53.

## v0.14 (Build 271) — offenerTreffer-Zeitprüfung: eigener Vorfix blockierte Abschluss-Übernahme beim gemeinsamen Live-Einkaufen

Bugfix (eigene Regression, Nutzerbericht: Bernhards „Einkauf abschließen"
kam bei Backup nie an, 3 Artikel blieben dort fälschlich aktuell abgehakt).
Der vorherige Fix (offenerTreffer matcht nur noch bei `eintrag.endZeit ==
nil`) verhinderte zwar zuverlässig, dass ein frischer Platzhalter mehrere
längst abgeschlossene historische Peer-Vorgänge auf sich aliasiert — war
damit aber zu grob und blockierte auch den eigentlich vorgesehenen
Regelfall: Gerät A schließt ab, Gerät B (eigener offener Platzhalter
derselben Liste) sieht den Vorgang beim ersten Sync-Kontakt bereits als
abgeschlossen. Ersetzt durch eine Zeit-Plausibilitätsprüfung VOR der
Aliasierung (`remoteEndZeit >= kandidat.startZeit`, dieselbe Regel, die
weiter unten ohnehin schon über die Übernahme der `endZeit` entscheidet) —
unterscheidet "plausibel dieselbe laufende Sitzung" von "eindeutig
historisch". Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 52.

## v0.14 (Build 270) — Warnung beim Anlegen eines Artikels mit bereits vorhandenem Namen

Feature (Nutzerbericht-Folgefund): tatsächliche Ursache der vorherigen
Listen-Diskrepanz war keine Sync-Ursache, sondern eine rein lokal
entstandene Artikel-Dublette (zwei unabhängig angelegte Artikel gleichen
Namens) — der namensbasierte Sync-Merge führt solche Dubletten nur beim
Import eines fremden Snapshots zusammen, nie auf rein lokalen Daten.
`ArtikelEditView` zeigt jetzt eine Warnung (kein Speicher-Block), sobald der
eingegebene Name bereits einem anderen Artikel gehört (case-insensitiv,
wie beim Sync-Merge). Neue, testbare Logik: `Artikel.dublette(name:alle:ausgenommen:)`.

## v0.14 (Build 269) — Datenintegritätsprüfung erkennt baumelnde `EinkaufslistenEintrag`-Referenzen

Bugfix-Folgefund (Nutzerbericht: nach dem vorherigen Fix korrekt 0 abgehakte
Artikel, aber „Backup" dauerhaft 2 Einkaufslisten-Einträge weniger als
„Bernhard"). Ursache: eine seit Längerem bestehende baumelnde
`Artikel`-Referenz auf Bernhards Gerät (Altbestand, über die aktuellen
`@Relationship(deleteRule: .cascade, inverse:)`-Deklarationen nicht mehr neu
entstehbar) ließ `SyncSnapshotExportService` die betroffenen
`EinkaufslistenEintrag`e bei JEDEM Export stillschweigend komplett auslassen
— unabhängig davon, wie oft ein Peer neu synchronisierte.
`DatenintegritaetsService.pruefe(context:)` prüfte diese Beziehung bisher gar
nicht, der Zustand war auf dem betroffenen Gerät selbst unsichtbar. Prüft
jetzt zusätzlich `EinkaufslistenEintrag.artikel`/`.einkaufsliste` und meldet
sie in Einstellungen → Debugging → „Datenintegrität" — der bestehende
Reparaturweg „Baumelnde Referenzen bereinigen" behebt den Zustand direkt.
Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 51.

## v0.14 (Build 268) — Frischer Sync-Beitritt zeigte längst abgehakte Artikel als aktuell abgehakt

Bugfix (Nutzerbericht: Gerät zeigte nach frischem Beitritt/„Ersetzen durch
Peer" 9 abgehakte Artikel an, der Peer korrekt 0). Ursache:
`SyncSnapshotImportService.mergeEinkaufsvorgaenge`s `offenerTreffer`-Zweig
prüfte nur Eigenschaften des lokalen Kandidaten, nicht ob der REMOTE-Eintrag
selbst noch offen war — ein frisch (durch `EinkaufenView.einkaufSicherstellen()`)
angelegter eigener Platzhalter-Vorgang aliasierte dadurch mehrere bereits
abgeschlossene Peer-Vorgänge gleichzeitig auf sich; die defensive
`remoteEndZeit >= startZeit`-Plausibilitätsprüfung verwarf danach jeden
Abschluss, der Vorgang blieb dauerhaft offen, alle daran gehängten,
längst abgehakten Artikel mehrerer vergangener Einkäufe erschienen fälschlich
als aktuell abgehakt. Fix: `offenerTreffer` matcht nur noch, wenn
`eintrag.endZeit == nil`. Details: `docs/DATENSYNCHRONISATION_VERLAUF.md`
Abschnitt 50.

## v0.14 (Build 267) — Ignorierte Ladenvorschläge nach „Ersetzen durch Peer“ verloren

Bugfix (Code-Review-Fund): `IgnorierterGeschaeftsVorschlag` ist rein
gerätelokal, nie Teil des Peer-`SyncSnapshot`. Das Vorher-Backup vor einem
„Ersetzen durch Peer"-Neuaufbau sicherte diese Liste zwar bereits mit
(`SyncErsetzenBackup.ignorierteGeschaeftsVorschlaege`), aber
`SyncErsetzenService.fuehreAusstehendeAktionAus(context:)` stellte sie im
`.ersetzenDurchPeer`-Zweig nie wieder her — nur der separate
„Backup wiederherstellen"-Zweig tat das. Nach jedem Sync-Beitritt mit
„Ersetzen" bot der `GeschaeftVorschlagBanner` deshalb bereits ignorierte
Vorschläge erneut an. Neuer Helper
`stelleIgnorierteGeschaeftsVorschlaegeWiederHer(_:context:)`, analog zur
bestehenden `stelleSyncEventsWiederHer`-Wiederherstellung (GitHub #80), jetzt
in beiden Zweigen aufgerufen.

## v0.14 (Build 266) — Neustart-Schleife: vorheriger Fix wirkungslos durch Race Condition mit `.onChange(of: scenePhase)`

Bugfix (Nutzerbericht: derselbe Fehler trat trotz des vorherigen Fixes
identisch weiter auf). Der Abschnitt-47-Fix übergab die „Rückkehrer-
Erkennung überspringen"-Information nur als Parameter über den `.task`-
Aufrufer von `SyncPollingService.starten(context:)` — `ShopWithMeApp` hat
aber einen zweiten, unabhängigen Aufrufer (`.onChange(of: scenePhase)`),
der beim App-Start fast immer zuerst feuert und dadurch den Skip praktisch
nie zum Zug kommen ließ. Die Information wird jetzt stattdessen synchron in
`ShopWithMeApp.init()` gesetzt (`SyncPollingService.ueberspringeRueckkehrerErkennungBeimNaechstenStart`,
`nonisolated(unsafe)`, analog `DatabaseLeaseService.storeURL`) — bevor
`body` und damit beide möglichen Aufrufer überhaupt existieren, also
race-unabhängig. Details: `docs/DATENSYNCHRONISATION_VERLAUF.md`
Abschnitt 49.

## v0.14 (Build 265) — „Zusammenführen“-Option beim Sync-Beitritt entfernt

Nutzerentscheidung nach den beiden Live-Funden rund um „Ersetzen"
(vorherige Einträge): der Sync-Ordner-Beitritt zu einer Gruppe mit
bestehenden Peer-Daten bietet jetzt nur noch „Ersetzen“ (+ „Abbrechen“) an,
„Zusammenführen“ wurde vollständig entfernt — inklusive des zugehörigen,
nur dafür genutzten Beitritts-Vorprüfungsmechanismus (GitHub #86, Teil 2:
`SyncSnapshotImportService.mehrdeutigeGeschaeftsKandidatenBeimBeitritt`,
`GeschaeftsAbgleichKandidat`, `geschaeftsKandidatBestaetigen`, zugehöriger
Unit-Test). Die laufende Hintergrund-Merge-Ambiguitätsprüfung („N mögliche
Duplikate prüfen“) ist davon unberührt. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 48.

## v0.14 (Build 264) — Neustart-Schleife nach „Ersetzen“: Gerät hielt sich fälschlich für aus der Sync-Gruppe entfernt

Bugfix (Nutzerbericht, Live-Test direkt nach dem vorherigen Fix): Nach
„Ersetzen"/Wiederherstellen + Neustart lief die Rückkehrer-Erkennung
(„bin ich noch Mitglied der Sync-Gruppe?") VOR dem ersten eigenen
Export-Zyklus — der aber erst den eigenen Peer-Unterordner im Sync-Ordner
anlegt. Das Gerät hielt sich dadurch direkt nach dem Neustart fälschlich für
ausgeschlossen, trat automatisch aus, und der Nutzer landete beim erneuten
Beitreten in einer Endlosschleife aus Ordner-Wahl/Neustart-Aufforderung.
`SyncErsetzenService.fuehreAusstehendeAktionAus(context:)` meldet jetzt
zurück, ob eine Aktion ausgeführt wurde; `SyncPollingService.starten(context:ueberspringeRueckkehrerErkennung:)`
lässt die Rückkehrer-Erkennung in genau diesem einen Fall aus. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 47 (inkl. Hinweis auf ein
Datenverlust-Risiko für zum Zeitpunkt der Schleife noch nicht synchronisierte
lokale Änderungen des betroffenen Geräts).

## v0.14 (Build 263) — Hintergrund-Sync lief nach „Ersetzen“/Wiederherstellen bis zum Neustart unbegrenzt mit dem alten Bestand weiter

Bugfix (Nutzerbericht): Nach einem „Ersetzen durch Peer" oder einer
Wiederherstellung (Sync-Ordner-Beitritt mit fremden Daten, Backup-
Wiederherstellung, Korruptions-Recovery) fordert die App zu einem Neustart
auf, um den Neuaufbau abzuschließen — der weiterhin laufende
`SyncPollingService`/`SyncICloudAenderungsBeobachter`/`MultipeerSyncService`
synchronisierten aber bis zu diesem Neustart unverändert weiter: der neue
Sync-Ordner-Pfad war bereits aktiv, während der In-Memory-Datenbestand noch
der alte war — je länger der Neustart auf sich warten ließ, desto mehr wurde
im Hintergrund mit der falschen Kombination aus altem Bestand und neuem
Ordner synchronisiert. Alle sechs Aufrufstellen (`SyncOrdnerSettingsView`,
`RootView.vollAbgleichAusloesen()`, `DebuggingView`) stoppen die drei Dienste
jetzt sofort beim Vormerken der Aktion statt erst beim Neustart;
`SyncOrdnerSettingsView` blendet zusätzlich „Jetzt synchronisieren“, „Ordner
wählen…“ und „Synchronisierung deaktivieren“ bis zum Neustart aus, damit auch
ein manueller Tap die Lücke nicht mehr offen lässt. Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 46.

## v0.14 (Build 262) — Alter offener Einkaufsvorgang wird beim Sync-(Wieder-)Beitritt nicht mehr fälschlich mit einem aktiven Peer-Vorgang vermischt

Bugfix (Nutzerbericht): Hatte ein Gerät vor einem (Wieder-)Beitritt zu einer
Sync-Gruppe — Erstbeitritt, Wieder-Beitritt nach Entfernung aus der Gruppe,
oder Wiederherstellung aus dem lokalen Backup — noch einen alten, nie
geschlossenen `Einkaufsvorgang` mit bereits eigenen `KaufEintrag`en für
dieselbe Geschäft+Liste-Kombination, matchte `SyncSnapshotImportService`s
`offenerTreffer`-Merge ihn blind gegen einen tatsächlich aktiven Vorgang eines
Peers — die eigenen, veralteten Käufe blieben hängen und erschienen zusätzlich
als (fälschlich) abgehakt in der listenweiten Ansicht. Neue
`EinkaufsvorgangAbschlussService.schliesseAlleOffenenEinkaufsvorgaenge(context:)`
schließt jetzt alle lokal offenen Vorgänge am eigentlichen Beitrittsmoment
(`SyncOrdnerSettingsView.ordnerFestlegen(_:)`, `SyncErsetzenService`s
Backup-Wiederherstellung), zusätzlich verlangt der `offenerTreffer`-Zweig
selbst jetzt einen leeren lokalen Kandidaten. 5 neue Tests. Details:
`docs/DATENSYNCHRONISATION.md` §4.3.

## v0.14 (Build 257) — Belegscan legt bei fehlendem Produktname automatisch ein neues Produkt an (Folgearbeit zu GitHub #47/#116)

Bugfix: Lieferte die Zuordnung beim Belegscan nur einen ``Artikel`` (Substring-
Treffer, KI-Vorschlag oder manuelle Zuweisung/Neuanlage in der Prüf-Ansicht),
aber noch keinen bekannten ``Produktname`` für das erkannte Geschäft, landete
der erfasste Preis bislang immer im geteilten Platzhalter-Standardprodukt des
Artikels — mehrere tatsächlich unterschiedliche Marken desselben Artikels
überschrieben sich dadurch gegenseitig in der Preishistorie. `BelegScanView`
löst jetzt über `Produkt.aufgeloestesOderNeuesProdukt(...)` in diesem Fall
automatisch ein eigenständiges Produkt auf oder legt eins neu an (Ausnahme:
ein reiner Alias-Treffer bleibt bewusst beim Standardprodukt). Produktname
kommt dabei vom bestätigten Anzeigenamen, falls der Nutzer ihn bewusst vom
Artikelnamen abweichend umbenannt hat, sonst vom rohen Bon-Text — inkl.
Wiedererkennung eines bereits existierenden, gleichnamigen Produkts, um
Dubletten zu vermeiden. 7 neue Tests. Details: `docs/ARTIKEL_PRODUKT_MODELL.md`
→ „Automatische Neuanlage beim Belegscan“.

## v0.14 (Build 254) — GitHub #116: Scan-Zuordnung erkennt Produktnamen (GitHub #47, Schritt 5/5 — Feature komplett)

Letzter Baustein von #47: `ArtikelZuordnungsService` bekommt eine neue
Matching-Stufe zwischen gelerntem `ArtikelAlias` und dem generischen
Artikel-Namens-Teilstring-Abgleich — Abgleich gegen `Produktname`
**innerhalb des beim Belegscan erkannten Geschäfts**. Ein Treffer liefert
sowohl Artikel als auch das konkrete `Produkt`; `BelegScanView` reicht dieses
Produkt direkt an `PreispunktService.erfassen` durch, statt wie bisher immer
nur beim Platzhalter-Standardprodukt zu landen. `PreispunktService`s
Slowly-Changing-Dimension-Vergleich (welcher Preispunkt gilt als "derselbe,
nur aktualisiert") berücksichtigt jetzt zusätzlich das Produkt, damit zwei
echte Produkte desselben Artikels+Geschäfts unabhängige Preishistorien
behalten. Die Positions-Zeile im Belegscan zeigt bei Treffer zusätzlich den
erkannten Produktnamen an. 9 neue Tests.

Bewusst unangetastet: `PreisschildScanView` (eigene, parallele
Zuordnungslogik, nutzte `ArtikelZuordnungsService` schon vorher nicht) und
`KaufEintrag` (weiterhin ohne `produkt`-Feld, seit GitHub #76 ohne
Preisrolle).

**Damit ist GitHub #47 (Artikel → Produkt → Produktname) nach 5 Schritten
vollständig umgesetzt** — Datenmodell, Migration, Sync, Preis-Aggregation,
UI und Scan-Zuordnung, siehe `docs/ARTIKEL_PRODUKT_MODELL.md`.

## v0.14 (Build 253) — GitHub #115: UI für Produkt/Produktname (GitHub #47, Schritt 4/5)

Erste sichtbare UI dieses gesamten Features (Schritte 1–3 waren reines
Fundament ohne Funktionsänderung): `ArtikelEditView` bekommt eine Sektion
"Produkte" (nur oberste Ebene, ohne das automatisch angelegte
Platzhalter-Produkt), von dort per Tap zur neuen `ProduktEditView`
navigierbar (Name, Produktnamen je Geschäft, eigene Preishistorie — analog
`ArtikelEditView`). `ArtikelHinzufuegenView` bekommt bei Artikeln mit mehr
als einem eigenen Produkt zusätzlich einen Chevron-Button für ein
Produktwahl-Sheet — der bestehende Sofort-Tap (GitHub #6/#45) bleibt
bewusst unverändert. Das gewählte Produkt erscheint danach klein unter dem
Artikelnamen auf der Einkaufsliste (`EinkaufenView`, gleiches Muster wie die
bestehende `notiz`-Anzeige).

Nebenbei korrigiert: `docs/BEDIENUNGSANLEITUNG.md` riet im
Alias-Namen-Abschnitt (aus #111, vor Existenz von `Produkt` geschrieben) für
unterschiedliche Marken fälschlich noch zu separaten Artikeln — jetzt auf
Produkte korrigiert.

## v0.14 (Build 252) — GitHub #114: Rekursive Preis-Aggregation für Produkt (GitHub #47, Schritt 3/5)

`Produkt.minimum`/`.maximum` implementieren jetzt die in
`docs/ARTIKEL_PRODUKT_MODELL.md` (Regel 2) bereits dokumentierte, bisher aber
nicht umgesetzte Kumulierung: ein Produkt mit `unterProdukte` (z.B.
Packungsgrößen) summiert deren Preise rekursiv über beliebig viele Ebenen,
statt nur eigene `preispunkte` zu betrachten (`preispunkteRekursiv`).

Präzisierung gegenüber dem ursprünglichen Plan-Text ("`ArtikelPreisSpanne` um
Produkt-Ebene erweitern"): `ArtikelPreisSpanne` erwies sich bei der
Umsetzung als bereits korrekt und unverändert lauffähig (gruppiert ohnehin
alle Preispunkte eines Artikels unabhängig von der Produkt-Hierarchie) — die
eigentliche Lücke lag allein auf `Produkt` selbst, siehe
`docs/ARTIKEL_PRODUKT_MODELL.md`. 4 neue Unit-Tests. Bewusst weiterhin keine
sichtbare Funktionsänderung (kein UI-Verwender vor Schritt 4/5).

## v0.14 (Build 251) — GitHub #113: Sync-Integration von Produkt/Produktname (GitHub #47, Schritt 2/5)

`Produkt`/`Produktname` (seit Schritt 1/5, v0.14) sind jetzt Teil der
geräteübergreifenden Datensynchronisation (`SyncSnapshot`-Version 7→8).
`mergeProdukte` matcht wie das bestehende `mergeArtikel`-Muster (ID/Alias →
exakter Name → Neuanlage), der Namensabgleich läuft aber bewusst
**innerhalb desselben, bereits aufgelösten Artikels** statt global, damit
gleichnamige Produkte unter verschiedenen Artikeln nicht fälschlich
zusammenfallen. Rekursive `elternProdukt`-Zuordnung (Packungsgrößen) läuft in
einem zweiten Durchlauf, da ein Kind-Eintrag in der Sync-Liste vor seinem
Eltern-Eintrag stehen kann. `mergeProduktnamen` ist rein additiv, analog dem
bestehenden `ArtikelAlias`-Merge.

Bewusst ohne die bei `mergeArtikel`/`mergeGeschaefte` vorhandene
Ambiguitäts-Rückstellung (`SyncAbgleichKandidat`) — Produkt hat noch keine
eigene Verwaltungs-UI (folgt in Schritt 4/5), ein gelegentlich doppelt
angelegtes, ähnlich benanntes Produkt ist ein geringeres Risiko als bei
Artikel/Geschäft.

`Preispunkt`/`EinkaufslistenEintrag` lösen ihr `Produkt` jetzt bevorzugt über
die echte synchronisierte Zuordnung auf, mit Fallback auf das
Schritt-1-Platzhalterprodukt bei älteren Peers. 6 neue Tests
(`ProduktSyncTests.swift`). Bewusst weiterhin keine sichtbare
Funktionsänderung.

## v0.14 (Build 250) — GitHub #112: Produkt/Produktname-Datenmodell (GitHub #47, Schritt 1/5)

Fundament für die Artikel→Produkt→Produktname-Hierarchie
(`docs/ARTIKEL_PRODUKT_MODELL.md`): neue Modelle `Produkt` (rekursiv
selbstreferenzierend für Varianten wie Packungsgrößen, `istStandard`-Flag für
automatisch angelegte Platzhalter) und `Produktname` (geschäftsabhängiger
Name desselben Produkts). `Artikel`/`Preispunkt`/`EinkaufslistenEintrag`
bekommen die dafür nötigen neuen, additiven Relationships —
`Preispunkt.artikel` bleibt zusätzlich gepflegt, keine bestehende Stelle
musste umgebaut werden.

Erste echte strukturelle SwiftData-Migration dieses Projekts: `SchemaV1`
(`Models/SchemaV1Frozen.swift`) friert alle 23 bisherigen Modelltypen
verschachtelt ein, `SchemaV2` referenziert die live weiterentwickelten Typen,
eine `MigrationStage.custom` verknüpft bestehende Preispunkte/Listeneinträge
automatisch mit einem Platzhalter-Produkt ihres Artikels. Verifiziert mit
einem echten, vor der Modelländerung angelegten On-Disk-Store
(`ProduktMigrationTests.swift`), nicht nur einem frischen In-Memory-Store —
etabliert damit das Migrationsmuster auch für künftige strukturelle
Änderungen (z.B. #88). 9 neue Unit-Tests. Bewusst keine sichtbare
Funktionsänderung — UI/Sync/Preis-Aggregation folgen in den Schritten 2–5.

## v0.13 (Build 249) — GitHub #111: Artikel-Alias-Namen

Erster von zwei Fällen aus der Aufteilung von GitHub #47/#58 (Ausprägung
folgt separat): ein Artikel kann jetzt mehrere Alias-Namen bekommen, unter
denen er bei der Artikelsuche zusätzlich gefunden wird (z.B. „Zahncreme“ für
„Zahnpasta“) — im Unterschied zu einer Ausprägung bleibt es dabei derselbe
Artikel, kein eigenes Produkt, kein eigener Preis.

Kein neues Modell nötig: das bereits vorhandene `ArtikelAlias` (bisher nur
für die Bon-Scan-Erkennung genutzt, siehe `ArtikelZuordnungsService`) trägt
jetzt auch manuell gepflegte Aliase. Neu: `ArtikelAlias.manuellHinzufuegen(name:zu:alle:context:)`
blockiert (statt wie `lernen(...)` stillschweigend umzuhängen), falls der
Name bereits einem anderen Artikel gehört. UI-seitig eine neue Sektion
„Alias-Namen“ in `ArtikelEditView` (Hinzufügen/Löschen) sowie erweiterte
Suche in `ArtikelHinzufuegenView` (`gefilterteArtikel` prüft zusätzlich
gegen die Aliase jedes Artikels). 3 neue Unit-Tests
(`ArtikelAliasTests`).

## v0.12 (Build 248) — GitHub #107 (1/3): Einkaufsvorgang-Abschluss-Logik extrahiert

Erster Baustein der View/Domänenlogik-Entflechtung aus GitHub #107. Die
Abschluss-Logik ("Einkauf abschließen"-Button und automatischer Abschluss
nach Inaktivität) lebte bisher ausschließlich als private Methode in
`EinkaufenView.swift` und konnte deshalb nie per Unit-Test abgesichert
werden — laut `docs/DATENSYNCHRONISATION.md` §4.3 brauchte sie in Session
2026-08-03 drei aufeinanderfolgende Live-Test-Fixes.

Neu: `EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(anker:duplikate:context:)`
bündelt die geteilte Logik beider Aufrufstellen (`EinkaufslisteView.einkaufAbschliessen()`,
`EinkaufenView.inaktivitaetPruefen()`) — stateloser Service nach dem im
Projekt etablierten Muster (`context: ModelContext`-Parameter), keine neue
`@Observable`-Architektur (dafür gibt es im Projekt keinen Präzedenzfall).
7 neue Unit-Tests decken alle drei historischen Live-Test-Funde ab. Reines
Struktur-Refactoring ohne Verhaltensänderung.

Schritt 2/3 (BelegScanView-Persistenz-Orchestrierung) und 3/3
(Anzeige-Filter-Logik) folgen als eigene, separat geplante Schritte.

## v0.12 (Build 247) — GitHub #102: @Attribute(.unique) auf den meistgejointen Modell-IDs

Nach Prüfung des realen Bestands per `ModellIDDuplikatService` (keine
Duplikate gefunden, nur ein Gerät im Sync-Verbund) `@Attribute(.unique)` auf
`id: UUID` ergänzt bei `Artikel`, `Geschaeft`, `Einkaufsliste`,
`Einkaufsvorgang`, `KaufEintrag` — den laut Issue meistgejointen Typen im
Sync-Merge. Jeder `FetchDescriptor(predicate: #Predicate { $0.id == x })` auf
diesen Typen nutzt dadurch einen Index statt eines Full-Table-Scans. Die
übrigen ~16 `@Model`-Typen bleiben vorerst unverändert (kleinere Tabellen,
seltener direkt per ID gejoint).

Test-Fund beim Rollout: SwiftData bricht bei einem Speicherversuch mit
bereits vergebener eindeutiger `id` nicht hart ab, sondern führt einen
stillen Upsert durch (zwei Objekte mit derselben `id` kollabieren beim
`save()` zu einer Zeile) — siehe Typ-Doku von `ModellIDDuplikatService` für
Details. Ändert nichts an der bereits umgesetzten Vorsichtsmaßnahme (Prüfung
vor der Einführung), relativiert aber das ursprünglich befürchtete
Absturzrisiko bei einer künftigen Migration auf einem Gerät mit
Alt-Duplikaten.

## v0.12 — GitHub #102 (Diagnose): Prüfwerkzeug für doppelte Modell-IDs

Vorbereitung für `@Attribute(.unique) var id: UUID` auf den app-eigenen
Model-IDs (bislang ohne Index — jeder ID-Lookup im Sync-Merge ist ein
Full-Table-Scan). Laut Migrations-Kriterium (`docs/DECISIONS.md`) ist die
Unique-Constraint-Einführung strukturell riskant, falls im realen Bestand
bereits doppelte `id`-Werte existieren (Migration würde fehlschlagen).

Neu: `ModellIDDuplikatService.pruefe(context:)` prüft alle ~21 `@Model`-Typen
mit eigener `id: UUID` auf Duplikate und meldet je Typ nur Anzahl betroffener
IDs/überzähliger Zeilen — bewusst ohne die IDs oder Inhalte selbst
preiszugeben. Über Einstellungen → Debugging → „Modell-ID-Duplikate" manuell
auslösbar. Das eigentliche `@Attribute(.unique)` folgt erst nach einer
sauberen Prüfung auf einem echten Gerätestand.

`SyncPeerZaehlerStand` und `WarengruppenDistanzPeerZaehlerStand` enthielten dieselbe
"nur bei tatsächlicher Änderung schreiben"-Entscheidungslogik für
`merkeEigenenZuwachsDesPeers` wortgleich zweimal, unterschieden nur im Namen des
Fremdschlüsselfelds (`geschaeftID` vs. `distanzID`). Gemeinsame Logik nach neuem
`GCounterPeerZustandService.merkeEigenenZuwachsDesPeers<T: PersistentModel>(...)`
extrahiert (generisch über einen `ReferenceWritableKeyPath<T, Int>` fürs Zählerfeld).
Bewusst NICHT der Fetch selbst extrahiert (bleibt je Typ mit seinem eigenen, konkreten
`#Predicate` bestehen) — ein generischer `#Predicate` über `Self` ist unzuverlässig.
Reines Struktur-Refactoring ohne Verhaltensänderung.

## v0.12 (Build 244) — GitHub #105: "Sofort nachführen"-Cache-Pattern gebündelt

Code-Review-Fund: `mergeArtikelKategorien`, `mergeGeschaefte`, `mergeArtikel`
und `mergeEinkaufslisten` (`SyncSnapshotImportService.swift`) wiederholten
denselben Aufbau wortgleich viermal (lokalen Bestand vorab fetchen, per
Dictionary indizieren, bei Neuanlage sofort nachführen).

- Neuer, generischer `LokalerBestandCache<T: IdentifizierbaresModell>`
  kapselt Fetch + ID-Index + `nachfuehren(_:)` — alle vier Funktionen nutzen
  ihn jetzt statt der Handimplementierung. Das jeweils unterschiedliche
  Matching (Name/Koordinaten/Ambiguitäts-Regel) bleibt unverändert je
  Funktion, da es keine dictionary-taugliche Gleichheit ist.
- Bewusst NICHT auf `mergeEinkaufsvorgaenge` ausgeweitet — dessen
  `offenerTreffer`-Fallback hat eine eigene, separat gehärtete Sonderrolle;
  nicht mit diesem risikoärmeren Refactor vermischt.
- Reiner interner Refactor, keine Verhaltensänderung. Build + vollständiger
  Testlauf (326 Tests, unverändert) grün.

## v0.12 (Build 243) — GitHub #108: SyncEntitaetsArt.Kind — echtes Enum für Dispatch-Stellen

Code-Review-Fund: `SyncEntitaetsArt` war nur ein Namespace aus `static let`-
String-Konstanten, kein echtes Enum — jeder `switch art { case
SyncEntitaetsArt.x: … default: break }` (`loescheFallsVorhanden`, `setzeName`,
`abgleichKandidatAlsUnterschiedlichBestaetigen` in
`SyncSnapshotImportService.swift`) bekam dadurch keine
Exhaustiveness-Prüfung vom Compiler — ein vergessener neuer Fall wäre lautlos
in `default:` verschwunden.

- Neues, verschachteltes `SyncEntitaetsArt.Kind: String`-Enum NUR für diese
  drei Dispatch-Stellen — die bestehenden `SyncEntitaetsArt.xyz`-String-
  Konstanten bleiben für Speicherung/Wire-Format unverändert (Vorwärts-
  kompatibilität mit künftigen, hier noch unbekannten Werten eines neueren
  Peers bliebe sonst nicht erhalten, analog `SyncEvent.artRaw`/`SyncEventArt`).
- Alle drei Stellen switchen jetzt exhaustiv über `Kind` (kein `default:`
  mehr) — bisher nicht relevante Fälle bleiben als explizite No-Op-Gruppen
  sichtbar, statt implizit zu verschwinden.
- Reiner interner Refactor, keine Verhaltensänderung. Build + vollständiger
  Testlauf (326 Tests, unverändert) grün.

## v0.12 (Build 242) — GitHub #99: dauerhaftes Sicherheitsnetz-Faktum gegen wiederbelebte Käufe

Behebt den in `docs/DATENSYNCHRONISATION.md` Abschnitt 4.7 dokumentierten
Live-Test-Bug (oszillierende Mitgliederzahl der Liste „Urlaub"): das
Sicherheitsnetz gegen wiederbelebte Käufe (`istBereitsAbgehakt`) stützte sich
ausschließlich auf noch existierende `KaufEintrag`e — `KaufEintragBereinigungService`
löscht diese aber 48h nach Abschluss ihres Vorgangs, ohne dass der
Artikel-/Listenbezug in einem Tombstone erhalten bleibt.

- **Neu: `ArtikelListenKauf`** (Bereich D, Schema-Erweiterung — additiv, keine
  neue `SchemaVN`/`MigrationStage` nötig, analog `ArtikelGeschaeftVerfuegbarkeit`) —
  eine Zeile pro (Artikel, Einkaufsliste)-Paar, dauerhaft, unabhängig von der
  48h-Karenzzeit und bewusst unabhängig von der Tombstone-Aufräum-Watermark.
- `SyncSnapshot.aktuelleFormatVersion` auf 7 erhöht (`artikelListenKaeufe`),
  wie bei allen vorherigen additiven Erweiterungen keine Rückwärtskompatibilität
  nötig.
- Geschrieben in `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` (lokal/
  per Event materialisiert) sowie in `SyncSnapshotImportService.mergeKaufEintraege`
  (Bereich-C-Snapshot-Merge, legt `KaufEintrag` direkt an).
- Einmalige Bestandsmigration (`DatenintegritaetsService.migriereArtikelListenKaeufeFallsNoetig`)
  sichert das Faktum beim Rollout für jeden noch existierenden `KaufEintrag`
  nach — kann naturgemäß nur erfassen, was zu diesem Zeitpunkt noch existiert.
- Bekannter, bewusst in Kauf genommener Randfall: `mergeArtikelListenKaeufe`
  läuft weiterhin NACH `mergeEinkaufslistenEintraege` in der Aufrufreihenfolge,
  ein im selben Sync-Zyklus frisch eintreffender Beleg wirkt sich deshalb erst
  im nächsten Zyklus aus (selbstauflösend, keine Umstellung der mehrfach
  live-getesteten Abhängigkeitsreihenfolge).

Details/Begründung: `docs/DATENSYNCHRONISATION.md` Abschnitt 4.7 (Nachtrag).
Neue Tests: `ArtikelListenKaufServiceTests`, zwei neue Fälle in
`SyncSnapshotImportServiceTests` (inkl. Regressionstest für das ursprüngliche
Bug-Szenario) und `DatenintegritaetsServiceTests`. Build + vollständiger
Testlauf (326 Tests) grün.

## v0.12 (Build 241) — Vier Code-Review-Funde behoben (Datenintegritäts-Check, Sync-Merge-Performance, Doku)

Aus dem vollständigen Code-Review-Durchgang vom 2026-08-05 (dafür angelegte
GitHub-Issues #99–#108) — die vier risikoärmsten, in sich geschlossenen Funde
zuerst umgesetzt; die größeren strukturellen Funde (u.a. #99, #102, #104,
#105, #107, #108) folgen gestaffelt gemäß der dort festgelegten Priorität.

- **#100:** `DatenintegritaetsService.istBaumelnd` prüfte `KaufEintrag.einkaufsvorgang`
  faktisch nie auf eine baumelnde Referenz — `gueltigeIDs: nil` lieferte
  bedingungslos `false`, unabhängig vom tatsächlichen Zustand. Jetzt mit
  echtem `Set<PersistentIdentifier>` wie die übrigen vier geprüften Felder;
  `istBaumelnd` braucht dadurch kein optionales `gueltigeIDs` mehr.
- **#103:** `mergeKaufEintraege`/`mergePreispunkte`/`mergeGeschaeftBesuche`
  prüften Existenz bisher per eigenem `fetchCount`-Aufruf PRO Remote-Eintrag —
  jetzt wie `SyncTombstoneService.geloeschteIDs` ein einmalig vorab geladenes
  `Set<UUID>` je Merge-Durchlauf.
- **#106:** Neue `Decimal.FormatStyle.euro`-Konstante (`Decimal+EuroFormat.swift`,
  analog `Decimal+CentRundung.swift`) ersetzt vier einzeln hartcodierte
  `.currency(code: "EUR")`-Stellen. An Aufrufstellen bewusst voll qualifiziert
  (`Decimal.FormatStyle.euro`) verwendet, nicht als kurze `.euro`-Dot-Syntax —
  Letztere löst laut Build-Befund innerhalb einer String-Interpolation sowie
  bei `Text(_:format:)` nicht zuverlässig auf.
- **#101:** Klarstellender Kommentar an `SchemaV1.versionIdentifier` — die
  SwiftData-interne Schema-Version `(1,5,0)` ist unabhängig von der
  App-Marketing-Version und stammt aus der Zeit vor dem v0.1-Reset.

Alle vier bewusst risikoarm/mechanisch, keine Verhaltensänderung für den
Anwender, kein `@Model`-Schema betroffen. Build + vollständiger Testlauf
(317 Tests) grün.

## v0.12 (Build 240) — Diagnose: fehlende Referenz bei nicht anwendbaren Sync-Events

Live-Test-Nachfolgefund zur vorherigen Geschäfts-Aggregate-Änderung (siehe
`docs/GESCHAEFTS_AGGREGATE.md` Abschnitt „Live-Verifikation"): drei hängende
`artikelAbgehakt`-Events ließen sich aus dem bisherigen, einheitlichen
`sync_event_nicht_anwendbar`-Log nicht mehr in „Bezug fehlt" vs. „Artikel
fehlt" auflösen.

- **`SyncImportService.materialisiere`** liefert jetzt statt `Bool` ein
  `MaterialisierungsErgebnis` (`erfolgreich`/`bezugFehlt`/`artikelFehlt`/
  `bezugUndArtikelFehlen`) — reines Diagnose-Detail, keine Verhaltensänderung.
- `sync_event_nicht_anwendbar`/`sync_event_aufgegeben` protokollieren seither
  zusätzlich `fehlt=bezug|artikel|beide`.
- Ergebnis der Live-Diagnose: root-caused auf listenlose Vorgänge, die von der
  neuen Bestandsmigration bereits gelöscht wurden, bevor der jeweils andere
  Peer die referenzierenden Events anwenden konnte — bewusst nicht behoben
  (Details/Begründung siehe verlinkter Abschnitt).

## v0.12 (Build 239) — Geschäfts-Aggregate entkoppelt von der Einkaufsliste

Siehe `docs/GESCHAEFTS_AGGREGATE.md` für die vollständige Herleitung. Ausgangspunkt:
`Einkaufsvorgang.einkaufsliste` (`deleteRule: .nullify`) ließ eine gelöschte
`Einkaufsliste` ihre `Einkaufsvorgang`e verwaist zurück — mit angehängten
`KaufEintrag`en für die App strukturell unerreichbar, aber wegen der echten
Kaufhistorie nicht automatisch bereinigbar (auf einem Testgerät akkumulierten sich
so 22 Vorgänge mit 136 Käufen).

- Neu: **`ArtikelGeschaeftVerfuegbarkeit`** (`Artikel`, `Geschaeft`) — dauerhafte
  Existenz-Tatsache "wurde hier mindestens einmal gekauft", ersetzt einen
  Live-`KaufEintrag`-Scan in `ArtikelVerfuegbarkeitService.istVerfuegbar`.
  Geschrieben bei jedem tatsächlich neuen `KaufEintrag`
  (`Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`).
- Neu: **`GeschaeftBesuch`** (`id` = `id` des ursprünglichen `Einkaufsvorgang`s,
  `geschaeft`, `startZeit`, `endZeit`, `anzahlProdukte`) — ersetzt den direkten
  `Einkaufsvorgang`-Zugriff in `GeschaeftBesuchsProtokollView`. Geschrieben von
  `GeschaeftBesuchService.erfassen(fuer:context:)` direkt nach
  `Einkaufsvorgang.abschliessen(...)`. Besuchsprotokoll zeigt jetzt zusätzlich die
  Produktanzahl je Besuch.
- **`Einkaufsliste.einkaufsvorgaenge` jetzt `deleteRule: .cascade`** (vormals
  `.nullify`) — sicher, weil beide dauerhaft wertvollen Ableitungen bereits vor
  einer möglichen Löschung festgeschrieben sind. Löschen einer Liste entfernt ihre
  `Einkaufsvorgang`e/`KaufEintrag`e jetzt vollständig, statt sie unerreichbar liegen
  zu lassen.
- Sync: beide neuen Typen als Bereich D in `lernen.json` mitgeführt
  (`SyncSnapshot.aktuelleFormatVersion` → 6) — additive Union-Merges, kein
  Tombstone-Bedarf (werden vom Nutzer nie direkt gelöscht).
- Neu: **`DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context:)`**
  — einmalige, idempotente Bestandsmigration (läuft vor
  `raeumeLeereListenloseVorgaengeAuf`): sichert beide Aggregate für alle bereits
  vorhandenen Daten nach, bevor listenlose `Einkaufsvorgang`e (jetzt sicher)
  endgültig gelöscht werden.

## v0.12 (Build 238) — Peer-Lebenszyklus, Baustein C: dynamischer Aufbewahrungs-Wasserstand (Abschluss)

Vierter und letzter Baustein, siehe `docs/PEER_LEBENSZYKLUS.md`. Ersetzt zwei feste,
unabhängig voneinander „gepflegte" Zeit-Fristen durch einen einzigen, sich selbst
nachführenden Mechanismus: Sync-Events/Tombstones gelten erst dann als sicher löschbar,
wenn jeder aktuell bekannte Peer nachweislich schon einen vollständigen Sync danach
hatte.

- Neu: **`SyncSnapshotImportService.aktuellerAufraeumWasserstand(in:)`** — liest live
  alle aktuell vorhandenen `peers/*/manifest.json` und bildet das Minimum ihrer
  Zeitstempel. Kein separat gepflegter Cache. `nil` (nichts löschen), wenn kein anderer
  Peer bekannt ist oder sich auch nur ein vorhandener Peer-Ordner nicht lesen lässt.
- **`SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()`** nutzt jetzt
  diesen Wasserstand statt der bisherigen festen 30-Tage-`eventAufbewahrungsfrist`
  (entfällt).
- Neu: **`SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context:)`** —
  dieselbe Logik für `SyncTombstone`-Zeilen, die vorher nie bereinigt wurden (dominiert
  von einem Tombstone pro Kauf, ~1500 Zeilen/Jahr geschätzt).
- `SyncAktualitaetsService.istAusDerZeitGefallen` bleibt unverändert (reiner, lokaler
  Selbst-Check ohne Gruppenbezug), bekommt aber einen eigenen, unabhängigen Wert
  (`veraltungsSchwelle`) statt weiter die entfallende `eventAufbewahrungsfrist`
  mitzunutzen.

## v0.12 (Build 237) — Peer-Lebenszyklus, Baustein C0: Manifest muss „vollständiger Sync" zertifizieren

Dritter von vier Bausteinen, siehe `docs/PEER_LEBENSZYKLUS.md`. Voraussetzung für den in
Baustein C geplanten dynamischen Aufbewahrungs-Wasserstand: `manifest.json` bedeutete
bisher nur „ein Export wurde versucht", nicht „ich habe erfolgreich alles importiert,
was es gab".

- **`SyncSnapshotExportService.exportierePaket(context:importErfolgreich:)`** — neuer
  Parameter (Default `true`), von `syncZyklus()` mit
  `snapshotImportErfolgreich && eventImportErfolgreich` durchgereicht. `manifest.json`
  bekommt nur noch bei erfolgreichem Import desselben Zyklus einen neuen Zeitstempel —
  bei Fehlschlag bleibt die alte Datei unverändert stehen, statt fälschlich „frisch" zu
  wirken.

## v0.12 (Build 236) — Peer-Lebenszyklus, Baustein A: Peer-Sterblichkeit sichtbar machen

Zweiter von vier Bausteinen, siehe `docs/PEER_LEBENSZYKLUS.md`.

- **`SyncOrdnerService.entfernePeer(_:in:context:)`** — die bisher in `DebuggingView`
  verankerte Peer-Entfernung (kompletter Ordner + `SyncPeerInfo`) extrahiert und auf
  koordinierten Dateizugriff (`SyncDateiZugriff`) statt rohem `FileManager` umgestellt.
- **`SyncPeerInfo.istWahrscheinlichTot`** — dieselbe 30-Tage-Schwelle wie der bestehende
  Ignorier-Mechanismus beim Sync-Import.
- Neuer proaktiver Dialog in `RootView` („Gerät seit langem nicht gesehen“) — schlägt bei
  App-Start/Rückkehr die Entfernung lange nicht gesehener Geräte vor, bestätigt durch den
  Nutzer, kein automatisches Löschen.
- `docs/BEDIENUNGSANLEITUNG.md` entsprechend ergänzt.

## v0.12 (Build 235) — Peer-Lebenszyklus, Baustein B: Rückkehrer-Erkennung

Erster von vier Bausteinen auf dem Weg zu einer dynamisch statt fest begrenzten
Aufbewahrung von Sync-Events/Tombstones (aktuell wächst `SyncTombstone` unbegrenzt,
dominiert von einem Tombstone pro Kauf) — Details und Gesamtplan in der neuen
`docs/PEER_LEBENSZYKLUS.md`. Dieser Schritt legt die Sicherheits-Grundlage: ein Gerät,
dessen Peer-Ordner von der Gruppe entfernt wurde, darf beim nächsten Start unter keinen
Umständen mehr seinen veralteten Bestand exportieren.

- Neu: **`SyncOrdnerService.binIchNochMitglied(in:)`** — prüft, ob der eigene
  Peer-Unterordner noch im geteilten Ordner existiert. `nil` bei nicht erreichbarem
  Ordner (kein Internet o.ä.), bewusst nicht als „ausgeschlossen" gewertet.
- **`SyncPollingService.starten(context:)`** prüft das jetzt als allerersten Schritt,
  noch vor dem eigentlichen Sync-Loop — der einzige Punkt, der garantiert vor jedem
  möglichen Sync-Zyklus dieser Session erreicht wird, unabhängig davon, ob der Start
  über `RootView().task` oder `.onChange(of: scenePhase)` ausgelöst wurde (zwischen
  beiden gibt es keine garantierte Reihenfolge). Bei Ausschluss: sofort lokales Backup +
  Sync-Ordner-Entfernung, kein weiterer Sync-Zyklus in dieser Session.
- Neuer Dialog in `RootView` („Aus der Sync-Gruppe entfernt") — „Alleine weitermachen"
  oder „Wieder beitreten" (öffnet die Sync-Einstellungen).
- `docs/BEDIENUNGSANLEITUNG.md` (Abschnitt „Datensynchronisation") entsprechend ergänzt.

## v0.12 (Build 234) — Fix: Stale Lookup-Tabelle bei Snapshot-Merge erzeugte Namensdubletten (Root-Cause zu Live-Bericht "Brot doppelt auf Urlaub-Liste")

`SyncSnapshotImportService.mergeArtikel`/`mergeGeschaefte`/`mergeEinkaufslisten`/
`mergeArtikelKategorien`/`mergeArtikelAliase` fetchten den lokalen Namens-/ID-Abgleich
jeweils EINMAL vor der Merge-Schleife über den Remote-Snapshot und aktualisierten ihn nie,
wenn innerhalb derselben Schleife ein neuer lokaler Datensatz angelegt wurde. Enthielt ein
einzelner Merge-Batch mehrere Fremdeinträge mit identischem Namen (z.B. mehrfach schnell
hintereinander hinzugefügtes "Brot"), fand ein späterer gleichnamiger Eintrag den gerade
erst vom vorherigen angelegten lokalen Datensatz nicht — pro zusätzlichem Eintrag entstand
eine weitere Dublette statt eines Alias auf den ersten:

- Alle fünf Funktionen führen `alleLokalen`/`alleLokalenNachID` jetzt sofort nach jedem
  `context.insert(...)` nach — derselbe Fix, der in `mergeEinkaufsvorgaenge` (GitHub
  #67-Erweiterung) bereits korrekt vorlag, jetzt konsistent auf alle betroffenen Stellen
  angewendet.
- 6 neue Regressionstests (je einer pro betroffener Funktion plus `GeschaeftTyp` als
  strukturell unbetroffene Vergleichskontrolle): zwei/drei gleichnamige Remote-Einträge im
  selben Batch dürfen nur einen lokalen Datensatz erzeugen.
- Bewusst **kein** Cleanup bereits entstandener Dubletten in diesem Schritt — nur der
  Code-Fix gegen künftige neue Fälle. Bestehende Dubletten (z.B. das doppelte "Brot")
  bleiben bis zu einem separaten, späteren Bereinigungsschritt bestehen.
- Verwandter Tombstone-Wachstums-Bug (`istBereitsAbgehakt` prüft keine Tombstones, lässt
  bereits gekaufte Artikel nach der 48h-Karenzzeit zurückkehren) bleibt bewusst
  ausgeklammert — eigenständiger Fix, noch in Diskussion (Live-Test-Fund, Session
  2026-08-04).

## v0.12 (Build 232) — Testabdeckung für `multipeerGruppenID`-Zeitlimit nachgezogen (Nachfolgefund zu #49, Issue #98)

Die in Build 230 beschriebene Umstellung von `SyncOrdnerService.multipeerGruppenID(in:)`
auf `async -> UUID?` (nil bei nicht erreichbarem Ordner statt geratener ID) war bereits
committet, der zugehörige neue Test aber noch nicht:

- Neuer Test `multipeerGruppenIDLiefertNilBeiNichtErreichbaremOrdner` — belegt, dass ein
  nicht erreichbarer Ordner `nil` statt einer geratenen ID liefert.
- Die beiden bestehenden Tests (`multipeerGruppenIDWirdEinmaligErzeugtUndDanachWiederverwendet`,
  `multipeerGruppenIDUnterscheidetSichZwischenVerschiedenenOrdnern`) auf `async`
  nachgezogen und um eine `!= nil`-Prüfung ergänzt.

## v0.12 (Build 231) — Pull-to-Refresh löst Sync direkt aus der Einkaufsliste aus, dezentere Multipeer-Statuszeile

Bisher war der einzige manuelle Sync-Auslöser der „Jetzt synchronisieren“-Button in den
Sync-Einstellungen — beim Einkaufen musste man dafür extra dorthin wechseln. Außerdem
wirkte die grün gefüllte Multipeer-Pille im Toolbar der Einkaufsliste wie ein Button ohne
Funktion (kein Tap-Handler). Jetzt:

- **Pull-to-Refresh in `EinkaufslisteView`** (`.refreshable`) löst denselben
  iCloud-Trigger-Picker + `SyncPollingService.syncZyklus()` aus wie der manuelle Button in
  `SyncOrdnerSettingsView` — kein Umweg mehr über die Einstellungen nötig.
- **`ICloudSyncTriggerPicker`** aus `SyncOrdnerSettingsView.swift` in eine eigene,
  gemeinsam genutzte Datei `Views/ICloudSyncTriggerPicker.swift` extrahiert (Single Source
  of Truth statt Duplikat für beide Aufrufstellen).
- **Multipeer-Statusanzeige in `EinkaufenView`** von einer grün gefüllten Toolbar-Pille
  (`bolt.horizontal.circle.fill`, wirkte wie ein funktionsloser Button) zu einer dezenten,
  linksbündig unter dem Listennamen platzierten Statuszeile („N Geräte verbunden“)
  umgestellt.
- `docs/BEDIENUNGSANLEITUNG.md` (Abschnitt „Datensynchronisation“) entsprechend
  aktualisiert.

## v0.12 (Build 230) — Zeitlimit für koordinierte Sync-Ordnerzugriffe (Nachfolgefund zu #49, Issue #98)

Die koordinierten Dateizugriffe in `SyncDateiZugriff` (`leseKoordiniert`/`schreibeKoordiniert`/
`erstelleVerzeichnisKoordiniert`/`listeKoordiniert`) hatten kein Zeitlimit. Bei einem
tatsächlich nicht erreichbaren Sync-Ordner (z.B. kein Internet für iCloud Drive) konnte das
still zu falschen Ergebnissen führen statt zu einem erkennbaren Fehler:

- **`SyncOrdnerService.multipeerGruppenID(in:)`** interpretierte einen fehlgeschlagenen
  Lesezugriff bisher identisch zu „Datei existiert noch nicht" und erfand eine neue,
  geratene Gruppen-ID — zwei zeitgleich nicht erreichbare Geräte hätten sich über den
  Discovery-Schlüssel nie mehr gefunden, ohne jede Fehlermeldung. Jetzt `async -> UUID?`,
  `nil` bei nicht erreichbarem Ordner, unterscheidet über `FileManager.fileExists` zwischen
  „wirklich noch nie angelegt" und „nur nicht lesbar".
- **`SyncExportService.exportiereNeueEvents`/`SyncImportService.importiereNeueEvents`**
  behandelten eine Zeitüberschreitung bisher stillschweigend als Erfolg, wodurch
  `SyncAktualitaetsService.vermerkeErfolgreichenZyklus()` fälschlich einen erfolgreichen
  Sync-Zyklus vermerkt hätte. Melden eine Zeitüberschreitung jetzt als echten Fehlschlag.
- Neu: **`SyncDateiZugriff.mitZeitlimit(sekunden:_:)`** (Default 20s) begrenzt jeden
  koordinierten Aufruf per `TaskGroup`-Wettlauf; neues Debug-Log-Ereignis
  `multipeerGruppenIDNichtAufloesbar`.

## v0.12 (Build 229) — Sichtbarer Sync-Status für den Multipeer-Kanal

Der Multipeer-Beschleunigungskanal (GitHub #49) lief bisher komplett unsichtbar für den
Anwender — `MultipeerSyncService` war zwar `ObservableObject`, aber ohne `@Published`-
Properties, sodass sich SwiftUI-Views nie auf seinen Zustand aktualisierten. Jetzt:

- **`MultipeerSyncService.aktiv`** ist jetzt `@Published`, neue `@Published private(set)
  var verbundenePeerNamen: [String]`, gepflegt in `session(_:peer:didChange:)` sowie beim
  Session-Abbau in `beendeAdvertisingUndBrowsing()`.
- **`SyncOrdnerSettingsView`**: neuer Abschnitt „Sync-Status“ zeigt Zeitpunkt des letzten
  erfolgreichen Ordner-Syncs (`SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm`)
  sowie den aktuellen Multipeer-Status (inaktiv / sucht / verbunden mit wem).
- **`EinkaufenView`**: kleines Blitz-Symbol mit Geräteanzahl im Toolbar, solange
  tatsächlich mindestens ein Peer per Multipeer verbunden ist — sonst ausgeblendet.
- **`DebuggingView`**: neue Sektion „Multipeer-Kanal“ mit demselben Status sowie (nur
  `#if DEBUG`) einem Schalter „Multipeer erzwingen“, um den Kanal unabhängig vom
  Einkaufen-Bildschirm testweise zu starten/stoppen.

## v0.12 (Build 228) — Code-Review-Fixes für den Multipeer-Beschleunigungskanal (GitHub #49)

Ultra-Review (8 Finder-Winkel, 9-fach unabhängig verifiziert) über den Build-227-Diff
fand sieben reale Bugs und zwei Cleanup-Punkte, alle gefixt:

- **Race: Datei-Batch-Import vs. Multipeer-Sofort-Anwendung.** `importiereNeueEvents`
  hielt seinen `gewinner`-Index über mehrere `await`-Punkte hinweg unverändert, während
  ein per Multipeer empfangenes Event auf einem separaten `@MainActor`-Task denselben
  Konflikt bereits entscheiden konnte — der Batch-Zyklus konnte den gerade erst korrekt
  gesetzten Zustand danach mit einem veralteten Snapshot überschreiben. Neue Sperre
  `SyncImportService.batchZyklusLaeuft`: `wendeEinzelnesEmpfangenesEventAn` tut während
  eines laufenden Batch-Zyklus bewusst nichts (kein Datenverlust, der Datei-Kanal liefert
  dasselbe Event ohnehin zusätzlich).
- **Race: Gruppen-ID-Marker-Datei.** `multipeerGruppenID(in:)` war ein ungeschütztes
  Read-then-write — zwei überlappende `starteAdvertisingUndBrowsing()`-Aufrufe (schnelles
  Verlassen+Wiederbetreten von `EinkaufenView`) konnten unterschiedliche UUIDs
  lesen/schreiben. Neue synchrone `wirdAufgebaut`-Sperre (vor dem ersten `await` gesetzt)
  verhindert überlappende Aufrufe vollständig.
- **scenePhase `.inactive` beendete den Multipeer-Kanal dauerhaft.** `stoppen()` lief auch
  bei kurzen Unterbrechungen (Anrufbanner, Kontrollzentrum), setzte aber `aktiv` nicht
  zurück — `starten()` prüfte `aktiv` nicht erneut, der Kanal blieb für den Rest der
  Einkaufssitzung tot. `starten(context:)` startet Advertising/Browsing jetzt erneut,
  falls `aktiv` bereits `true`, aber `session` `nil` ist.
- **UTF8-Kürzung von `MCPeerID.displayName` konnte über dem 63-Byte-Limit bleiben.** Das
  manuelle Byte-Array-Trimmen entfernte nur Continuation-Bytes, nie einen angeschnittenen
  Leading-Byte — belegt durch einen Repro-Fall, der nach der „Kürzung" weiterhin über dem
  Limit lag. Ersetzt durch `Character`-weises `removeLast()`, das nie mitten in einer
  Mehrbyte-Sequenz schneidet.
- **`#Preview`-Blöcke fehlten das neue `MultipeerSyncService`-EnvironmentObject** in
  `EinkaufenView.swift` und `App/RootView.swift` — Absturz beim Öffnen der Xcode-Canvas-
  Preview. Ergänzt.
- **Voller `SyncEvent`-Tabellen-Scan pro einzelnem Multipeer-Event**, entgegen der eigenen
  Dokumentation von `alleAktuellenGewinnerUndBekannteIDs` ("nur für den Batch-
  Anwendungsfall"). `wendeEinzelnesEmpfangenesEventAn` prüft jetzt zuerst günstig
  `istBereitsBekannt`, dann die gezielte Einzelabfrage `aktuellerGewinner` statt eines
  vollen Index-Aufbaus.
- **Parameter-Schatten + asymmetrischer Peer-Guard:** der Einladungs-Kontext-Parameter
  hieß `context` und verdeckte die gleichnamige `ModelContext?`-Property; der
  Gruppen-Schlüssel-Check war zwischen Advertiser/Browser dupliziert, nur die
  Browser-Seite prüfte bereits verbundene Peers. Umbenannt zu `gruppenContext`,
  gemeinsamer `passtGruppenSchluessel(_:)`-Helfer, Guard auf beiden Seiten.
- **Cleanup:** `SyncExportService.schreibeBlocking`/`SyncSnapshotExportService.schreibeBlocking`
  delegieren jetzt an `SyncDateiZugriff.schreibeKoordiniert` statt das
  `NSFileCoordinator`-Schreib-Muster ein drittes Mal zu duplizieren (Signaturen
  unverändert, keine Aufrufstelle betroffen).

**Bewusst nicht verändert:** Das im Review ebenfalls aufgezeigte, aber explizit
dokumentierte Vertrauensmodell (Zertifikat wird ungeprüft akzeptiert, Gruppen-Schlüssel
wandert vor Verbindungsaufbau unverschlüsselt über `discoveryInfo`/Einladungs-Kontext) —
schwächer als das bisherige Datei-Kanal-Vorbild, aber eine Design-Entscheidung, keine
versehentliche Regression. Zurückgestellt zur bewussten Entscheidung, nicht automatisch
gehärtet.

Kein SwiftData-Modell betroffen. Build/Test grün (35 Suiten/284 Tests), Simulator- und
Geräte-Build sauber.

## v0.12 (Build 227) — GitHub #49: Multipeer-Beschleunigungskanal für die Datensynchronisation

- Neuer, rein additiver Sync-Kanal (``MultipeerSyncService``) neben dem
  bestehenden FileProvider-Kanal: solange `EinkaufenView` auf zwei Geräten in
  Reichweite (WLAN/Bluetooth) gleichzeitig sichtbar ist, werden neue
  Bereich-A-`SyncEvent`s zusätzlich sofort per `MCSession` gespiegelt — die
  geteilte Datei bleibt Quelle der Wahrheit, ohne Verbindung ändert sich
  nichts am bisherigen Verhalten.
- Gruppen-Identität als Marker-Datei `.sync-gruppen-id` im geteilten Ordner
  selbst abgeleitet (``SyncOrdnerService/multipeerGruppenID(in:)``) — bewusst
  nicht von einer `Einkaufsliste.id` wie ursprünglich im Issue skizziert, da
  ein Ordner inzwischen alle Listen eines Geräts abdeckt. Bonjour-Service-Type
  ist app-weit fest (`NSBonjourServices` muss statisch deklariert werden); der
  eigentliche Gruppen-Abgleich läuft über `discoveryInfo`/Einladungs-Kontext.
  Details: `docs/DATENSYNCHRONISATION.md` §1, ``MultipeerSyncService``-Typ-Doku.
- Neue Info.plist-Berechtigung `NSLocalNetworkUsageDescription` +
  `NSBonjourServices` (`project.yml`) — neuer Berechtigungsdialog beim ersten
  gemeinsamen Einkaufen nach dem Update, siehe `docs/BEDIENUNGSANLEITUNG.md`.
- Kein SwiftData-Modell betroffen (`MultipeerSyncService` ist ein reiner
  Laufzeit-Dienst, keine `@Model`-Klasse) — keine `SchemaVN`/`MigrationStage`-
  Frage.
- **Noch ohne echten Zwei-Geräte-Live-Test** (Simulatoren können Bluetooth/
  AWDL-Peer-Discovery nicht zuverlässig nachbilden) — siehe
  `docs/DATENSYNCHRONISATION.md` §9 „Bekannte Grenzen".

## v0.11 (Build 226) — GitHub #80: SyncEvent-„bereits gesehen"-Zustand übersteht Wipe-und-Neuaufbau

- `SyncErsetzenService` (Korruptions-Recovery, Erstbeitritt, sowie der
  erzwungene Voll-Abgleich aus GitHub #89) löschte beim Neuaufbau bisher
  unbemerkt die lokale `SyncEvent`-Tabelle mit — der nächste Sync-Zyklus las
  danach jede noch nicht abgelaufene Peer-Event-Datei erneut.
- `SyncErsetzenBackup` sichert jetzt zusätzlich den lokal bekannten
  `SyncEvent`-Bestand (neues Feld `bekannteSyncEvents`) und stellt ihn nach
  einem Neuaufbau wieder her, inklusive korrekt erhaltenem
  `hochgeladen`-Status für noch nicht exportierte eigene Events. Details:
  `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 45.
- Kein SwiftData-Modell betroffen (`SyncErsetzenBackup` ist reines
  Codable-Backup-Format, keine `@Model`-Klasse) — keine
  `SchemaVN`/`MigrationStage`-Frage. `bekannteSyncEvents` ist optional, ein
  Backup im alten Format bleibt weiterhin decodierbar.

## v0.11 (Build 225) — GitHub #68: KaufEintrag.ursprungsGeraeteID zentralisiert Ursprungs-Unterdrückung

- `KaufEintrag` bekommt ein neues additiv-optionales Attribut
  `ursprungsGeraeteID: String?` (`nil` = lokal entstanden, sonst die
  Geräte-ID des Peers, von dem der Eintrag per Sync-Event oder Snapshot
  übernommen wurde — analog `SyncEvent.autorGeraeteID`).
- Die Regel „ein fremd entstandener `KaufEintrag` bekommt nie einen
  `kategorieBesuchsIndex`" (sonst würde die ladenspezifische, von
  `AbteilungsDistanzService` gelernte Distanzmatrix mit der Laufreihenfolge
  eines anderen Geräts verfälscht) war bisher nur an zwei unabhängigen
  Call-Sites (`SyncImportService.materialisiere`,
  `SyncSnapshotImportService.mergeKaufEintraege`) von Hand nachgebildet.
  `KaufEintrag.init` erzwingt sie jetzt zentral im Typ selbst — ein
  künftiger weiterer Konstruktionsort kann sie nicht mehr vergessen.
- Additiv-optional: keine neue `SchemaVN`/`MigrationStage` nötig, siehe
  `docs/BUILD_WORKFLOW.md` → „SwiftData-Migration: wann welche
  Schema-Version?".

## v0.11 (Build 223) — Fix: WarengruppenDistanzPeerZaehlerStand fehlte im SwiftData-Schema (GitHub #87)

- `WarengruppenDistanzPeerZaehlerStand` (der Peer-Zähler-Baustein aus dem
  #87-Merge-Fix) war nie in `SchemaV1.models` (`SchemaDefinition.swift`)
  eingetragen — SwiftData kennt den Typ mangels Relationship zu einem
  gelisteten Modell nicht implizit. `SyncSnapshotImportService.mergeWarengruppenDistanzen`
  legt beim Sync trotzdem Instanzen davon an, sobald ein Peer-Beitrag zu
  einer Warengruppen-Distanz gemeldet wird.
- Reiner Registrierungsfehler, aufgefallen weil die Testsuite ihr eigenes,
  manuell zusammengestelltes Schema nutzt (dort war der Typ korrekt gelistet)
  und den Produktions-Schemaaufbau deshalb nie durchlief.
- Additiv-optional (kein bestehender Modelltyp geändert, keine
  Datentransformation): keine neue `SchemaVN`/`MigrationStage` nötig, siehe
  `docs/BUILD_WORKFLOW.md` → „SwiftData-Migration: wann welche
  Schema-Version?“.

## v0.11 (Build 222) — Aktive Rückfrage bei mehrdeutigen Sync-Merge-Kandidaten + Test-Fixes

- Drei bisher fehlschlagende Tests waren keine Mitternachts-/Zeitgrenzen-Bugs:
  die drei Zähler-Tests fehlten Koordinaten auf beiden `Geschaeft`-Seiten
  (seit GitHub #86 für automatisches Merging zwingend), und
  `wochenverdichtungBehaeltHoechstenPreisMitEchtemDatum` war tatsächlich
  wochentagsabhängig (feste -10/-8-Tage-Offsets konnten je nach Testlauf-Tag
  über einen ISO-Wochenwechsel rutschen) — jetzt an den Wochenstart verankert.
- Neues additives Modell `SyncAbgleichKandidat`: `Geschaeft`/`Artikel`/
  `Einkaufsliste`, die beim laufenden Hintergrund-Sync nicht eindeutig
  zugeordnet werden können (z.B. ein Geschäft ohne Koordinaten), werden
  jetzt zurückgestellt und dem Nutzer über ein Badge in
  `SyncOrdnerSettingsView` zur aktiven Entscheidung vorgelegt, statt wie
  bisher still als Dublette angelegt zu werden — erweitert die bereits
  bestehende Beitritts-Rückfrage (GitHub #86 Teil 2) auf den laufenden Sync
  und alle drei Bereich-B-Typen.

## v0.11 (Build 221) — Umbenennung Warengruppe → Abteilung in GUI und internen Bezeichnern

- Alle sichtbaren GUI-Texte ("Warengruppe(n)" → "Abteilung(en)") in Views,
  Hilfetexten (`HelpView`) und der Bedienungsanleitung umbenannt.
- Fünf UI-Typen inkl. Dateien umbenannt: `WarengruppenVerwaltungView` →
  `AbteilungenVerwaltungView`, `NeueWarengruppeSheet` → `NeueAbteilungSheet`,
  `WarengruppeHinzufuegenSheet` → `AbteilungHinzufuegenSheet`,
  `GeschaeftWarengruppenSektion` → `GeschaeftAbteilungenSektion`, sowie das rein
  private `WarengruppeBearbeitenView` → `AbteilungBearbeitenView`.
- Zusätzlich, da nicht persistiert: `WarengruppenDistanzService` →
  `AbteilungsDistanzService` (inkl. Datei/Tests) und `WarengruppenVorschlag` →
  `AbteilungsVorschlag` (`AISuggestionService`, KI-Vorschlag für Geschäftstyp-Abteilungen).
- **Bewusst NICHT angefasst** (gleicher Grund wie bei der Kategorie→Warengruppe-
  Umbenennung, GitHub #62): der `@Model`-Typ `WarengruppenDistanz` und
  `WarengruppenDistanzPeerZaehlerStand` selbst, alle davon persistierten
  Relationship-/Attribut-Namen (u.a. `Geschaeft.warengruppenDistanzen`) sowie die
  Codable-Feldnamen der Sync-Snapshots (`WarengruppenDistanzSnapshot`,
  `SyncSnapshot.warengruppenDistanzen`) — eine echte Modell-Umbenennung bliebe
  weiterhin GitHub #62 vorbehalten, jetzt mit Zielname `Abteilung`/
  `AbteilungsDistanz` statt `Warengruppe`/`WarengruppenDistanz` (siehe
  `docs/ROADMAP.md`).

## v0.11 (Build 220) — GitHub #93: Geschäftsspezifisch gelernte Kategorie reduziert Mehrfachkategorie-Anzeige

- Neu: `WarengruppenDistanzService.gelernteKategorie(fuer:in:context:)` wertet
  `KaufEintrag.kategorie` je (Artikel, Geschäft) aus und liefert ab mindestens 5
  Käufen mit mindestens 80% Mehrheit eine eindeutige Kategorie
  (GitHub-Nachfolgefund zu #36).
- `EinkaufenView` zeigt einen mehrfach kategorisierten Artikel bei gewähltem
  Geschäft nur noch im gelernten Abschnitt statt gleichzeitig in allen
  zugeordneten — vorher weiterhin (kein Geschäft gewählt, noch nicht genug
  Kaufhistorie oder Lernmodus aktiv), jetzt mit kleinem Hinweis-Symbol
  markiert. Im Lernmodus (`zeigeAlleArtikel`) bewusst weiter ungefiltert, damit
  eine falsch gelernte Zuordnung sichtbar korrigierbar bleibt.
- `Artikel.fuehrendeKategorie(inGeschaeft:context:)` nutzt die gelernte
  Kategorie jetzt als Top-Priorität vor dem bisherigen sortIndex-Fallback
  (wirkt sich auf Belegscan-/Preisschild-Scan-/Sync-Import-Zuordnung aus).
- Auslöser: Nutzerbericht „Zähler stimmt nicht, 5 Artikel angezeigt aber 0/4"
  auf der Liste „Urlaub" — Ursache war die gewollte Mehrfachanzeige aus #36,
  vom Fortschritts-Zähler (zählt eindeutige Artikel) nicht berücksichtigt.

## v0.11 (Build 218) — GitHub #92: startDownloadingUbiquitousItem-Fix + experimenteller Dokumenten-Picker-Trigger

- Recherche zu #91s nur temporärer Wirkung ergab eine seit iOS 18.4
  dokumentierte Regression: bereits als "downloaded" markierte Dateien
  laden neuere Remote-Versionen nicht mehr automatisch nach.
  `SyncDateiZugriff.leseKoordiniert(_:)`/`.listeKoordiniert(_:)` rufen
  deshalb jetzt vor jedem koordinierten Zugriff zusätzlich
  `FileManager.startDownloadingUbiquitousItem(at:)` auf.
- Nutzeridee als bewusst unbelegtes Experiment umgesetzt: der manuelle
  "Jetzt synchronisieren"-Button blendet kurz einen
  `UIDocumentPickerViewController` auf den Sync-Ordner ein und schließt ihn
  automatisch wieder (``ICloudSyncTriggerPicker``) — Testidee, dieselbe
  File-Provider-Enumeration wie beim Öffnen in der Files-App auszulösen.
  Wirkung noch nicht durch Live-Test bestätigt.

## v0.11 (Build 216) — GitHub #91 (Fortsetzung): Langlebiger NSMetadataQuery-Beobachter + koordinierte Schreibzugriffe

- Der koordinierte-Listings-Fix aus der letzten Version brachte laut
  Live-Test ebenfalls keine Verbesserung. Neuer, gegen Apples offiziellen
  „Designing for Documents in iCloud"-Guide verifizierter dritter Anlauf:
  `SyncICloudAenderungsBeobachter` — eine **langlebige** `NSMetadataQuery`
  (statt wie beim ersten Anlauf jeden Zyklus neu erzeugt und nach 2s
  gestoppt), gescoped auf den `peers/`-Ordner sowie je bekanntem Peer dessen
  Ordner plus `events/`/`kaeufe/`-Unterordner (nicht nur die
  Sync-Ordner-Wurzel — die Query beobachtet zuverlässig nur die Wurzel jedes
  gescopten Ordners). Reagiert dauerhaft auf
  `NSMetadataQueryDidUpdateNotification` und stößt dann einen zusätzlichen
  Sync-Zyklus an.
- Dabei geprüft, ob auch alle Schreibzugriffe auf den Sync-Ordner koordiniert
  sind (Apples iCloud-Doku verlangt das für jeden Zugriff, nicht nur Lesen):
  sechs unkoordinierte Stellen gefunden und auf neue gemeinsame Funktionen
  `SyncDateiZugriff.erstelleVerzeichnisKoordiniert(_:)`/`.loescheKoordiniert(_:)`/
  `.verschiebeKoordiniert(von:nach:)` umgestellt.
- Details in `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 42.

## v0.11 (Build 215) — GitHub #91 (Fortsetzung): iCloud-Weckimpuls wirkungslos, Root Cause jetzt koordinierte Verzeichnis-Listings

- Zwei-Geräte-Live-Test zeigte: der `NSMetadataQuery`-Weckimpuls aus der
  vorherigen Version brachte keine Verbesserung — Geräte synchronisierten
  weiterhin nur nach manuellem Öffnen des Sync-Ordners in der Files-App.
  `SyncICloudWeckerService` komplett entfernt (kostete nur ~2s pro Zyklus
  ohne Nutzen); Recherche bestätigt zwei Gründe, warum die Grundannahme
  falsch war (`NSMetadataQuery` triggert selbst keinen Download unbekannter
  Objekte, und beobachtet zuverlässig nur die Wurzel des gescopten Ordners,
  nicht die tiefer liegenden `peers/<Gerät>/…`-Unterordner).
- Neuer, diesmal gegen Apple-Dokumentation verifizierter Fix-Versuch: alle
  Verzeichnis-Listings innerhalb des Sync-Ordners laufen jetzt über die neue
  `SyncDateiZugriff.listeKoordiniert(_:)` (koordinierter
  `NSFileCoordinator`-Zugriff, analog zum bestehenden `leseKoordiniert(_:)`
  für einzelne Dateien, GitHub #52) statt über ungeschütztes
  `FileManager.contentsOfDirectory`.
- Details in `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitte 39 (Nachtrag)
  und 40.

## v0.11 (Build 214) — Fix: WarengruppenDistanz-Merge reihenfolgeabhängig (GitHub #87)

- `SyncSnapshotImportService.mergeWarengruppenDistanzen` mittelte bei einem
  bereits vorhandenen lokalen Eintrag bisher naiv 50/50 mit dem Peer-Wert,
  unabhängig davon, wie viele Beobachtungen hinter jeder Seite steckten —
  reihenfolgeabhängig, anfällig für Einzel-Ausreißer. Jetzt ein echter
  gewichteter Mittelwert nach Beobachtungsanzahl (G-Counter-Muster, analog
  `Geschaeft.anzahlEinkaufsvorgaenge`), gedeckelt auf `WarengruppenDistanz.maximaleMergeGewichtung`
  (≈ `1 / WarengruppenDistanzService.lernrate`, da das lokale Lernen selbst
  nur ein begrenztes EMA-Gedächtnis hat) und idempotent bei wiederholtem
  Sync desselben Peer-Standes (nur der tatsächliche Zuwachs seit dem
  zuletzt bekannten Stand fließt ein, kein erneutes Mischen bereits
  bekannter Information). Neues Modell `WarengruppenDistanzPeerZaehlerStand`.
  `SyncSnapshot.aktuelleFormatVersion` auf 5 angehoben
  (`WarengruppenDistanzSnapshot.eigeneAnzahlBeobachtungen` neu). Details in
  `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 41.

## v0.11 (Build 213) — Fix: iCloud-Weckimpuls (GitHub #91) crashte mit API-Misuse

- Live-Test-Fund direkt nach Einführung: Crash `[CRIT] API MISUSE: running a
  NSMetadataQuery with maxConcurrentOperationCount != 1 is not supported`.
  `NSMetadataQuery.operationQueue` verlangt eine serielle Queue, ein
  unkonfiguriertes `OperationQueue()` hat aber unbegrenzte Nebenläufigkeit.
  Fix: `maxConcurrentOperationCount = 1` vor der Zuweisung setzen. Details in
  `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 39 (Nachtrag).

## v0.11 (Build 211) — GitHub #91: Aktiver iCloud-Weckimpuls vor jedem Sync-Zyklus

- Neu: `SyncICloudWeckerService.wecke(ordner:)` läuft als erster Schritt
  jedes `SyncPollingService.syncZyklus()` (automatisch wie über „Jetzt
  synchronisieren") — eine kurz laufende, auf den Sync-Ordner gescopte
  `NSMetadataQuery` stößt aktiv den iCloud-Abgleich an, statt nur passiv
  bereits lokal gecachte Ordnerinhalte zu lesen (Live-Test-Beobachtung:
  Peer-Änderungen tauchten teils erst auf, nachdem der Ordner manuell in der
  Files-App geöffnet wurde). Wartet höchstens 2s (Timeout, testbar/nachjustierbar),
  blockiert den Zyklus aber nie länger; bei Ordnern anderer Anbieter (Synology
  Drive, lokal) wirkungslos, da `NSMetadataQuery` auf iOS fest an iCloud
  gebunden ist, kein Sonderfall nötig.
- Neues Diagnose-Event `sync_icloud_wecker_abgeschlossen` (Sync-Debug-Modus,
  Details: `rechtzeitig=<Bool> dauer=<Duration>`) als Grundlage, den
  Timeout-Wert später empirisch nachzujustieren.
- Details in `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 39.

## v0.11 (Build 210) — Live-Test-Fund: Einkauf abschließen ließ Duplikat-Vorgänge und eine Sync-Sicherheitsnetz-Lücke zurück

- Im Mehrgeräte-Live-Test gefunden: „Einkauf abschließen" schloss nur den
  lokalen Anker-Vorgang, während die listenweite Sichtbarkeit abgehakter
  Artikel (seit der Vorgangs-Entkopplung) alle offenen Vorgänge einer Liste
  umfasst — abgehakte Artikel blieben an übrig gebliebenen, weiterhin offenen
  Duplikat-Vorgängen (auch anderer Geschäfte) hängen und tauchten nach dem
  Abschließen unverändert weiter als abgehakt auf.
- Fix: „Einkauf abschließen" (und das automatische Abschließen nach
  Inaktivität) schließen jetzt alle offenen Vorgänge derselben Liste,
  unabhängig vom Geschäft — der Besuchszähler wird dabei weiterhin nur
  einmal erhöht.
- Dabei zweite Lücke gefunden: das Sync-Merge-Sicherheitsnetz gegen verpasste
  Events nutzte „irgendein Vorgang der Liste ist offen" als Näherung für
  „dieser Kauf ist bereits bekannt". Sobald durch den obigen Fix keine Liste
  mehr offen war, holte ein noch nicht aktueller Peer-Snapshot bereits
  gekaufte Artikel zurück auf die offene Liste (bestätigt: Listenstand sprang
  bei beiden Geräten unabhängig voneinander hoch und blieb auf
  unterschiedlichen Endständen stehen).
- Fix: ein normal synchronisierendes Gerät behandelt „ich habe irgendwann
  einen KaufEintrag dafür" jetzt als dauerhaftes Faktum statt
  vorgangs-abhängig; nur ein Gerät, das laut
  `SyncAktualitaetsService.istAusDerZeitGefallen` tatsächlich lange nicht
  synchronisiert hat, fällt weiter auf die alte, schwächere Prüfung zurück.
- Zusätzlich: die DB-Debug-Log-Writer-Instanz wird jetzt zwischengespeichert
  statt bei jedem Aufruf neu erzeugt — verhinderte, dass zwei fast
  gleichzeitige Protokoll-Schreibvorgänge sich gegenseitig überschrieben
  (abgeschnittene/vertauschte Log-Zeilen).
- Details: `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3 (zweiter/dritter
  Nachtrag) und 4.7, `docs/LOGGING.md`.

## v0.10 (Build 202) — Live-Test-Fund: Dedupe-Schutz beim Abhaken galt nur pro Vorgang statt listenweit

- Im Zwei-Geräte-Test gefunden: Artikel, die in unterschiedlichen Läden für
  dieselbe Liste eingekauft wurden, ließen sich nach dem Sync auf dem
  anderen Gerät nicht mehr abwählen/reaktivieren (z.B. um ein versehentliches
  Abhaken rückgängig zu machen).
- Ursache: der Schutz gegen doppeltes Abhaken prüfte nur den aktuellen
  Einkaufsvorgang, nicht die ganze Liste. Da die "abgehakt"-Anzeige seit
  Kurzem listenweit über alle offenen Vorgänge gilt, konnte derselbe Artikel
  unter zwei verschiedenen offenen Vorgängen (zwei Geschäften) unabhängig
  abgehakt werden — zwei Kaufeinträge entstanden, von denen ein einzelnes
  Abwählen nur einen entfernte.
- Fix: Dedupe-Schutz prüft jetzt listenweit über alle offenen Vorgänge.
  Zusätzlich räumen `Abwählen`/`dauerhaft entfernen` jetzt alle passenden
  Einträge auf einmal auf, nicht nur den ersten Treffer — das behebt auch
  bereits bestehende Duplikate aus der Testphase. Details:
  `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 38.

## v0.10 (Build 201) — Live-Test-Fund: Sichtbarkeit „abgehakt“ hing am falschen Kriterium (Zeitfenster statt Vorgangs-Status)

- Im fortgesetzten Zwei-Geräte-Test gefunden: nach „Einkauf abschließen“ auf
  einem Gerät blieben die abgehakten Artikel auf der geschäftsneutralen
  Ansicht (kein Geschäft gewählt) weiterhin sichtbar; zusätzlich zeigten
  beide Geräte trotz erzwungenem Sync unterschiedliche Artikel für dieselbe
  Liste.
- Ursache: die Sichtbarkeitsregel filterte nach
  `KaufEintrag.datum >= aktuellerEinkauf.startZeit` — einem Zeitpunkt aus der
  rein lokalen, zufälligen Vorgangs-Historie des BETRACHTENDEN Geräts, nicht
  aus dem tatsächlichen Zustand des Vorgangs. Der ursprüngliche Auftrag war
  eindeutig: sichtbar, solange der Einkauf NICHT ABGESCHLOSSEN ist — das ist
  ein Zustand (`endZeit`), kein Zeitpunkt-Vergleich.
- Fix: `Einkaufsvorgang.abgehakteKaufEintraege(fuerListe:unter:)` filtert
  jetzt schlicht auf `endZeit == nil`, kein Zeitfenster mehr. Sobald ein
  Gerät „Einkauf abschließen“ ausführt, verschwinden dessen Artikel nach dem
  Sync auf JEDEM Gerät konsistent aus der „abgehakt“-Ansicht. Details:
  `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 37.

## v0.10 (Build 200) — Live-Test-Fund: „dauerhaft entfernen“/„Abwählen“ wurden nach Vorgangs-Rotation zum stillen No-op

- Im echten Zwei-Geräte-Test zur letzten Änderung (Einkaufsvorgang
  entkoppelt) gefunden: nach „Einkauf abschließen“ konnte ein bereits
  abgehakter Artikel über die Geschäftsansicht per Wisch-Geste NICHT mehr
  zuverlässig dauerhaft entfernt/abgewählt werden — er blieb dann auf
  anderen Ansichten/Geräten weiterhin fälschlich als „abgehakt“ stehen.
- Ursache: `EinkaufenView.umschalten(_:kategorie:)`/`entferneDauerhaft(_:)`
  suchten den zu mutierenden `KaufEintrag` über einen Fetch, der nach
  `datum >= einkaufsvorgang.startZeit` filterte — „Einkauf abschließen“ legt
  aber sofort einen neuen Vorgang mit späterer Startzeit an, wodurch der
  echte, ältere Eintrag herausgefiltert wurde (stiller No-op, kein
  `artikelDauerhaftEntfernt`-Sync-Event wurde je aufgezeichnet).
- Fix: beide Funktionen ermitteln den Eintrag jetzt direkt über
  `EinkaufslisteView.kaufEintrag(fuer:)` — dieselbe Quelle, die auch die
  Sichtbarkeit des Buttons bestimmt — statt ihn über ein Zeitfenster erneut
  zu erraten. Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 36.

## v0.10 (Build 199) — Einkaufsvorgang entkoppelt: Live-Ansicht braucht keine geteilte Vorgangs-Identität mehr

- Architektur-Vereinfachung: die Live-Ansicht „was ist gerade abgehakt" löst
  sich jetzt über die **Einkaufsliste** (ohnehin bereits geteilt) statt über
  einen von allen Geräten übereinstimmend gewählten `Einkaufsvorgang`.
  `EinkaufenView.abgehakteKaufEintraegeFuerAktuelleListe` zeigt alle
  Kaufeinträge der aktuellen Liste, unabhängig davon, an welchem (auch
  bereits geschlossenen) Vorgang sie hängen — solange ihr Datum nicht vor
  dem Start des eigenen aktuellen Einkaufs liegt.
- Damit entfällt die gesamte „Vorgangs-Umleitung" ersatzlos —
  `Einkaufsvorgang.offenerNachfolger`, `SyncImportService.aufOffenenNachfolgerUmgeleitet`
  sowie der `bekannter`-geschlossen-Zweig in
  `SyncSnapshotImportService.mergeEinkaufsvorgaenge` sind gelöscht. Das war
  historisch der mit Abstand fehleranfälligste Teil der gesamten
  Synchronisation und Auslöser für GitHub #66/#67/#69. `offenerTreffer`
  (verhindert doppelt gezählte Besuche) und `Einkaufsvorgang.kanonischer(unter:)`
  bleiben unverändert bestehen.
- `EinkaufenView.umschalten(_:kategorie:)`/`entferneDauerhaft(_:)` ermitteln
  den tatsächlichen Besitzer-Vorgang eines Kaufeintrags jetzt per frischem,
  liste-/zeitfenster-beschränktem Fetch, statt blind auf dem lokalen
  Anker-Vorgang zu operieren.
- Details, Begründung und Testabdeckung: `docs/DATENSYNCHRONISATION.md`
  Abschnitt 4.3, `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 35.
- **Hinweis:** wie bei allen bisherigen Änderungen an dieser Stelle sollte
  vor endgültigem Vertrauen ein echter Zwei-Geräte-Test erfolgen (ein Gerät
  schließt „Einkauf abschließen" mitten im gemeinsamen Einkauf, während das
  andere weiter abhakt).

## v0.10 (Build 198) — Geschäft kommt bei umgeleiteten Abhaken-Ereignissen aus der Nutzlast statt aus dem Container-Vorgang (GitHub #66)

- `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` legte einen neuen
  `KaufEintrag` nach einer Vorgangs-Umleitung bisher mit dem Geschäft des
  NACHFOLGE-Vorgangs an, statt mit dem Geschäft, an dem der Kauf laut
  sendendem Gerät tatsächlich stattfand — z.B. wenn „Einkauf abschließen"
  die Geschäftsauswahl zurücksetzt (GitHub #51).
- `SyncEventNutzlast` bekommt ein additiv-optionales `geschaeftID`; das
  sendende Gerät zeichnet dort sein eigenes aktives Geschäft mit auf.
  `SyncImportService` löst diese ID beim Materialisieren zu einem lokalen
  Geschäft auf (über den Bereich-B-Alias) und übergibt sie als Override —
  analog dem bereits bestehenden `kategorie`-Override, aber bewusst doppelt
  optional (`Geschaeft??`), um „kein Override" von „Override auf explizit
  kein Geschäft" zu unterscheiden. `geschaeftNameSnapshot` wird automatisch
  mitkorrigiert.
- Geprüft und dokumentiert: dieser Fix entschärft auch GitHub #69 (store-loser
  Umleitungs-Fallback) vollständig auf der Datenebene — der Kaufeintrag trägt
  jetzt immer das korrekte Geschäft, unabhängig vom Container-Vorgang. #69
  bleibt trotzdem offen für die verbleibende, rein kosmetische
  Gruppierungsfrage.

## v0.10 (Build 197) — Deterministische Kanon-Wahl bei mehreren offenen Einkaufsvorgang-Kandidaten (GitHub #67-Erweiterung)

- Legten zwei Geräte kurz nacheinander (vor dem ersten Sync-Zyklus)
  unabhängig je einen eigenen offenen Einkaufsvorgang für dieselbe
  (Geschäft, Liste)-Kombination an, wählten `offenerNachfolger`,
  `EinkaufenView.aktuellerEinkauf` und `mergeEinkaufsvorgaenge`s
  `offenerTreffer`-Zweig jeweils einen beliebigen, von der SwiftData-
  Fetch-Reihenfolge abhängigen Treffer — ein Gerät konnte dadurch dauerhaft
  auf seinem eigenen, vom Merge bereits „verlorenen" Vorgang hängen bleiben
  und vom anderen Gerät abgehakte Artikel während des laufenden Einkaufs nie
  als abgehakt sehen (das eigentliche „nicht mehr kaufen"-Verhalten war
  davon nicht betroffen, nur die Live-Anzeige).
- Neue gemeinsame Regel `Einkaufsvorgang.kanonischer(unter:)`: ältester
  `startZeit` gewinnt, bei Gleichstand die kleinere `id` als Tiebreaker
  (analog `LamportTimestamp`) — an allen drei Stellen eingesetzt. Da
  `startZeit` beim Sync unverändert übernommen wird, kommen alle Geräte
  danach zuverlässig auf denselben Vorgang.
- Deckt bewusst nicht #69 ab (store-loser Fallback bei fehlendem passendem
  Geschäft) — das bleibt eigenständig offen.

## v0.10 (Build 196) — Härtung: automatischer Rollback bei eindeutig fehlgeschlagenem Neuaufbau

- `SyncErsetzenService.fuehreAusstehendeAktionAus` zeigte einen Rückgang nach
  einem „Ersetzen durch Peer"-Neuaufbau bisher nur an (Vorher-/Nachher-
  Zusammenfassung), verhinderte ihn aber nicht. Ein EINDEUTIGER Totalverlust
  (Ordnerzugriff gescheitert, oder kein einziger erreichbarer Peer bringt
  irgendetwas zurück, obwohl vorher Daten vorhanden waren) importiert jetzt
  automatisch das ohnehin vorhandene Vorher-Backup zurück, statt den leeren
  Neuaufbau stehen zu lassen — `DebuggingView` zeigt dafür zusätzlich einen
  roten Hinweis. Ein teilweiser Rückgang (kann legitim sein, z.B. bereits
  verarbeitete Peer-Löschungen) bleibt bewusst nur informativ, keine
  automatische Aktion.

## v0.10 (Build 195) — Sync-Merge für Geschäfte korrigiert + aktive Rückfrage beim Ordner-Beitritt (GitHub #86)

- **Bug-Fix.** `SyncSnapshotImportService.mergeGeschaefte` verglich Geschäfte
  beim automatischen Hintergrund-Merge bisher mit der großzügigen,
  interaktiven Regel (Name exakt ODER Teilstring ODER reine
  Koordinaten-Nähe, immer mit dem globalen 75m-Standardwert statt des
  individuellen `erkennungsradius`). Neue, strengere Regel nur für diesen
  automatischen Pfad (`GeschaeftErkennungService.istGleicherOrtFuerSyncMerge`):
  Name muss EXAKT übereinstimmen UND beide Koordinaten müssen innerhalb der
  strengeren der beiden individuellen Radien liegen — behebt sowohl den
  ursprünglich gemeldeten Radius-Bug als auch den Fund, dass gleicher/
  überlappender Name allein schon reichte, unabhängig von der Distanz.
- **Neu: aktive Rückfrage beim Sync-Ordner-Beitritt.** Der Beitritt zu einem
  Ordner mit bestehenden Peer-Daten ist ein einmaliger, nutzerinitiierter
  Moment — hier lohnt sich eine Rückfrage, die im laufenden Betrieb bewusst
  nicht eingeführt wurde. `SyncSnapshotImportService.mehrdeutigeGeschaeftsKandidatenBeimBeitritt(context:)`
  scannt vor dem eigentlichen Merge (reines Lesen, keine Zustandsänderung)
  die Stammdaten aller Peers auf Kandidaten, die nach der alten, großzügigen
  Regel übereinstimmen würden, aber nicht nach der neuen strengen — bei
  Treffern fragt `GeschaeftsBeitrittsAbgleichSheet` aktiv nach („gleicher
  Laden" mit Namenswahl, oder „unterschiedliche Läden").
- Im laufenden Betrieb danach bleibt bewusst keine neue Zusammenführungs-
  Funktion nötig: seltene, zeitgleich unabhängig angelegte Duplikate fallen
  als zwei sichtbare Einträge auf und lassen sich über die bereits
  bestehende Löschfunktion bereinigen (Tombstone propagiert die Löschung
  automatisch an alle Geräte).

## v0.10 (Build 194) — Debug-Protokolle: drei Verbositätsstufen + Wiederholungs-Drosselung, Security-Scope-Zugriffsdiagnose

- **Verbositätsstufen statt An/Aus.** `SyncDebugLogger`/`DatabaseDebugLogger`
  bekommen je eine `Protokollstufe` (`Fehler`/`Standard`/`Ausführlich`,
  `Services/DebugLogWriter.swift`) statt eines einfachen Bool-Schalters —
  Analyse zweier realer Sync-Debug-Protokolle zeigte ca. 60% reines
  "unverändert"-Rauschen im Normalbetrieb. Bestehende Installationen werden
  beim ersten Zugriff einmalig vom alten Bool-Key migriert. `DebuggingView`
  zeigt pro Protokoll einen Picker statt eines Toggles.
- **Wiederholungs-Drosselung.** Neuer `WiederholungsFilter`
  (`Services/DebugLogWriter.swift`): exakt wiederholte Ereignisse (gleicher
  Typ + gleicher Detail-Text) werden zugunsten eines periodischen
  Lebenszeichens (60s) unterdrückt — ein Live-Fund zeigte, dass eine einzige
  anhaltende Störung binnen 27 Minuten 1065 identische Fehlerzeilen erzeugt
  hatte.
- **Security-Scope-Zugriffsdiagnose (neues `Ausführlich`-Ereignis
  `sync_scope_zugriff`).** Diagnose für einen Live-Test-Fund: das
  "Backup"-Gerät verlor mitten in einem Sync-Zyklus dauerhaft den
  Ordnerzugriff (`sync_ordner_zugriff_fehlgeschlagen` für jeden weiteren
  Schritt bis Sitzungsende), ohne dass sich aus dem bisherigen Protokoll
  klären ließ, ob ein verschachtelter/überlappender Scope-Zugriff (historische
  Root Cause eines identischen Symptoms, `docs/DATENSYNCHRONISATION_VERLAUF.md`
  §30) oder eine rein externe Ursache dahintersteckte. Neuer
  `SyncOrdnerZugriffsDiagnose`-Helper (`SyncOrdnerService.swift`) protokolliert
  jetzt um alle acht wiederkehrenden Top-Level-Sync-Funktionen herum
  Aufrufstelle, Erfolg/Fehlschlag und welche anderen Aufrufstellen zu diesem
  Zeitpunkt selbst noch einen Scope offen halten.
- Details, Stufen-Einordnung aller Ereignistypen und Schlüsselbildung des
  Wiederholungsfilters in `docs/LOGGING.md`.

## v0.10 (Build 193) — Sync-Event-Bereinigung: Alters-Löschung + erzwungener Voll-Abgleich für lange abwesende Geräte (GitHub #89)

- Eigene, hochgeladene Bereich-A-Event-Dateien (`peers/{gerät}/events/`)
  werden jetzt nach 30 Tagen automatisch gelöscht
  (`SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig`), statt
  unbegrenzt zu wachsen. Abgesichert durch `SyncAktualitaetsService`: ein
  bereits etabliertes Gerät, das selbst länger als dieselbe Frist nicht
  erfolgreich synchronisiert hat, erkennt das lokal und löst statt eines
  additiven Merges einen erzwungenen Voll-Abgleich aus (Store leeren, aus
  dem aktuellen Peer-Bestand neu aufbauen, bestehender
  `SyncErsetzenService`-Mechanismus) — bewusst **kein**
  Zusammenführen-Angebot, da additive Merges eigene Bereich-A-Karteileichen
  nie entfernen würden. Neue Nutzer-Meldung „Sync-Abgleich nötig" in
  `RootView`, kritische Voraussetzung: eigene ausstehende Änderungen werden
  vor dem Abgleich zuerst exportiert. Details, verworfene Alternative
  (Konsum-Quittung pro Peer) und Begründung in
  `docs/SYNC_EVENT_BEREINIGUNG.md`.
- Nebenbei zwei bereits vor dieser Session bestehende, latente Testfehler
  gefunden und behoben (`SyncSnapshotExportServiceTests.nurGeaenderterTeilWirdNeuGeschrieben`/
  `nurEinkaufslisteGeaendertLaesstStammJsonUnveraendert` prüften fälschlich
  auf Datei-Nichtexistenz statt auf Inhaltsänderung — ein Paket-Teil wird
  bereits beim allerersten Zyklus geschrieben, auch mit leerem Inhalt).

## v0.10 (Build 192) — Test-Fix Abschnitt-25-Guard (GitHub #79), DB-Debugging verschmolzen (GitHub #84), Preishistorie-Verdichtung in die Einstellungen (GitHub #83)

- **GitHub #79.** `neuerEinkaufsvorgangVomPeerErhoehtNichtZusaetzlichDenZaehler`
  war seit dem Abschnitt-25-Guard (siehe `mergeEinkaufsvorgaenge`) veraltet: der
  Test konstruierte bewusst eine unauflösbare `einkaufslisteID`, genau den Fall,
  den der Guard jetzt korrekt überspringt. Fix: Snapshot referenziert jetzt eine
  lokal vorab angelegte `Einkaufsliste` (analog benachbarter Tests) — prüft
  wieder den ursprünglich beabsichtigten Fall. Reiner Test-Fix, kein
  Produktionscode geändert.
- **GitHub #84.** `DebuggingView`s bisher zwei fast identische Sektionen
  (Sync-Debug-Modus, DB-Debug-Modus) zu einem gemeinsamen „Debug-Modus"-
  Abschnitt mit zwei Unteroptionen verschmolzen — ein Protokollgröße-/Teilen-/
  Leeren-Block statt zwei. Der DB-Debug-Log-Dateiname trägt jetzt zusätzlich den
  gesetzten Gerätenamen (`DatabaseLeaseService.eigenerGeraeteNameOverride`),
  z.B. „Küche DB Debug.log" statt des generischen `db-debug.log`. Dabei auch
  eine stale Footer-Behauptung korrigiert (Datenbank-Protokoll wurde laut
  `docs/LOGGING.md` schon länger nicht mehr in einen gemeinsamen Ordner
  gespiegelt).
- **GitHub #83.** Die Schwellwert-Einstellungen der automatischen
  Preishistorie-Verdichtung (`PreispunktVerdichtungSection`) von „Debugging"
  nach „Einstellungen → Preishistorie" verschoben — gehören fachlich dorthin,
  nicht zur Diagnose.

## v0.10 (Build 191) — Diagnose-Logging für Einkaufsvorgang-Abschluss-Übernahme

- **Nutzerbericht (2026-08-02):** "Abhaken synchronisiert, Einkauf
  abschließen nicht." Ein neuer Regressionstest
  (`abschlussEinesUeberOffenenTrefferAliasiertenVorgangsWirdBeimZweitenZyklusUebernommen`)
  bestätigt, dass der zugrundeliegende Merge-Mechanismus im isolierten Test
  korrekt funktioniert — die reale Ursache bleibt offen. Damit sie beim
  nächsten Reproduzieren mit aktivem Sync-Debug-Modus eindeutig sichtbar
  wird, protokolliert `SyncSnapshotImportService.mergeEinkaufsvorgaenge`
  jetzt explizit, ob und warum eine vom Peer gemeldete `endZeit`
  übernommen/nicht übernommen wurde (`sync_einkaufsvorgang_abschluss_uebernommen`/
  `_nicht_uebernommen`, Grund: `umgeleitetAufNachfolger`/`bereitsAbgeschlossen`/
  `endZeitVorStartZeit`) sowie wenn ein Eintrag ganz ohne Matching-Versuch
  übersprungen wird (`sync_einkaufsvorgang_eintrag_uebersprungen`, Grund:
  `unaufloesbareListe`/`tombstone`). Reine Diagnose-Ergänzung, keine
  Verhaltensänderung.

## v0.10 (Build 189) — Sync-Performance: einkaufslistenEintraege aus stamm.json in listen.json ausgelagert (GitHub #85)

- **Analyse-Fund.** `stamm.json` enthielt neben den echten (seltenen)
  Stammdaten (Geschäftstypen/Kategorien/Geschäfte/Artikel/Listen/Aliase)
  zusätzlich `einkaufslistenEintraege` — den vollständigen
  Einkaufslisten-Inhalt als additives Sicherheitsnetz neben den eigentlich
  zuständigen Bereich-A-Events. Da der Fingerabdruck-Vergleich `stamm.json`
  als eine Einheit behandelt, riss praktisch jedes Abhaken/Hinzufügen/
  Entfernen auf einer Einkaufsliste einen kompletten Neuaufbau/-schrieb der
  eigentlich stabilen Stammdaten mit sich — genau das Muster, das GitHub #82
  für `kaufEintraege` bereits behoben hatte, hier unentdeckt in `stamm.json`
  weiterbestehend. `einkaufslistenEintraege` ist jetzt ein eigener,
  unabhängig fingerabdruck-geprüfter Paket-Teil (`SyncListenSnapshot`/
  `listen.json`) — Details und Migrationsverhalten für Peers mit alter
  `stamm.json` in `docs/EXPORT_PAKET_UMBAU.md`. Merge-Logik unverändert.
  Regressionstest `nurEinkaufslisteGeaendertLaesstStammJsonUnveraendert`
  verifiziert die Kernaussage direkt.

## v0.10 (Build 188) — Umbenennung Kategorie → Warengruppe in GUI und internen Bezeichnern (GitHub #62)

- Alle sichtbaren GUI-Texte ("Kategorie(n)" → "Warengruppe(n)") in Views,
  Hilfetexten (`HelpView`) und der Bedienungsanleitung umbenannt.
- Vier dedizierte Verwaltungs-Views inkl. Dateien umbenannt:
  `KategorienVerwaltungView` → `WarengruppenVerwaltungView`,
  `NeueKategorieSheet` → `NeueWarengruppeSheet`,
  `KategorieHinzufuegenSheet` → `WarengruppeHinzufuegenSheet`,
  `GeschaeftKategorienSektion` → `GeschaeftWarengruppenSektion`, sowie das rein
  private `KategorieBearbeitenView` → `WarengruppeBearbeitenView`.
- **Bewusst NICHT angefasst** (siehe Rückfrage/Entscheidung in der Session vom
  2026-08-02): der `@Model`-Typ `ArtikelKategorie` selbst, alle davon
  persistierten Relationship-/Attribut-Namen (`Artikel.kategorie(n)`,
  `Geschaeft.kategorien`/`ausgeschlosseneKategorien`, `KaufEintrag.kategorie`,
  `WarengruppenDistanz.kategorieA/B`, `GeschaeftTyp.standardKategorien`) sowie
  alle Codable-Feldnamen der Sync-Snapshots (`SyncSnapshot.swift`) und der
  `SyncEntitaetsArt`-Bezeichner. Eine echte Modell-Umbenennung wäre die erste
  strukturelle SwiftData-Migration dieses Projekts überhaupt und müsste wegen
  der Relationship-Kopplung mindestens sechs Modelltypen einfrieren (siehe
  `docs/DECISIONS.md` → „Duplicate version checksums"-Vorfall) — bewusst als
  eigener, separat zu planender Schritt zurückgestellt, GitHub #62 bleibt dafür
  offen.

## v0.10 (Build 187) — Einkaufslisten-Fortschritt im Titel (GitHub #74), Wischgesten am Standort-Vorschlag (GitHub #73)

- **GitHub #74.** Der Bildschirmtitel beim Einkaufen (`EinkaufslisteView`) zeigt
  jetzt zusätzlich zum Listennamen den Fortschritt für den laufenden
  Einkaufsvorgang, Format „<Name> (<abgehakt>/<gesamt>)". Nutzt die bereits
  vorhandenen `offeneArtikel`/`abgehakteArtikel`-Zähler, keine neue
  Datengrundlage nötig.
- **GitHub #73.** `GeschaeftVorschlagBanner` lässt sich jetzt zusätzlich zu den
  bestehenden Buttons/dem „…“-Menü per Wischgeste bedienen: rechts = Haupt-
  Aktion (auswählen/anlegen), links = dauerhaft ignorieren, hoch = einmalig
  verwerfen. Reine zusätzliche Eingabe-Route auf dieselben, bereits
  existierenden Aktionen — kein neues Verhalten.

## v0.10 (Build 186) — Sync-Performance: Event-Dateien werden anhand der ID im Dateinamen vorgefiltert

- **Analyse-Fund, Abschnitt 9 „Bekannte Grenzen".** Event-Dateien werden nie
  gelöscht (`peers/{geraeteID}/events/` wächst unbegrenzt) — bislang las und
  dekodierte `SyncImportService.importiereNeueEvents` deshalb bei JEDEM
  Sync-Zyklus JEDE jemals exportierte Peer-Event-Datei erneut, auch längst
  entschiedene. Neu: `SyncEventService.alleAktuellenGewinnerUndBekannteIDs`
  liefert einmal pro Zyklus zusätzlich die Menge bereits bekannter
  Event-IDs; Dateien, deren im Dateinamen kodierte ID (`{lamport}_{uuid}.json`)
  bereits bekannt ist, werden vor dem Lesen übersprungen. Ein Event, dessen
  Referenz noch nicht auflösbar ist, wird laut bestehender Retry-Semantik NIE
  als bekannt markiert — bleibt also außerhalb der Menge und wird weiterhin
  jeden Zyklus neu versucht, unverändert korrekt. Keine Migration, keine
  Verhaltensänderung an der Konfliktauflösung selbst.

## v0.10 (Build 185) — Sync-Performance: Kaufhistorie-Export und Event-Konfliktcheck gebatcht

- `SyncKaeufeExportService.exportiereNeueKaeufe` prüfte bisher pro lokalem
  `KaufEintrag` einzeln per `FileManager.fileExists`, ob dessen `kaeufe/`-Datei
  schon existiert (N Datei-Stat-Aufrufe pro Zyklus gegen einen ggf.
  Cloud-gestützten Ordner). Jetzt EIN `contentsOfDirectory`-Aufruf, Abgleich
  gegen ein In-Memory-`Set`. Bewusst kein persistiertes Export-Flag auf
  `KaufEintrag` erwogen — das hätte dieselbe Bug-Klasse zurückgebracht, die für
  die übrigen Paket-Teile bereits gefunden/gefixt wurde (Flag sagt „schon
  geschrieben", Datei existiert nach Ordnerwechsel/Reaktivierung aber
  tatsächlich nicht mehr).
- `SyncEventService.aktuellerGewinner` (Bereich-A-Konfliktauflösung) fetchte
  bislang bei JEDEM eingehenden Event erneut die komplette `SyncEvent`-Tabelle
  und dekodierte jede Nutzlast neu — O(n²) bei n eingehenden Events in einem
  Zyklus. Neu: `SyncEventService.alleAktuellenGewinner` baut den
  Gewinner-Index einmal pro Zyklus, `SyncImportService` hält ihn während der
  Verarbeitung selbst aktuell. Die einmalige Einzelabfrage (Überkauf-Hinweis in
  `Einkaufsvorgang`) bleibt unverändert bei der bisherigen Funktion. Keine
  SwiftData-Migration nötig (reiner In-Memory-Index statt Schema-Änderung).

## v0.10 (Build 184) — Sync-Performance: redundante Fetches/lineare Scans in den Merge-Pfaden entfernt

- **Analyse-Fund.** `erstelleSnapshot` fetchte `Einkaufsliste`/`Einkaufsvorgang`
  je zweimal für die "gültige IDs"-Sets, obwohl die Objekte kurz zuvor bereits
  geladen waren — jetzt aus dem vorhandenen Array abgeleitet statt neu gefetcht.
- `mergeEinkaufslistenEintraege`/`istBereitsAbgehakt` fetchten bislang bei
  JEDEM Remote-Eintrag erneut alle lokalen `Einkaufsvorgang`e — jetzt einmal
  vor der Schleife geladen.
- `erstellePaketTeile` (Peer-Zyklus-Pfad) baute bei jedem Sync-Zyklus die
  komplette `KaufEintrag`-Historie (laut Analyse oft der größte Anteil), obwohl
  das Ergebnis nie verwendet wurde (die Historie läuft seit GitHub #82 separat
  über `SyncKaeufeExportService`) — `erstelleSnapshot(context:mitKaufEintraegen:)`
  überspringt diesen Fetch jetzt für diesen Pfad.
- Bereich-B-Merges (`mergeArtikelKategorien`/`mergeGeschaefte`/`mergeArtikel`/
  `mergeEinkaufslisten`/`mergeEinkaufsvorgaenge`) suchten den ID-Treffer bisher
  linear (`first(where:)`) über alle lokalen Objekte — jetzt per vorab
  gebautem Dictionary in O(1). `SyncEntitaetsAliasService.aufgeloesteID`
  fetchte zudem pro Remote-Eintrag einzeln; die fünf Merge-Funktionen nutzen
  jetzt eine einmal pro Peer geladene Alias-Map (`alleAliaseNachArt`), analog
  dem bestehenden `SyncTombstoneService.geloeschteIDs`-Muster. Reine
  Performance-Änderung ohne Verhaltensänderung; für die heutige Datenmenge
  nicht spürbar, aber ein Fund bei wachsendem Bestand.

## v0.10 (Build 183) — Fix: Paket-Teile fehlten dauerhaft nach Reaktivieren der Synchronisierung

- **Live-Test-Fund.** Der in `UserDefaults` gespeicherte Fingerabdruck je
  Paket-Teil übersteht bewusst einen App-Neustart, sagte aber nichts darüber
  aus, ob die zugehörige Datei am Zielort noch existiert. Nach
  Deaktivieren/Reaktivieren der Synchronisierung fehlten `stamm.json`/
  `lernen.json`/`vorgaenge.json`/`preise.json`/`tombstones.json` im neu
  verbundenen Peer-Ordner dauerhaft — nur `manifest.json` (immer geschrieben)
  und `kaeufe/` (Existenz-Check pro Datei) legten sich an. Fix:
  `schreibeTeilFallsGeaendert` prüft jetzt zusätzlich, ob die Datei
  tatsächlich noch existiert — nur bei Fingerabdruck-Übereinstimmung UND
  vorhandener Datei wird übersprungen. Details: `docs/EXPORT_PAKET_UMBAU.md`.

## v0.10 (Build 181) — Fix: kompletter Sync-Stillstand durch verschachtelte Security-Scope-Zugriffe

- **Live-Test-Fund, direkt nach der export.json-Paket-Umstellung.** Das neue
  `kaeufe/`-Aufräumen rief bei jedem per Tombstone empfangenen gelöschten
  `KaufEintrag` ein eigenes `startAccessingSecurityScopedResource()`/
  `stop…()` auf `SyncSnapshotImportService.loescheFallsVorhanden` auf —
  verschachtelt im bereits offen gehaltenen Security-Scope von
  `importiereSnapshots`. Bei einem realen Peer-Bestand (~190 Tombstones) ~190
  verschachtelte Zyklen in einem einzigen Sync-Durchlauf — destabilisierte den
  Zugriff auf echten Geräten binnen Minuten dauerhaft: kompletter,
  bleibender Sync-Stillstand in beide Richtungen, auch für unabhängige
  Bereich-A-Aktionen (abhaken/hinzufügen). Fix: Aufräumen nur noch gebündelt
  aus `KaufEintragBereinigungService` (ein Zugriff für die ganze Liste), nicht
  mehr aus der Tombstone-Schleife. Details: `docs/EXPORT_PAKET_UMBAU.md`.

## v0.10 (Build 180) — Sync-Paket statt export.json-Monolith (GitHub #82)

- **GitHub #82.** `export.json` (ein Monolith, bei jedem Sync-Zyklus komplett
  neu aufgebaut und kodiert — `kaufEintraege` allein 56% der Dateigröße in
  einem realen Export) ersetzt durch mehrere unabhängig fingerabdruck-geprüfte
  Dateien (`manifest.json`, `tombstones.json`, `stamm.json`, `lernen.json`,
  `vorgaenge.json`, `preise.json`) plus ein Append-Log für die Kaufhistorie
  (`kaeufe/`, ein `<uuid>.json` pro `KaufEintrag`, analog dem bestehenden
  Bereich-A-Eventlog `events/`) — neuer `SyncKaeufeExportService`. Harter
  Formatschnitt, kein Dual-Read.
- Zusätzlich: `SyncSnapshotImportService.mergeKaufEintraege`/`mergePreispunkte`
  nutzen jetzt einen indexierten Existenz-Check statt vollem Fetch + linearem
  Scan (O(n) statt O(n·m) pro Merge-Zyklus).
- Der bisherige `SyncSnapshot`-Monolith-Typ bleibt für den lokalen
  Backup-/Wiederherstellungs-Pfad (`SyncErsetzenService`, GitHub #63)
  unverändert bestehen.
  Details: `docs/EXPORT_PAKET_UMBAU.md`.

## v0.10 (Build 178) — Nicht-deterministischer Sync-Fingerabdruck (GitHub #78) + manuelle KaufEintrag-Bereinigung

- **GitHub #78.** `SyncSnapshotExportService` nutzte drei eigene
  `JSONEncoder()`-Instanzen ohne `.sortedKeys` — Foundation garantiert die
  Top-Level-Schlüsselreihenfolge nur mit dieser Option, ohne sie ergaben
  zwei inhaltlich identische Snapshots unterschiedliche SHA256-Fingerabdrücke.
  Der „nur bei echter Änderung schreiben"-Vergleich (GitHub #70/#71) hielt
  das fälschlich für „geändert" und schrieb `export.json` dadurch bei
  praktisch jedem Sync-Zyklus neu, unabhängig vom tatsächlichen Bestand.
  Jetzt ein einziger geteilter, `.sortedKeys`-konfigurierter Encoder für
  Datei-Schreiben, Fingerabdruck und Diagnose-Text.
- Neuer Debug-Button „KaufEintraege jetzt bereinigen" (Einstellungen →
  Debugging → Statuskonsolidierung erzwingen): löst
  `KaufEintragBereinigungService.bereinigen(context:)` direkt aus, ohne auf
  die 24h-Sperre der automatischen Terminierung zu warten — u.a. um den
  Fix aus der vorigen Version sofort zu verifizieren.
  Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 28.

## v0.10 (Build 177) — Verwaiste KaufEintraege verhindert und aufgeräumt

- **Analyse-Fund** (export.json wuchs trotz aktiver Bereinigung): über die
  Hälfte aller `KaufEintrag`e in einem Live-Export trugen `einkaufsvorgang ==
  nil` — entstanden durch `SyncSnapshotImportService.mergeKaufEintraege`, das
  einen Remote-Eintrag trotz nicht auflösbarem `Einkaufsvorgang` (z.B. lokal
  bereits per Tombstone gelöscht) mit `einkaufsvorgang = nil` statt gar nicht
  anlegte. `KaufEintragBereinigungService.bereinigen` erfasste solche Einträge
  wegen ihres fehlenden `einkaufsvorgang?.endZeit` nie — ein struktureller
  Ratschen-Effekt, der die Datei bei jedem Sync-Zyklus weiter wachsen ließ.
  Fix in zwei Teilen: `mergeKaufEintraege` überspringt einen unauflösbar
  referenzierten Eintrag jetzt wie seinen Vorgang; `bereinigen` löscht
  bereits bestehende verwaiste Einträge sofort (keine Karenzzeit — sie hatten
  nie eine fachliche Funktion). Details: `docs/DATENSYNCHRONISATION_VERLAUF.md`
  Abschnitt 27.

## v0.10 (Build 176) — Lesbare Peer-Ordnernamen (GitHub #81)

- Peer-Ordner unter `peers/` im geteilten Sync-Ordner tragen jetzt den vom
  Anwender vergebenen Gerätenamen statt nur einer rohen UUID (`PeerOrdnerName`),
  damit sie sich in Finder/Dateien-App direkt einem Gerät zuordnen lassen. Ein
  kurzes ID-Suffix ist immer Teil des Namens — macht jede Kollisionsprüfung
  unnötig. Ändert sich der Gerätename später, wird der bestehende Ordner
  umbenannt statt neu angelegt (keine verwaisten Event-Dateien).
- Im selben Zug einen latenten Bug behoben: die interne Peer-Identität für den
  additiven Cross-Device-Zähler und die „bereits abgehakt von …"-Anzeige wurde
  bisher aus dem Ordnernamen statt aus dem dafür vorgesehenen Feld
  `SyncSnapshot.geraeteID` abgeleitet — hätte mit der Ordnernamens-Änderung
  sonst zu doppelt gezählten Peer-Ständen geführt. Details:
  `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 26.

## v0.10 (Build 175) — Preishistorie-Verdichtung (täglich → wöchentlich → monatlich)

- **GitHub #76-Folgearbeit.** Neuer `PreispunktVerdichtungService`: reduziert alte
  `Preispunkt`e stufenweise statt sie zu löschen — pro Tag höchstens ein Punkt
  (überzählige: nur der zuletzt beobachtete bleibt), nach 7 Tagen pro Kalenderwoche
  auf den höchsten Preis reduziert, nach 365 Tagen zusätzlich pro Kalendermonat.
  Alle drei Schwellwerte im Debug-Menü einstellbar, läuft automatisch für alle
  Nutzer (kein Ein-/Ausschalter). Details: `docs/PREISHISTORIE_VERDICHTUNG.md`.
- Neue interaktive Tages-Kollisionsabfrage beim Scannen (`BelegScanView`/
  `PreisschildScanView`, `TagesKollisionZeile`): existiert für Artikel+Geschäft
  bereits heute ein abweichender Preis, zeigt die Prüf-Ansicht einen Hinweis mit
  Umschalt-Button — Vorbelegung „wird ersetzt", der Anwender kann stattdessen den
  bestehenden Preis behalten (z.B. bei einem offensichtlichen Scan-Fehler).

## v0.10 (Build 173) — Automatische Bereinigung verarbeiteter KaufEintraege (Phase 2)

- **GitHub #76, Phase 2.** `PreisHistorieBereinigungService` zielt jetzt
  ausschließlich auf `Preispunkt` (echte Preishistorie, nutzerkonfigurierbare
  Frist, Standard „Nie"). Ein neuer `KaufEintragBereinigungService` übernimmt die
  Bereinigung von `KaufEintrag` (operative Buchungszeile ohne Preisrolle) und
  dadurch leer gewordenen `Einkaufsvorgang`en — immer aktiv, ohne
  Nutzer-Einstellung, feste Karenzzeit (48h), da ein `KaufEintrag` nach Abschluss
  seines Einkaufsvorgangs fachlich keine Funktion mehr hat.
- **Zwei Bugs beim Umsetzen gefunden und dabei direkt gefixt (GitHub #77):** ein
  `#Predicate` mit Force-Unwrap (`$0.endZeit! < stichtag`) lieferte nachweislich
  keine Treffer, obwohl derselbe Vergleich in reinem Swift korrekt war — Fix:
  ungefilterter Fetch + Swift-seitiger `.filter`. Zusätzlich wird „wird dieser
  Vorgang leer" jetzt vor statt nach der Löschung berechnet, da SwiftData die
  inverse `@Relationship`-Sammlung nachweislich erst bei/nach `context.save()`
  aktualisiert.
- Zwei weitere, unabhängig davon vorbestehende Testfehler als eigene Issues
  dokumentiert (nicht in diesem Schritt behoben): #78 (nicht-deterministischer
  Sync-Fingerabdruck, `JSONEncoder` ohne `.sortedKeys`), #79 (veralteter Test
  nach dem „Abschnitt 25"-Guard).

## v0.10 (Build 172) — Preishistorie von KaufEintrag entkoppelt: neue Modelle Preispunkt/ArtikelAlias

- **GitHub #76, Phase 1.** `KaufEintrag` bündelte bisher zwei unabhängige Rollen:
  operative Buchungszeile eines laufenden Einkaufsvorgangs UND Preishistorie-
  Datenpunkt. Preishistorie ist jetzt ein eigenständiges Model (`Preispunkt`) —
  entsteht unabhängig von einem Einkaufsvorgang (z.B. beim Preisschild-Scan) und nur
  bei tatsächlicher Preisänderung ggü. dem zuletzt bekannten Preis für dasselbe
  (Artikel, Geschäft)-Paar (Slowly-Changing-Dimension-Muster, `PreispunktService`).
- Alias-Lernen (vormals `KaufEintrag.gelernteZuordnung`, lineare Suche über die
  komplette Kaufhistorie bei jedem Scan) ist jetzt ein eigenes, kleines
  `ArtikelAlias`-Modell — ein Eintrag pro erkanntem Rohnamen, O(1) statt O(Historie).
- `KaufEintrag.preis`/`produktName`/`alternativerName` bleiben als migrierte Altlast
  bestehen (analog `Geschaeft.typenRaw`) — `KaufEintrag.preisverlaufMigrierenFallsNoetig(context:)`
  überführt bestehende Werte beim nächsten App-Start einmalig nach
  `Preispunkt`/`ArtikelAlias` und setzt sie danach auf `nil`.
- `SyncSnapshot.formatVersion` 3 → 4: `KaufEintragSnapshot` verliert die Preisfelder,
  `preispunkte`/`artikelAliase` neu hinzugekommen. Keine Rückwärtskompatibilität
  nötig (Projekt ohne feste Nutzerbasis, wie bei früheren Versionssprüngen).
- Neue `@Relationship(inverse:)`-Deklarationen für `Preispunkt` auf `Geschaeft`
  (`.cascade`) und `Artikel` (`.nullify`) — analog den bestehenden für `KaufEintrag`,
  verhindert dieselbe Klasse baumelnder Referenzen wie beim historischen
  „fehlende inverse-Deklarationen"-Vorfall (`docs/DATABASE_CONCURRENCY.md`).
- Hintergrund/Größenabschätzung: `docs/ROADMAP.md` → „`export.json` als Paket statt
  Monolith", Issue #76.

## v0.9 (Build 170) — Fix: zwei unabhängig baumelnde Einkaufsvorgang-Referenzen konnten fälschlich zusammengeführt werden

- Systematischer Audit aller Merge-Pfade (Auslöser: ein Einkaufsvorgang
  verlor unerwartet seine `endZeit`, obwohl der Code sie nirgends nullt)
  fand einen echten Bug: der Abgleich für „ist das derselbe reale Einkauf"
  verglich zwei Listen-Referenzen auf Gleichheit, ohne zu prüfen, ob eine
  davon überhaupt einen echten Wert hat — `nil == nil` ist in Swift `true`,
  wodurch ein bereits kaputter (listenloser) lokaler Vorgang fälschlich als
  „Treffer" für einen völlig unabhängigen, ebenfalls listenlosen Fremd-
  Eintrag durchgehen konnte. Der bestehende Guard aus dem vorigen Fix
  (unauflösbare Liste → nicht verarbeiten) greift jetzt vor jedem
  Matching-Versuch, nicht nur beim Neuanlegen.
- Alle übrigen Merge-Funktionen wurden gegen dieselben vier Kriterien
  geprüft (fehlende Existenz-Validierung, destruktives Überschreiben,
  unbedingte Zuweisungen, `nil`-gegen-`nil`-Fehlmatches) — keine weiteren
  Funde.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 25.

## v0.9 (Build 169) — Reparaturweg für baumelnde Referenzen ohne SQLite-Direktzugriff

- Baumelnde Referenzen (Absturzrisiko) konnten bisher nur gemeldet, nie
  automatisch repariert werden — eine echte Reparatur wurde als „bräuchte
  direkten SQLite-Zugriff, nicht trivial" eingeschätzt. Tatsächlich reicht
  das bereits vorhandene Zusammenspiel aus Export (filtert baumelnde
  Referenzen beim Schreiben ohnehin zu `nil`) und dem bestehenden
  Wipe-und-Neuaufbau-Mechanismus: ein frischer Snapshot des eigenen,
  aktuellen Bestands ist von Natur aus bereits „repariert".
- Neuer Debugging-Einstiegspunkt „Baumelnde Referenzen bereinigen (ohne
  Sync-Gerät)…" — funktioniert unabhängig von einem konfigurierten
  Sync-Ordner, nur sichtbar, wenn tatsächlich etwas gemeldet wurde.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 24.

## v0.9 (Build 168) — Automatische Bereinigung leerer Geister-Einkaufsvorgänge

- Von den zuvor gefundenen listenlosen „Geister"-Einkaufsvorgängen (fehlende
  Einkaufsliste, für die App unerreichbar) sind die ohne angehängte Käufe
  beweisbar verlustfrei löschbar — anders als die seit Langem bekannten
  „baumelnden Referenzen", die absichtlich nicht automatisch repariert
  werden (Absturzrisiko). Läuft jetzt automatisch bei jedem App-Start, bevor
  die übrige Datenintegritäts-Prüfung ihren Bericht erstellt. Vorgänge mit
  echten angehängten Käufen werden weiterhin nicht automatisch gelöscht und
  bleiben Teil des Berichts.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 23.

## v0.9 (Build 167) — Doku-Konsolidierung: Datensynchronisation

- Fünf teils überlappende, teils überholte Dokumente zur Datensynchronisation
  (`DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, `DATENSYNCHRONISATION_BEWERTUNG.md`,
  `DATENBANK_BACKUP_RESTORE_BEWERTUNG.md`, plus verstreute Abschnitte in
  `DATABASE_CONCURRENCY.md`/`ARCHITECTURE.md`) zu zwei klar getrennten
  Dokumenten konsolidiert: `docs/DATENSYNCHRONISATION.md` (neu, aktuelle
  Architektur-Referenz — wie funktioniert es heute) und
  `docs/DATENSYNCHRONISATION_VERLAUF.md` (umbenannt vom vormaligen
  Umsetzungsplan, chronologisches Verlaufsprotokoll — warum ist es so, jeder
  Live-Test-Fund/Bugfix). Zwei rein historische Bewertungsdokumente gelöscht,
  ihr noch relevanter Inhalt (Entitäts-Matching/Merge-Reihenfolge) in die neue
  Referenz übernommen. `docs/DATABASE_CONCURRENCY.md` bleibt fokussiert auf
  lokale Schreibkoordination, drei thematisch fehlplatzierte Sync-Abschnitte
  in den Verlauf verschoben. Keine Code-Änderung.

## v0.9 (Build 166) — Neuaufbau-Zusammenfassung + Erkennung listenloser Einkaufsvorgänge

- „Gerät zurücksetzen und von Sync-Gerät neu aufbauen" gab bisher keine
  Rückmeldung darüber, was tatsächlich zurückkam — ein Neuaufbau, der weniger
  Daten zurückbekam als vorher vorhanden war (z.B. weniger Einkaufslisten,
  weil kein erreichbarer Peer den vollständigen Stand hatte), blieb dadurch
  unbemerkt. Zeigt in den Debugging-Einstellungen jetzt eine Vorher-/Nachher-
  Zusammenfassung je Bereich direkt nach dem Neuaufbau, Rückgänge rot
  hervorgehoben — das bestehende „Backup wiederherstellen" bleibt daneben als
  Rückgängig-Option sichtbar.
- Die bestehende Datenintegritäts-Prüfung erkennt baumelnde Referenzen
  (Absturzrisiko), nicht aber einen gültigen `nil`-Bezug ohne Einkaufsliste —
  genau die Fehlerkategorie aus dem vorigen Fix. Prüft jetzt zusätzlich
  darauf, meldet betroffene Vorgänge als eine aggregierte Zeile (inkl. Anzahl
  real angehängter Käufe) und markiert einen ungewöhnlich schnellen Zuwachs
  seit der letzten Prüfung zusätzlich als Warnung.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 21.

## v0.9 (Build 165) — Fix: unbegrenzt wachsende „Geister"-Einkaufsvorgänge ohne Liste/Geschäft

- Direkte Analyse zweier echter `export.json`-Dateien fand die eigentliche
  Hauptursache der andauernden Sync-Oszillation: 907 von 959 lokalen
  Einkaufsvorgängen auf einem Testgerät hatten weder ein Geschäft noch eine
  Einkaufsliste — für die App komplett unerreichbare „Geister"-Vorgänge, 107
  davon mit real angehängten Käufen (Bananen, Äpfel, Intermezzo, Knoppers,
  Hackfleisch, …), die dadurch nirgends in der Einkaufsansicht auftauchten.
  Erklärt sowohl den „hat nicht sauber synchronisiert"-Befund bei
  abgehakten Artikeln als auch das Oszillieren von `export.json` ganz ohne
  Geräte-Interaktion — der reine automatische Sync-Zyklus reichte, um immer
  weitere Geister-Vorgänge aus bereits baumelnden Referenzen zu erzeugen.
- Ursache: `SyncSnapshotImportService.mergeEinkaufsvorgaenge` legte auch dann
  einen neuen Vorgang an, wenn sowohl Geschäft- als auch Listen-Referenz eines
  empfangenen Eintrags unauflösbar waren. Legt jetzt keinen neuen Vorgang mehr
  an, wenn keine Liste auflösbar ist (ein fehlendes Geschäft bleibt weiterhin
  legitim — Einkauf ohne gewählten Laden ist Normalfall).
- Bewusst noch nicht Teil dieses Fixes: Bereinigung der bereits vorhandenen
  Geister-Vorgänge auf betroffenen Geräten (Cascade-Löschung würde die real
  angehängten Käufe mitlöschen) — auf Nutzerwunsch zunächst nur der
  Root-Cause-Fix, Datenrettung folgt separat.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 20.

## v0.9 (Build 164) — Debug: manuelle Statuskonsolidierung + unnötige Saves bei Bereich-B-Merge vermieden

- Live-Tests der Fingerabdruck-Normalisierung (Abschnitt 18) zeigten weiterhin
  Sync-Ping-Pong, dessen Konvergenz auf zwei automatische Fristen wartet (48h
  Event-Give-up, 30 Tage Peer-Alter) — zu lange, um es im Test abzuwarten.
  Debugging-Einstellungen haben jetzt eine Sektion „Statuskonsolidierung
  erzwingen" mit zwei Werkzeugen: „Events aufräumen" gibt aktuell nicht
  anwendbare empfangene Events sofort auf statt die 48h-Frist abzuwarten;
  „Export.json aufräumen" erzwingt einen frischen eigenen Voll-Export und
  löscht verwaiste `export.json`-Dateien von Peers jenseits der
  30-Tage-Altersgrenze. Beide rühren bewusst nicht an eigenen, noch nicht
  abgeholten ausgehenden Event-Dateien (siehe frühere, revertierte
  Event-Pruning-Regression).
- Beim Prüfen der Merge-Logik zusätzlich gefunden: `SyncSnapshotImportService`
  wies Typ-/Kategorie-Relationen bei jedem Merge-Durchlauf unbedingt neu zu,
  selbst wenn sich inhaltlich nichts änderte — eine SwiftData-`@Relationship`
  gilt bei jeder Zuweisung als verändert, unabhängig vom tatsächlichen Inhalt,
  was bei praktisch jedem Sync-Zyklus einen unnötigen `context.save()`
  erzwang. Zuweisung erfolgt jetzt nur noch, wenn sich das Ergebnis
  tatsächlich vom bisherigen Wert unterscheidet.
- Details, inkl. der noch offenen Frage nach einer beobachteten periodischen
  4-Werte-Oszillation im `geschaeftsTypen`-Bereich des Exports:
  `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 19.

## v0.9 (Build 163) — Fix: Backup-Anzeige/-Wiederherstellung fehlte (GitHub #63), Belegscan-Vorschlag nicht antippbar (GitHub #57)

- #63: Der vorherige Fix legte zwar ein lokales Backup an, zeigte es aber nirgends
  an. Sync-Einstellungen haben jetzt eine eigene „Lokales Backup"-Sektion mit
  Erstellungsdatum und Größe, sowie eine eigenständige „Backup wiederherstellen"-
  Aktion, unabhängig vom „Synchronisierung deaktivieren"-Fluss.
- #57: Der vorherige Fix (größeres Tap-Areal) reichte nicht — der Tap kam gar
  nicht erst an. Die Vorschlagsliste war direkt an den Fokus des TextFields
  gebunden; ein Tap auf einen Vorschlag entzieht dem TextField sofort den Fokus
  (Touch trifft eine andere View), wodurch die Liste verschwand, bevor der
  Button-Tap erkannt wurde. Sichtbarkeit läuft jetzt über einen eigenen State,
  der beim Fokusverlust erst verzögert zurückgesetzt wird. Zusätzlich
  Schriftgröße der Vorschläge von `.subheadline` auf `.body` erhöht.

## v0.9 (Build 162) — Fix: export.json wurde trotz unverändertem Inhalt weiter neu geschrieben

- Ein weiterer Live-Test zeigte: `export.json` wurde weiterhin praktisch bei
  jedem Sync-Zyklus neu geschrieben, obwohl sich fachlich nichts änderte.
  Ursache: der Inhalts-Fingerabdruck sortierte nur die äußeren Snapshot-Arrays
  (ein Eintrag je Geschäft/Artikel/…), nicht aber die ID-Arrays INNERHALB
  eines Eintrags (`typIDs`, `kategorieIDs`, `ausgeschlosseneKategorieIDs`,
  `alternativeNamen`, `ignorierteArtikelNamen`, `geschaeftsTypIDs`) — deren
  Reihenfolge ist bei einem erneuten Fetch aus SwiftData ebenso wenig
  garantiert wie die des äußeren Arrays.
- Fix: alle inneren ID-/Namens-Arrays werden jetzt vor dem Vergleich
  ebenfalls sortiert.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 18.

## v0.9 (Build 161) — Fix: Besuchszähler wuchs unbegrenzt durch Sync (G-Counter-Korrektur)

- Der neue Diagnose-Log zeigte: `export.json` wurde praktisch bei jedem
  Sync-Zyklus neu geschrieben, weil sich `Geschaeft.anzahlEinkaufsvorgaenge`
  ständig änderte — ohne dass tatsächlich neue Einkäufe stattfanden.
  Ursache: die additive Merge-Regel behandelte den von einem Peer gemeldeten
  Gesamtwert als reinen Zuwachs, obwohl dieser Gesamtwert selbst schon
  Beiträge des EMPFANGENDEN Geräts enthielt (aus einem früheren Sync) — jeder
  Beitrag wurde dadurch bei jedem Hin-und-Her zwischen zwei Geräten erneut
  mitgezählt, unbegrenzt aufschaukelnd.
- Fix: echtes G-Counter-Muster (CRDT). `Geschaeft` unterscheidet jetzt
  `eigeneAnzahlEinkaufsvorgaenge` (nur lokal, nie durch Sync verändert) von
  `anzahlEinkaufsvorgaenge` (berechnete Summe aus eigenem Anteil + zuletzt
  bekanntem eigenen Beitrag jedes Peers). Der Snapshot exportiert nur noch
  den eigenen Anteil, nie den bereits gemergten Gesamtwert.
  `SyncSnapshot.aktuelleFormatVersion` auf 3 erhöht.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 17.
- Bereits vor diesem Fix aufgelaufene, überhöhte Zähler lassen sich über
  „Zähler zurücksetzen" in den Geschäfts-Stammdaten manuell bereinigen.

## v0.9 (Build 160) — Sync-Debug-Modus: sichtbar machen, welcher Bereich export.json neu schreibt

- Neues Protokoll-Ereignis `sync_snapshot_geschrieben` (bisher gab es nur
  `sync_snapshot_unveraendert_uebersprungen` für den Fall, dass NICHT
  geschrieben wurde) — beide Ereignisse protokollieren jetzt Anzahl + einen
  kurzen Inhalts-Fingerabdruck je Teil-Bereich (`geschaeftsTypen`,
  `geschaefte`, `artikel`, `einkaufsvorgaenge`, `kaufEintraege`, …). Zwei
  aufeinanderfolgende Protokollzeilen im Sync-Debug-Modus lassen sich damit
  direkt vergleichen: ändert sich nur eine Anzahl, kam dort etwas hinzu/weg;
  ändert sich nur der Fingerabdruck bei gleicher Anzahl, hat sich ein Feld
  eines bestehenden Eintrags geändert (z.B. eine `endZeit`, ein additiver
  Zähler).
- Details: `docs/LOGGING.md` → „Mechanismus: Datensynchronisation".

## v0.9 (Build 159) — Fix: Mehrfach offene Einkaufsvorgänge derselben Liste durch stale Merge-Liste

- Wurzelursachen-Fund für einen Teil der „dangling Einkaufsvorgang"-Bugfamilie:
  `SyncSnapshotImportService.mergeEinkaufsvorgaenge` gefetchte lokale
  Vorgangsliste einmalig zu Beginn — enthielt ein einzelner Peer-Snapshot
  mehrere Einträge für denselben, noch unbekannten offenen Vorgang derselben
  Liste, wurde jeder weitere Eintrag fälschlich als zusätzlicher,
  eigenständig offener Vorgang angelegt statt wiederverwendet. Ein späterer
  Merge-Durchlauf konnte einem dieser Duplikate dadurch die `endZeit` eines
  völlig anderen, längst abgeschlossenen Vorgangs zuweisen (belegt: zwei
  Vorgänge mit `startZeit` NACH der übernommenen `endZeit`, chronologisch
  unmöglich). Sichtbar für den Anwender als: Artikel erscheint kurz als
  abgehakt/synchronisiert, verschwindet dann wieder von der Liste.
- Fix: neu angelegte Vorgänge werden jetzt sofort in die lokale Vergleichsliste
  nachgetragen; zusätzlich verwirft eine neue Plausibilitätsprüfung jede
  `endZeit`, die vor dem eigenen `startZeit` läge.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 16.

## v0.9 (Build 158) — Fix: Endlos-Retry für Bereich-A-Referenzen ohne Tombstone

- Ergänzt den bestehenden Tombstone-basierten Endlos-Retry-Fix um eine
  Alters-Schwelle (`SyncImportService.maximalesEventAlterFuerRetry`, 48h):
  ein echter Zwei-Geräte-Live-Test zeigte, dass ein referenzierter
  `Einkaufsvorgang` auch OHNE Tombstone dauerhaft unauflösbar werden kann
  (verschwindet spurlos aus jedem künftigen Snapshot, z.B. durch eine
  Nachfolger-Umleitung auf dem Ursprungsgerät). Ohne diese Schwelle wurde ein
  solches Event für immer bei jedem Sync-Zyklus erneut versucht und
  protokolliert (`sync_event_nicht_anwendbar`), ohne je zu konvergieren —
  beobachtet über mehr als sieben Minuten durchgehend. Wird jetzt nach der
  Frist aufgegeben (`sync_event_aufgegeben`) statt endlos weiterversucht.
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 15.

## v0.9 (Build 155) — Fix: Endlos-Retry-Log für Events auf gelöschte Referenzen

- `SyncImportService`: Ein empfangenes Event, dessen referenzierte
  `Einkaufsliste`/`Einkaufsvorgang`/`Artikel` per Tombstone als absichtlich
  gelöscht markiert ist, wird jetzt sofort als bekannt markiert statt bei
  jedem Sync-Zyklus erneut als `sync_event_nicht_anwendbar` protokolliert zu
  werden — vorher lief der Retry für so eine Referenz endlos, weil sie (im
  Unterschied zu einer nur noch nicht angekommenen Referenz) nie entstehen
  konnte.

## v0.9 — Fix: Event-Datei-Pruning löschte nicht abgeholten Sync-Rückstand

- Revert des in der vorherigen DB-Optimierungsrunde eingeführten
  Event-Datei-Pruning (`SyncExportService`): „hochgeladen" bedeutete nur, dass
  das eigene Gerät die Datei geschrieben hatte, nicht, dass ein Peer sie schon
  gelesen hat. Bei einem echten Zwei-Geräte-Test löschte der erste Aufräumlauf
  einen bereits bestehenden, noch nicht abgeholten Sync-Rückstand —
  `artikelAbgehakt`-Events kamen danach auf dem zweiten Gerät gar nicht mehr
  an. Ein sicheres Aufräumen bräuchte eine echte Peer-Lese-Bestätigung, die es
  aktuell nicht gibt; bis dahin bleibt „Offene Alt-Datei-Frage" (siehe
  `docs/DATENSYNCHRONISATION_VERLAUF.md`) bewusst wieder offen.
- Die übrigen Änderungen der DB-Optimierungsrunde (gedrosselte
  Peer-Metadaten, `hasChanges`-Gate, `export.json`-Fingerabdruck-Skip,
  Reentrancy-Guard, Auto-Close, Einkaufsvorgang-Retention) bleiben unverändert
  bestehen.

## v0.9 (Build 152) — DB-Optimierung: weniger unnötige Sync-Schreibvorgänge, Einkaufsvorgang-Aufräumung (GitHub #60/#70/#71)

- Sync-Zyklus schreibt nicht mehr unbedingt bei jedem Tick (5s/60s): lokale
  Peer-Metadaten (`SyncPeerInfo.zuletztGesehen`) werden gedrosselt statt bei
  jedem Import aktualisiert, `context.save()` läuft nur noch bei tatsächlichen
  Änderungen (`context.hasChanges`), und `export.json` wird nur noch bei
  inhaltlich geändertem Snapshot neu geschrieben (SHA256-Fingerabdruck-Vergleich).
  Zusammen die Hauptursache für das Flackern der Einkaufsliste alle 5s
  (GitHub #60) sowie unnötig häufige Schreibzugriffe (GitHub #70).
- `SyncExportService` löscht eigene, bereits hochgeladene Event-Dateien jetzt
  nach 7 Tagen automatisch — vorher unbegrenztes Wachstum im Sync-Ordner.
- Reentrancy-Guard in `EinkaufenView.einkaufSicherstellen()` gegen mehrere
  nebenläufig ausgelöste `.onChange`-Handler — Verdacht auf (Mit-)Ursache der
  in GitHub #71 beobachteten, im Millisekundenabstand angelegten
  `Einkaufsvorgang`-Duplikate.
- `EinkaufenView` schließt den aktuellen Einkaufsvorgang jetzt automatisch bei
  Inaktivität ab (3h mit Geschäft, 24h ohne) statt nur die Geschäftsauswahl
  zurückzusetzen — Voraussetzung dafür, dass die folgende Bereinigung ihn je
  erreichen kann.
- `PreisHistorieBereinigungService` räumt jetzt zusätzlich alte, abgeschlossene
  und leere `Einkaufsvorgang`e auf (dieselbe Aufbewahrungsfrist wie für
  `KaufEintrag` — vorher gar keine Aufräumlogik für `Einkaufsvorgang`).
  Beide Löschungen hinterlassen jetzt einen `SyncTombstone`, damit sie im
  Mehrgeräte-Fall nicht von einem Peer, der sie noch führt, wiederbelebt
  werden — dabei zwei vorbestehende Lücken im Tombstone-Mechanismus selbst
  geschlossen (`mergeEinkaufsvorgaenge`/`mergeKaufEintraege` prüften ihren
  „neu anlegen"-Zweig bislang nicht gegen Tombstones).
- Details: `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 14,
  `docs/PREISHISTORIE_BEREINIGUNG.md`.

## v0.9 (Build 151) — Suchfeld bleibt nach Artikel-Auswahl gefiltert (GitHub #64)

- `ArtikelHinzufuegenView`: Nach Tap auf einen Artikel (Hinzufügen, Entfernen oder
  Neuanlage) wird das Suchfeld sofort geleert, damit direkt weitergetippt werden
  kann, ohne vorher per (x) zu löschen. Die Trefferliste fällt dabei aber **nicht**
  mehr sofort auf die volle unfilterte Ansicht zurück, sondern bleibt auf dem
  bisherigen Suchtext eingefroren (neuer State `wirksamerSuchtext` +
  `filterEinfrieren`-Flag), bis der Nutzer das nächste Zeichen tippt.

## v0.9 (Build 150) — Fix: Sicherheitsnetz holte abgehakte Artikel nach „Einkauf abschließen" zurück

- Fix: `SyncSnapshotImportService.istBereitsAbgehakt` (Bereich-A-Sicherheitsnetz
  für `EinkaufslistenEintrag`) prüfte nur lokal noch **offene**
  `Einkaufsvorgang`e. Schloss „Einkauf abschließen" den Vorgang mit dem
  `KaufEintrag` des Artikels, fiel der Check heraus — ein noch veralteter
  Peer-Snapshot holte den bereits abgehakten Artikel dadurch wieder auf die
  offene Liste zurück; ein erneutes Abhaken erzeugte wegen der neuen
  `bezugsID` des Nachfolge-Vorgangs zusätzlich eine sichtbare Dublette.
  Geschlossene Vorgänge zählen jetzt ebenfalls, aber nur solange für dieselbe
  Liste aktuell ein offener Nachfolger existiert (derselbe
  `Einkaufsvorgang.offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)`-
  Helfer wie die Vorgangs-Umleitung aus Build 148/149) — dieselbe
  „dangling Einkaufsvorgang"-Ursachen-Familie wie GitHub #52, hier im
  bislang unadressierten Bereich-A-Pfad.

## v0.9 (Build 149) — Code-Review-Fixes: fälschliche Vorgangs-Umleitung, doppelter Kategorie-Index

- Fix: Die in v0.9 (Build 148) eingeführte Vorgangs-Umleitung
  (`SyncImportService.aufOffenenNachfolgerUmgeleitet`) wurde fälschlich auch
  auf `artikelAbgewaehlt`/`artikelDauerhaftEntfernt` angewendet — diese
  müssen einen bereits bestehenden `KaufEintrag` FINDEN (auf dem
  ursprünglichen, ggf. geschlossenen Vorgang), nicht auf dessen offenem
  Nachfolger. Die Umleitung führte dort zu einem stillen No-op, das Event
  galt aber trotzdem als erledigt — ein Abwählen/dauerhaftes Entfernen eines
  Peers ging so dauerhaft verloren.
- Fix: Dieselbe „dangling Einkaufsvorgang"-Lücke bestand auch im
  Bereich-C-Snapshot-Merge (`mergeEinkaufsvorgaenge`) — jetzt über einen
  gemeinsamen `Einkaufsvorgang.offenerNachfolger(...)`-Helfer behoben (statt
  zweier unabhängiger Kopien der Such-/Bevorzugungslogik).
- Fix: `naechsterKategorieBesuchsIndex` konnte für eine Kategorie, die
  bereits einen echten Besuchsindex hatte, fälschlich einen zweiten
  (Duplikat-)Index vergeben, wenn die ungeordnete `kaufEintraege`-Relationship
  zuerst auf einen remote materialisierten, indexlosen Eintrag traf — verfälschte
  die von `WarengruppenDistanzService` gelernte Distanzmatrix.
- Fix: `EinkaufenView.umschalten` prüfte beim Abwählen über die veraltete,
  vor dem Micro-Lease-`await` erfasste `einkaufsvorgang`-Property statt der
  frisch aufgelösten Referenz — Absturzrisiko bei einer nebenläufigen
  Sync-Löschung.
- Aufgeräumt: Zeilen-Closure in `EinkaufenView` hielt unnötig die komplette
  Kategorie-Gruppe (inkl. aller Artikel der Sektion) statt nur der Kategorie.

Gefunden durch `/code-review --fix` (8 Finder-Agents + Verifikation) über den
Diff seit v0.8. Vier weitere, tiefergehende Architektur-Befunde bewusst
zurückgestellt und als GitHub-Issues dokumentiert (Geschäfts-Zuordnung bei
Umleitung, Alias-Semantik, fehlendes Ursprungsgerät-Feld auf `KaufEintrag`,
store-loser Umleitungs-Fallback).

## v0.9 (Build 148) — Minor-Version-Bump: Sync-Robustheit & Mehrfachkategorien-Anzeige

Reine Versionsanhebung, kein neuer Funktionsumfang gegenüber dem letzten v0.8-Stand
— schließt den seit v0.8 gewachsenen Block an Sync-Robustheit-Fixes (dangling
Einkaufsvorgang nach „Einkauf abschließen", Distanzlern-Isolation gegen fremd
abgehakte Artikel) und die neue Mehrfachkategorien-Anzeige als abgeschlossenen
Minor-Release ab. Zusätzlich behobene Inkonsistenz: `VERSION`-Datei war seit
längerem bei „0.7" stehengeblieben, während `project.yml` bereits „0.8" führte —
jetzt wieder synchron.

## v0.8 (Build 147) — Artikel mit mehreren Kategorien: gleichzeitig in allen Abschnitten, geschäftsspezifisches Lernen

- Fix/Neu (GitHub-Nachfolgefund zu #36): ein Artikel mit mehreren Kategorien
  (z.B. Ohropax unter „Drogerie" und „Reisebedarf") wird beim Einkaufen jetzt
  gleichzeitig in ALLEN zugehörigen Abschnitten angezeigt statt nur in einer
  einzigen „führenden" — die vorherige Einzelauswahl hing von der nicht
  ordnungsgarantierten `Artikel/kategorien`-Relationship ab und ließ den
  Artikel bei Sync-Zyklen sichtbar zwischen Abschnitten springen. Abgehakt
  wird der Artikel dabei überall zugleich; aus welchem Abschnitt tatsächlich
  abgehakt wurde, geht als Kategorie in den `KaufEintrag` ein — Grundlage
  dafür, dass `WarengruppenDistanzService` jetzt pro Geschäft lernen kann, in
  welcher der mehreren Kategorien ein Artikel dort tatsächlich steht (z.B.
  Sojasauce bei Edeka unter „Soßen", bei Aldi unter „Asia").
- Fix: mehrere durch Sync verursachte Dateninkonsistenzen behoben — abgehakte
  Artikel, die kurz nach „Einkauf abschließen" auf einem Peer eintrafen,
  landeten auf dem bereits geschlossenen statt dem neuen offenen
  Einkaufsvorgang (unsichtbar in der Ansicht, tauchte danach fälschlich
  wieder auf der Liste auf); außerdem verfälschten remote abgehakte Artikel
  (Live-Event wie Snapshot-Merge) bislang die lokale
  ``WarengruppenDistanzService``-Lernbasis, da ihnen ein Besuchsindex aus der
  eigenen Reihenfolge zugewiesen wurde statt gar keinem.

## v0.8 (Build 142) — Inaktivitäts-Reset der Geschäftsauswahl

- Neu (GitHub #51): die aktive Geschäftsauswahl beim Einkaufen wird jetzt
  zusätzlich zum bisherigen Reset nach „Einkauf abschließen" auch nach 3
  Stunden ohne Interaktion mit der Einkaufsliste (Abhaken, Menge ändern,
  Entfernen) automatisch zurückgesetzt — egal ob die App dabei im Vorder-
  oder Hintergrund war (`EinkaufenView.inaktivitaetPruefen()`).

## v0.8 (Build 141) — Belegscan-S&W-Standard, Speicherort-Cleanup, Peer-Namen, Warengruppen bei Neuanlage

- Neu (GitHub #61): Belegscan konvertiert aufgenommene/importierte Bilder vor
  Texterkennung und Anzeige automatisch zu Schwarz/Weiß (Graustufen mit
  angehobenem Kontrast) — `VNDocumentCameraViewController` bietet dafür keine
  eigene Filter-Option, daher als Nachbearbeitung umgesetzt.
- Entfernt (GitHub #54): `DatabaseLocationService`/„Datenbank & Speicherort"
  — überflüssig seit die event-basierte Datensynchronisation die lokale DB
  immer am Standardpfad belässt. `DatabaseDebugLogger`s Log-Spiegelung in
  einen gemeinsamen DB-Ordner (nur für dieses Feature relevant) mitentfernt.
- Neu (GitHub #65): eigener Gerätename in den Sync-Einstellungen statt des
  generischen `UIDevice.current.name` — wirkt sich automatisch auf
  Lease-Meldungen, Sync-Snapshots und die Peer-Liste aus.
- Neu (GitHub #56): der Warengruppen-Abschnitt (`GeschaeftKategorienSektion`,
  aus `GeschaeftDetailView` extrahiert) steht jetzt auch beim Anlegen eines
  per Geolocation neu erkannten Geschäfts zur Verfügung, bevor es gespeichert
  wird.

## v0.8 (Build 139) — KRITISCH: Ersetzen-Absturz auf echtem Gerät behoben

Build 138s „Ersetzen"/„Gerät zurücksetzen" ersetzte den Store zur Laufzeit —
auf einem echten Gerät führte das zu einem SQLite-I/O-Fehler und Absturz
(`SyncPollingService.stoppen()` wartet nicht auf einen bereits laufenden
Sync-Zyklus, siehe `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: gescheiterter
Versuch...").

- Behoben: „Ersetzen"/„Gerät zurücksetzen"/„Wiederherstellen" merken die
  Aktion jetzt nur noch vor und bitten um einen App-Neustart — die
  eigentliche Store-Löschung passiert erst ganz am Anfang des neuen
  Prozesses, bevor irgendein `ModelContainer` existiert. Strukturell
  ausgeschlossen statt einzeln gejagt.
- `ModelContainerController`/der Laufzeit-Container-Austausch wieder entfernt.

## v0.8 (Build 138) — Neu: Ersetzen/Backup/Wiederherstellen für Sync-Beitritt (GitHub #63)

- Neu: `SyncErsetzenService` — beim erstmaligen Verknüpfen eines
  Sync-Ordners mit bereits vorhandenen Peer-Daten kann jetzt zwischen
  „Zusammenführen" (Standard, unverändert) und „Ersetzen" (lokale Daten durch
  Peer-Stand ersetzen, z.B. um private Kaufhistorie nicht in eine geteilte
  Gruppe einfließen zu lassen) gewählt werden. Vor dem Ersetzen wird
  automatisch ein lokales Backup angelegt, bei „Synchronisierung
  deaktivieren" kann es wiederhergestellt werden.
- Neu: Debugging-Bildschirm → „Gerät zurücksetzen und von Sync-Gerät neu
  aufbauen…" — nutzt denselben Mechanismus als Korruptions-Recovery: löscht
  die lokale Datenbank physisch (vorher gesichert) und baut sie ausschließlich
  aus einem erreichbaren Peer-Snapshot neu auf. Umgeht damit strukturell das
  Problem, dass eine bereits korrumpierte Zeile (siehe Build 136/137) über
  die normale SwiftData-API nicht reparierbar ist.
- `ModelContainer` ist jetzt zur Laufzeit austauschbar (`ModelContainerController`)
  statt fest in `ShopWithMeApp` verdrahtet — Voraussetzung für das
  physische Ersetzen ohne App-Neustart.

## v0.8 (Build 137) — Weitere Abstürze auf demselben baumelnden `Geschaeft` behoben

Build 136 stoppte den Absturz-Loop, reparierte aber nicht den zugrundeliegenden
Datensatz (nicht sicher möglich, siehe Build 136) — derselbe `Geschaeft/p9`
stürzte deshalb an anderen, bisher ungeschützten Lesepfaden weiter ab.

- Behoben: `GeschaeftHaeufigkeitService.favoriten`, `KaufEintrag.anzeigeName`,
  `PreisHistorieZeile`, `BelegScanView` (3 Stellen),
  `EinkaufenView.MengenNotizSheet` lasen `.geschaeft?.name`/`.artikel?.name`
  bzw. schrieben `.artikel?.einheit` ungeschützt. Neue
  `ModelContext.existiertNochImStore(_:)` sowie `KaufEintrag.artikelNameSicher`/
  `geschaeftNameSicher` zentralisieren die Absicherung (siehe
  `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: verbleibende ungeschützte
  Lesepfade").

## v0.8 (Build 136) — KRITISCH: Absturz-Loop durch den Reparaturlauf selbst behoben

Build 134s neuer `DatenintegritaetsService.repariereFallsNoetig` (siehe unten)
verursachte bei betroffenen Datenbeständen einen **deterministischen
Absturz-Loop bei jedem App-Start** (`Artikel/p19` in `KaufEintrag.artikel.setter`,
Crash-Log `ShopWithMe-2026-07-30-000333.ips`): der Versuch, eine erkannte
baumelnde Referenz per Setter zu nullen (`eintrag.artikel = nil`), stürzte
selbst ab — SwiftDatas Setter muss beim Nullen die alte Gegenseite auffalten,
um sich aus deren inversem Array zu entfernen, und genau diese alte Gegenseite
ist die bereits baumelnde. Da der Absturz vor `context.save()` auftrat, blieb
nichts vom Lauf erhalten — jeder Neustart wiederholte denselben Absturz.

- Behoben: `DatenintegritaetsService` (umbenannt: `repariereFallsNoetig` →
  `pruefe`) ist jetzt bewusst rein lesend, keine automatische Reparatur mehr.
  Details und Begründung in `docs/DATABASE_CONCURRENCY.md` → „Nachtrag:
  rückwirkende Reparatur bereits bestehender Korruption" (Korrektur-Abschnitt).
- Debugging-Bildschirm → Sektion „Datenintegrität" entsprechend angepasst
  (zeigt weiterhin gefundene baumelnde Referenzen, repariert aber nichts mehr
  automatisch).

## v0.8 (Build 135) — Absturz durch nebenläufige Löschung während eines Micro-Lease-Erwerbs

- Behoben: Absturz `Artikel/p19` in `KaufEintrag.artikel.setter` — anders als
  die vorherige Version keine fehlende `inverse`-Deklaration, sondern eine
  neben­läufige Löschung (z.B. per Peer-Tombstone) genau während ein anderer
  Bildschirm eine zuvor erfasste Artikel-/Geschäfts-Referenz nach einem
  Micro-Lease-Erwerb noch schreiben wollte (siehe
  `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: nebenläufige Löschung während
  eines Micro-Lease-Erwerbs").
- Neu: `ModelReference<T>` (`Models/ModelReference.swift`) — generischer
  Ersatz für das Halten lebendiger Objektreferenzen über eine `await`-Grenze
  hinweg, löst erst unmittelbar vor der Verwendung frisch auf. Angewendet in
  `KaufEintragZuordnenSheet`, `BelegScanView`, `PreisschildScanView`,
  `EinkaufenView`, `GeschaeftListView`, `ArtikelListView`,
  `ArtikelHinzufuegenView`, `MilkForUsImportService`,
  `PreisHistorieBereinigungService`.

## v0.8 (Build 134) — Rückwirkende Reparatur baumelnder Referenzen (Absturz `Geschaeft/p9` u.ä.)

- Neu: `DatenintegritaetsService.repariereFallsNoetig(context:)` läuft still bei
  jedem App-Start und behebt bereits bestehende "baumelnde" Referenzen (Relikt
  von vor den `inverse:`-Fixes in Build 30, siehe `docs/DATABASE_CONCURRENCY.md`
  → „Nachtrag: rückwirkende Reparatur bereits bestehender Korruption") — Auslöser
  war ein weiterhin auftretender Absturz (`Geschaeft/p9`, diesmal in
  `GeschaeftHaeufigkeitService.favoriten`/`.name.getter`), obwohl die
  `inverse:`-Deklarationen künftige Korruption bereits verhindern.
- Neu: Debugging-Bildschirm → Sektion „Datenintegrität" zeigt den zuletzt
  gefundenen/behobenen Bestand, erlaubt eine manuelle erneute Prüfung und den
  Export des vollständigen Protokolls (`DatenintegritaetsLogger`, immer aktiv,
  nicht an einen Debug-Schalter gekoppelt).

## v0.8 (Build 133) — Kritischer Fix: App-Hänger beim Start (schwarzer Bildschirm, kein Absturzprotokoll)

Der in der letzten Version eingeführte `SyncOrdnerBeobachter` (`NSFilePresenter`
für schnellere Sync-Erkennung) verursachte auf echten Geräten einen Hänger
direkt beim App-Start — vermutlich ein Deadlock zwischen dem
`presentedItemOperationQueue = .main` des Presenters und den bereits
bestehenden synchronen `NSFileCoordinator`-Schreibzugriffen (ebenfalls auf dem
Main-Thread). Vollständig zurückgenommen — reines Zeit-Polling (5s/60s) bleibt
der einzige Erkennungsmechanismus, wie vor dieser Version. Details in
`SyncPollingService`s Typ-Dokumentation.

## v0.8 (Build 132) — Fix: Sicherheitsnetz holte bereits abgehakte Artikel zurück (+ vermutlicher Absturzauslöser)

- Behoben: Ein bereits abgehakter Artikel erschien wieder in der "offenen"
  Ansicht der Einkaufsliste — bei aktivierter "alle Artikel zeigen"-Option
  sogar doppelt, begleitet von einer SwiftUI-`ForEach`-Warnung über doppelte
  IDs (ein bekannter Absturzauslöser, passend zum gemeldeten Crash).
  Ursache: Das in der letzten Version eingeführte Einkaufslisten-
  Sicherheitsnetz (`mergeEinkaufslistenEintraege`) fügte einen Artikel additiv
  wieder zur Liste hinzu, sobald ein Peer ihn noch listete — ohne zu prüfen,
  ob er zwischenzeitlich bereits abgehakt wurde (Abhaken entfernt den
  Listen-Eintrag als Seiteneffekt, ohne eigenes Sync-Event). Zusätzlich
  defensiv abgesichert: `EinkaufenView` schließt abgehakte Artikel jetzt
  explizit aus der offenen Liste aus und dedupliziert die abgehakte Liste
  nach Artikel-Identität. Details in
  `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 11b.

## v0.8 (Build 131) — Fix: Einkaufsvorgang-Dublette beim gemeinsamen Einkaufen

- Behoben: Abgehakte Artikel erschienen auf einem Gerät, aber nicht auf dem
  anderen, und Kaufeinträge verdoppelten sich mit der Zeit. Ursache: Jedes
  Gerät legte beim gemeinsamen Einkaufen unabhängig einen eigenen
  Einkaufsvorgang an, sobald es selbst keinen offenen kannte — dieselbe
  Bug-Klasse wie zuvor bei der Einkaufsliste, jetzt bei `Einkaufsvorgang`.
  `mergeEinkaufsvorgaenge` erkennt jetzt einen lokal noch offenen
  Einkaufsvorgang für dasselbe Geschäft/dieselbe Liste als denselben
  realweltlichen Einkauf (Alias-Mechanismus wie bei Einkaufsliste/Artikel).
  Bereits vor diesem Fix entstandene doppelte Kaufeinträge müssen einmalig
  manuell bereinigt werden (Geschäfts-Preisübersicht). Details in
  `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 11a.

## v0.8 (Build 130) — Architektur-Revision „Alternative A": Löschungen + vollständiger Einkaufslisten-Inhalt im Snapshot

Nach einem Live-Test mit zwei echten Geräten (GitHub #52) zeigten sich zwei
strukturelle Lücken, die kein Bugfix, sondern eine Architekturentscheidung
brauchten:

- **Gelöschte Geschäfte/Artikel/Kategorien/Einkaufslisten kamen zurück** —
  der additive Bereich-B-Merge kannte keine Löschsemantik. Neu: `SyncTombstone`
  merkt absichtliche Löschungen vor und verhindert, dass ein Peer sie aus
  seinem eigenen (veralteten) Snapshot heraus wiederbelebt.
- **Einkaufslisten-Mitgliedschaft hatte kein Sicherheitsnetz** — anders als
  Stammdaten (jederzeit aus dem vollständigen Snapshot wiederherstellbar) gab
  es für „welcher Artikel steht auf welcher Liste" keinen Vollzustands-Fallback,
  nur die Bereich-A-Events selbst. Neu: `SyncSnapshot.einkaufslistenEintraege`
  überträgt den vollständigen Listeninhalt additiv mit — ein Peer, der ein
  Event verpasst hat, holt sich den fehlenden Stand beim nächsten
  Snapshot-Import nach.
- Alias-Tracking (bislang nur `Artikel`/`Einkaufsliste`) auf `Geschaeft`/
  `ArtikelKategorie` erweitert (nötig, damit Tombstones für per Namens-/
  Koordinatenmatching zusammengeführte Objekte korrekt auflösen).
- `SyncPeerInfo` merkt sich jetzt den Zeitpunkt des letzten Snapshots;
  Snapshots älter als 30 Tage werden komplett ignoriert (verwaiste
  Test-Installationen spielen so nicht mehr für immer alte Daten zurück).
  Peers lassen sich zusätzlich manuell entfernen (Einstellungen → Debugging).
- Format-Version des Snapshots auf 2 erhöht — keine Rückwärtskompatibilität
  zu alten `export.json`-Dateien (Projekt ohne feste Nutzerbasis).

Details und Restrisiken (unerreichbare Vorgeschichte aus der Zeit vor
Bereich-A-Events) in `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt
11/12.

## v0.8 (Build 128) — Sync-Ordner-Beobachtung (schnellere Erkennung) + Einkaufslisten-Diagnose

- Neuer `SyncOrdnerBeobachter` (`NSFilePresenter`) beobachtet den Sync-Ordner
  auf Dateisystem-Änderungen und löst bei Erkennung sofort einen zusätzlichen
  Sync-Zyklus aus, statt starr auf das nächste 5s/60s-Intervall zu warten —
  providerunabhängig (funktioniert auch für Synology Drive, anders als das
  iCloud-spezifische `NSMetadataQuery`), ergänzt das bestehende Zeit-Polling
  nur als schnelleren Zusatz-Auslöser.
- Neues Diagnose-Event `sync_einkaufslisten_stand` (Sync-Debug-Modus):
  protokolliert nach jedem Snapshot-Merge den kompletten lokalen
  Einkaufslisten-Bestand samt Eintragszahl — macht Dubletten mit gleichem
  Namen, aber unterschiedlicher Eintragszahl direkt im Protokoll sichtbar.

## v0.8 (Build 127) — Fix: neu beigetretenes Gerät bekam eine unsichtbare Einkaufslisten-Dublette (GitHub #52-Nachfolgefund)

- Behoben: `Einkaufsliste` wurde beim Bereich-B-Merge bislang per ID
  gematcht (bewusste, aber fehlerhafte Entscheidung, siehe
  `docs/DATENSYNCHRONISATION_VERLAUF.md`). Da jedes Gerät beim
  allerersten Start automatisch eine eigene Standardliste namens
  „Einkaufsliste" anlegt, bevor je synchronisiert wurde, entstand bei jedem
  Beitritt zu einem bestehenden Sync-Ordner eine zweite, für den Nutzer
  unsichtbare Dublette — die tatsächlich synchronisierten Artikel landeten
  darauf, während die UI weiterhin die eigene (fast leere) Liste zeigte.
  `Einkaufsliste` wird jetzt wie `Artikel` namensbasiert gematcht
  (`SyncEntitaetsAlias` sorgt dafür, dass spätere Bereich-A-Events des Peers
  weiterhin auflösen). Betroffene, bereits bestehende Dubletten müssen einmalig
  manuell zusammengeführt werden (siehe Einstellungen → Einkaufslisten).

## v0.8 (Build 126) — Nachbesserung #53: Debug-Einstellungen in einer Ansicht statt nur einem Abschnitt

Die vorherige Umsetzung von #53 bündelte die drei Diagnose-Einträge nur
optisch unter einer gemeinsamen Section-Überschrift, führte aber weiterhin zu
drei getrennten Bildschirmen. Jetzt eine einzige neue `DebuggingView` mit allen
drei Bereichen (Sync-Debug-Modus, DB-Debug-Modus, in Debug-Builds zusätzlich
der Standort-Suchradius) als Sections in einem Formular — `SyncDebugSettingsView`,
`DatabaseDebugSettingsView` und `DebugEinstellungenView` entfernt, ihr Inhalt
vollständig übernommen (inkl. gemeinsam genutzter Share-Sheet-Brücke statt
zweier identischer Kopien).

## v0.8 (Build 125) — Drei kleine Fixes (GitHub #51, #53, #57)

- **#51:** Die Geschäftsauswahl beim Einkaufen wird nach Abschluss eines
  Einkaufs jetzt zurückgesetzt, statt am zuletzt genutzten Geschäft
  weiterzulaufen.
- **#53:** Die bisher über mehrere Zeilen verstreuten Diagnose-Einstellungen
  (Sync-Debug-Modus, DB-Debug-Modus, Debug-Einstellungen) sind jetzt in einem
  eigenen „Debugging"-Abschnitt gebündelt.
- **#57:** Tippen auf einen Artikel-Namensvorschlag beim Belegscan
  funktionierte nicht zuverlässig — den Vorschlags-Buttons in `PositionsZeile`
  fehlte `.contentShape(Rectangle())`/volle Zeilenbreite, das tappable Areal
  war nur der eng anliegende Text. Dasselbe Bug-Muster wurde bereits einmal
  zuvor in diesem Projekt behoben (Typ-/Kategorie-Toggle-Zeilen).

## v0.8 (Build 124) — Teilfix: langsamer App-Start durch Sync-Zyklus (GitHub #55)

- `SyncPollingService`s Polling-Loop läuft jetzt mit `.utility`-Priorität statt
  ererbter Standardpriorität, damit er bei der App-Start/Vordergrund-Rückkehr
  konkurrierende SwiftUI-Rendering-Arbeit nicht blockiert. Teillösung — die
  synchrone Merge-/Speicherlogik auf dem `MainActor` bleibt bei großem lokalem
  Bestand weiterhin spürbar. Details in `docs/DATABASE_CONCURRENCY.md`.

## v0.8 (Build 123) — Fix: neu beigetretenes Gerät synchronisiert keine Bestandsdaten (GitHub #52)

- Behoben: Die Sync-Lesepfade (`SyncImportService`, `SyncSnapshotImportService`)
  lasen Peer-Dateien ungeschützt per `Data(contentsOf:)`. Für ein Gerät, das
  einem bereits genutzten Sync-Ordner neu beitritt, lagen diese Dateien (iCloud
  Drive/Synology Drive) nur als noch nie heruntergeladener Cloud-Platzhalter
  vor — der Lesezugriff schlug sofort fehl, ohne die Datei anzufordern, sodass
  der erste Sync-Zyklus komplett leer blieb. Neuer, koordinierter Lesezugriff
  (`SyncDateiZugriff.leseKoordiniert`, analog zum bereits bestehenden
  koordinierten Schreibzugriff) löst bei Bedarf zuverlässig den Download aus,
  in einem Hintergrund-Task, damit dabei nicht der Haupt-Thread blockiert wird.
  Details in `docs/DATABASE_CONCURRENCY.md`.

## v0.7 (Build 121) — Fix: wiederkehrender Absturz beim App-Start durch baumelnde Fremdreferenzen

- Behoben: Der erste Fix (siehe unten, "Absturz bei veralteter Geschäft-Referenz
  nach Standorterkennung") beseitigte nicht die eigentliche Ursache eines
  wiederkehrenden Absturzes direkt beim App-Start (immer derselbe
  `PersistentIdentifier`, `Geschaeft/p9`) — die tatsächliche Ursache waren acht
  Relationship-Eigenschaften im Datenmodell ohne `@Relationship(inverse:)`, die
  SwiftData beim Löschen des referenzierten Objekts nicht zuverlässig
  nullifizieren/kaskadieren ließ. Dadurch blieben "baumelnde" Referenzen auf
  bereits gelöschte Datensätze im Store liegen; `SyncSnapshotExportService`,
  das bei jedem App-Start sofort läuft, griff ungeschützt auf `.id` dieser
  Referenzen zu und crashte. Fix: alle acht fehlenden `inverse:`-Deklarationen
  ergänzt (verhindert künftige Korruption) sowie `SyncSnapshotExportService.erstelleSnapshot`
  gegen bereits bestehende baumelnde Referenzen abgesichert (degradiert zu
  `nil`/übersprungen statt Absturz, protokolliert über den neuen
  `SyncDebugLogger`-Eventtyp `sync_baumelnde_referenz_gefunden`). Details in
  `docs/DATABASE_CONCURRENCY.md`, Abschnitt „Behobener Absturz: fehlende
  `inverse`-Deklarationen führen zu baumelnden Referenzen".

## v0.7 (Build 119) — Fix: Absturz bei veralteter Geschäft-Referenz nach Standorterkennung

- Behoben: Die automatische Standort-Ladenerkennung
  (`GeschaeftErkennungService.vorschlag`/`alleInDerNaehe`) hielt die zu Beginn
  übergebene `Geschaeft`-Liste über zwei potenziell mehrsekündige
  `await`-Wartepunkte (Standortermittlung, MapKit-Suche) hinweg fest. Wurde
  in dieser Zeit ein `Geschaeft` gelöscht (durch den Nutzer selbst oder —
  durch die neue Datensynchronisation wahrscheinlicher geworden — während
  eines automatischen Hintergrund-Sync-Zyklus lief parallel etwas anderes),
  crashte der App-Start bzw. die Standorterkennung mit einem
  SwiftData-Fatal-Error. Beide Funktionen laden die Geschäfte jetzt nach den
  Wartepunkten frisch aus dem `ModelContext`, bevor sie darauf zugreifen.
  Details in `docs/GESCHAEFTSERKENNUNG.md`.

## v0.7 (Build 118) — Sync-Debug-Modus: Datengrundlage für spätere Polling-Optimierung (GitHub #39)

- Neuer, optionaler „Sync-Debug-Modus" (Einstellungen, standardmäßig aus)
  protokolliert lokal: wie alt empfangene Updates (Events/Snapshots) beim
  Eintreffen waren (die tatsächlich beobachtete Sync-Latenz — bisher nur
  geschätzt, siehe Umsetzungsplan-Dokument), wie lange ein Sync-Zyklus
  dauert, und Ordner-Zugriffsfehler (bisher unsichtbar, da alle
  Sync-Funktionen best-effort arbeiten).
- Grundlage, um die in Phase 4 gewählten Polling-Intervalle (5s/60s) und die
  bewusst noch fehlenden Mechanismen (Fehler-Backoff, Konsolidierung) später
  mit echten Praxisdaten statt Annahmen zu überprüfen und nachzujustieren.
- `SyncOrdnerSettingsView` nutzt jetzt denselben `SyncPollingService.syncZyklus()`
  wie das automatische Polling, statt die vier Sync-Aufrufe zu duplizieren —
  die neue Protokollierung gilt dadurch für beide Auslöser (manuell und
  automatisch).

## v0.7 (Build 117) — Datensynchronisation Phase 4: automatisches Hintergrund-Polling (GitHub #39)

- Neuer `SyncPollingService` synchronisiert jetzt automatisch, solange die
  App im Vordergrund ist — sofort bei App-Start bzw. Rückkehr aus dem
  Hintergrund, danach alle 5 Sekunden während aktiv gemeinsam eingekauft wird
  (Einkaufen-Bildschirm sichtbar), sonst alle 60 Sekunden. Manuelles
  „Jetzt synchronisieren" bleibt zusätzlich weiter verfügbar.
- Läuft nur im Vordergrund (iOS pausiert reine In-App-Timer im Hintergrund) —
  echte Synchronisation bei gesperrtem Gerät bräuchte das
  `BackgroundTasks`-Framework und ist bewusst nicht Teil dieser Phase.
- Kein Fehler-Backoff und keine separate Konsolidierungslogik umgesetzt
  (Details und Begründung in `docs/DATENSYNCHRONISATION_VERLAUF.md`).
- Damit sind alle sechs Phasen des Datensynchronisations-Umsetzungsplans
  umgesetzt (mit den oben und im Plan-Dokument genannten, bewussten
  Vereinfachungen). Offen bleibt nur noch das separate, weiterhin
  zurückgestellte Multipeer-Vorhaben (Issue #49).

## v0.7 (Build 116) — Datensynchronisation Phase 5: automatischer Erst-Sync beim Verbinden (GitHub #39)

- Sync-Ordner verknüpfen (Einstellungen → Datensynchronisation) löst jetzt
  sofort einen ersten Sync-Zyklus aus, statt dass danach noch manuell auf
  „Jetzt synchronisieren" getippt werden muss — enthält der Ordner bereits
  Daten anderer Geräte, werden sie direkt beim Verbinden gemergt.
- Damit ist Phase 5 des Datensynchronisations-Umsetzungsplans abgeschlossen.
  Offen bleiben nur noch Phase 4 (automatisches Hintergrund-Polling) und das
  separate, weiterhin zurückgestellte Multipeer-Vorhaben (Issue #49).

## v0.7 (Build 115) — Überkauf-Hinweis beim gemeinsamen Einkaufen (GitHub #48)

- Wenn zwei Geräte im selben Einkauf denselben Artikel abhaken, zeigt
  `EinkaufenView` jetzt einen kurzen, sich selbst ausblendenden Hinweis
  („Bereits von {Gerätename} abgehakt“) statt den zweiten Versuch
  stillschweigend zu ignorieren.
- `Einkaufsvorgang.artikelAbhaken(_:context:)` liefert dafür ein neues
  `AbhakErgebnis` (`.abgehakt`/`.bereitsAbgehaktVon(geraeteID:)`), ermittelt
  über die bereits für die Datensynchronisation vorhandene
  Konfliktauflösung — kein zusätzliches Datenfeld auf `KaufEintrag` nötig.
- Neues, kleines `SyncPeerInfo`-Modell merkt sich die Anzeigenamen bekannter
  Peer-Geräte (aus dem neuen `SyncSnapshot.geraeteName`-Feld), um die
  Geräte-ID im Hinweis in einen lesbaren Namen aufzulösen.
- Damit ist Phase 6 des Datensynchronisations-Umsetzungsplans (GitHub #39)
  abgeschlossen.

## v0.7 (Build 114) — Datensynchronisation Phase 3b: Bereich-C/D-Import (GitHub #39)

- `SyncSnapshotImportService` merged jetzt auch Historie und Lernen:
  Einkaufsvorgänge (ID-basiert übernommen, damit Bereich-A-Ereignisse sie
  weiterhin auflösen können; ein bereits abgeschlossener Einkauf wird nie
  wieder geöffnet), Kaufeinträge (unveränderliche Historie, Duplikate anhand
  ihrer ID ausgeschlossen) und die Warengruppen-Distanzmatrix (Mittelwert bei
  bereits vorhandenem Eintrag, sonst Übernahme).
- Damit ist die Datensynchronisation aus GitHub #39 (ohne den bewusst
  zurückgestellten Multipeer-Kanal) in ihrer Kernfunktion vollständig: Export
  und Import für alle vier Datenbereiche laufen über denselben
  „Jetzt synchronisieren"-Button.

## v0.7 (Build 113) — Datensynchronisation Phase 3a: Bereich-B-Import (GitHub #39)

- Neuer `SyncSnapshotImportService` — liest `export.json` aus allen fremden
  Peer-Ordnern und merged Stammdaten (Geschäftstypen, Kategorien, Geschäfte,
  Artikel, Einkaufslisten) in den lokalen Bestand, unter Wiederverwendung
  bestehender Matching-Bausteine (Namensabgleich, Standort-Erkennung). Kein
  bereits lokal gesetzter Wert wird dabei überschrieben — nur fehlende Werte
  werden ergänzt, Mengen (Kategorien, ignorierte Artikel, alternative Namen)
  vereinigt.
- `Geschaeft.anzahlEinkaufsvorgaenge` wird jetzt korrekt additiv über mehrere
  Geräte gemergt (neuer `SyncPeerZaehlerStand`-Zähler-Zuwachs pro Peer, kein
  Überschreiben und keine Doppelzählung bei wiederholtem Sync);
  `umbauVerdacht` per Oder-Verknüpfung.
- Neue `SyncEntitaetsAlias`-Tabelle: da Artikel über Namensabgleich statt über
  die ID gematcht werden, aber weiterhin von Bereich-A-Ereignissen über die
  ursprüngliche Geräte-ID referenziert werden, merkt sich diese Tabelle die
  Zuordnung — verhindert, dass künftige Ereignisse für einen zusammengeführten
  Artikel ins Leere laufen.
- Noch nicht enthalten (Phase 3b): Merge von Einkaufsvorgängen, Kaufeinträgen
  und der Warengruppen-Distanzmatrix.

## v0.7 (Build 112) — Datensynchronisation Phase 2: Bereich-A-Import (GitHub #39)

- Neuer `SyncImportService` — liest Event-Dateien aus allen fremden
  Peer-Ordnern und wendet sie an, ausgelöst über denselben
  „Jetzt synchronisieren"-Button wie der Export. Bereits bekannte Events werden
  nicht erneut angewendet; konkurrierende Events zum selben Artikel/Bezug
  werden über die neue `SyncKonfliktAufloesung` entschieden ("dauerhaft
  entfernt" schlägt alles, "abwählen" schlägt "abhaken", sonst gewinnt der
  höhere Lamport-Zähler).
- Die 5 Bereich-A-Mutationsfunktionen (`Einkaufsliste.artikelHinzufuegen`,
  `Einkaufsvorgang.artikelAbhaken` u.a.) sind jetzt in eine reine
  Zustandsmutation und einen aufzeichnenden Wrapper aufgeteilt — verhindert,
  dass beim Anwenden eines empfangenen Events fälschlich ein neues, selbst
  authored Event entsteht. `SyncEventService.uebernehmen(_:context:)` fügt ein
  empfangenes Event stattdessen unverändert (mit ursprünglicher
  Geräte-Urheberschaft) lokal ein.
- Bekannte Grenze dieser Phase (dokumentiert in
  `docs/DATENSYNCHRONISATION_VERLAUF.md`): Ohne den noch ausstehenden
  Bereich-B/C/D-Import (Phase 3) funktioniert der Bereich-A-Import nur
  zuverlässig für Listen/Einkäufe/Artikel, die auf dem empfangenden Gerät
  bereits bekannt sind. Nicht anwendbare Events werden nicht als erledigt
  markiert und bei jedem weiteren Sync-Zyklus automatisch erneut versucht.

## v0.7 (Build 111) — Datensynchronisation Phase 1b: Bereich-B/C/D-Snapshot-Export (GitHub #39)

- Neues `SyncSnapshot`-DTO-Format (Bereich B: Geschäftstypen, Kategorien,
  Geschäfte, Artikel, Einkaufslisten; Bereich C: Einkaufsvorgänge, Kaufeinträge;
  Bereich D: Warengruppen-Distanzen) mit Format-Versionsfeld für künftige
  Kompatibilität.
- Neuer `SyncSnapshotExportService` — schreibt bei „Jetzt synchronisieren"
  zusätzlich zu den Bereich-A-Events einen vollständigen `export.json`-Snapshot
  des aktuellen Datenbestands in den eigenen Peer-Ordner. Reines Schreiben,
  noch keine Fälligkeits-/Konsolidierungslogik (kommt mit Phase 4) und noch kein
  Import (Phase 2/3).
- `docs/DATENSYNCHRONISATION_VERLAUF.md` um mehrere beim Entwurf
  getroffene/geklärte Entscheidungen ergänzt: `Geschaeft.erkennungsradius`
  synchronisiert sich als Teil des Geschäfts; die Lernzähler
  (`anzahlEinkaufsvorgaenge` u.a.) brauchen eine additive statt
  überschreibende Merge-Regel (Phase 3); dauerhaft ignorierte
  Belegscan-Positionen gelten als Eigenschaft des Geschäfts.

## v0.7 (Build 110) — Datensynchronisation Phase 1a: Bereich-A-Event-Export (GitHub #39)

- Neuer Einstellungen-Bildschirm „Datensynchronisation" — Sync-Ordner (z.B.
  iCloud Drive/Synology Drive) festlegen oder entfernen, bewusst getrennt vom
  bestehenden Datenbank-Speicherort (die lokale Datenbank bleibt unverändert am
  Standardpfad). Manueller „Jetzt synchronisieren"-Button für diese Phase —
  automatisches, periodisches Auslösen folgt erst mit der in
  `docs/DATENSYNCHRONISATION_VERLAUF.md` als Phase 4 geplanten
  Konsolidierung/adaptivem Polling.
- Neuer `SyncExportService` — schreibt lokale, noch nicht hochgeladene
  `SyncEvent`s als einzelne JSON-Dateien in den eigenen Peer-Ordner
  (`peers/{geraeteID}/events/`) und markiert sie danach als hochgeladen. Reines
  Schreiben — Lesen fremder Peer-Ordner ist Phase 2.

## v0.7 (Build 109) — Datensynchronisation Phase 0: LamportClock + SyncEvent-Grundgerüst (GitHub #39)

- Neue `LamportClock` (`Services/LamportClock.swift`) — lokale logische Uhr als
  Basis für eine geräteübergreifend eindeutige Ereignisreihenfolge, siehe
  `docs/DATENSYNCHRONISATION_VERLAUF.md`.
- Neues additives SwiftData-Modell `SyncEvent` (`Models/SyncEvent.swift`) +
  `SyncEventService.aufzeichnen(...)` — zeichnet Artikel-Hinzufügen/-Entfernen
  auf einer Einkaufsliste sowie Abhaken/Abwählen/dauerhaftes Entfernen auf einem
  Einkaufsvorgang als lokale Events auf.
- Noch kein Export/Import — reine lokale Aufzeichnung (Phase 0 von 7, siehe
  Phasenplan im Umsetzungsplan-Dokument). Kein Verhaltensunterschied für
  Nutzer:innen in dieser Phase.

## v0.7 (Build 104) — Architekturbewertung: Datenbank-Backup/Restore/Merge (GitHub #50)

- Neue `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` — Architektur für Backup,
  Wiederherstellung und Merge über einen Remote-Ordner, der (anders als die
  bisherige `DatabaseLocationService`-Funktion) nicht der aktive Speicherort
  wird, sondern nur für einmalige, manuell ausgelöste Vorgänge dient. Noch nicht
  implementiert — siehe Phasenplan im Dokument.

## v0.7 (Build 103) — Belegscan-Qualität: Dokumentenscanner, Zeilen-Leserichtung

- **Dokumentenoptimierte Aufnahme:** `BelegScanView` nutzt jetzt
  `VNDocumentCameraViewController` (VisionKit, neue `DesignSystem/DokumentScanView.swift`)
  statt eines rohen Kamerafotos (`UIImagePickerController`) — automatische
  Kantenerkennung, Perspektivkorrektur und Kontrastoptimierung vor der OCR.
  Erwartet deutlich weniger Erkennungsfehler bei schräg gehaltenen, verknitterten
  oder schlecht beleuchteten Kassenbons. `PreisschildScanView` bleibt bewusst bei
  `UIImagePickerController` — dessen Kantenerkennung ist auf seitenartige
  Dokumente ausgelegt, nicht auf ein einzelnes Regal-Preisschild.
- **OCR-Zeilen in Leserichtung sortiert:** neue
  `[ErkannteZeile].sortiertInLeserichtung()` (oben nach unten, bei gleicher Zeile
  links nach rechts) statt Visions nicht garantiert lesereihenfolge-treuer
  Ausgabe zu übernehmen — verhindert, dass Artikelname und Preis
  unterschiedlicher Zeilen bei einer leicht schiefen Aufnahme fälschlich
  zusammengeführt werden.
- `VNRecognizeTextRequest.minimumTextHeight = 0.01` ergänzt, damit kleine
  Thermodruck-Schrift zuverlässiger erkannt wird.
- Details in `docs/BELEGSCAN.md`.

## v0.7 (Build 102) — Warengruppen-Ausschluss, Singular/Plural-Suche, Karten-/Sortier-Fixes (GitHub #42–#46)

- **Karten-Auto-Zoom entfernt (GitHub #42):** Korrektur der #41-Umsetzung — die
  Karte in `GeschaeftStammdatenEditView` zoomt nicht mehr automatisch nach, wenn
  Pin oder Erkennungsradius geändert werden; nur noch eine radius-bewusste
  Anfangsansicht (`initialPosition`, einmalig).
- **Automatisch zugeordnete Warengruppen einzeln ausschließbar (GitHub #43):**
  Neues `Geschaeft.ausgeschlosseneKategorien` (Negativliste) — eine über den
  Geschäftstyp automatisch verfügbare Kategorie lässt sich für ein einzelnes
  Geschäft per Wischgeste ausschließen, ohne sie generell vom Geschäftstyp zu
  entfernen. Taucht danach wieder unter „Kategorie hinzufügen“ auf.
- **Singular/Plural-unabhängige Artikelsuche (GitHub #44):** Neue
  `String.passtAlsSingularPluralZu(_:)` kombiniert eine deterministische
  Wortstamm-Heuristik (Umlaut-Faltung + Präfix-Vergleich gegen gängige deutsche
  Pluralendungen) mit `NLTagger`s `.lemma`-Schema als Zusatzsignal. Empirisch
  gegen 15 typische Einkaufs-Wortpaare getestet: die Heuristik allein deckt alle
  Fälle korrekt ab, `NLTagger` allein nur rund die Hälfte (und einmal aktiv
  falsch) — deshalb nur additiv verwendet, nie als alleinige Grundlage.
- **Artikel-hinzufügen-Sheet (GitHub #45):** Titel zeigt jetzt zusätzlich den
  Namen der Einkaufsliste; bereits auf der Liste stehende Artikel zeigen das
  App-weit einheitliche Abhak-Symbol statt „Auf Liste“-Text und lassen sich per
  erneutem Tap wieder von der Liste nehmen (neues
  `Einkaufsliste.artikelEntfernen(_:context:)`).
- **Umlaut-Sortierung in „Einstellungen → Artikel“ (GitHub #46):** Folgefall zu
  #34 — der „Alphabetisch“-Modus sowie die Reihenfolge innerhalb einer
  Kategorie-Gruppe im „Nach Kategorie“-Modus nutzten noch die rohe
  `@Query`-Reihenfolge statt der bereits vorhandenen `vergleicheAlphabetisch`-Extension.

## v0.7 (Build 101) — Individueller Erkennungsradius pro Geschäft (GitHub #41)

- Neues additiv-optionales `Geschaeft.erkennungsradius` (Fallback: der bisherige
  globale Standard `GeschaeftErkennungService.koordinatenTreffertoleranz`, 75m)
  ersetzt für `istBekannterTreffer(_:fuer:)` die feste globale Trefftoleranz —
  einstellbar per Slider (20–500m) in `GeschaeftStammdatenEditView`, direkt unter
  der Karte, mit einem `MapCircle`-Overlay, das den Radius am Standort-Pin
  einzeichnet und sich beim Verschieben des Sliders live mit der Kartenregion
  mitzoomt.
- `effektiverSuchradius(basis:vorhandeneGeschaefte:)`: der eigentliche Apple-Maps-
  Suchradius (`suchradius`/`alleInDerNaeheRadius`) wächst jetzt automatisch auf
  den größten individuell konfigurierten Erkennungsradius mit — sonst würde ein
  größerer individueller Radius wirkungslos bleiben, weil `MKLocalPointsOfInterestRequest`
  den betreffenden Laden bei größerer Entfernung als der (bisher festen)
  Suchradius-Grenze gar nicht erst zurückliefert.
- Details in `docs/GESCHAEFTSERKENNUNG.md` → „Individueller Erkennungsradius pro
  Geschäft".

## v0.7 (Build 99) — Geschäft-Detail/-typ-Kategorien, Umlaut-Sortierung, Tap-Flächen (GitHub #34, #37, #38, #40)

- **Umlaut-Sortierung (GitHub #34):** Neue `String`-Extension
  (`alphabetischerAnfangsbuchstabe`/`vergleicheAlphabetisch(mit:)`) sortiert und
  gruppiert Namen mit Umlauten jetzt bei ihrem Basisbuchstaben (Ä bei A, Ö bei
  O, Ü bei U) statt — wie beim reinen Unicode-Codepoint-Vergleich zuvor —
  fälschlich ans Listenende. Angewandt in `GeschaeftListView`,
  `ArtikelHinzufuegenView`, `EinkaufenView`, `ArtikelPreisSpanne`,
  `GeschaeftHaeufigkeitService`, `ArtikelListView` und `GeschaeftsTypKategorienView`.
- **Geschäft-Detail zeigt alle verfügbaren Kategorien (GitHub #37):** Der
  „Kategorien“-Abschnitt in `GeschaeftDetailView` zeigt jetzt manuell
  zugeordnete **und** über den Geschäftstyp automatisch verfügbare Kategorien
  gemeinsam, alphabetisch, automatische Kategorien mit Untertitel „Automatisch
  über Geschäftstyp“ gekennzeichnet und nicht direkt entfernbar (nur manuell
  zugeordnete lassen sich per Wischgeste entfernen).
- **Geschäftstyp bearbeiten (GitHub #40):** `GeschaeftTyp` hat jetzt ein
  Farbfeld (`farbeHex`, additiv-optional). Die Detailansicht eines
  Geschäftstyps erlaubt jetzt zusätzlich zur Kategorien-Zuordnung das Ändern
  von Name, Symbol und Farbe (wiederverwendete `SymbolFarbAuswahlZeile`,
  auch beim Neuanlegen eines Geschäftstyps). Gerade per „KI-Vorschlag“
  vorgeschlagene Warengruppen sind für die Dauer der Sitzung zusätzlich mit
  „KI-Vorschlag“ markiert (bewusst nicht dauerhaft persistiert).
- **Ganze Zeile tippbar (GitHub #38):** Die Typ-Auswahlzeilen in
  `GeschaeftStammdatenEditView` sowie die Kategorie-Toggle-Zeilen in
  `GeschaeftsTypKategorienView` und die gemeinsame `SymbolFarbAuswahlZeile`
  reagieren jetzt über die volle Zeilenbreite auf Taps (`.contentShape(Rectangle())`)
  statt nur auf den sichtbaren Text/Icon-Inhalt.
- GitHub #36 (adaptive Einkaufslistenoptimierung) ist mit der Regal-Entfernung
  (Build 96) vollständig abgeschlossen.

## v0.7 (Build 98) — Code-Review-Fixes (Umbau-Hinweis, Import-Duplikate, Doppelberechnung)

- **Umbau-Hinweis-Dialog** feuerte bei jedem Einkauf erneut, solange der
  Verdacht bestehen blieb, statt nur beim erstmaligen Erkennen
  (`WarengruppenDistanzService`/`EinkaufenView`).
- **MilkForUs-Import** und **KI-Warengruppen-Vorschlag** konnten bei doppeltem
  Namen im selben Lauf jeweils ein Duplikat anlegen (stale Artikel-/
  Kategorien-Snapshot innerhalb der Schleife).
- **Kategorie-Editor** zeigte Artikel, die nur über die alte, einzelwertige
  Kategorie-Zuordnung bestehen, nicht in der Artikel-Liste an.
- **EinkaufenView** berechnete Kategorien-Gruppierung/-Sortierung und
  Artikel-Filter pro Render mehrfach statt einmal.
- **Einkaufsbesuch unter einer Minute** zeigte eine leere Dauer im
  Besuchsprotokoll.
- Totes Fallback in der Startpunkt-Wahl des Sortier-Algorithmus entfernt.
- Ergebnis eines `/code-review` über den v0.6-Zyklus — Details siehe Commit
  `6c5aad6`. Zwei weitere Findings (Regal-only-Kategorien und
  Geschäftstyp-Migration können bei bereits migrierten Altgeräten Daten
  verloren haben) werden manuell statt per Code-Fix nachgereicht, da die App
  nicht produktiv ist.

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

## v0.2 (Build 100) — Artikel-Verwaltung

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
