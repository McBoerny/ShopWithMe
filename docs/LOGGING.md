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
`debug_mode_{enabled,disabled}` (Meta-Ereignis, damit beim Auswerten klar ist, ab
wann überhaupt protokolliert wurde). Micro- und Session-Lease teilen sich
dieselben Ereignistypen — unterschieden über ein `"micro"`/`"session"`-Präfix im
Detail-Text statt über eigene Ereignistypen.

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

Zweiter konkreter Mechanismus, ergänzt mit Phase 4 des
`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` (GitHub #39). Zweck: Der Plan
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
welche Funktion), `debug_mode_{enabled,disabled}`.

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
