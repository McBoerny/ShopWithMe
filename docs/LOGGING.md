# ShopWithMe — Logging & Debugging Architektur

Status: **Umgesetzt seit Build 30** (`Services/DebugLogWriter.swift`,
`Services/DatabaseDebugLogger.swift`, `Views/Einstellungen/
DatabaseDebugSettingsView.swift`). Sammelstelle für alle optionalen
Diagnose-/Debug-Logging-Mechanismen der App — aktuell einer (DB-Debug-Modus),
weitere folgen bei Bedarf als eigene Abschnitte in diesem Dokument, statt über
mehrere Dateien verstreut zu werden.

## Zweck & gemeinsame Prinzipien

Jeder künftige Logging-/Debug-Mechanismus in ShopWithMe folgt denselben
Grundregeln, unabhängig vom konkreten Anwendungsfall:

- **Opt-in, standardmäßig aus.** Kein Mechanismus protokolliert in der
  regulären Nutzung ungefragt mit — jeder hat einen eigenen globalen Schalter
  in den Einstellungen.
- **Drei Verbositätsstufen statt eines einfachen An/Aus** (seit 2026-08-02,
  siehe „Gemeinsamer Baustein: `Protokollstufe`" unten): `Fehler` (nur
  Störungen und seltene bedeutsame Ereignisse), `Standard` (zusätzlich die
  normale Zyklus-/Aktions-Aktivität), `Ausführlich` (zusätzlich hochfrequente
  Detail-Ereignisse, nur für eine gezielte Tiefenanalyse). Jeder Mechanismus
  ordnet seine eigenen Ereignistypen einer dieser Stufen zu.
- **Wiederholte identische Ereignisse werden gedrosselt**, statt jede
  Wiederholung einzeln zu schreiben (siehe „Gemeinsamer Baustein:
  `WiederholungsFilter`" unten) — verhindert, dass eine einzelne anhaltende
  Störung (z.B. ein dauerhaft fehlschlagender Ordnerzugriff) das Protokoll
  mit tausenden identischen Zeilen flutet.
- **Kein spürbarer Overhead bei Deaktivierung.** Schalter-Zustand wird
  In-Memory gecacht (nicht bei jedem Aufruf `UserDefaults` lesen), damit ein
  deaktivierter Mechanismus praktisch unsichtbar im Code bleibt.
- **Rein lokales Diagnose-Werkzeug, kein Server.** Auswertung erfolgt manuell
  (Log-Datei lesen/teilen), kein automatischer Upload — konsistent mit der
  Grundsatzentscheidung gegen einen eigenen Server/CloudKit (siehe
  `docs/DATABASE_CONCURRENCY.md` → „Verworfene Alternativen").
- **Asynchrones Schreiben.** Das Protokollieren selbst darf die beobachteten
  Vorgänge nicht messbar verlangsamen oder verfälschen (kein Logging auf dem
  Hauptpfad der zu diagnostizierenden Operation).
- **Einheitliches Zeilenformat über alle Mechanismen hinweg:**
  `[ISO8601-Zeitstempel] [Gerätename] [Ereignistyp] Details…` — menschenlesbar
  und einfach maschinell auswertbar (z.B. per Zeilen-Split), damit Logs
  verschiedener Mechanismen später gemeinsam ausgewertet werden können, ohne
  je Mechanismus ein eigenes Format zu parsen.
- **Feste Größenrotation** (Zwei-Datei-Rotation: aktuelle Datei +
  `.previous`), damit kein Mechanismus unbegrenzt wächst.

## Gemeinsamer Baustein: `Protokollstufe` & `WiederholungsFilter`

Eingeführt 2026-08-02 nach einer konkreten Analyse zweier realer
Sync-Debug-Protokolle (`docs/DATENSYNCHRONISATION_VERLAUF.md` §30/§32): ca.
60% des Zeilenvolumens im Normalbetrieb bestand aus je Zyklus unbedingt
mehrfach feuernden „unverändert"-Zeilen ohne Diagnosewert für die meisten
Fragestellungen, und eine einzelne anhaltende Störung erzeugte binnen 27
Minuten 1065 identische Fehlerzeilen.

- **`Protokollstufe`** (`Services/DebugLogWriter.swift`): geordnetes Enum
  `aus < fehler < standard < ausfuehrlich`. Jeder Ereignistyp jedes
  Mechanismus trägt eine `mindestStufe`; geschrieben wird, wenn die
  eingestellte Stufe die des Ereignisses erreicht oder übersteigt. Ersetzt
  den früheren reinen Bool-Schalter — bestehende Installationen werden beim
  ersten Zugriff einmalig migriert (alter „an"-Zustand → `.standard`, „aus"
  → `.aus`).
- **`WiederholungsFilter`** (`Services/DebugLogWriter.swift`): unterdrückt
  exakt wiederholte (gleicher Ereignistyp + gleicher Detail-Text) Ereignisse
  zugunsten eines periodischen Lebenszeichens (Standard: alle 60s) mit
  Zähler der zwischenzeitlich unterdrückten Wiederholungen. Ändert sich der
  Inhalt, wird sofort wieder normal protokolliert. Jeder Mechanismus hält
  eine eigene Instanz und reicht jeden `log(...)`-Aufruf hindurch, bevor er
  tatsächlich geschrieben wird.
- **UI:** `DebuggingView` zeigt pro Mechanismus einen Picker mit den drei
  Stufen statt eines einfachen Toggles.

## Gemeinsamer Baustein: `DebugLogWriter`

Um zu vermeiden, dass jeder künftige Mechanismus Dateischreiben, Rotation,
`os.Logger`-Spiegelung und Share-Sheet-Export neu implementiert, ist ein
gemeinsamer, mechanismus-unabhängiger `DebugLogWriter`-Baustein vorgesehen:

- Nimmt Ereignisse entgegen (`Kategorie`, `Ereignistyp`, `Details`-String),
  unabhängig davon, welcher Mechanismus sie erzeugt.
- Kapselt: Zwei-Datei-Rotation bei fester Größengrenze, Spiegelung nach
  `os.Logger` (Subsystem = Bundle-ID, `Category` = übergebene Kategorie, z.B.
  `DatabaseConcurrency`), Schreiben auf einer eigenen Queue/einem eigenen
  Actor.
- Jeder Mechanismus (z.B. `DatabaseDebugLogger`) ist dann ein dünner,
  fachlicher Wrapper um diesen gemeinsamen Baustein — eigen ist nur der
  Schalter, die Ereignistypen und ggf. der Speicherort (lokal vs. zusätzlich
  im gemeinsamen Cloud-Ordner).
- Settings-Muster je Mechanismus: eigener `UserDefaults`-Boolean + eigene View
  unter `Views/Einstellungen/`, analog zum bestehenden Muster von
  `DatabaseLocationService`/`DatabaseLocationSettingsView`, da es (Stand
  dieser Dokumentation) noch keinen zentralen Settings-Store im Projekt gibt.

**Live-Test-Fund (Session 2026-08-03): Writer-Instanz je Mechanismus
zwischenspeichern, nicht bei jedem Aufruf neu erzeugen.** `DebugLogWriter`
ist ein `actor` und serialisiert Schreibzugriffe damit zuverlässig — aber
nur GEGEN SICH SELBST, nicht gegen eine bei jedem `log(...)`-Aufruf frisch
erzeugte zweite Instanz auf dieselbe Datei. `SyncDebugLogger` legt seinen
Writer als stabile `static let` einmalig an und war davon nie betroffen;
`DatabaseDebugLogger` braucht wegen des im Dateinamen enthaltenen,
änderbaren Geräte-Präfix (GitHub #84) eine dynamische Erzeugung und
instanziierte bis dahin bei jedem Aufruf neu — sichtbar geworden, als das
`einkauf_abschluss_ausgeloest`/`einkauf_abschluss_durchgefuehrt`-Paar
(siehe unten) zwei `log(...)`-Aufrufe kurz hintereinander auslöste: die
beiden `seekToEnd()`+`write()`-Sequenzen aus zwei verschiedenen Instanzen
überschrieben sich teilweise gegenseitig — sichtbar als abgeschnittene
(fehlender Zeitstempel-Präfix) bzw. in der Reihenfolge vertauschte
Protokollzeilen. Fix: die Writer-Instanz wird jetzt unter einem `NSLock`
(analog dem Muster von `WiederholungsFilter`) zwischengespeichert und nur
bei tatsächlich geändertem Präfix neu erzeugt — jeder künftige Mechanismus
mit dynamischem Dateinamen sollte demselben Muster folgen statt `lokalerWriter`
als reine Computed Property ohne Cache zu implementieren.

## Mechanismus: DB-Debug-Modus (Sync/Lock/Öffnen)

Erster und aktuell einziger konkreter Mechanismus. Protokolliert Probleme
rund um das in `docs/DATABASE_CONCURRENCY.md` beschriebene
Micro-Lease-Verfahren (Sync, Lock, Öffnen, Speichern), damit sie nach einem
Live-Test mit mehreren Geräten ausgewertet werden können.

### Bausteine

- **Globaler Schalter:** `UserDefaults`-Boolean (Key z.B.
  `datenbankDebugModusAktiv`), analog zum bestehenden Bookmark-Key in
  `DatabaseLocationService.swift:27`. Neue View `DatabaseDebugSettingsView`
  (Vorbild: `DatabaseLocationSettingsView`), verlinkt aus `SettingsView.swift`
  neben dem bestehenden Eintrag zum Datenbank-Speicherort. Enthält: Toggle
  „Debug-Modus", aktuelle Log-Dateigröße, Button „Log teilen" (Share Sheet),
  Button „Log leeren".
- **`DatabaseDebugLogger`:** fachlicher Wrapper um den gemeinsamen
  `DebugLogWriter` (Kategorie `DatabaseConcurrency`), aufgerufen von
  `DatabaseLeaseService`/`DatabaseLocationService` aus an den unten gelisteten
  Ereignis-Punkten.

### Gewählte Parameter

| Parameter | Wert | Begründung |
|---|---|---|
| Speicherort | **Lokal je Gerät + zusätzlich im gemeinsamen DB-Ordner** (`<Gerätename>-<kurze-Geräte-ID>-debug.log` neben dem Store) | Ermöglicht, nach einem Testlauf die Ereignisse mehrerer Geräte nebeneinander auszuwerten, ohne Logs manuell von jedem Gerät einzusammeln — sie synchronisieren automatisch mit, solange der Debug-Modus aktiv ist. Zusätzlicher Sync-Traffic ist unkritisch, da reiner Text und nur bei aktivem Debug-Modus. |
| Verbosität | **Fehler + Lebenszyklus-Ereignisse** | Erlaubt, den Ablauf um einen Fehler herum nachzuvollziehen (was geschah davor), ohne die Detailtiefe eines vollständigen Traces (unnötiges Volumen, wenn kein Problem vorliegt). |
| Rotation | **Feste Größengrenze, älteste Einträge verwerfen** (z.B. 1 MB je Log-Datei) | Vorhersagbare, begrenzte Größe passend zum Minimal-Datentransfer-Ziel (siehe `docs/DATABASE_CONCURRENCY.md` → „Datentransfer-Schätzung"). Umsetzung über die gemeinsame Zwei-Datei-Rotation aus `DebugLogWriter`. |

### Protokollierte Ereignistypen (Lebenszyklus-Ebene)

`store_open_{start,success,failure}`,
`lease_acquire_{attempt,success,denied_readonly}`, `lease_stale_takeover`,
`lease_release`, `save_{success,failure}`, `dedupe_conflict_detected`,
`einkauf_abschluss_{ausgeloest,duplikat_geschlossen,durchgefuehrt}`,
`debug_mode_{enabled,disabled}` (Meta-Ereignis, damit beim Auswerten klar ist, ab
wann überhaupt protokolliert wurde). Micro- und Session-Lease teilen sich
dieselben Ereignistypen — unterschieden über ein `"micro"`/`"session"`-Präfix im
Detail-Text statt über eigene Ereignistypen.

**`einkauf_abschluss_ausgeloest`** (2026-08-03, Diagnose für den Live-Test-Fund
„Einkauf abschließen bewirkt scheinbar nichts trotz sichtbar abgehakter
Artikel"): protokolliert bei jedem Tap auf „Einkauf abschließen", bevor der
eigentliche Vorgang geschlossen wird (Details:
`geschaeft=… eigeneEintraege=N offeneVorgaengeFuerListe=K
andereOffeneVorgaengeMitEintraegen=J listenweitAbgehaktGesamt=M
andereGeschaefte=[Name=Anzahl,…]`). Ursprünglicher Verdacht: seit die
Sichtbarkeit abgehakter Artikel listenweit über alle offenen Vorgänge einer
``Einkaufsliste`` gilt — unabhängig vom gewählten Geschäft, siehe
``Einkaufsvorgang/abgehakteKaufEintraege(fuerListe:unter:)`` —,
``EinkaufslisteView/einkaufAbschliessen()`` aber nur den EINEN zur aktuellen
Geschäftsauswahl gehörenden Vorgang schließt. Ein erster Fix (schließt alle
offenen Vorgänge derselben Geschäft+Liste-Kombination) behob einen
bestätigten Testfall NICHT vollständig — `andereGeschaefte` zeigte, dass die
übrig gebliebenen Einträge an einem offenen Vorgang eines ANDEREN Geschäfts
derselben Liste hingen, außerhalb der engeren Kombination. Der zweite Fix
schließt seither ALLE offenen Vorgänge derselben Liste, unabhängig vom
Geschäft — siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3, „zweiter
Nachtrag".

**`einkauf_abschluss_duplikat_geschlossen`** (2026-08-03, Diagnose für den
Live-Test-Fund „Einkauf abschließen auf einem Gerät beendet ungewollt einen
noch aktiven Vorgang eines anderen Geräts"): protokolliert je tatsächlich
mitgeschlossenem Duplikat-Vorgang, VOR dessen Schließen (Details:
`geschaeft=… eigeneEintraege=N letzteAktivitaetVorSekunden=S`).
`letzteAktivitaetVorSekunden` misst gegen den jüngsten `KaufEintrag.datum`
dieses Vorgangs (sonst `startZeit`) — ein kleiner Wert (wenige Sekunden/
Minuten) bei gleichzeitig mehreren aktiven Geräten ist der Verdacht, dass
der zweite Fix (siehe `einkauf_abschluss_ausgeloest` unten) zu weit geht:
er kann einen Vorgang schließen, der auf einem anderen Gerät gerade aktiv
in Benutzung ist, nicht nur eine seit Langem verwaiste Karteileiche. Noch
kein Fix umgesetzt — die Diagnose soll erst zeigen, ob ein Schwellwert
(„nur schließen, wenn seit N Minuten inaktiv") das zuverlässig unterscheidet.

**`einkauf_abschluss_durchgefuehrt`** (2026-08-03): protokolliert direkt im
Anschluss, NACHDEM alle Duplikat-Vorgänge geschlossen wurden (Details:
`geschlosseneDuplikate=N verbleibendOffenMitEintraegenFuerListe=M`).
`verbleibendOffenMitEintraegenFuerListe` ist eine erneute Zählung nach dem
Schließen und sollte im Erfolgsfall immer `0` sein — ein Wert `> 0` zeigt
direkt im Log eine verbleibende Lücke, statt sie aus einem stillen „hat
nicht funktioniert" im nächsten Testlauf erneut erraten zu müssen.

**Stufen-Einordnung** (siehe „Gemeinsamer Baustein: `Protokollstufe`" oben):
`Fehler` für `store_open_failure`, `lease_acquire_denied_readonly`,
`lease_stale_takeover`, `save_failure`, `dedupe_conflict_detected`,
`debug_mode_{enabled,disabled}`; `Standard` für den Rest (inkl.
`einkauf_abschluss_{ausgeloest,duplikat_geschlossen,durchgefuehrt}`). Anders als beim Sync-Protokoll aktuell keine
`Ausführlich`-exklusiven Ereignisse — das Micro-Lease-Verfahren ist
aktionsgetrieben (ein Lease pro Speichervorgang), nicht poll-getrieben, und
hat damit kein Äquivalent zu `sync_snapshot_unveraendert_uebersprungen`.

**Bewusst nicht umgesetzt:** eigene Ereignistypen für WAL-Checkpoints,
`NSFileCoordinator`-Fehler oder `NSFilePresenter`-Änderungsbenachrichtigungen —
`docs/DATABASE_CONCURRENCY.md` erzwingt keinen Checkpoint pro Lease (siehe dort
„Datentransfer-Schätzung") und registriert aktuell keinen `NSFilePresenter` zur
aktiven Änderungserkennung (jeder Lease-Erwerb liest die Lock-Datei ohnehin frisch
via `NSFileCoordinator`). Käme das später hinzu, gehören die Ereignistypen hier
ergänzt.

### Bekannte Grenzen

- Fügt selbst zusätzlichen Sync-Traffic hinzu (klein, aber nicht null) —
  konsistent mit „optional", sollte für reguläre Nutzung standardmäßig aus
  bleiben und nur gezielt für Testphasen aktiviert werden.
- Rein lokales Diagnose-Werkzeug, kein Crash-Reporting-Server (siehe
  gemeinsame Prinzipien oben).

## Mechanismus: Datensynchronisation

Zweiter konkreter Mechanismus (siehe `docs/DATENSYNCHRONISATION.md` für die
aktuelle Architektur, Abschnitt 7 für die Debug-/Statuskonsolidierungs-
Werkzeuge), ergänzt mit Phase 4 des `docs/DATENSYNCHRONISATION_VERLAUF.md`
(GitHub #39). Zweck: Der Plan
schätzt die tatsächliche Sync-Latenz (5–30s iCloud Drive, 1–10s Synology
Drive) auf Basis von `docs/DATABASE_CONCURRENCY.md`, nicht auf Basis echter
Messungen, und Phase 4 verzichtet bewusst auf Fehler-Backoff, weil die
Sync-Funktionen bisher keine auswertbare Erfolgs-/Fehlerrückmeldung liefern.
Dieses Protokoll schafft die fehlende Datengrundlage für beides, damit die
Polling-Intervalle in `SyncPollingService` später mit echten Praxisdaten statt
Annahmen nachjustiert werden können.

### Bausteine

- **Globaler Schalter:** `UserDefaults`-Boolean (Key
  `datensyncDebugModusAktiv`). Neue View `SyncDebugSettingsView` (Vorbild:
  `DatabaseDebugSettingsView`), verlinkt aus `SettingsView.swift` neben dem
  bestehenden Eintrag zur Datensynchronisation. Enthält: Toggle „Debug-Modus",
  aktuelle Log-Dateigröße, Button „Protokoll teilen" (Share Sheet), Button
  „Protokoll leeren".
- **`SyncDebugLogger`:** fachlicher Wrapper um den gemeinsamen
  `DebugLogWriter` (Kategorie `Datensynchronisation`), aufgerufen von
  `SyncPollingService`, `SyncImportService`, `SyncSnapshotImportService`,
  `SyncExportService` und `SyncSnapshotExportService` an den unten gelisteten
  Ereignis-Punkten.

### Abweichung vom DB-Debug-Modus: nur lokal, keine Spiegelung

Anders als der DB-Debug-Modus wird das Datensynchronisations-Protokoll
bewusst **nicht** zusätzlich in den Sync-Ordner gespiegelt. Die für die
Optimierung relevanten Werte (Alter eines empfangenen Updates, Dauer eines
Sync-Zyklus) sind bereits aus rein lokaler Sicht aussagekräftig — eine
geräteübergreifende Zusammenführung würde zusätzliche
Security-Scope-Handhabung beim Schreiben in den (im Gegensatz zum
DB-Ordner nicht dauerhaft offen gehaltenen) Sync-Ordner erfordern, ohne für
den Optimierungszweck nötig zu sein.

### Protokollierte Ereignistypen

`sync_zyklus_{start,ende}` (Details bei `ende`: gemessene Zyklusdauer),
`sync_event_empfangen`/`sync_snapshot_empfangen` (Details: `alter_sekunden=…`
— Differenz zwischen jetzt und dem Erzeugungszeitpunkt auf dem
Herkunftsgerät, nur für tatsächlich neu angewendete Updates, nicht für
Verlierer im Konfliktfall), `sync_ordner_zugriff_fehlgeschlagen` (Details:
welche Funktion), `sync_baumelnde_referenz_gefunden` (Details: Modelltyp +
`PersistentIdentifier` — siehe `docs/DATABASE_CONCURRENCY.md`, Abschnitt
„Behobener Absturz: fehlende `inverse`-Deklarationen führen zu baumelnden
Referenzen"; markiert eine bereits vor diesem Fix entstandene, still
ignorierte Fremdreferenz beim Snapshot-Export), `sync_einkaufslisten_stand`
(Details: `anzahl=N [Name=Eintragszahl, …]` — kompletter lokaler
Einkaufslisten-Bestand nach jedem Snapshot-Merge-Durchlauf; macht Dubletten
mit gleichem Namen, aber unterschiedlicher Eintragszahl direkt im Protokoll
sichtbar, siehe GitHub #52-Nachfolgefund), `sync_event_nicht_anwendbar`
(Details: `art=… bezugsID=… artikelID=…` — ein empfangenes Bereich-A-Event
verweist auf eine lokal noch nicht auflösbare Einkaufsliste/einen
Einkaufsvorgang/Artikel, siehe `SyncImportService`s Retry-Semantik; wird bei
jedem weiteren Zyklus erneut protokolliert, bis die Referenz auflösbar wird —
hält sie sich dauerhaft, ist das ein Hinweis auf einen fehlenden/fehlerhaften
``SyncEntitaetsAlias``), `sync_peer_verworfen_altersgrenze` (Details: welcher
Peer — dessen Snapshot ist älter als
`SyncSnapshotImportService.maximalesSnapshotAlter` und wird komplett
ignoriert, siehe Architektur-Revision „Alternative A"), `sync_event_aufgegeben`
(Details wie `sync_event_nicht_anwendbar` — Event ist auch nach
`SyncImportService.maximalesEventAlterFuerRetry` nicht anwendbar und wird
aufgegeben statt weiter versucht, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md`
Abschnitt 15), `sync_snapshot_unveraendert_uebersprungen`/`sync_snapshot_geschrieben`
(GitHub #70-Nachfolgefrage „welche Änderung löst tatsächlich ein Schreiben
von `export.json` aus": Details bei beiden ein Diagnose-Text `bereich=Anzahl/KurzHash`
je Teil-Bereich — `geschaeftsTypen`, `artikelKategorien`, `geschaefte`,
`artikel`, `einkaufslisten`, `einkaufslistenEintraege`, `einkaufsvorgaenge`,
`kaufEintraege`, `warengruppenDistanzen`, `tombstones`; zusätzlich bei
`sync_snapshot_geschrieben` `vorher=…` mit den ersten 8 Zeichen des zuvor
geschriebenen Gesamt-Fingerabdrucks. Zwei aufeinanderfolgende Protokollzeilen
direkt vergleichbar: ändert sich nur die Anzahl eines Bereichs, ist dort ein
Eintrag hinzugekommen/verschwunden; ändert sich nur der Kurzhash bei
gleicher Anzahl, hat sich ein Feld eines bestehenden Eintrags geändert (z.B.
`endZeit` gesetzt, ein additiver Zähler erhöht) — siehe
`SyncSnapshotExportService.diagnoseText(of:)`), `debug_mode_{enabled,disabled}`.

**GitHub #91 (dritter Anlauf) — `SyncICloudAenderungsBeobachter`:**
`sync_icloud_beobachter_ausgeloest` (feuert bei jeder über die langlebige
`NSMetadataQuery` erkannten Fremdänderung — Beleg dafür, dass die Query
tatsächlich reagiert, nicht nur läuft) und
`sync_icloud_beobachter_scope_aktualisiert` (Details: `peers=N scopes=M` —
die Query wurde neu aufgebaut, initial oder weil sich die bekannte
Peer-Liste geändert hat).

**GitHub #92 (experimentell):** `sync_icloud_picker_trigger_ausgeloest` —
der manuelle "Jetzt synchronisieren"-Button hat kurz einen
`UIDocumentPickerViewController` auf den Sync-Ordner eingeblendet
(``ICloudSyncTriggerPicker``). Reiner Beleg, dass der Trigger ausgelöst
wurde, keine Aussage über dessen Wirkung — dafür der zeitliche Abstand zu
nachfolgenden `sync_event_empfangen`/`sync_snapshot_empfangen`-Zeilen im
selben Protokoll heranziehen.

**Diagnose für `Einkaufsvorgang`-Abschluss-Übernahme** (2026-08-02, Nutzerbericht
„Einkauf abschließen synchronisiert nicht"): `sync_einkaufsvorgang_abschluss_uebernommen`/
`sync_einkaufsvorgang_abschluss_nicht_uebernommen` (Details:
`vorgangID=… grund=…`, `grund` eines von `umgeleitetAufNachfolger`/
`bereitsAbgeschlossen`/`endZeitVorStartZeit` beim Nicht-Übernehmen — siehe
`SyncSnapshotImportService.mergeEinkaufsvorgaenge`, Guard-Kaskade um
`vorhandener.endZeit`), `sync_einkaufsvorgang_eintrag_uebersprungen` (Details:
`vorgangID=… grund=…`, `grund` eines von `unaufloesbareListe`/`tombstone` —
der Eintrag wurde ohne jeden Matching-Versuch verworfen, bevor die
Abschluss-Prüfung überhaupt erreicht wurde).

**Diagnose für das `EinkaufslistenEintrag`-Sicherheitsnetz** (2026-08-10,
Nutzerbericht: Artikel fehlte nach frischem Neuaufbau/„Ersetzen durch Peer"
auf dem betroffenen Gerät, obwohl der Peer ihn aktuell noch führte):
`sync_listeneintrag_sicherheitsnetz_uebersprungen` (Details: `artikel=…
liste=… istAusDerZeitGefallen=…`) — `SyncSnapshotImportService.mergeEinkaufslistenEintraege`
hat einen vom Peer aktuell gemeldeten Eintrag verworfen, weil
`istBereitsAbgehakt` (`ArtikelListenKauf`, oder der ältere
`vorgaengeFuerListe`-Fallback) diesen Artikel auf dieser Liste bereits als
„jemals gekauft" führt. Vorher komplett stumm; erlaubt jetzt, einen echten
Altfund von einem legitimen erneuten Hinzufügen zu unterscheiden, dessen
direktes `artikelHinzugefuegt`-Ereignis dieses Gerät nie erreicht hat (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 54).

**`sync_scope_zugriff`** (2026-08-02, Diagnose für einen Live-Test-Fund —
permanenter `sync_ordner_zugriff_fehlgeschlagen` auf dem „Backup"-Gerät ohne
erkennbaren Auslöser, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md` §30/§32):
``SyncOrdnerZugriffsDiagnose`` protokolliert um jeden
`startAccessingSecurityScopedResource()`-Aufruf der acht wiederkehrenden
Top-Level-Sync-Funktionen herum Details der Form `<Aufrufstelle>
erfolgreich=<Bool> gleichzeitigOffen=<kommagetrennte Liste oder "keine">` —
macht verschachtelten/überlappenden Scope-Zugriff (historische Root Cause
eines identischen Symptoms, siehe §30) von einem rein extern verursachten
Ordner-Ausfall unterscheidbar. Nur bei ``Protokollstufe/ausfuehrlich``, da es
pro Aufrufstelle bei jedem Zyklus feuert.

**GitHub #49 — `MultipeerSyncService` (Beschleunigungskanal):**
`multipeer_peer_{verbunden,getrennt}` (Details: `peerID.displayName`) und
`multipeer_event_empfangen` (Details: `alter_sekunden=…`, gleiche Bildung wie
`sync_event_empfangen` — direkt damit vergleichbar, um die tatsächliche
Latenz-Ersparnis gegenüber dem Datei-Kanal aus echten Live-Tests abzulesen,
statt sie nur anzunehmen).

**Stufen-Einordnung** (siehe „Gemeinsamer Baustein: `Protokollstufe`" oben):
`Ausführlich` für `sync_snapshot_unveraendert_uebersprungen` (feuert 6× pro
Zyklus unbedingt, größter Volumentreiber im Normalbetrieb) und
`sync_scope_zugriff`; `Standard` für `sync_zyklus_{start,ende}`,
`sync_event_empfangen`, `sync_snapshot_empfangen`, `sync_einkaufslisten_stand`,
`sync_snapshot_geschrieben`, `sync_icloud_beobachter_ausgeloest`,
`sync_icloud_beobachter_scope_aktualisiert`,
`sync_icloud_picker_trigger_ausgeloest`, `multipeer_peer_{verbunden,getrennt}`,
`multipeer_event_empfangen`; `Fehler` für
den Rest (u.a. `sync_ordner_zugriff_fehlgeschlagen`,
`sync_event_nicht_anwendbar`, `sync_peer_verworfen_altersgrenze`,
`sync_event_aufgegeben`).

**Bewusste Wiederverwendung von `wallClock`/`erzeugtAm` für die
Latenzmessung:** Diese Felder sind in `SyncEvent`/`SyncSnapshot` als „nur
informativ, nie für Ordnung zwischen Geräten verwendet" dokumentiert (siehe
`LamportClock`-Doku) — das gilt weiterhin für die *fachliche Korrektheit*
(Konfliktauflösung läuft ausschließlich über den Lamport-Zähler). Für eine
*Diagnose*-Messung wie hier, bei der es nur um die ungefähre beobachtete
Latenz geht (nicht um eine korrekte Ereignis-Reihenfolge), ist die
Geräteuhr hingegen genau der richtige Wert.

### Bekannte Grenzen

- Setzt hinreichend synchrone Geräteuhren voraus (üblich bei iOS/NTP, aber
  nicht garantiert) — eine falsch gehende Uhr auf einem Peer verzerrt dessen
  gemessene Latenzwerte auf den empfangenden Geräten.
- Rein lokales Diagnose-Werkzeug ohne geräteübergreifende Zusammenführung
  (siehe oben) — für einen Vergleich mehrerer Geräte müssen die Protokolle
  aktuell manuell nebeneinandergelegt werden (z.B. Teilen-Button je Gerät).

## FAQ: Warum zwei getrennte Protokolldateien statt einer gemeinsamen?

Wiederkehrende Nachfrage, weil Sync- und DB-Debug-Modus in der UI längst zu
einem gemeinsamen „Debug-Modus"-Abschnitt verschmolzen sind (siehe „Nachtrag
GitHub #84" unten) — warum dann noch zwei Log-*Dateien* statt einer?

- **Die Implementierung ist bereits gemeinsam, nur die Log-Datei nicht.**
  `SyncDebugLogger` und `DatabaseDebugLogger` sind beide nur dünne Wrapper
  (siehe „Gemeinsamer Baustein: `DebugLogWriter`" oben) um denselben
  Schreib-/Rotations-/`os.Logger`-Mechanismus, dieselbe
  `Protokollstufe`-Logik und dieselbe UI-Sektion. Es gibt also keine
  doppelte Infrastruktur mehr, die eine Zusammenlegung einsparen würde —
  diese Dopplung wurde bereits mit `DebugLogWriter` (Build 30) und der
  UI-Fusion (GitHub #84) beseitigt.
- **Getrennt sind bewusst nur die Ereignisvokabulare und die Datei selbst**,
  weil beide Mechanismen unterschiedliche Fragen zu unterschiedlichen
  Subsystemen beantworten: das Sync-Protokoll misst Zyklusdauer/Latenz des
  geräteübergreifenden Sync-Protokolls, das DB-Protokoll den
  Lease-/Lock-Ablauf des rein lokalen Micro-Lease-Verfahrens (siehe
  `docs/DATABASE_CONCURRENCY.md`). Beim gezielten Auswerten eines konkreten
  Problems (z.B. „warum synchronisiert Gerät X nicht") will man genau dieses
  eine Protokoll lesen, ohne die Zeilen des jeweils anderen Mechanismus
  manuell herausfiltern zu müssen.
- **Eine gemeinsame Datei würde neue Kosten verursachen, ohne bestehende
  Dopplung abzubauen:** entweder ein Kategorie-Präfix je Zeile zum
  nachträglichen Filtern (zusätzliche Lese-Logik) oder Verzicht auf die
  getrennte Größenrotation je Mechanismus — dann könnte ein sehr aktiver
  Mechanismus (z.B. `sync_snapshot_unveraendert_uebersprungen`, feuert 6× pro
  Zyklus) die Einträge des ruhigeren DB-Protokolls vorzeitig aus der
  Rotation verdrängen.
- **Ein historischer Unterschied bestätigt die Trennung zusätzlich:** die
  Spiegelung in einen geteilten Ordner war ausschließlich für den
  DB-Debug-Modus relevant, nie für den Sync-Debug-Modus (siehe „Abweichung
  vom DB-Debug-Modus: nur lokal, keine Spiegelung" oben bzw. „Nachtrag
  GitHub #54") — ein weiteres Indiz, dass beide Mechanismen trotz
  gemeinsamer Bausteine unterschiedliche Anforderungen an ihr jeweiliges Log
  haben.

**Fazit:** Die einzige verbliebene Dopplung liegt im Boilerplate innerhalb
von `SyncDebugLogger`/`DatabaseDebugLogger` selbst (UserDefaults-Migration,
Stufen-Cache, eigene `WiederholungsFilter`-Instanz — je Datei ca. 30–40
Zeilen), nicht in den Protokolldateien oder der UI. Eine denkbare, bisher
nicht umgesetzte Verfeinerung wäre ein gemeinsamer generischer Basistyp für
genau dieses Boilerplate; das würde aber nichts an der bewusst getrennten
Protokolldatei je Mechanismus ändern.

## Mechanismus: Datenintegrität (Reperaturlauf gegen baumelnde Referenzen)

Anders als die beiden Mechanismen oben **nicht** an einen Debug-Schalter
gekoppelt — Reparaturen an baumelnden Referenzen (siehe
`docs/DATABASE_CONCURRENCY.md` → „Nachtrag: rückwirkende Reparatur bereits
bestehender Korruption") sind selten, aber sicherheitsrelevant genug, dass sie
unabhängig von einer laufenden Debug-Sitzung nachvollziehbar bleiben sollen.

### Bausteine

- **`DatenintegritaetsLogger`:** dünner, immer aktiver Wrapper um
  `DebugLogWriter` (Kategorie `Datenintegritaet`, Datei `datenintegritaet.log`),
  ohne eigenen Schalter.
- **`DatenintegritaetsService.repariereFallsNoetig(context:)`:** läuft bei
  jedem App-Start, protokolliert jede vorgenommene Reparatur als
  Freitext-Ereignis (`reparatur`) und hält den zuletzt erzeugten Bericht
  zusätzlich in `UserDefaults` (`DatenintegritaetsService.letzterBericht`) vor,
  damit `DebuggingView` ihn ohne erneuten Lauf anzeigen kann.
- **`DebuggingView` → Sektion „Datenintegrität":** zeigt den letzten Bericht,
  Button „Jetzt erneut prüfen" (löst `repariereFallsNoetig` manuell erneut
  aus), Button „Protokoll teilen…" (Share Sheet über das vollständige,
  dauerhafte Protokoll).

### Bekannte Grenzen

- Rein lokales Diagnose-Werkzeug ohne geräteübergreifende Zusammenführung.
- Der Bericht beschreibt nur, was in der aktuellen Sitzung repariert wurde —
  keine rückwirkende Historie über App-Neuinstallationen hinweg (die
  Protokolldatei selbst bleibt aber über Neuinstallationen der App hinweg
  nicht erhalten, da sie im Dokumentenordner der App liegt).

## Weitere Mechanismen (geplant, noch nicht spezifiziert)

Noch kein konkreter Bedarf dokumentiert. Künftige Kandidaten (z.B. Debugging
für `AISuggestionService`/`ReceiptScanService`) werden hier als eigene
Abschnitte ergänzt, sobald sie gebraucht werden — jeweils als dünner Wrapper
um `DebugLogWriter`, mit eigenem Schalter und eigenen Ereignistypen.

## Umsetzungsstand (Build 30)

Alle Punkte umgesetzt und per `xcodebuild build`/`test` verifiziert:

1. `Services/DebugLogWriter.swift` (gemeinsamer Baustein): Zwei-Datei-Rotation,
   `os.Logger`-Spiegelung, Actor-basiertes asynchrones Schreiben.
2. `Services/DatabaseDebugLogger.swift` + `Views/Einstellungen/
   DatabaseDebugSettingsView.swift` als ersten Wrapper um `DebugLogWriter`,
   eingebunden in `DatabaseLeaseService` und `ShopWithMeApp` (Store-Öffnen).
   Verlinkt in `SettingsView.swift`, Export per Share Sheet.
3. Tests in `ShopWithMeTests/DebugLogWriterTests.swift` (Zeilenformat, Rotation,
   Leeren) — Schalter-Verhalten (aktiviert/deaktiviert) indirekt über die
   `istAktiv`-Prüfung in `DatabaseDebugLogger.log(_:details:)` abgedeckt.

**Noch offen:** ein Live-Test mit mehreren physischen Geräten gegen einen
tatsächlich installierten Cloud-Provider, um die geräteübergreifende Auswertung
der gespiegelten Log-Dateien im gemeinsamen DB-Ordner zu verifizieren (siehe
`docs/DATABASE_CONCURRENCY.md` → „Umsetzungsstand").

## Nachtrag (GitHub #54): Spiegelung in den gemeinsamen DB-Ordner entfernt

`DatabaseLocationService` (das oben referenzierte "Datenbank an einen anderen
Speicherort verlagern"-Feature) wurde entfernt — es gibt seit der neuen,
event-basierten Datensynchronisation (`docs/DATENSYNCHRONISATION_VERLAUF.md`)
keinen Anwendungsfall mehr, bei dem die Store-Datei selbst in einem geteilten
Ordner liegt. Die oben beschriebene Log-Spiegelung "zusätzlich im gemeinsamen
DB-Ordner" (`DatabaseDebugLogger.geteilterWriter`/`konfiguriere(geteilterOrdner:)`)
ergab nur in diesem Szenario Sinn und wurde mitentfernt. `DatabaseDebugLogger`
protokolliert seitdem ausschließlich lokal je Gerät — die
geräteübergreifende Auswertung aus dem "Noch offen"-Punkt oben ist damit
hinfällig.

**GitHub #84:** Der Dateiname trägt seither den gesetzten Gerätenamen (siehe
`DatabaseLeaseService.eigenerGeraeteNameOverride`), z.B. „Küche DB Debug.log"
statt des vorherigen generischen `db-debug.log` — ohne eigenen Override
generisch „Gerät DB Debug.log". Zusätzlich sind Sync- und DB-Debug-Modus in der
UI (`DebuggingView`) zu einem gemeinsamen „Debug-Modus"-Abschnitt mit zwei
Unteroptionen verschmolzen, statt zwei fast identischer Sektionen.
