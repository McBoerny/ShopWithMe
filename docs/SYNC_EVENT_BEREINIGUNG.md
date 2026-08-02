# ShopWithMe — Sync-Event-Bereinigung

Status: **Umgesetzt** (GitHub #89). Löst `docs/DATENSYNCHRONISATION.md`
Abschnitt 9 „Bekannte Grenzen" → „Event-Dateien werden nie gelöscht" —
`peers/{geraeteID}/events/` wuchs bisher unbegrenzt.

## Auslöser

Ein früherer Versuch, eigene Event-Dateien nach einer festen Frist zu
löschen, wurde bereits einmal zurückgenommen (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md`): Zwei Testgeräte hatten einen
Sync-Rückstand, der älter war als die gewählte Löschfrist — der erste
Aufräumlauf löschte dadurch noch nicht abgeholte `artikelAbgehakt`-Events,
die betroffenen Artikel synchronisierten danach zwischen den Geräten gar
nicht mehr.

**Analyse:** Von den fünf Bereich-A-Event-Arten haben nur zwei ein
Sicherheitsnetz im periodischen Bereich-B/C-Snapshot:

| Event | Sicherheitsnetz vorhanden? |
|---|---|
| `artikelHinzugefuegt` | Ja (`listen.json`, additiv) |
| `artikelAbgehakt` | Teilweise (neuer `KaufEintrag` über `kaeufe/` gesichert) |
| `artikelEntfernt` | Nein |
| `artikelAbgewaehlt` | Nein |
| `artikelDauerhaftEntfernt` | Nein |

Für die drei ungeschützten Löschungen gilt: löscht ein Gerät lokal per
`context.delete(...)`, ohne vorher einen `SyncTombstone` zu setzen, kann ein
Peer, der genau dieses Event verpasst, die Löschung nirgendwo sonst
nachgeliefert bekommen — der additive Bereich-A-Sicherheitsnetz-Teil
(`listen.json`) kann per Definition nur hinzufügen, nie entfernen.

## Verworfene Alternative: Konsum-Quittung pro Peer

Erwogen: jeder Peer schreibt zurück, bis zu welchem Lamport-Zähler er von
jedem anderen Peer bereits gelesen hat; eigene Events werden erst gelöscht,
wenn alle Peers quittiert haben. **Verworfen**, weil Geräte volatil sind —
kommen und gehen, können beliebig lange abwesend sein. Jede Definition von
„wie lange warten wir auf ein fehlendes Quittungs-Peer, bevor wir es
ignorieren" ist wieder nur eine Heuristik, nur eine Ebene tiefer versteckt.

## Gewählter Ansatz: Alters-Löschung + erzwungener Voll-Abgleich für lange abwesende, bereits etablierte Geräte

Zwei komplementäre Bausteine:

### 1. Zeit-basierte Löschung (`SyncExportService`)

`SyncExportService.eventAufbewahrungsfrist` (Standard 30 Tage, dieselbe
Größenordnung wie `SyncSnapshotImportService.maximalesSnapshotAlter`) —
`raeumeAlteEigeneEventDateienAufFallsFaellig()` löscht eigene Event-Dateien,
deren Datei-Änderungsdatum älter ist, höchstens einmal pro
`automatischesBereinigungsintervall` (24h, analog
`KaufEintragBereinigungService`) tatsächlich ausgeführt. Aufgerufen aus
`RootView` bei App-Start/Vordergrund-Wechsel, wie die übrigen
`automatisch…FallsFaellig`-Dienste.

Das Alters-Kriterium ist das Datei-Änderungsdatum, nicht ein Feld im
Event-Inhalt (`wallClock`) — ein Inhalts-Check würde jede Datei erst
lesen/dekodieren müssen, genau die Kosten, die der ID-Vorfilter beim Import
(`SyncImportService`) vermeidet.

### 2. `SyncAktualitaetsService` — erzwungener Voll-Abgleich statt Zusammenführen

- Jedes Gerät merkt sich lokal (`UserDefaults`, analog `LamportClock`) den
  Zeitpunkt seines letzten **erfolgreichen** Sync-Zyklus
  (`zuletztErfolgreichSynchronisiertAm`, gesetzt von
  `SyncPollingService.syncZyklus()` bei Erfolg).
- `istAusDerZeitGefallen(context:)`: Sync-Ordner aktiv, Gerät bereits
  etabliertes Mitglied (mindestens ein `SyncPeerInfo`-Eintrag —
  `istEtabliertesMitglied(context:)`), UND letzter erfolgreicher Zyklus
  liegt länger als `eventAufbewahrungsfrist` zurück.
- **Migrations-Fall:** `nil` (noch nie aufgezeichnet) gilt bewusst NICHT als
  „aus der Zeit gefallen" — sonst löste jedes bereits vor GitHub #89
  etablierte Gerät beim ersten Start nach dem Update fälschlich einen
  Voll-Abgleich aus.
- **Kein Zusammenführen-Angebot:** additive Merges können nur hinzufügen,
  nie entfernen — ein bereits etabliertes Gerät mit potenziell veralteten
  lokalen Karteileichen bekäme den aktuellen Peer-Stand additiv
  draufgepackt, die eigenen Karteileichen blieben unangetastet. Nur ein
  echter Ersatz (`SyncErsetzenService.planeErsetzenDurchPeer`, bereits
  bestehender Korruptions-Recovery-/Erstbeitritt-Mechanismus, GitHub #63)
  räumt das strukturell weg.
- **Neu beitretende Geräte sind unbetroffen** — für sie gilt unverändert der
  bestehende Zusammenführen/Ersetzen/Abbrechen-Dialog
  (`SyncOrdnerSettingsView`, `docs/DATENSYNCHRONISATION.md` Abschnitt 6), da
  bei ihnen kein „eigene Karteileichen"-Risiko besteht.

### Kritische Reihenfolge: erst exportieren, dann ersetzen

`RootView.vollAbgleichAusloesen()` führt vor `planeErsetzenDurchPeer` zuerst
einen echten `syncPollingService.syncZyklus()` aus — sichert damit eigene,
noch nicht hochgeladene lokale Änderungen aus der Abwesenheitszeit, bevor der
lokale Store beim nächsten Start geleert und neu aufgebaut wird. Schlägt
dieser Export fehl (kein Ordnerzugriff), wird **nichts** geplant — die
Prüfung greift beim nächsten Vordergrund-Wechsel erneut, statt eigene
Änderungen zu riskieren.

### Warum kein Tombstone-Mechanismus für Bereich-A-Löschungen nötig ist

Ursprünglich erwogen: `EinkaufslistenEintrag`/`KaufEintrag`-Löschungen
(Abwählen/Entfernen/Dauerhaft-Entfernen) zusätzlich per `SyncTombstone`
absichern, damit Bereich-A-Events komplett verzichtbar werden. Mit diesem
Entwurf nicht nötig: ein Gerät, das durchgehend regelmäßig synchronisiert,
liest ein neues Event typischerweise innerhalb von Minuten — die 30-Tage-
Frist bietet dafür reichlich Puffer. Nur ein Gerät, das tatsächlich so lange
abwesend war, dass es ein Event verpasst haben könnte, ist überhaupt
betroffen — und genau dieser Fall wird durch den erzwungenen Voll-Abgleich
sauber aufgefangen, ohne dass `EinkaufslistenEintrag` eine
geräteübergreifende Identität und einen eigenen Tombstone-Mechanismus
bräuchte (strukturell deutlich aufwändiger und fehleranfälliger).

## UI

`RootView` zeigt bei erkannter „aus der Zeit gefallen"-Situation einen
`confirmationDialog` („Sync-Abgleich nötig") mit den Optionen „Jetzt
abgleichen" (löst `vollAbgleichAusloesen()` aus) und „Später erinnern"
(reiner Dismiss, keine dauerhafte Stummschaltung — die Prüfung greift beim
nächsten Vordergrund-Wechsel erneut). Nach erfolgreichem Einleiten des
Voll-Abgleichs derselbe „Neustart nötig"-Hinweis wie beim bestehenden
Ersetzen-Pfad (`SyncOrdnerSettingsView`).

## Diagnose

`SyncDebugLogger`-Ereignisse: `sync_event_dateien_bereinigt` (Details:
`anzahl=N`), `sync_aus_der_zeit_gefallen_erkannt` (Details:
`zuletztErfolgreichAm=…`), `sync_voll_abgleich_eingeleitet`.

## Offene Punkte

- Exakter Schwellenwert (30 Tage) noch nicht mit echten Mehrgeräte-Daten
  verifiziert — `SyncExportService.eventAufbewahrungsfrist` ist bewusst eine
  `static var`, um ihn später ohne Code-Änderung an anderer Stelle
  nachjustieren zu können.
- Kein „Abbrechen für immer" — wiederholtes „Später erinnern" zeigt den
  Dialog bei jedem weiteren Vordergrund-Wechsel erneut, solange die
  Bedingung zutrifft. Bewusst so belassen (kein stiller Dauerzustand), aber
  noch nicht mit echten Nutzern auf Aufdringlichkeit geprüft.
