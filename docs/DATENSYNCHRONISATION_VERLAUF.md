# Datensynchronisation — Verlauf (GitHub #39, ohne Multipeer)

**Dieses Dokument ist ein chronologisches Verlaufsprotokoll** — ursprünglicher
Plan (Abschnitte 1–13), dann fortlaufend numerierte „Nachtrag"-Abschnitte für
jeden späteren Live-Test-Fund/Bugfix. Für die Frage „wie funktioniert
Datensynchronisation *heute*" ist `docs/DATENSYNCHRONISATION.md` die
maßgebliche, aktuelle Referenz — hier nachlesen für „warum ist das so",
„was wurde wann entschieden/gefixt", nicht für den aktuellen Sollzustand.
Diese Datei wurde im Zuge einer Doku-Konsolidierung umbenannt (vormals
`DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`) und um vormals an anderer Stelle
verstreute, thematisch hierher gehörende Abschnitte ergänzt: 11c (aus
`docs/ARCHITECTURE.md`), 13a (aus `docs/DATABASE_CONCURRENCY.md`) und 22 (aus
`docs/DATABASE_CONCURRENCY.md`).

**Bezug:** [Issue #39](https://github.com/McBoerny/ShopWithMe/issues/39).

**Kursänderung gegenüber einer früheren internen Bewertung** (vormals eigene
Datei `DATENSYNCHRONISATION_BEWERTUNG.md`, im Zuge der Doku-Konsolidierung
gelöscht — ihr einziger noch relevanter Inhalt ist diese Kursänderung selbst,
hier bereits vollständig wiedergegeben): jene Bewertung empfahl, den
Großteil von #39 nicht umzusetzen, weil die bestehende „ein geteilter Ordner
+ Lease"-Architektur für Mehrgeräte-Zugriff ausreiche. Nach erneuter,
ausdrücklicher Nutzervorgabe gilt das nicht mehr: Gewünscht ist die in #39
vorgeschlagene **event-basierte, dynamische Architektur** — jedes Gerät führt
seine **eigene, lokale, live genutzte Datenbank**, ein Remote-Share hält
Kopien/Events aller Teilnehmer möglichst zeitnah synchron, darüber gleichen sich
alle Mitnutzer ab. **Bewusst ausgeklammert bleibt vorerst der
MultipeerConnectivity-Kanal** (WiFi/Bluetooth-Echtzeitaustausch im Laden, siehe
Issue #49) — dieser Plan deckt ausschließlich den FileProvider-Kanal
(iCloud Drive/Synology Drive o.ä.) ab.

**Status: Phase 0 umgesetzt** (`LamportClock`, `SyncEvent`-Modell,
`SyncEventService`, lokale Aufzeichnung in allen 5 relevanten
Mutationsfunktionen). **Phase 1a umgesetzt** (Bereich-A-Event-Export):
`SyncOrdnerService` (Sync-Ordner-Bookmark, getrennt vom Datenbank-Speicherort),
Settings-Bildschirm zum Festlegen/Entfernen des Ordners samt manuellem
„Jetzt synchronisieren", `SyncExportService.exportiereNeueEvents(context:)`
schreibt un-hochgeladene Events als JSON-Dateien nach
`peers/{geraeteID}/events/`.

**Scoping-Entscheidung zu Phase 1 (Abweichung von der ursprünglichen
Formulierung unten):** Der volle Bereich-B/C/D-`export.json`-Snapshot
(Stammdaten/Historie/Lernen) war bewusst **nicht** Teil von Phase 1a, sondern
wurde auf Phase 1b verschoben, da das DTO-Design selbst eine substantielle
Entwurfsentscheidung war (siehe Abschnitt 4.2/4.2a).

**Status: Phase 1b umgesetzt** — `SyncSnapshot`-DTOs (Bereich B: `GeschaeftTyp`,
`Abteilung`, `Geschaeft`, `Artikel`, `Einkaufsliste`; Bereich C: alle
`Einkaufsvorgang`, `KaufEintrag`; Bereich D: `WarengruppenDistanz`) und
`SyncSnapshotExportService.exportiereSnapshot(context:)`, der bei jedem
manuellen „Jetzt synchronisieren" einen vollständigen `export.json` in den
eigenen Peer-Ordner schreibt (unbedingt, ohne die in Abschnitt 5.5
beschriebene Fälligkeits-/Konsolidierungslogik — die kommt mit Phase 4). Die
noch offenen Merge-Regeln für additive Zähler sind in 4.2a vorgemerkt, aber
noch nicht implementiert (Import/Merge ist Phase 2/3).

**Status: Phase 2 umgesetzt** (Bereich-A-Import): `SyncImportService` liest
Event-Dateien aus allen fremden Peer-Ordnern, wendet ``SyncKonfliktAufloesung``
(neu als echter Code implementiert, vorher nur Doku-Skizze in Abschnitt 4.4) je
(`bezugsID`, `artikelID`)-Paar an und materialisiert das Ergebnis über
dieselben Mutationsfunktionen wie lokale Aktionen. Dafür wurden die 5
Mutationsfunktionen in eine reine `…OhneEventAufzeichnung`-Variante und einen
aufzeichnenden Wrapper aufgeteilt (siehe „Wichtiger Zusatzfund" unten) und
``SyncEventService.uebernehmen(_:context:)`` ergänzt, das ein empfangenes Event
unverändert (fremde Lamport-Zähler/Geräte-ID) lokal übernimmt, statt es
fälschlich neu zu authoren.

**Wichtiger Zusatzfund beim Entwurf von Phase 2 (jetzt gelöst):** Die 5
Mutationsfunktionen riefen bisher immer `SyncEventService.aufzeichnen` auf.
Hätte der Import dieselben Funktionen direkt wiederverwendet, hätte jedes
angewendete fremde Event zusätzlich ein neues, selbst-authored Event mit der
eigenen Lamport-Uhr erzeugt — fremde Aktionen wären fälschlich diesem Gerät
zugeschrieben und beim nächsten Export dupliziert an alle Peers zurückgespiegelt
worden. Gelöst durch Aufteilung in reine Zustandsmutation + aufzeichnenden
Wrapper (siehe Code).

**Bekannte, bewusst nicht in dieser Phase gelöste Grenze:** Ein empfangenes
Event referenziert seine `Einkaufsliste`/seinen `Einkaufsvorgang`/seinen
`Artikel` nur über deren `UUID`. Bevor Phase 3 (Import Bereich B/C/D)
existiert, kann diese Referenz bei einem frisch beigetretenen Gerät noch fehlen
— das Event wird dann bewusst NICHT als bekannt markiert, sondern bei jedem
weiteren Sync-Zyklus automatisch erneut versucht, bis die Referenz (durch
Phase 3 oder eine direkt lokal ausgeführte Aktion) existiert. Ein Nebeneffekt:
ein bereits anwendbares, aber schwächeres Event kann übergangsweise vor einem
noch nicht anwendbaren stärkeren Event materialisiert werden; das System
konvergiert danach selbstständig auf den korrekten Endzustand (die
Mutationsfunktionen sind idempotent/selbstkorrigierend), siehe
`SyncImportService`-Doku-Kommentar im Code für Details. **Ohne Phase 3 ist
Phase 2 also nur für Entitäten korrekt, die auf beiden Geräten bereits vor dem
Sync existierten** (z.B. weil sie schon vor dem Verbinden des Sync-Ordners lokal
angelegt wurden) — für den vollständigen Mehrgeräte-Fall braucht es beide
Phasen zusammen.

**Status: Phase 3a umgesetzt** (Bereich-B-Import: Stammdaten) —
`SyncSnapshotImportService` liest `export.json` aus allen fremden Peer-Ordnern
und merged `GeschaeftTyp`/`Abteilung`/`Geschaeft`/`Artikel`/
`Einkaufsliste` dependency-geordnet in den lokalen Bestand, unter
Wiederverwendung der in `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2
hergeleiteten Matching-Bausteine (`GeschaeftTyp.mitNamen`,
`GeschaeftErkennungService.istGleicherOrt`, Namensabgleich für
`Abteilung`/`Artikel`). Grundprinzip aller Merge-Regeln: **nie
destruktiv** — ein bestehender lokaler Wert wird nie durch einen abweichenden
Remote-Wert überschrieben, nur fehlende Werte werden ergänzt und Mengen
(Abteilungen, Typen, ignorierte Artikel, alternative Namen) vereinigt. Die
additive Merge-Regel für `Geschaeft.anzahlEinkaufsvorgaenge` (Abschnitt 4.2a)
ist jetzt über ``SyncPeerZaehlerStand`` (Zähler-Zuwachs seit dem zuletzt
bekannten Stand jedes Peers) tatsächlich implementiert, `umbauVerdacht` per
ODER-Verknüpfung, `unauffaelligeEinkaeufeInFolge` bewusst weiterhin
ungemergt.

**Neu ergänzt: `SyncEntitaetsAlias`.** Da `Artikel` (anders als
`Einkaufsliste`/`Einkaufsvorgang`) über Namensabgleich statt über die ID
gematcht wird, aber trotzdem von Bereich-A-`SyncEvent`s über die
ursprüngliche Peer-ID referenziert wird, merkt sich diese neue,
additive Tabelle "fremde ID X entspricht lokaler ID Y", sobald ein
Namens-Match zwei unterschiedliche UUIDs zusammenführt.
``SyncImportService``s `artikel(mitID:)`-Auflösung (Phase 2, rückwirkend
ergänzt) schlägt hier zuerst nach, bevor sie direkt per ID sucht — ohne diesen
Fallback wären künftige Events dieses Peers für den betroffenen Artikel
dauerhaft ins Leere gelaufen.

**Revidiert (GitHub #52-Nachfolgefund):** `Einkaufsliste` wurde zunächst
bewusst NICHT namensbasiert gematcht (anders als in der ursprünglichen
Bootstrap-Merge-Tabelle empfohlen), sondern wie `Einkaufsvorgang` per ID — mit
der Befürchtung, ein Namens-Match könnte zwei tatsächlich unterschiedliche
Listen fälschlich zusammenführen. In der Praxis war das Gegenteil der
Regelfall: JEDES Gerät legt beim allerersten Start automatisch eine eigene
Standardliste namens „Einkaufsliste" an (`Einkaufsliste.standard(context:)`),
bereits bevor je synchronisiert wurde — bei ID-basiertem Matching entstand
dadurch bei jedem Beitritt zu einem bestehenden Sync-Ordner eine zweite, für
den Nutzer unsichtbare Dublette, auf der die tatsächlich synchronisierten
Artikel landeten, während die UI weiterhin die eigene (fast leere) Liste
zeigte. `Einkaufsliste` wird jetzt wie `Artikel` namensbasiert gematcht, mit
demselben `SyncEntitaetsAlias`-Mechanismus für spätere Bereich-A-Events.

**Status: Phase 3b umgesetzt** (Historie/Lernen) — `SyncSnapshotImportService`
merged jetzt auch `Einkaufsvorgang` (ID-basiert wie `Einkaufsliste`, damit
Bereich-A-Events ihn weiterhin auflösen können; ein bereits lokal
abgeschlossener Einkauf wird nie wieder geöffnet, nur eine fehlende `endZeit`
nachgetragen — bewusst ohne `abschliessen()` aufzurufen, sonst würde
`Geschaeft.anzahlEinkaufsvorgaenge` zusätzlich zur bereits laufenden additiven
Zähler-Merge-Regel ein zweites Mal erhöht), `KaufEintrag` (Union nach `id`,
unveränderliche Historie) und `WarengruppenDistanz` (einfacher Mittelwert bei
bereits vorhandenem Eintrag, sonst Übernahme — vereinfacht ggü. der im
#39-Vorschlag skizzierten besuchsgewichteten Mittelung, da der Snapshot keine
Besuchszahl je Eintrag mitführt). Die Zuordnungstabellen
(`GeschaeftTyp`/`Abteilung`/`Geschaeft`/`Artikel`/`Einkaufsliste`) aus
Phase 3a werden dafür direkt wiederverwendet. **Damit ist Phase 3 (Import
Bereich B/C/D) vollständig umgesetzt.**

**Status: Phase 5 umgesetzt** (Gruppen-Setup-UX, siehe Abschnitt 6) —
`SyncOrdnerSettingsView.ordnerFestlegen(_:)` löst direkt beim Verknüpfen eines
Ordners einen ersten vollständigen Sync-Zyklus aus, statt dass danach noch
manuell auf „Jetzt synchronisieren" getippt werden muss. Der eigentliche
Bootstrap-Merge war durch Phase 3 bereits abgedeckt.

**Status: Phase 6 umgesetzt** (GitHub #48, Überkauf-Hinweis) — siehe
Abschnitt 8 unten für Details.

**Status: Phase 4 umgesetzt** (Konsolidierung + adaptives Polling, Abschnitt
5.4/5.5) — mit einer per Nutzerentscheidung abweichenden, einfacheren
Intervall-Logik als ursprünglich skizziert:

- Neuer `SyncPollingService` führt einen vollständigen Sync-Zyklus (Import +
  Export für alle vier Bereiche) automatisch aus, solange die App im
  Vordergrund ist — sofort beim App-Start bzw. bei Rückkehr aus dem
  Hintergrund, danach alle 5 Sekunden, solange `EinkaufslisteView` sichtbar
  ist (aktiv gemeinsam eingekauft wird), sonst alle 60 Sekunden. Abweichung
  von der ursprünglichen 5s/30s-Tabelle: kein separates
  Hintergrund-Intervall, da ein reiner In-App-`Task`-Loop ohnehin pausiert,
  sobald iOS die App suspendiert (siehe „Bekannte Grenze" unten) — die
  Unterscheidung wäre wirkungslos gewesen.
- **Kein Fehler-Backoff umgesetzt** (die im Plan skizzierte Eskalation bis
  120s bei wiederholten Fehlern) — alle Sync-Funktionen sind heute
  best-effort mit stillem Fehlschlagen (`try?`) ohne auswertbares
  Erfolgs-/Fehlersignal; ein Backoff hätte zunächst eine Erfolgs-/Fehler-
  Rückmeldung aus jeder Sync-Funktion gebraucht. Bei Bedarf nachrüstbar.
- **Konsolidierung (Abschnitt 5.5, „wann einen vollen Snapshot schreiben")
  nicht separat umgesetzt** — `SyncSnapshotExportService` schreibt (wie seit
  Phase 1b) bei jedem Zyklus unbedingt einen vollen `export.json`. Bei 60s-
  bzw. 5s-Takt ist das schreibhäufiger als die ursprünglich elizierte
  24h/50-Event-Schwelle, aber unkritisch für den heutigen Umfang (kleine
  JSON-Dateien, kein Löschen alter Event-Dateien nötig, da noch keins
  angelegt wird).
- **Bekannte, bewusst nicht gelöste Grenze:** Ein In-App-`Task`-Loop läuft
  nur, während die App im Vordergrund ist — iOS pausiert ihn beim Wechsel in
  den Hintergrund (siehe `ShopWithMeApp`, das `starten`/`stoppen` an
  `scenePhase` koppelt). Echte Synchronisation bei gesperrtem Gerät oder
  schon vor dem Öffnen der App bräuchte das `BackgroundTasks`-Framework mit
  eigenen Entitlements und System-Throttling — nicht Teil dieser Phase.
- **Offene Alt-Datei-Frage:** Event-Dateien in `peers/{geraeteID}/events/`
  werden nie gelöscht — wächst über Zeit unbegrenzt. War in der
  ursprünglichen Planung Teil der jetzt nicht umgesetzten Konsolidierung
  (Löschen nach 2h-Sicherheitsfenster). Für den aktuellen Umfang unkritisch
  (kleine JSON-Dateien), aber ein späterer Aufräum-Mechanismus bleibt sinnvoll.

**Ergänzung: `SyncDebugLogger` (Datengrundlage für spätere Optimierung).**
Damit die oben getroffenen Annahmen (5s/60s-Intervalle, kein Backoff, keine
Konsolidierung) später mit echten Praxisdaten statt Schätzungen überprüft
werden können, protokolliert ein neuer, optionaler Debug-Modus (siehe
`docs/LOGGING.md` → „Mechanismus: Datensynchronisation") lokal: die
tatsächlich beobachtete Latenz empfangener Events/Snapshots (Alter beim
Eintreffen — genau der Wert, den die „Realistische Erwartung ohne Multipeer"
oben bisher nur schätzt), die Dauer jedes Sync-Zyklus und
Ordner-Zugriffsfehler (bisher unsichtbar, da alle Sync-Funktionen mit `try?`
best-effort arbeiten — Vorstufe für einen künftigen Fehler-Backoff). Standardmäßig
aus, Einstellungen → „Sync-Debug-Modus". Als Nebeneffekt nutzt
`SyncOrdnerSettingsView` jetzt denselben `SyncPollingService.syncZyklus()`
wie das automatische Polling, statt die vier Sync-Aufrufe zu duplizieren —
die Protokollierung passiert dadurch an einer einzigen Stelle für beide
Auslöser (manuell und automatisch).

---

## 1. Architekturüberblick

```
Gerät A                                    Gerät B
┌──────────────────┐                      ┌──────────────────┐
│ Lokale SwiftData- │                      │ Lokale SwiftData- │
│ DB (live, wie     │                      │ DB (live, wie     │
│ heute)            │                      │ heute)            │
│                    │                      │                    │
│ + SyncEvent-Log    │                      │ + SyncEvent-Log    │
└─────────┬──────────┘                      └─────────┬──────────┘
          │ schreibt nur                              │ schreibt nur
          │ eigenen Peer-Ordner                        │ eigenen Peer-Ordner
          ▼                                            ▼
┌──────────────────────────────────────────────────────────────┐
│  Geteilter Ordner (iCloud Drive / Synology Drive, vom Nutzer  │
│  gewählt)                                                      │
│  peers/{geräteA}/export.json + events/*.json                  │
│  peers/{geräteB}/export.json + events/*.json                  │
└──────────────────────────────────────────────────────────────┘
```

Jedes Gerät liest **alle** Peer-Ordner (auch die eigenen, zur Kontrolle), schreibt
aber **ausschließlich** in seinen eigenen — dadurch entsteht strukturell nie ein
Schreibkonflikt zwischen zwei Geräten (kein Lease-Mechanismus für diesen Teil
nötig, anders als beim heutigen „eine gemeinsame Store-Datei"-Modell).

## 2. Wichtigste Anpassung ggü. dem Original-Vorschlag: SwiftData bleibt

Der ursprüngliche #39-Vorschlag sah GRDB (rohes SQLite) mit einem separaten
Event-Log **und** separaten materialisierten Zustandstabellen vor. Für ShopWithMe
wird das angepasst:

- **Kein Wechsel der Persistenzschicht.** Die bestehenden SwiftData-Modelle
  (`Einkaufsliste`, `Artikel`, `Geschaeft`, `KaufEintrag`, …) bleiben unverändert
  die „materialisierte" Wahrheit, aus der die UI liest (`@Query` usw.) — kein
  kompletter Rewrite der Modellschicht, kein neues Persistenz-Framework.
- **`SyncEvent` ist ein zusätzliches, additives SwiftData-Modell**, keine
  Ablösung. Bestehende Mutations-Funktionen (`Einkaufsliste.artikelHinzufuegen`,
  `Einkaufsvorgang.artikelAbhaken`, …) bleiben die einzige Stelle, an der Daten
  verändert werden — sie bekommen zusätzlich einen Aufruf, der ein `SyncEvent`
  erzeugt. Damit bleibt exakt eine Code-Stelle pro Aktion verantwortlich (keine
  Duplizierung zwischen „lokaler Pfad" und „Event-Anwendungs-Pfad" — siehe
  Abschnitt 4.3).
- **Konsequenz für `DatabaseLocationService`/`DatabaseLeaseService`:** Für den
  Mehrbenutzer-Fall wird `DatabaseLocationService` durch dieses neue Verfahren
  **abgelöst** — die lokale Datenbank bleibt immer am Standardpfad, der bisherige
  „aktiven Speicherort auf einen geteilten Ordner verschieben"-Weg entfällt für
  „gemeinsam einkaufen". Der verbliebene Einzelnutzer-Fall (persönlicher
  Ordner-Umzug ohne Teilen) wurde mangels eigenständigem Bedarf ebenfalls entfernt
  (GitHub #54) — `DatabaseLocationService` existiert nicht mehr.
  `DatabaseLeaseService` bleibt unverändert bestehen, dient aber nur noch der
  Schreibkoordination innerhalb eines einzelnen Geräts.

## 3. Geräte-Identität und Lamport-Clock

- **NodeId:** `DatabaseLeaseService.geraeteID` wird wiederverwendet (bereits
  vorhandene, über App-Starts stabile UUID pro Gerät) — keine zweite
  Geräte-Identität nötig.
- **Neuer `LamportClock`-Service** (analog zum Vorschlag in #39, in Swift statt
  der dortigen Skizze):

```swift
enum LamportClock {
    private static let schluessel = "lamportZaehler"

    static func naechsterZaehler() -> UInt64 {
        let aktuell = (UserDefaults.standard.object(forKey: schluessel) as? UInt64) ?? 0
        let naechster = aktuell + 1
        UserDefaults.standard.set(naechster, forKey: schluessel)
        return naechster
    }

    static func beiEmpfang(fremderZaehler: UInt64) {
        let aktuell = (UserDefaults.standard.object(forKey: schluessel) as? UInt64) ?? 0
        UserDefaults.standard.set(max(aktuell, fremderZaehler) + 1, forKey: schluessel)
    }
}
```

## 4. Event-Log

### 4.1 Neues Modell `SyncEvent`

```swift
@Model
final class SyncEvent {
    var id: UUID
    var art: String                 // z.B. "artikelAbgehakt", "artikelHinzugefuegt"
    var nutzlast: Data               // JSON-codierte Detaildaten der Aktion
    var lamportZaehler: UInt64
    var lamportGeraeteID: String
    var autorGeraeteID: String       // = lamportGeraeteID, aber semantisch getrennt
    var wallClock: Date
    var hochgeladen: Bool            // schon in den eigenen Peer-Ordner exportiert?
    ...
}
```

`nutzlast` referenziert Entitäten über ihre app-eigene `UUID` (`Artikel.id`,
`Einkaufsliste.id`, …) — nie über `persistentModelID` (siehe die in dieser Session
bereits einmal gefundene Falle: `persistentModelID`-Strings sind vor dem
Speichern nicht eindeutig).

### 4.2 Welche Aktionen erzeugen ein Event (Umfang v1)

Empfehlung: nicht von Anfang an jede einzelne Modelländerung synchronisieren,
sondern nach Dringlichkeit/Häufigkeit gestaffelt (Tabelle unten) — Struktur
angelehnt an die „Datenbereiche"-Tabelle aus dem #39-Vorschlag:

| Bereich | Inhalt | Sync-Frequenz | Konfliktregel |
|---|---|---|---|
| **A — zeitkritisch** | `Einkaufsliste`-Mitgliedschaft (hinzufügen/entfernen/Menge), Abhaken/Abwählen (`Einkaufsvorgang`) | Bei jedem Sync-Zyklus (Abschnitt 5.3) | CRDT-Regeln (Abschnitt 4.4) |
| **B — Stammdaten** | `Artikel`, `Abteilung`, `GeschaeftTyp`, `Geschaeft` (inkl. `erkennungsradius`, `ausgeschlosseneAbteilungen`, `IgnorierterArtikel` — siehe Entscheidungen unten), `Einkaufsliste` (nur `id`/`name`, siehe 4.2a) | Export bei jedem Sync-Zyklus, weniger zeitkritisch | Namens-/Koordinaten-Matching (bereits vorhandene Bausteine, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2) |
| **C — Historie** | `KaufEintrag`, **alle** `Einkaufsvorgang` (auch laufende, siehe 4.2a) | Export, seltener (z.B. nur bei Konsolidierung) | Union nach `id`, nie Konflikt (jeder Kauf ein abgeschlossenes Ereignis) |
| **D — Lernen** | `WarengruppenDistanz` | Export, selten | Gewichteter Mittelwert (siehe #39-Vorschlag §5.2 „mergeDistanzMatrix", direkt übertragbar) |
| **Nicht synchronisiert** | `DebugEinstellungen`, lokale UI-Zustände, `IgnorierterGeschaeftsVorschlag` (siehe Entscheidungen unten) | — | — |

**Entscheidungen (Nutzer, nach Rückfrage):**
- `Geschaeft.erkennungsradius` (GitHub #41) → **Bereich B**, gehört zum Geschäft.
- `Geschaeft.anzahlEinkaufsvorgaenge`/`umbauVerdacht`/`unauffaelligeEinkaeufeInFolge` →
  Bereich B, aber **additiv gemergt**, nicht per Last-Write-Wins überschrieben (siehe
  4.2a).
- `IgnorierterArtikel` (dauerhaft ignorierte Belegscan-Positionen, GitHub #19) →
  **Bereich B**, wird als Eigenschaft/Ausnahme des Geschäfts betrachtet („obwohl es
  ein Lebensmittelladen ist, gibt es dort kein XY").
- `IgnorierterGeschaeftsVorschlag` (weggewischter Standort-Vorschlag,
  `GeschaeftErkennungService`) → **nicht synchronisiert** — meine Einschätzung
  (nicht explizit vom Nutzer bestätigt): eine reine Geräte-/GPS-Rauschen-Petitesse,
  kein Fakt über das Geschäft. Bei Bedarf revidierbar.
- Format-Versionsfeld im Bereich-B/C/D-Snapshot: **ja** (`SyncSnapshot.formatVersion`),
  „universell sinnvoll". Für Bereich-A-Event-Dateien nicht zusätzlich nachgerüstet —
  dort übernimmt bereits der String-statt-Enum-Rohwert von `SyncEventArt` denselben
  Zweck (unbekannte künftige Event-Arten landen auf `nil` statt abzustürzen).

### 4.2a Beim Entwurf des Snapshots (Phase 1b) entdeckte Ergänzungen

- **`Einkaufsliste`/`Einkaufsvorgang`-Existenz-Lücke:** Bereich-A-`SyncEvent`s
  referenzieren eine `Einkaufsliste` bzw. einen `Einkaufsvorgang` nur über deren
  `UUID` (`bezugsID`) — beide Entitätstypen selbst waren in der ursprünglichen
  Bereich-Tabelle aber gar nicht als synchronisiert vorgesehen. Ohne eigenen
  Snapshot-Eintrag könnte ein Peer-Gerät ein empfangenes Bereich-A-Event (Phase 2)
  nicht anwenden, dessen `bezugsID` auf eine ihm noch unbekannte Liste/einen noch
  unbekannten, laufenden Einkauf verweist. Lösung: `Einkaufsliste` (nur `id`/`name`)
  und **alle** `Einkaufsvorgang` (nicht nur abgeschlossene, `endZeit` bleibt
  optional) sind jetzt Teil des Snapshots.
- **Additive Zähler auf `Geschaeft` brauchen eine eigene Merge-Regel statt
  Last-Write-Wins** (relevant für Phase 3, hier nur vorgemerkt, damit es nicht
  vergessen wird): `anzahlEinkaufsvorgaenge` wird unabhängig von der eigentlichen
  Kaufhistorie geführt und manuell zurücksetzbar (GitHub #30) — ein naives
  Überschreiben beim Sync würde Besuche verlieren, die zwischen zwei Sync-Zyklen auf
  einem Gerät entstanden sind. Braucht eine Delta-Merge-Regel (Summe der Zuwächse
  seit dem zuletzt bekannten Stand jedes Peers), keine einfache Addition der
  Rohwerte (sonst Doppelzählung bei wiederholtem Sync). `umbauVerdacht` eignet sich
  für eine einfache ODER-Verknüpfung. `unauffaelligeEinkaeufeInFolge` ist trotz
  Zähler-Charakter **kein** additiver Wert — er zählt unauffällige Einkäufe *in
  Folge*; zwei Geräte-Werte zu addieren würde eine so nie stattgefundene Serie
  vortäuschen. Vorschlag für Phase 3: diesen einen Wert bewusst gerätelokal
  berechnet lassen statt zu mergen.

### 4.3 Wo Events erzeugt werden

An denselben Stellen, die heute schon die einzige Mutations-Quelle sind — z.B.:

```swift
func artikelAbhaken(_ artikel: Artikel, context: ModelContext) {
    // ... bestehende Logik unverändert ...
    context.insert(eintrag)
    eintrag.einkaufsvorgang = self
    SyncEventService.aufzeichnen(.artikelAbgehakt(artikelID: artikel.id, ...), context: context)
}
```

`SyncEventService.aufzeichnen(_:context:)` kapselt Lamport-Zähler-Vergabe +
`SyncEvent`-Erzeugung an einer Stelle — Bereich-A-Aktionen (Tabelle 4.2) rufen
das jeweils direkt auf; Bereich B/C/D werden stattdessen bei der Export-Erstellung
(Abschnitt 5.2) aus dem aktuellen Modellzustand abgeleitet, statt für jede
einzelne Änderung ein Event zu erzeugen (unnötig für seltener wichtige Daten).

**Wartungsrisiko, offen benannt:** Jede künftige neue Aktion auf einer
Bereich-A-Entität muss daran denken, `SyncEventService.aufzeichnen` aufzurufen —
sonst sieht kein anderes Gerät diese Änderung. Empfehlung: ein Test pro
Bereich-A-Mutationsfunktion, der genau das prüft (analog zu den bestehenden
Dedupe-Tests), damit ein Vergessen beim nächsten Feature auffällt statt sich
still einzuschleichen.

### 4.4 Konfliktregeln (aus #39 §4.1 übernommen)

```swift
enum SyncKonfliktAufloesung {
    static func gewinnt(_ a: SyncEvent, ueber b: SyncEvent) -> Bool {
        if a.art == "artikelDauerhaftEntfernt" { return true }
        if b.art == "artikelDauerhaftEntfernt" { return false }
        if a.art == "artikelAbgewaehlt", b.art == "artikelAbgehakt" { return true }
        if b.art == "artikelAbgewaehlt", a.art == "artikelAbgehakt" { return false }
        return a.lamportZaehler > b.lamportZaehler
    }
}
```

„Entfernen schlägt alles", „Abwählen schlägt Abhaken" (lieber ein Artikel
versehentlich wieder offen als ein übersehener Doppelkauf) — identisch zur
#39-Vorlage.

## 5. Sync-Kanal

### 5.1 Ordnerstruktur im geteilten Ordner

```
{geteilter Ordner}/
  peers/
    {geraeteID-A}/
      export.json           ← konsolidierter Bereich-B/C/D-Stand
      events/
        0001_{uuid}.json     ← einzelne Bereich-A-Events seit letztem Export
        0002_{uuid}.json
    {geraeteID-B}/
      ...
```

### 5.2 Export (eigener Anteil hochladen)

Pro Sync-Zyklus: alle lokalen, noch nicht hochgeladenen `SyncEvent`s
(Bereich A) als einzelne JSON-Dateien in `peers/{eigeneGeraeteID}/events/`
schreiben; bei Fälligkeit (siehe Konsolidierung, Abschnitt 5.5) zusätzlich einen
vollständigen `export.json` (Bereich B/C/D, aus dem aktuellen lokalen Zustand
abgeleitet) schreiben.

### 5.3 Import (fremde Anteile lesen und anwenden)

Pro bekanntem Peer-Ordner (außer dem eigenen): neue Event-Dateien seit dem
gespeicherten Cursor lesen, pro Event `LamportClock.beiEmpfang(...)` aufrufen,
dann **dieselbe bestehende Mutations-Funktion aufrufen, die auch lokale Aktionen
auslöst** (z.B. `Einkaufsvorgang.artikelAbhaken`) — keine separate
„Event-Interpretations-Logik", die von der echten Programmlogik abweichen könnte.
Vor dem Anwenden: Konfliktprüfung (Abschnitt 4.4) gegen bereits vorhandene
lokale/andere-Peer-Events derselben Entität.

### 5.4 Adaptive Polling (aus #39 §6.3 übernommen)

| Zustand | Intervall |
|---|---|
| `EinkaufenView` aktiv sichtbar | 5s |
| App im Hintergrund | 30s |
| Nach Fehler | exponentiell bis 120s, sofort zurück auf 5s bei Erfolg |

### 5.5 Konsolidierung

Wenn kein aktiver Einkauf läuft und (kein Export vorhanden ODER letzter Export
älter als 24h ODER mehr als 50 ungesicherte Events): vollständigen `export.json`
schreiben, dann alte Event-Dateien nach einem Sicherheitsfenster (2h, damit
andere Geräte sie vorher lesen konnten) löschen — identisch zum #39-Vorschlag.

## 6. Gruppen-Setup (vereinfacht ggü. #39, kein Trusted-Peers-Modell nötig)

1. Person A wählt/erstellt einen geteilten Ordner (iCloud-/Synology-Freigabe).
2. Person B verknüpft in ihren Einstellungen denselben Ordner (`.fileImporter`,
   analog zum bisherigen `SyncOrdnerService`-Muster).
3. **Bootstrap:** Beim ersten Verknüpfen eines Ordners mit bereits vorhandenen
   Peer-Daten wird der komplette fremde Bestand gelesen und mit dem eigenen
   lokalen Bestand gemergt (identischer Algorithmus wie in
   `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2 hergeleitet — der bleibt
   also nicht ungenutzt, sondern wird hier für den einmaligen Bootstrap-Moment
   gebraucht). Ab dann läuft der laufende Betrieb über Events (Abschnitt 5).
4. Kein separates Vertrauens-/Freigabemodell in der App nötig — Zugriff auf den
   Ordner selbst (vom Betriebssystem/Cloud-Anbieter verwaltet) ist das
   Vertrauensmerkmal.

## 7. Realistische Erwartung ohne Multipeer

Ohne den bewusst ausgeklammerten Bluetooth/WiFi-Direct-Kanal ist die tatsächliche
Latenz durch die Sync-Geschwindigkeit des Cloud-Anbieters begrenzt — laut
`docs/DATABASE_CONCURRENCY.md` grob 5–30s bei iCloud Drive, 1–10s bei Synology
Drive. „Möglichst zeitnah" heißt hier: so schnell wie adaptives Polling plus
Cloud-Anbieter es zulassen, nicht Sekundenbruchteile. Multipeer (Issue #49)
bliebe der Weg, das auf <1s zu drücken — hier bewusst nicht Teil dieses Plans,
ließe sich aber später ergänzen, ohne diese Architektur zu verwerfen (Multipeer
würde denselben `SyncEvent`-Typ nur zusätzlich sofort an verbundene Peers
spiegeln, statt auf den nächsten Polling-Zyklus zu warten).

## 8. Verhältnis zu #48 und #50

- **#48 (Überkauf-Hinweis) — umgesetzt (Phase 6):** wie vorhergesagt einfacher
  als ursprünglich geplant. `Einkaufsvorgang.artikelAbhaken(_:context:)`
  liefert jetzt ein `AbhakErgebnis` (`.abgehakt` oder
  `.bereitsAbgehaktVon(geraeteID:)`); die Geräte-ID kommt aus
  `SyncEventService.aktuellerGewinner(bezugsID:artikelID:context:)` (derselben
  Konfliktauflösung wie Phase 2) statt aus einem neuen
  `KaufEintrag.abgehaktVonGeraet`-Feld. Einzige Ergänzung ggü. der
  ursprünglichen Einschätzung: `SyncEvent.autorGeraeteID` ist nur eine UUID,
  für einen lesbaren Namen kam ein neues, kleines `SyncPeerInfo`-Modell dazu
  (peerGeraeteID → geraeteName, gefüllt aus dem neuen `SyncSnapshot.geraeteName`-Feld
  bei jedem Bereich-B-Import) — das war in der ursprünglichen Einschätzung nicht
  bedacht. `EinkaufenView` zeigt bei Überkauf einen kurzen, selbst
  ausblendenden Hinweis („Bereits von {Gerätename} abgehakt“ bzw. neutral
  „Bereits abgehakt“, falls Name/Gerät nicht auflösbar) statt eines
  Bestätigungsdialogs (YAGNI, wie im ursprünglichen Issue #48 vorgeschlagen).
- **#50 (Ersetzen/Merge beim Beitritt):** wird zum Bootstrap-Baustein aus
  Abschnitt 6 — nicht mehr die tragende Architektur für laufenden Betrieb (das
  übernehmen jetzt die Events), aber weiterhin exakt der Mechanismus für den
  einmaligen ersten Verknüpfungsmoment.

## 9. Risiken

- **Umfang:** Dies ist die mit Abstand größte Änderung dieser Session — realistisch
  mehrere Wochen Arbeit, nicht Tage, selbst mit den in Abschnitt 2 beschriebenen
  Vereinfachungen (SwiftData statt GRDB).
- **Event/Modell-Konsistenz-Pflege** (Abschnitt 4.3) ist eine dauerhafte
  Zusatzlast für jede künftige Funktion, die Bereich-A-Daten berührt.
- **Testaufwand:** jeder Sync-Schritt braucht Tests mit zwei simulierten Geräten
  (zwei In-Memory-`ModelContainer` + manuell getriebenem Sync-Zyklus statt echtem
  Dateisystem-Polling in Unit-Tests).
- **Kein echter Live-Test bisher** — wie schon in der #50-Bewertung notiert, sollte
  ein Test mit echten Geräten/echtem Cloud-Anbieter früh im Umsetzungsprozess
  erfolgen, nicht erst am Ende.

## 10. Phasenplan

1. **Phase 0 — Grundgerüst:** `LamportClock`, `SyncEvent`-Modell,
   `SyncEventService.aufzeichnen(_:context:)`, noch ohne Export/Import — nur
   lokal Events mitschreiben und in Tests prüfen, dass sie korrekt entstehen.
2. **Phase 1 — Export:** eigene Events + periodischer `export.json` in den
   Peer-Ordner schreiben (nur schreiben, noch nicht lesen).
   - **1a (umgesetzt):** Sync-Ordner-Auswahl (`SyncOrdnerService`) +
     Bereich-A-Event-Export (`SyncExportService`).
   - **1b (umgesetzt):** Bereich-B/C/D-Snapshot (`SyncSnapshot`,
     `SyncSnapshotExportService`) aus dem aktuellen Modellzustand abgeleitet und
     als `export.json` geschrieben.
3. **Phase 2 (umgesetzt) — Import Bereich A:** fremde Events lesen,
   Konfliktregeln (4.4, jetzt `SyncKonfliktAufloesung`) anwenden, über
   bestehende (nicht-aufzeichnende) Mutations-Funktionen lokal einspielen
   (`SyncImportService`).
4. **Phase 3 (umgesetzt) — Import Bereich B/C/D:** Stammdaten-/Historien-/
   Lern-Merge beim Einlesen fremder `export.json`-Dateien.
   - **3a (umgesetzt):** Stammdaten (`GeschaeftTyp`, `Abteilung`,
     `Geschaeft`, `Artikel`, `Einkaufsliste`) via `SyncSnapshotImportService` +
     `SyncEntitaetsAlias` (fremde↔lokale ID bei Namens-Matches).
   - **3b (umgesetzt):** Historie/Lernen (`Einkaufsvorgang` ID-basiert,
     `KaufEintrag` als Union nach `id`, `WarengruppenDistanz` gemittelt).
5. **Phase 4 (umgesetzt, vereinfacht) — Konsolidierung + adaptives Polling**
   (Abschnitt 5.4/5.5): `SyncPollingService` (5s aktiv einkaufend / 60s
   ruhend, nur im Vordergrund) — ohne Fehler-Backoff und ohne separate
   Konsolidierungslogik, siehe Details oben.
6. **Phase 5 (umgesetzt) — Gruppen-Setup-UX** (Abschnitt 6): der
   Bootstrap-Merge-Teil war durch Phase 3 bereits abgedeckt (dieselbe
   Merge-Logik läuft unabhängig davon, ob ein Peer-Ordner beim Verbinden schon
   Daten enthält oder nicht); ergänzt wurde nur noch, dass
   `SyncOrdnerSettingsView.ordnerFestlegen(_:)` direkt beim Verknüpfen eines
   Ordners automatisch einen ersten Sync-Zyklus auslöst (Import + Export für
   alle vier Bereiche), statt dass die Person danach erst manuell auf
   „Jetzt synchronisieren" tippen muss.
7. **Phase 6 (umgesetzt) — #48 auf Basis echter Events**: `AbhakErgebnis`,
   `SyncEventService.aktuellerGewinner`, `SyncPeerInfo` (Geräte-Namen),
   nicht-blockierender Hinweis in `EinkaufenView`.
8. **Phase 7 (separates Issue #49, weiterhin an Bedingungen geknüpft):**
   Multipeer als zusätzlicher Beschleunigungs-Kanal, falls nach Phase 0–6 im
   echten Gebrauch tatsächlich benötigt.

## 11. Architektur-Revision „Alternative A" (nach Live-Test mit zwei echten Geräten)

Ein realer Zwei-Geräte-Test nach Abschluss von Phase 0–6 (GitHub #52,
zusammen mit dessen ursprünglicher Fassung "Erst-Sync funktioniert nicht")
deckte zwei strukturelle Lücken auf, die kein reiner Bugfix, sondern eine
bewusste Architekturentscheidung nötig machten:

1. **Gelöschte Bereich-B-Entitäten kamen zurück.** Der additive Bereich-B-Merge
   ("nie destruktiv", Abschnitt 5.1) kannte keine Löschsemantik — löschte ein
   Gerät ein `Geschaeft`/`Artikel`/`Abteilung`/`Einkaufsliste`, brachte
   jeder Peer, der es noch in seinem eigenen Snapshot führte, es beim
   nächsten Sync unwissentlich zurück.
2. **Bereich A (Events) hatte kein Sicherheitsnetz.** Anders als Bereich B
   (jederzeit aus dem vollständigen Snapshot wiederherstellbar) trug der
   `EinkaufslisteSnapshot` nur `id`/`name`, nie die tatsächliche
   Mitgliedschaft. Ein Peer, der ein `artikelHinzugefuegt`-Event verpasste
   (oder dessen Liste erst nachträglich per Namensmatching aliasiert wurde,
   siehe #52-Nachfolgefund), hatte **keine** Möglichkeit, den fehlenden Stand
   je nachzuholen — die ursprünglich für Bereich A geplante
   Event-Konsolidierung (Abschnitt 5.5, nie umgesetzt) hätte dieselbe Lücke
   sogar aktiv verschärft, da geprunte Events ohne Snapshot-Fallback
   unwiederbringlich verloren wären.

**Entscheidung (zwei Alternativen abgewogen, siehe Session-Verlauf):**
„Alternative A" gewählt — Bereich A bekommt strukturell dasselbe
Sicherheitsnetz wie Bereich B, statt die Lücken einzeln zu patchen.
Keine Rückwärtskompatibilität zu bereits im Feld befindlichen
`export.json`-Dateien nötig (Projekt ohne feste Nutzerbasis) —
`SyncSnapshot.aktuelleFormatVersion` auf 2 erhöht, Sync-Ordner für den
nächsten Testlauf neu aufgesetzt.

**Umgesetzt:**

- **`SyncSnapshot.einkaufslistenEintraege`** — vollständiger
  Einkaufslisten-Inhalt (Artikel + Menge + Notiz) additiv im Snapshot
  mitgeführt. Events bleiben der schnelle Kanal fürs aktive gemeinsame
  Einkaufen; der Snapshot fängt nur nach, was ein Peer verpasst hat
  (`SyncSnapshotImportService.mergeEinkaufslistenEintraege`). Entfernen bleibt
  Aufgabe der `artikelEntfernt`-Events — dieser Teil ist bewusst nie
  destruktiv.
- **`SyncTombstone`** (neues Modell) — merkt absichtliche Löschungen von
  `Geschaeft`/`Artikel`/`Abteilung`/`Einkaufsliste`/`KaufEintrag` vor,
  wird im Snapshot mitgeführt (`SyncSnapshot.tombstones`) und beim Import
  zuerst verarbeitet (`mergeTombstones`): löscht ein dadurch als entfernt
  markiertes, lokal noch vorhandenes Objekt, und verhindert (über
  `SyncTombstoneService.geloeschteIDs`), dass die nachfolgenden
  Merge-Schritte es aus einem veralteten Peer-Snapshot neu anlegen. Alle
  UI-Löschstellen (`GeschaeftListView`, `ArtikelListView`,
  `AbteilungenVerwaltungView`, `EinkaufslistenVerwaltungView`,
  `GeschaeftPreisUebersichtView`) rufen `SyncTombstoneService.markiereGeloescht(...)`
  vor dem eigentlichen `context.delete(...)` auf.
- **`SyncEntitaetsAlias`-Erweiterung auf `Geschaeft`/`Abteilung`** —
  Voraussetzung dafür, dass ein Tombstone für ein per Namens-/
  Koordinatenmatching zusammengeführtes Objekt überhaupt auf die richtige
  lokale ID aufgelöst werden kann (vorher nur für `Artikel`/`Einkaufsliste`
  registriert). `Geschaeft`/`Abteilung` übernehmen jetzt außerdem
  konsequent die Remote-ID beim Neuanlegen (vorher bekam ein neu erzeugtes
  `Geschaeft` immer eine zufällige, vom Original abweichende ID).
- **`SyncPeerInfo.zuletztGesehen` + `SyncSnapshotImportService.maximalesSnapshotAlter`**
  (Standard: 30 Tage) — ein Snapshot, der älter als die Altersgrenze ist,
  wird komplett ignoriert, der Peer also wie nicht vorhanden behandelt.
  Verhindert, dass verwaiste Peer-Ordner aus früheren Testinstallationen
  (jede Neuinstallation erzeugt eine neue Geräte-ID) dauerhaft alte Daten
  zurückspielen. Ergänzend: manuelle Peer-Entfernung in
  `DebuggingView` (löscht `SyncPeerInfo`-Eintrag + Peer-Ordner im
  Sync-Ordner).

**Bewusst nicht in diesem Umbau enthalten:**

- Keine Tombstones für `GeschaeftTyp` (aktuell keine Lösch-UI dafür) — bei
  Bedarf trivial ergänzbar (dieselbe generische `SyncEntitaetsArt`/
  `SyncTombstone`-Infrastruktur).
- Kein Verfallsdatum/keine Bereinigung für Tombstones selbst — die Liste
  wächst unbegrenzt, aber langsam (nur tatsächliche Löschungen).
- Automatische Retention-Löschung alter `KaufEintrag`e
  (`PreisHistorieBereinigungService`) bekommt **keinen** Tombstone — das ist
  eine bewusste, wiederkehrende Aufräum-Policy, kein "dieses Geschäft/dieser
  Artikel existiert nicht mehr"-Signal; ein Tombstone dafür würde die Liste
  bei jeder automatischen Bereinigung unnötig wachsen lassen.

### 11a. Nachtrag: dieselbe Lücke bei `Einkaufsvorgang`

Der erste Live-Test nach Umsetzung von Abschnitt 11 zeigte dieselbe Bug-Klasse
ein drittes Mal, jetzt bei `Einkaufsvorgang`: Abgehakte Artikel erschienen auf
Gerät A, aber nicht auf Gerät B, und Kaufeinträge verdoppelten sich mit der
Zeit. Ursache: `mergeEinkaufsvorgaenge` matchte bislang **ausschließlich** per
ID, mit der (falschen) Doku-Annahme, "beide Geräte sprächen beim gemeinsamen
Einkauf automatisch über dieselbe Identität". Tatsächlich legt
`EinkaufenView.einkaufSicherstellen()` auf jedem Gerät unabhängig einen
eigenen, zufällig-IDten Einkaufsvorgang an, sobald es selbst keinen offenen für
das gewählte Geschäft/Liste kennt — noch bevor ein Sync stattfinden konnte.
Zwei Geräte, die "gemeinsam" im selben Laden einkaufen, hatten dadurch de
facto **zwei unabhängige** Einkaufsvorgänge; Abhaken auf A landete auf einem
für B unsichtbaren Objekt, während parallel auf B eigene `KaufEintrag`e für
dieselben Artikel entstanden — die sich beim Sync als Dubletten summierten.

**Fix:** `mergeEinkaufsvorgaenge` erkennt jetzt zusätzlich einen lokal noch
**offenen** Einkaufsvorgang für dasselbe (`Geschaeft`, `Einkaufsliste`)-Paar
als denselben realweltlichen Einkauf und registriert einen Alias (identisches
Muster wie `Einkaufsliste`/`Artikel`) — die vorhandene Dedupe-Prüfung in
`Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` (siehe
`docs/DATABASE_CONCURRENCY.md`) greift danach korrekt, da beide Geräte nach
dem Merge über dasselbe lokale Objekt sprechen. `SyncImportService.einkaufsvorgang(mitID:)`
löst jetzt ebenfalls über den Alias auf.

**Nicht rückwirkend behoben:** Bereits vor diesem Fix entstandene doppelte
Kaufeinträge (aus zwei zuvor unabhängigen Einkaufsvorgängen) bleiben bestehen
— dieselbe Einschränkung wie bei der Einkaufsliste-Dublette; überzählige
Preishistorie-Einträge lassen sich über die Geschäfts-Preisübersicht manuell
entfernen (jetzt korrekt tombstoned, kommen also nicht zurück).

### 11b. Nachtrag: Sicherheitsnetz holte bereits abgehakte Artikel zurück

Ein weiterer Live-Test deckte einen direkten Bug im in Abschnitt 11
eingeführten Einkaufslisten-Sicherheitsnetz auf: Ein bereits abgehakter
Artikel erschien wieder in der "offenen" Ansicht — bei aktivierter "alle
Artikel zeigen"-Option sogar doppelt (SwiftUI meldete dazu passend `ForEach`
mit doppelten IDs, ein bekannter Absturzauslöser).

**Ursache:** `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` entfernt
den `EinkaufslistenEintrag` eines abgehakten Artikels als **Seiteneffekt**,
ohne dafür ein eigenes `artikelEntfernt`-Event aufzuzeichnen (das Abhaken
selbst ist bereits das maßgebliche Event). Ein Peer, dessen Snapshot diesen
Zustandswechsel noch nicht kennt, listete den Artikel deshalb weiterhin in
`einkaufslistenEintraege` — `mergeEinkaufslistenEintraege` (Abschnitt 11) hatte
keine Prüfung dagegen und fügte ihn additiv wieder hinzu, obwohl er lokal
bereits einen `KaufEintrag` hatte.

**Fix:** `mergeEinkaufslistenEintraege` prüft jetzt zusätzlich, ob der Artikel
in einem lokal noch offenen `Einkaufsvorgang` von derselben Liste bereits
abgehakt ist, und überspringt die Wiederherstellung in diesem Fall. Zusätzlich
defensiv abgesichert in `EinkaufenView`: `offeneArtikel` schließt jetzt
abgehakte Artikel explizit aus, `abgehakteArtikel` dedupliziert nach
Artikel-Identität (schützt auch gegen die in 11a beschriebenen, bereits
bestehenden doppelten `KaufEintrag`e).

### 11c. Nachtrag: dieselbe Umleitungslücke im Bereich-A-Event-Pfad (verschoben aus `docs/ARCHITECTURE.md`)

Dieselbe „dangling Einkaufsvorgang"-Ursachenfamilie wie 11a/11b, hier für den
Bereich-A-Event-Empfang statt den Bereich-C-Snapshot-Merge: Ein per
Bereich-A-Event empfangenes Abhaken, das noch einen von diesem Gerät bereits
per „Einkauf abschließen" geschlossenen `Einkaufsvorgang` referenziert (der
sendende Peer kannte dessen `endZeit` beim Senden noch nicht), wurde von
`SyncImportService.einkaufsvorgang(mitID:context:aufOffenenNachfolgerUmleiten:)`
auf den aktuell offenen Nachfolger für dieselbe `Einkaufsliste` umgeleitet
(bevorzugt mit gleichem `Geschaeft`, sonst irgendeinen offenen, über den
gemeinsamen Helfer
`Einkaufsvorgang.offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)` —
genutzt sowohl hier als auch von
`SyncSnapshotImportService.mergeEinkaufsvorgaenge`, das dieselbe Lücke im
Bereich-C-Snapshot-Merge hatte, siehe 11a) — vorher landete der `KaufEintrag`
unsichtbar auf dem geschlossenen Vorgang und wurde vom nächsten
Snapshot-Merge fälschlich wieder auf die offene Liste zurückgeholt.

**Nur für `.artikelAbgehakt`** (materialisiert einen NEUEN Eintrag) —
`.artikelAbgewaehlt`/`.artikelDauerhaftEntfernt` müssen einen bereits
BESTEHENDEN Eintrag auf dem ursprünglichen Vorgang finden und werden bewusst
nicht umgeleitet (Code-Review-Fund: eine Umleitung ließ sie sonst still ins
Leere laufen, während das Event trotzdem als erledigt galt). Zusätzlich
bekommt ein so oder per Snapshot-Merge (`mergeKaufEintraege`) fremd
materialisierter `KaufEintrag` bewusst **keinen** `abteilungBesuchsIndex` — er
beschreibt die Laufreihenfolge des SENDENDEN Geräts, nicht die dieses
Geräts, und würde `AbteilungsDistanzService` sonst mit einer erfundenen
Besuchsposition füttern; `Einkaufsvorgang.naechsterAbteilungBesuchsIndex`
ignoriert solche indexlosen Einträge bei der Suche nach einem bereits
vorhandenen Index, um keinen Duplikat-Index für dieselbe Abteilung zu
vergeben.

**Dieselbe Lücke bestand unadressiert auch im Bereich-A-„Sicherheitsnetz"**
(`SyncSnapshotImportService.mergeEinkaufslistenEintraege`/
`istBereitsAbgehakt` — bereits in 11b beschrieben, hier ergänzend): Der
Check, ob ein Artikel bereits abgehakt ist, betrachtete nur lokal noch
**offene** `Einkaufsvorgang`e. Schloss „Einkauf abschließen" den Vorgang mit
dem `KaufEintrag`, fiel der Artikel aus diesem Check heraus — ein noch
veralteter Peer-Snapshot holte ihn dann über das Sicherheitsnetz erneut auf
die offene Liste zurück, ein anschließendes erneutes Abhaken erzeugte wegen
der neuen `bezugsID` des Nachfolge-Vorgangs einen zusätzlichen `KaufEintrag`
(sichtbare Dublette). `istBereitsAbgehakt` zählt seither auch geschlossene
Vorgänge, aber **nur** solange für dieselbe Liste aktuell ein offener
Nachfolger existiert (derselbe `offenerNachfolger`-Helfer) — ein vor Wochen
einmal gekaufter und später legitim neu zur Liste hinzugefügter Artikel
bleibt dadurch weiterhin über das Sicherheitsnetz erreichbar.

**Zurückgestellte, tiefergehende Befunde aus demselben Code-Review:**
Geschäfts-Zuordnung eines per Umleitung materialisierten `KaufEintrag`
(übernimmt das Geschäft des Nachfolge-Vorgangs, oft `nil`);
`SyncEntitaetsAlias`s „einmal geschrieben, eingefroren"-Semantik passt nicht
zu einer mehrfach rotierenden Umleitung; kein Ursprungsgerät-Feld auf
`KaufEintrag` (zwei unabhängige, nicht typsicher erzwungene Stellen
unterdrücken `abteilungBesuchsIndex`); store-loser Umleitungs-Fallback bei
zwei konkurrierenden Einkäufen ohne Geschäft-Treffer.

## 12. Restrisiko: unerreichbare Vorgeschichte vor Einführung dieses Features

Einkaufslisten-Einträge, die entstanden, **bevor** Bereich-A-Events (Phase 0)
bzw. der volle Snapshot-Inhalt (Abschnitt 11) existierten, wurden nie als
Event aufgezeichnet und stecken auch in keinem historischen Snapshot — sie
lassen sich nicht rückwirkend zwischen Geräten abgleichen. Beobachtet beim
Live-Test: zwei Geräte mit jeweils eigener, seit Monaten gewachsener
Einkaufslisten-Historie zeigten nach dem ersten Sync weiterhin
unterschiedliche Eintragszahlen auf gleichnamigen Listen. Kein Bug, keine mit
dieser Architektur behebbare Lücke — betroffene Nutzer müssen abweichende
Altbestände einmalig manuell abgleichen (siehe Einstellungen →
Einkaufslisten).

Empfehlung für den Einstieg: Phase 0 zuerst, in sich abgeschlossen und ohne
Auswirkung auf bestehendes Verhalten (reines Mitschreiben, noch kein Sync) — gute
Gelegenheit, das Event-Modell und die Mutations-Integration zu verproben, bevor
Dateisystem-Sync (Phase 1+) dazukommt.

## 13. `SyncErsetzenService` — Ersetzen/Backup/Wiederherstellen (GitHub #63)

Zwei Beweggründe, ein Mechanismus:

1. **GitHub #63** — Merge funktioniert seit #52 korrekt für den Regelfall
   (frisches Gerät, nur Seed-Daten); offen blieb, dass Bereich C
   (Kaufhistorie) immer additiv merged — ein Nutzer mit bereits bestehender,
   privater Kaufhistorie kann aktuell nicht verhindern, dass sie beim
   Beitritt zu einer geteilten Gruppe unwiderruflich einfließt.
2. **Korruptions-Recovery**: ein bereits korrumpierter lokaler Datensatz
   (baumelnde Referenz, siehe `docs/DATABASE_CONCURRENCY.md`) lässt sich über
   die normale SwiftData-Objektgraph-API nicht sicher reparieren — jede
   schreibende Operation muss die Inverse-Gegenseite auffalten und crasht
   dabei, falls genau diese Gegenseite die bereits baumelnde ist. Ein
   vollständiges Zurücksetzen umgeht das strukturell, da die korrumpierten
   Zeilen nie wieder geöffnet werden.

**Physisches Löschen statt zeilenweisem Wipe — Korrektur nach echtem
Geräte-Absturz:** Ein erster Entwurf machte den `ModelContainer` zur Laufzeit
austauschbar (`ModelContainerController`, `RootView().id(generation)` für
einen erzwungenen View-Baum-Neuaufbau) und löschte die Store-Datei, während
die App weiterlief. Auf einem echten Gerät führte das zu
`BUG IN CLIENT OF libsqlite3.dylib` / `SQLite error 6922, disk I/O error` und
einem Absturz: `SyncPollingService.stoppen()` fordert Cancellation nur
kooperativ an, wartet aber nicht, bis ein bereits laufender Sync-Zyklus
tatsächlich beendet ist — lief einer noch, griff er weiter auf die Datei zu,
während sie physisch gelöscht wurde. **Deshalb jetzt: Neustart-Aufforderung
statt nahtlosem Austausch.** Der Anwender wird gebeten, die App zu schließen
und neu zu öffnen; die eigentliche Ersetzung passiert erst danach, ganz am
Anfang des neuen Prozesses (`ShopWithMeApp.init()`), **bevor** überhaupt ein
`ModelContainer` für die Datei existiert — an diesem Punkt kann garantiert
nichts anderes (kein Hintergrund-Timer, keine offene Ansicht) noch auf den
Store zugreifen, weil der komplette vorherige Prozess beendet wurde. `App/ModelContainerController.swift`
wurde wieder entfernt, `ShopWithMeApp` ist wieder ein einfacher `let
modelContainer`.

**`SyncErsetzenService`** (neu, `Services/SyncErsetzenService.swift`) —
zweigeteilt in „planen" (aktuelle Sitzung) und „ausführen" (nächster Start):
- `erstelleBackup(context:)` — lokales, nicht geteiltes Backup unter
  `Application Support/Backups/ersetzen-backup.json`, wiederverwendet
  `SyncSnapshotExportService.erstelleSnapshot(context:)`, ergänzt um
  ``IgnorierterGeschaeftsVorschlag`` (gerätelokal, nicht Teil von
  `SyncSnapshot`) in einer Backup-Hülle (`SyncErsetzenBackup`, neu,
  `Models/SyncErsetzenBackup.swift`) — das Peer-Wire-Format bleibt
  unangetastet. **Genau ein Backup, wird bei jedem Ersetzen/Beitritt
  überschrieben** (mit dem Anwender abgestimmt) — löst die in #63 offene
  „welches Backup beim Austritt"-Frage automatisch, da es nur eins gibt.
- `planeErsetzenDurchPeer(context:)` / `planeWiederherstellenAusBackup()` —
  sichern (ersteres) und merken nur eine `AusstehendeAktion` in `UserDefaults`
  vor. Verändern den aktuellen Datenbestand **nicht** — die UI zeigt danach
  sofort den Neustart-Hinweis.
- `loescheStoreDateiFallsAusstehend(url:)` — von `ShopWithMeApp.init()` als
  allererstes aufgerufen, noch vor dem Öffnen des `ModelContainer`s. Löscht
  die Store-Datei (samt `-wal`/`-shm`) nur, falls eine Aktion aussteht —
  sonst (jeder normale Start) ohne Wirkung.
- `fuehreAusstehendeAktionAus(context:)` — aus `ShopWithMeApp`s `.task` (nach
  dem synchronen `init()`, sobald ein `async`-Kontext verfügbar ist), füllt
  den jetzt frischen, leeren Context: entweder via
  `SyncSnapshotImportService.importiereSnapshots(context:)` (bereits
  vorhanden — jede `mergeX`-Funktion legt bei fehlendem lokalem Treffer frisch
  an, ein leerer Kontext wird dadurch automatisch korrekt neu aufgebaut) oder,
  bei Wiederherstellung, über den neuen, schmalen Wrapper
  `SyncSnapshotImportService.importiereEinzelnenSnapshot(_:peerGeraeteID:context:)`
  mit einer Sentinel-Geräte-ID (kein Phantom-`SyncPeerInfo`-Eintrag). Löscht
  die ausstehende Aktion danach.

**UI, drei Einstiegspunkte, alle mit `.confirmationDialog`/`role: .destructive`
+ abschließendem „Neustart nötig"-Hinweis, kein stilles Ausführen** (#63s
eigene Anforderung):
1. Erster Sync-Ordner-Beitritt (`SyncOrdnerSettingsView.ordnerFestlegen(_:)`) —
   `SyncOrdnerService.hatVorhandenePeers(in:)` erkennt bereits vorhandene
   Peer-Daten, bietet dann „Zusammenführen" (Standard, unverändert, läuft
   sofort) vs. „Ersetzen" (plant nur vor, Neustart-Hinweis).
2. Manuelles Zurücksetzen jederzeit (Korruptions-Recovery) —
   `DebuggingView.DatenintegritaetSection`, direkt unter der Erklärung, warum
   keine automatische Reparatur stattfindet; deaktiviert ohne konfigurierten
   Sync-Ordner (ohne Peer kein Wiederaufbau möglich).
3. Wiederherstellung bei Austritt — „Synchronisierung deaktivieren" bietet,
   falls ein Backup existiert, dessen Wiederherstellung an (ebenfalls nur
   vorgemerkt, Neustart-Hinweis).

Da die eigentliche Ersetzung erst nach einem echten Prozess-Neustart passiert,
entfällt die ursprüngliche Nebenläufigkeits-Sorge um `SyncPollingService`
vollständig — es gibt nichts mehr, das während der Operation pausiert werden
müsste.

**Verifikationsstand:** Automatisierte Tests (`SyncErsetzenServiceTests.swift`)
decken Backup-Rundlauf, Überschreib-Semantik, Planen-ohne-Seiteneffekt, reines
Datei-Löschen sowie das Befüllen eines bereits leeren Contexts ab. **Bewusst
nicht in einem einzigen Testlauf nachgestellt:** „Datei löschen, dann an
derselben URL neu öffnen" — ein solcher Versuch ließ selbst nach sauberem
ARC-Deallozieren des ersten `ModelContainer` den Testprozess mit demselben
`BUG IN CLIENT OF libsqlite3.dylib`-Muster abstürzen (siehe Kommentar in der
Testdatei). SwiftData/CoreData scheint intern noch etwas asynchron gegen die
Datei laufen zu haben, das durch bloßes Dealloziieren nicht sofort beendet
wird — im echten Prozess-Neustart-Fall kann es diese Restaktivität aus dem
alten Prozess dagegen gar nicht geben. Der volle Ablauf (Neustart-Hinweis →
tatsächlicher Neustart → korrekt befüllter Store) muss daher manuell auf
einem echten Gerät verifiziert werden.

### 13a. Nachtrag: Crash-Details und generelle Lehre (verschoben aus `docs/DATABASE_CONCURRENCY.md`)

Der in Abschnitt 13 beschriebene erste Entwurf (Laufzeit-Austausch des
`ModelContainer`) führte auf einem echten Gerät konkret zu:

```
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API
violation: vnode unlinked while in use: .../default.store
CoreData: error: (6922) I/O error for database ... SQLite error code:6922,
'disk I/O error'
data store (...) did not return a snapshot for: PersistentIdentifier(...
EinkaufslistenEintrag/p60...)
Fatal error: This model instance was invalidated because its backing data
could no longer be found the store.
```

**Ursache:** `SyncPollingService.stoppen()` (`schleife?.cancel()`) fordert
Cancellation nur kooperativ an — der Loop-Body prüft `Task.isCancelled` nur
zwischen zwei Zyklen, nicht während eines bereits laufenden `syncZyklus()`.
War beim Tippen auf „Ersetzen"/„Gerät zurücksetzen" gerade ein Zyklus aktiv,
lief er nach `stoppen()` einfach weiter und griff auf die Store-Datei zu,
während sie physisch gelöscht wurde. Ein zusätzlicher Fund beim Nachbau
eines entsprechenden Unit-Tests: selbst innerhalb eines einzigen
Testprozesses ließ sich „Store-Datei löschen, dann an derselben URL neu
öffnen" nicht sicher nachstellen, obwohl der erste `ModelContainer` sauber
per ARC dealloziert war — derselbe `BUG IN CLIENT OF libsqlite3.dylib`-Fehler
trat weiterhin auf und brachte teils den Testprozess selbst zum Absturz.
SwiftData/CoreData scheint intern noch etwas asynchron gegen die Datei zu
laufen (vermutlich WAL-Checkpointing oder Coordinator-Aufräumarbeiten), das
durch bloßes Dealloziieren der sichtbaren Swift-Referenz nicht sofort beendet
wird.

**Lehre für künftige Fälle dieser Art:** „ich pausiere den Hintergrund-Timer,
bevor ich etwas Destruktives tue" reicht nicht, wenn die Pause nur über
kooperative Task-Cancellation läuft — ein bereits laufender Durchlauf ist
davon unberührt. Wo eine destruktive Operation wirklich exklusiven Zugriff
braucht, ist eine Prozessgrenze (Neustart) einer laufzeitinternen
Koordination vorzuziehen, sofern die UX das zulässt — genau der Ansatz, der
in Abschnitt 13 als `SyncErsetzenService` umgesetzt wurde.

## 14. DB-Optimierung — Datenminimierung im Sync-Zyklus (GitHub #60/#70/#71)

**Ausgangsbefund:** Eine Analyse der offenen DB-/Sync-Issues zeigte, dass der
größte Effizienzverlust nicht am JSON-Format lag, sondern daran, dass
`SyncPollingService.syncZyklus()` bei **jedem** Tick (5s aktiv einkaufend /
60s ruhend) unbedingt schrieb — lokal *und* in den Sync-Ordner — selbst wenn
sich am eigentlichen Datenbestand seit dem letzten Zyklus nichts geändert
hatte. Das erklärte mehrere Symptome gleichzeitig: #60 (Flackern der
Einkaufsliste alle 5s — jeder Zyklus löste eine echte, für die Liste
irrelevante Store-Änderung aus, die `@Query`-Beobachter trotzdem
benachrichtigte), #70 (häufige Schreibzugriffe) und #71 (viele fast
identische Zeitstempel-Einträge in `export.json`).

**Umgesetzt:**

1. **`SyncPeerInfo.zuletztGesehen` gedrosselt** (`Models/SyncPeerInfo.swift`):
   wurde bisher bei jedem Import eines Peer-Snapshots unbedingt auf dessen
   (bei jedem Zyklus neuem) `erzeugtAm` gesetzt — eine echte SwiftData-Änderung
   pro Zyklus, unabhängig vom eigentlichen Inhalt. Wird jetzt nur noch bei
   einem Delta ≥ 1h geschrieben; die einzige Konsumentin
   (`SyncSnapshotImportService.maximalesSnapshotAlter`, 30-Tage-Schwelle)
   braucht keine feinere Auflösung.
2. **`context.save()` nur bei `context.hasChanges`**
   (`SyncImportService.importiereNeueEvents`,
   `SyncSnapshotImportService.importiereSnapshots`/`importiereEinzelnenSnapshot`):
   ein reiner Poll-Zyklus ohne neue fremde Daten erzwingt jetzt keine
   Store-Mutation mehr.
3. **`export.json` nur bei geändertem Inhalt schreiben**
   (`SyncSnapshotExportService`): ein SHA256-Fingerabdruck über den
   normalisierten Snapshot-Inhalt (Meta-Felder `erzeugtAm`/`geraeteID`/
   `geraeteName` ausgenommen, alle Teil-Arrays vor dem Hashen nach `UUID`
   sortiert, damit reine Fetch-Reihenfolge-Unterschiede nicht als Änderung
   zählen) wird mit dem zuletzt tatsächlich geschriebenen verglichen —
   identisch → weder Encoding noch Datei-Schreiben. Der
   `maximalesSnapshotAlter`-Check bleibt unberührt: eine über Tage
   unveränderte, aber weiterhin gültige `export.json` ist kein „verwaister
   Peer-Ordner", die 30-Tage-Schwelle bleibt dafür grob genug.
4. ~~**Event-Datei-Pruning**~~ — **wieder zurückgenommen** (Live-Test mit zwei
   Geräten direkt nach Einführung): eigene, bereits hochgeladene Event-Dateien
   wurden nach 7 Tagen gelöscht, unabhängig davon, ob ein Peer sie überhaupt
   schon gelesen hatte — „hochgeladen" beschreibt nur, dass DIESES Gerät die
   Datei geschrieben hat, nicht, dass sie bei allen Peers angekommen ist. Da
   zwischen den beiden Testgeräten bereits ein länger als die Frist
   bestehender Sync-Rückstand vorlag, löschte der erste Aufräumlauf genau
   diesen noch nicht abgeholten Rückstand — abgehakte Artikel synchronisierten
   danach zwischen den Geräten gar nicht mehr, weil die zugehörigen
   `artikelAbgehakt`-Event-Dateien bereits weg waren. Die „Offene
   Alt-Datei-Frage" (unten) bleibt damit bewusst wieder offen: ein sicheres
   Aufräumen bräuchte eine echte Bestätigung, dass alle Peers eine Datei
   bereits konsumiert haben (z.B. ein Zuletzt-gelesen-Cursor pro Peer), die es
   aktuell nicht gibt — ein reiner Zeit-Heuristik-Ersatz dafür ist nicht
   sicher genug, wie dieser Vorfall zeigt.
5. **Reentrancy-Guard in `EinkaufenView.einkaufSicherstellen()`:** mehrere
   unabhängige `.onChange`-Handler (`ausgewaehltesGeschaeft`,
   `ausgewaehlteListe`, `offeneEinkaufsvorgaenge.count`) konnten nebenläufig
   je einen eigenen `Task` auslösen, die den `aktuellerEinkauf ==
   nil`-Guard beide vor dem jeweils anderen Insert als wahr lasen — Verdacht
   auf (Mit-)Ursache für die in #71 beobachteten, im Abstand von
   Millisekunden angelegten `Einkaufsvorgang`-Duplikate. Ein
   `@State`-Reentrancy-Flag (gesetzt als erste synchrone Anweisung vor dem
   ersten `await`, auf dem `MainActor` dadurch race-frei) verhindert das.
6. **Auto-Close bei Inaktivität generalisiert** (`EinkaufenView.inaktivitaetPruefen()`,
   vorher nur Geschäftsauswahl-Reset, GitHub #51): ein Ladenbesuch ist
   naturgemäß zeitlich begrenzt (1–3h) und wird nach
   `inaktivitaetsSchwelleMitGeschaeft` (3h) automatisch abgeschlossen —
   inklusive Lernschritt (`AbteilungsDistanzService.verarbeiteEinkauf`),
   aber bewusst OHNE Umbau-Hinweis-Dialog (niemand ist beim automatischen
   Schließen aktiv am Bildschirm, um ihn sinnvoll einzuordnen; ein später
   erkannter Umbau wird beim nächsten *manuellen* Abschließen ganz normal
   gemeldet). Ohne gewähltes Geschäft — reines bedarfsweises Abhaken über
   mehrere Tage verteilt, ohne je „Einkauf abschließen" zu tippen — gilt
   `inaktivitaetsSchwelleOhneGeschaeft` (24h), damit dieser Anwendungsfall
   nicht gestört wird. **Wichtige Voraussetzung für Punkt 7:** Vorher gab es
   für diesen Fall überhaupt keinen Abschluss-Mechanismus — ein
   `Einkaufsvorgang` blieb für immer `offen`, wodurch ihn
   `PreisHistorieBereinigungService` (die nur abgeschlossene Vorgänge
   anfasst) strukturell nie erreichen konnte.
7. **Retention-Bereinigung auf `Einkaufsvorgang` ausgeweitet + Tombstones für
   Retention-Löschungen** — siehe `docs/PREISHISTORIE_BEREINIGUNG.md` für
   Details. Kurzfassung: dieselbe Aufbewahrungsfrist wie für `KaufEintrag`
   räumt jetzt auch alte, abgeschlossene, leere `Einkaufsvorgang`e auf; beide
   Löschungen hinterlassen jetzt einen `SyncTombstone` (vorher bewusst
   unterlassen, siehe Abschnitt 11 oben — das machte die Bereinigung im
   Mehrgeräte-Fall aber faktisch wirkungslos, da der additive Bereich-C-Merge
   den gelöschten Eintrag vom nächsten Peer zurückbekam). Dabei zwei
   vorbestehende Lücken im Tombstone-Mechanismus selbst geschlossen:
   `mergeEinkaufsvorgaenge`/`mergeKaufEintraege` prüften ihren
   "neu anlegen"-Zweig bislang nicht gegen `SyncTombstoneService.geloeschteIDs`
   (anders als die Bereich-B-Merges) und `loescheFallsVorhanden` kannte noch
   keinen `Einkaufsvorgang`-Fall — ohne beides hätte ein neuer
   Einkaufsvorgang-Tombstone gar nicht gewirkt.

**Bewusst zurückgestellt:** Der ursprünglich mit angedachte zweite,
hintergrundgebundene `ModelContext` für die Merge-Berechnung (Punkt 5 der
Priorisierung, siehe `docs/DATABASE_CONCURRENCY.md` → „Teilbehobenes Problem:
langsamer App-Start durch Sync-Zyklus") bleibt an eine Messung gebunden, wie
dort selbst vorgesehen — Punkte 1–3 oben dürften die tatsächlich gemessene
Zyklusdauer bereits spürbar senken (weniger/kleinere Saves), eine
Neubewertung mit echten `SyncDebugLogger`-Zahlen sollte vor diesem größeren
Architektur-Eingriff stehen.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün, neue
Unit-Tests für die Tombstone-Lücken (`SyncSnapshotImportServiceTests`) und die
Einkaufsvorgang-Retention (`PreisHistorieBereinigungServiceTests`) ergänzt.
Ein Live-Test mit zwei echten Geräten direkt nach dieser Optimierungsrunde
deckte den unter Punkt 4 beschriebenen Regressions-Fund auf (Event-Pruning
zurückgenommen, s.o.) — noch nicht erneut mit echten Geräten nachverifiziert,
dass der Revert die gemeldete Sync-Störung tatsächlich behebt. Die
Fingerabdruck-basierte `export.json`-Skip-Logik (Punkt 3) verdient ebenfalls
weiterhin eine Beobachtung über mehrere reale Zyklen, ob die
Fetch-Reihenfolge-Normalisierung in der Praxis tatsächlich stabil genug ist,
um unnötige Schreibvorgänge zuverlässig zu vermeiden, ohne echte Änderungen
fälschlich zu unterdrücken.

### 15. Nachtrag: Endlos-Retry für dauerhaft unauflösbare Bereich-A-Referenzen

Derselbe Zwei-Geräte-Live-Test (Abschnitt 14) deckte über die Event-Pruning-
Regression hinaus einen zweiten, unabhängigen Befund auf: `SyncDebugLogger`
zeigte auf einem Gerät durchgehend über mehrere Minuten (jeder Zyklus erneut)
denselben `sync_event_nicht_anwendbar`-Eintrag für dieselben drei
`artikelAbgehakt`-Events — ohne je zu konvergieren. Abgleich der `export.json`
beider Geräte bestätigte: der referenzierte `Einkaufsvorgang` existierte auf
**keinem** der beiden Geräte mehr, hatte aber auch **keinen** `SyncTombstone`
— eine bislang nicht vorgesehene dritte Möglichkeit neben „noch nicht
angekommen" (retrywürdig) und „absichtlich gelöscht" (Tombstone, sofort
aufgeben). Vermuteter Auslöser: dieselbe „dangling Einkaufsvorgang"-Ursachen-
Familie wie in Abschnitt 11a — der Vorgang wurde auf dem Ursprungsgerät durch
eine Nachfolger-Umleitung ersetzt, bevor seine ursprüngliche ID je Teil eines
Bereich-C-Snapshots wurde, wodurch sie spurlos aus jedem künftigen Snapshot
verschwand, ohne dass irgendein Gerät sie je als „gelöscht" vermerkt hätte.

**Zwei Ergänzungen in `SyncImportService`:**
1. Tombstone-Prüfung (`referenzDauerhaftGeloescht`) — Events, deren Referenz
   per Tombstone als absichtlich gelöscht markiert ist, werden sofort als
   bekannt markiert statt endlos erneut versucht.
2. **Alters-Schwelle** (`maximalesEventAlterFuerRetry`, 48h): deckt den oben
   beschriebenen dritten Fall ab, bei dem gar kein Tombstone existiert — ein
   Event, dessen Referenz auch nach dieser (bewusst großzügigen, analog
   ``SyncSnapshotImportService/maximalesSnapshotAlter``) Frist nicht auflösbar
   ist, wird aufgegeben (distinkt protokolliert als `sync_event_aufgegeben`,
   dann als bekannt markiert) statt für immer erneut versucht.

Löst nicht die zugrunde liegende Ursache (warum die alte ID nie Teil eines
Snapshots wurde) — das bleibt Teil der größeren, bereits mehrfach
dokumentierten „dangling Einkaufsvorgang"-Bugfamilie —, begrenzt aber
zuverlässig den Schaden eines einzelnen betroffenen Vorgangs auf einen
einmaligen, für den Anwender sichtbaren Sync-Ausfall dieses einen Kaufs statt
auf dauerhaftes Log-Rauschen und wiederholte nutzlose Zyklusarbeit.

### 16. Nachtrag: Wurzelursache eines Teils der „dangling Einkaufsvorgang"-Bugfamilie gefunden

Ein weiterer Zwei-Geräte-Live-Test (2026-07-31, Symptom: „Artikel erscheint
kurz als abgehakt/synchronisiert, verschwindet dann wieder") lieferte über den
direkten Abgleich der `export.json` beider Geräte den ersten harten Beweis für
eine tatsächliche Wurzelursache aus dieser Bugfamilie (bisher nur an
Symptomen — Abschnitt 11, 11a, 11b, 15 — behandelt, nie an der Quelle):

**Befund:** Drei unterschiedliche `Einkaufsvorgang`-IDs (`E4A62D76`, `845641FB`,
`01387E15`) trugen auf **beiden** Geräten identisch dieselbe `endZeit`
(`807141471.238757`, übereinstimmend bis auf die Mikrosekunde) — obwohl zwei
davon (`845641FB`, `01387E15`) einen `startZeit` **nach** dieser `endZeit`
hatten. Chronologisch unmöglich für eine echte `abschliessen()`-Aktion (die
immer `Date()` zum tatsächlichen Zeitpunkt verwendet) — ein sicheres Indiz für
eine fälschlich übernommene, fremde `endZeit`.

**Ursache, in `mergeEinkaufsvorgaenge` gefunden:** `alleLokalen` wurde beim
Funktionsstart einmalig gefetcht. Enthielt ein einzelner Peer-Snapshot mehrere
`remote`-Einträge, die eigentlich alle denselben, für dieses Gerät noch
unbekannten offenen Vorgang für dieselbe Liste meinten (z.B. mehrere
store-lose Einkäufe desselben Peers), „sah" der `offenerTreffer`-Zweig einen
im selben Durchlauf gerade erst per `context.insert` angelegten Vorgang
nicht — jeder weitere solche Eintrag legte dadurch einen **zusätzlichen,
eigenständig offenen** Vorgang für dieselbe Liste an, statt den bereits
angelegten wiederzuverwenden. Bei einem späteren Merge-Durchlauf traf dann ein
weiterer Eintrag per `offenerTreffer` auf eines dieser überzähligen
Duplikate und übertrug ihm die `endZeit` eines völlig anderen, längst
abgeschlossenen Vorgangs — die eigentliche Merge-Regel
(„`endZeit` nur nachtragen, wenn lokal noch `nil`") schützt hier nicht, weil
der Duplikat-Vorgang ja tatsächlich noch kein `endZeit` hatte.

**Verbindung zu Abschnitt 15:** Genau diese Art von Vorgang — mit
fälschlich zugewiesener, chronologisch unmöglicher `endZeit` — erfüllt die
Bedingung von
``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:context:)``
(„geschlossener Vorgang zählt nur, solange ein aktuell offener Nachfolger
existiert") nicht mehr zuverlässig, sobald kein Nachfolger mehr gefunden wird
— exakt der Mechanismus, der das „kurz synchronisiert, dann wieder
verschwunden"-Symptom erklärt. Vermutlich auch (Teil-)Ursache für den in
Abschnitt 15 dokumentierten `60EE808A`-Fund (spurlos aus jedem Snapshot
verschwundene ID ohne Tombstone) — mehrere unabhängig entstandene Duplikat-
Vorgänge für dieselbe Liste würden erklären, warum eine einzelne ID nie in
den „gewinnenden" Bestand übernommen wurde.

**Fix (`SyncSnapshotImportService.mergeEinkaufsvorgaenge`):**
1. `alleLokalen` ist jetzt `var` — ein neu angelegter Vorgang wird sofort
   angehängt, damit ein späterer Eintrag derselben Schleife ihn über
   `offenerTreffer` korrekt findet, statt einen weiteren Duplikat-Vorgang
   anzulegen.
2. Zusätzliche, unabhängig wirksame Plausibilitätsprüfung: eine `endZeit`,
   die vor dem eigenen `startZeit` läge, wird verworfen statt übernommen —
   ein genereller Schutz gegen dieselbe Fehlerklasse, auch falls sie über
   einen bisher unentdeckten anderen Pfad nochmal auftritt.

**Bewusst nicht rückwirkend repariert:** Bereits bestehende, auf diese Weise
korrumpierte `Einkaufsvorgang`-Datensätze (wie die drei oben gefundenen)
bleiben mit ihrer falschen `endZeit` im Bestand — eine rückwirkende Korrektur
bräuchte eine Heuristik, um „echte" von „übernommene" `endZeit`-Werte zu
unterscheiden, die es nicht sicher geben kann.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün, zwei neue
Regressionstests (`SyncSnapshotImportServiceTests`) — mehrere neue Vorgänge
derselben Liste in einem Snapshot werden zusammengeführt statt dupliziert;
eine unplausible `endZeit` vor dem eigenen `startZeit` wird verworfen. Noch
nicht erneut mit echten Geräten nachverifiziert.

### 17. Nachtrag: `Geschaeft.anzahlEinkaufsvorgaenge` zählte sich bei jedem Sync doppelt — G-Counter-Korrektur

Der Sync-Debug-Modus (Diagnose-Erweiterung aus dem vorherigen Nachtrag,
Abschnitt 16-Umfeld) zeigte: `export.json` wurde auf einem Testgerät
praktisch bei **jedem** Zyklus (5–60s) neu geschrieben, über Stunden hinweg,
ohne erkennbare Nutzeraktivität — der `geschaefte`-Teilbereich hatte bei
fast jedem Zyklus einen anderen Kurz-Fingerabdruck, obwohl Anzahl und
Abteilungen/Artikel/Kaufeinträge über mehrere Zyklen hinweg stabil blieben.
Das deutete auf ein sich kontinuierlich veränderndes Feld innerhalb
`GeschaeftSnapshot` hin.

**Ursache (durch Nachrechnen der Merge-Regel bestätigt):**
``SyncPeerZaehlerStand/zuwachs(peerGeraeteID:geschaeftID:remoteWert:context:)``
(Abschnitt 4.2a) implementierte eine „Delta seit zuletzt gesehenem
Gesamtwert"-Regel — korrekt für einen Zähler, den nur EIN Gerät fortschreibt,
aber strukturell falsch für einen Wert, der selbst schon aus mehreren
Geräten gemergt wurde: Gerät A meldet seinen (bereits Bs Beitrag
enthaltenden) Gesamtwert an B zurück; B kennt A als Peer noch nicht und
zählt den gesamten Wert als neu — darunter den ursprünglich von B selbst
stammenden Anteil, der jetzt über A zurückkam. Jede weitere Synchronisation
zwischen zwei Geräten erhöhte dadurch BEIDE Zähler um genau 1, ganz ohne
neuen echten Einkauf — ein unbegrenzt aufschaukelnder Regelkreis, der
gleichzeitig erklärt, warum `export.json` nie zur Ruhe kam: Das Feld änderte
sich tatsächlich bei jedem Zyklus, die Fingerabdruck-Logik aus der
vorherigen Optimierungsrunde funktionierte korrekt, es gab nur echten
(unerwünschten) Inhalt zum Erkennen.

**Fix: echtes G-Counter-Muster (CRDT) statt Delta-auf-Gesamtwert.**
1. `Geschaeft` unterscheidet jetzt zwei Werte: ``Geschaeft/eigeneAnzahlEinkaufsvorgaenge``
   (NUR die auf diesem Gerät selbst entstandenen Abschlüsse, nie durch Sync
   verändert) und ``Geschaeft/anzahlEinkaufsvorgaenge`` (der bisherige,
   weiterhin überall gelesene Name — jetzt eine berechnete Eigenschaft: Summe
   aus dem eigenen Anteil und dem zuletzt bekannten EIGENEN Beitrag jedes
   Peers). Keine neue gespeicherte Eigenschaft — derselbe
   `anzahlEinkaufsvorgaengeRaw`-Rohwert wie vorher, nur zwei unterschiedlich
   benannte berechnete Sichten darauf; additiv-optional, keine
   Migrationsentscheidung nötig.
2. `SyncPeerZaehlerStand` merkt sich jetzt den von einem Peer gemeldeten
   EIGENEN Beitrag (reines Ablegen, `merkeEigenenZuwachsDesPeers`, keine
   Arithmetik mehr) statt eines Gesamtwert-Deltas — und ist über die bereits
   lokal aufgelöste ``Geschaeft/id`` statt der peer-eigenen Fremd-ID indiziert
   (sauberer: verschiedene Peers können für dasselbe reale Geschäft
   unterschiedliche Fremd-IDs melden, siehe ``SyncEntitaetsAlias``).
3. `GeschaeftSnapshot.anzahlEinkaufsvorgaenge` → `eigeneAnzahlEinkaufsvorgaenge`
   — der Snapshot exportiert jetzt nur noch den rein lokalen Anteil des
   sendenden Geräts, nie mehr den bereits gemergten Gesamtwert.
   `SyncSnapshot.aktuelleFormatVersion` auf 3 erhöht (wieder keine
   Rückwärtskompatibilität nötig; bis beide Geräte einmal mit dem neuen Code
   exportiert haben, wird das jeweils andere `export.json` beim Decodieren
   übergangsweise wie „kein Snapshot vorhanden" behandelt — stiller
   Fehlschlag über `try?`, selbstheilend nach dem nächsten eigenen Export).
4. Manueller Reset (GitHub #30, `GeschaeftStammdatenEditView`) läuft jetzt
   über die neue Methode ``Geschaeft/zaehlerZuruecksetzen(context:)`` — setzt
   den eigenen Anteil auf 0 UND vergisst die bekannten Peer-Beiträge für
   dieses Geschäft (rein lokal, dieselbe bereits vorher akzeptierte
   Einschränkung wie beim alten Zähler: ein Peer, der seinen Beitrag später
   erneut meldet, zählt ihn wieder mit, bis auch er zurücksetzt).
5. `merkeEigenenZuwachsDesPeers` schreibt nur bei tatsächlicher Änderung
   (dieselbe Überlegung wie bei ``SyncPeerInfo`` in Abschnitt 14) — sobald
   niemand einen neuen echten Einkauf abschließt, bleibt der Wert über
   beliebig viele Sync-Zyklen stabil, `export.json` wird dann (zusammen mit
   der Fingerabdruck-Logik aus Abschnitt 14) tatsächlich nicht mehr
   neu geschrieben.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Zwei
Regressionstests in `SyncSnapshotImportServiceTests`: Grundverhalten (Summe
aus eigenem Anteil + Peer-Beiträgen, wiederholter Import desselben Standes
addiert nichts) sowie eine gezielte Zwei-Geräte-Simulation (zwei getrennte
`ModelContainer`, vier Runden abwechselndes Hin-und-Her-Synchronisieren ohne
neuen echten Einkauf) — der Gesamtwert bleibt auf beiden Seiten bei 1 statt
(mit der alten Regel) auf 5 bzw. 4 anzuwachsen. Noch nicht mit echten
Geräten nachverifiziert; bereits vor diesem Fix aufgelaufene, überhöhte
Zähler-Werte werden nicht rückwirkend korrigiert (über den bereits
bestehenden „Zähler zurücksetzen"-Button in den Geschäfts-Stammdaten bei
Bedarf manuell behebbar).

### 18. Nachtrag: Fingerabdruck-Normalisierung hatte innere Arrays übersehen

Ein weiterer Live-Test nach den Abschnitten 16/17 zeigte: `export.json`
wurde weiterhin praktisch bei jedem Zyklus neu geschrieben
(`sync_snapshot_geschrieben` statt `sync_snapshot_unveraendert_uebersprungen`),
obwohl `einkaufsvorgaenge`/`artikel`/`kaufEintraege`-Anzahlen über viele
Zyklen hinweg stabil blieben — nur `geschaefte` (und `abteilungen`,
`artikel`) zeigten bei jedem Zyklus einen anderen Kurz-Fingerabdruck.

**Ursache:** ``SyncSnapshotExportService/normalisiertFuerVergleich(_:)``
(Abschnitt 14) sortierte bisher nur die ÄUSSEREN Arrays (ein Eintrag je
Entität) nach ihrer `UUID`. Die ID-Arrays INNERHALB eines einzelnen
Eintrags — `GeschaeftSnapshot/typIDs`/`abteilungIDs`/
`ausgeschlosseneAbteilungIDs`/`alternativeNamen`/`ignorierteArtikelNamen`,
``AbteilungSnapshot/geschaeftsTypIDs``,
``ArtikelSnapshot/abteilungIDs`` — sind ebenfalls aus SwiftData-
`@Relationship`-Sammlungen abgeleitet und unterliegen derselben fehlenden
Fetch-Reihenfolgen-Garantie wie der äußere `FetchDescriptor`. Ohne
Sortierung dieser inneren Arrays erschien praktisch jeder Zyklus fälschlich
als inhaltliche Änderung, sobald sich nur die Reihenfolge (nie die Menge)
der zugeordneten IDs zwischen zwei Fetches unterschied.

**Fix:** `normalisiertFuerVergleich` sortiert jetzt zusätzlich alle inneren
ID-/Namens-Arrays vor dem äußeren Sortieren nach Entitäts-ID.
``inhaltsFingerabdruck(of:)``/``normalisiertFuerVergleich(_:)`` sind dafür
von `private` auf `internal` herabgestuft (kein Zugriff von außerhalb des
Moduls, aber testbar via `@testable import`) — SwiftDatas Fetch-Reihenfolgen-
Instabilität lässt sich in einem kleinen In-Memory-Testcontainer nicht
zuverlässig erzwingen, ein direkter Test auf Reihenfolge-Unabhängigkeit ist
daher aussagekräftiger als ein Versuch, das reale Nichtdeterminismus-Verhalten
nachzustellen.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Neuer
Test in `SyncSnapshotExportServiceTests` — zwei Snapshots mit identischem
fachlichen Inhalt, aber unterschiedlicher Reihenfolge sowohl der äußeren
Geschäfte-Liste als auch der inneren `typIDs`/`abteilungIDs`/
`alternativeNamen`/`ignorierteArtikelNamen` ergeben denselben Fingerabdruck.
Noch nicht mit echten Geräten nachverifiziert.

### 19. Nachtrag: Fingerabdruck-Fix reichte nicht — echte periodische Oszillation, plus manuelle Statuskonsolidierung

Live-Retest nach Abschnitt 18 (neuer Build auf beiden Geräten): `export.json`
wurde weiterhin bei praktisch jedem Zyklus neu geschrieben. Diesmal aber ein
konkreterer Befund: der Diagnose-Kurzhash für `geschaeftsTypen` (11 Einträge,
KEINE inneren ID-Arrays, keine Stelle im Code schreibt je auf `GeschaeftTyp`s
eigene Felder außer bei der Neuanlage) durchläuft über ~20 Zyklen einen exakt
wiederkehrenden 4-Werte-Zyklus (`9eb56318 → 87b5521b → b20f12e5 → 75007f91 →
9eb56318 → …`). Bei 32 Bit Hash-Raum ist ein zufälliges Zusammentreffen auf
exakt dieselben vier Werte über so viele Wiederholungen praktisch
ausgeschlossen — der zugrunde liegende Inhalt ändert sich also wirklich,
nicht bloß eine Diagnose-Artefakt-Fetch-Reihenfolge.

**Naheliegende Hypothese geprüft und verworfen:** Vermutet wurde, dass
`GeschaeftTyp.mitNamen` (unsortierter `FetchDescriptor` mit `fetchLimit = 1`)
bei lokalen Namens-Duplikaten nichtdeterministisch zwischen zwei
unterschiedlichen `GeschaeftTyp`-Objekten hin- und herwechseln könnte — anders
als `Abteilung`/`Geschaeft`/`Artikel` hat `GeschaeftTyp` kein
Alias-Register für Namenstreffer mit abweichender ID. Ein direkter Abgleich
der beiden vom Nutzer bereitgestellten `export.json`-Dateien (Endzustand nach
dem Test) zeigt jedoch: auf jedem Gerät exakt 11 `GeschaeftTyp`-Einträge ohne
Namens-Duplikate; die IDs unterscheiden sich zwar erwartungsgemäß zwischen den
Geräten (z.B. „Lebensmittel" `6CC8FD96` auf Bernhard vs. `628B6F3A` auf
Backup — nie über einen Alias vereinheitlicht, aber stabil pro Gerät), was für
sich genommen keine Oszillation erklärt, solange `mitNamen` innerhalb EINES
Geräts immer dasselbe Objekt zurückliefert. Die Hypothese ist damit nicht
bestätigt.

**Offen:** Die beiden bereitgestellten Dateien sind Endzustände nach Abschluss
des Tests, keine aufeinanderfolgenden Exports während der beobachteten
Oszillation — die genaue Ursache des 4-Werte-Zyklus ist damit noch nicht
lokalisiert. Nächster sinnvoller Diagnoseschritt: zwei tatsächlich
aufeinanderfolgende `export.json`-Exporte desselben Geräts sichern (z.B. durch
kurzzeitiges Kopieren zwischen zwei Zyklen) und byteweise diffen, statt sich
auf die 32-Bit-Kurzhashes im Protokoll zu verlassen.

**Pragmatischer Zwischenschritt:** Da die automatische Konvergenz auf zwei
Fristen wartet (48h Event-Give-up, Abschnitt 15/16; 30 Tage Peer-Snapshot-
Alter, ``SyncSnapshotImportService/maximalesSnapshotAlter``) — beide zu lang,
um sie in einem Testlauf abzuwarten — gibt es jetzt in den Debugging-
Einstellungen zwei manuelle Werkzeuge („Statuskonsolidierung erzwingen"):
- **Events aufräumen** (``SyncImportService/raeumeNichtAnwendbareEventsAuf(context:)``):
  setzt die Give-up-Schwelle für einen einzelnen Durchlauf auf 0 und gibt so
  alle aktuell nicht anwendbaren empfangenen Events sofort auf.
- **Export.json aufräumen** (``SyncSnapshotExportService/erzwingeFrischenExport(context:)``
  + ``SyncSnapshotImportService/raeumeVerwaisteFremdeExportsAuf()``): verwirft
  den eigenen Fingerabdruck-Cache und erzwingt einen sofortigen frischen
  Voll-Export, UND löscht fremde `export.json`-Dateien jenseits der
  30-Tage-Altersgrenze.

Beide rühren bewusst nicht an den eigenen, noch nicht abgeholten ausgehenden
Event-Dateien — siehe Abschnitt zur revertierten Event-Pruning-Regression
weiter oben, warum genau das schon einmal echte, noch nicht angekommene
Syncs zerstört hat.

**Zusätzlich gefunden und behoben, beim Prüfen der Merge-Logik auf diese
Fragestellung hin:** ``mergeAbteilungen``/``mergeGeschaefte``/
``vervollstaendige`` wiesen `lokal.typen`/`lokal.abteilungen`/
`lokal.ausgeschlosseneAbteilungen`/`lokal.geschaeftsTypen` bislang UNBEDINGT
das Ergebnis von `vereinigtGeordnet(...)` zu — auch dann, wenn sich dadurch
inhaltlich nichts änderte. Eine SwiftData-`@Relationship`-Eigenschaft gilt bei
jeder Zuweisung als verändert, unabhängig davon, ob der neue Wert inhaltlich
mit dem alten übereinstimmt — das erzwang bei praktisch jedem Merge-Durchlauf
ein `context.hasChanges == true` und damit einen echten `context.save()`,
selbst wenn kein Peer tatsächlich etwas Neues beitrug. Neuer Helfer
``vereinigeGeordnetFallsNoetig(_:mit:)`` weist nur noch zu, wenn sich das
Ergebnis tatsächlich vom bisherigen Wert unterscheidet. Dies allein erklärt
noch nicht den beobachteten 4-Werte-Zyklus in ``geschaeftsTypen`` (dessen
eigene Felder bleiben davon unberührt), reduziert aber unnötige Saves bei
jedem Sync-Zyklus unabhängig davon.

**Aus einem direkten Vergleich der vom Nutzer bereitgestellten
`export.json`-Dateien beantwortet: Kann iCloud Drive selbst (statt der App)
das wiederholte Neuschreiben auslösen?** Nein — ``sync_snapshot_geschrieben``
wird ausschließlich nach einem In-Prozess-SHA256-Fingerabdruck-Vergleich auf
bereits aus SwiftData geladenen, noch nicht auf die Festplatte geschriebenen
Daten protokolliert (``exportiereSnapshot(context:)``, vor jeder
Dateisystem-/Cloud-Interaktion). iCloud Drive/Synology Drive sind reine
Byte-Relays: sie können Datei-METADATEN (Änderungsdatum, Cloud-Status)
verändern, aber keine Inhalts-Bytes erfinden, die diesen Vergleich
beeinflussen könnten. Die Oszillationsursache liegt also mit Sicherheit in
der App-eigenen Datenschicht, nicht in der Cloud-Synchronisation selbst.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Noch
nicht mit echten Geräten nachverifiziert; die eigentliche Oszillationsursache
bleibt offen.

### 20. Nachtrag: unbegrenzt wachsende „Geister"-Einkaufsvorgänge — die eigentliche Hauptursache

Direkte Analyse zweier vom Nutzer bereitgestellter, echter `export.json`-
Dateien (nach dem Abschnitt-19-Fix) förderte den eigentlichen Haupttreiber
der andauernden Oszillation zutage: von 959 lokalen `Einkaufsvorgang`-
Objekten auf einem Testgerät hatten **907 weder ein `Geschaeft` noch eine
`Einkaufsliste`** — auf dem zweiten Testgerät waren es nur 13 von 106.
Darunter waren 800 leer, aber **107 hatten reale, angehängte `KaufEintrag`e**
(echte Käufe wie „Bananen", „Äpfel", „Intermezzo", „Knoppers", „Hackfleisch").

**Erklärt mehrere zuvor beobachtete Symptome auf einen Schlag:**
- Warum ein Gerät „sehr lange einen anderen Zustand bei den abgehakten
  Artikeln" hatte, der „nicht sauber synchronisiert" hat: Abhaken landete auf
  einem für die App unsichtbaren „Geister"-Vorgang statt auf dem geteilten,
  sichtbaren.
- Warum `export.json` „weiter oszillierte, obwohl keine Aktion am Gerät
  vorgenommen wurde": der reine, automatisch laufende Sync-Zyklus reicht
  bereits aus, um aus bereits vorhandenen baumelnden Referenzen immer neue
  Geister-Vorgänge zu erzeugen — keine Nutzerinteraktion nötig.
- Vermutlich (nicht abschließend bestätigt) auch die frühere Beobachtung
  „einmal abgehakte Artikel erscheinen kurz und verschwinden wieder".

**Ursache:** ``SyncSnapshotImportService/mergeEinkaufsvorgaenge`` legte im
„else"-Zweig (kein bekannter, kein offener Treffer, kein Tombstone) auch dann
einen neuen lokalen ``Einkaufsvorgang`` an, wenn sowohl `remoteGeschaeft` als
auch `remoteListe` `nil` waren — d.h. die entsprechende Referenz war bereits
auf dem SENDENDEN Gerät baumelnd (``sichereID`` ließ sie dort beim Export
weg, das JSON-Feld fehlt komplett). Ein solcher Vorgang ist für die gesamte
App unerreichbar: ``EinkaufenView/aktuellerEinkauf`` und
``Einkaufsvorgang/offenerNachfolger(fuerListe:...)`` verlangen beide immer
eine konkrete Liste. Jeder weitere baumelnde Fremd-Eintrag (unabhängig vom
genauen Entstehungsmechanismus der ursprünglichen Baumelnd-Referenz — dazu
siehe „Offen" unten) erzeugte dadurch einen weiteren, für immer unsichtbaren
Geister-Vorgang.

**Fix:** Der „else"-Zweig verwirft jetzt Einträge ohne auflösbare
`remoteListe` (`continue`, kein Anlegen) — analog zum bereits bestehenden
`geloeschteIDs`-Fall. Ein fehlendes `remoteGeschaeft` bleibt weiterhin
legitim (Einkauf ohne gewähltes Geschäft ist Normalfall). Neuer Test
``einkaufsvorgangOhneAufloesbareListeWirdNichtAngelegt`` in
`SyncSnapshotImportServiceTests`.

**Bewusst NICHT Teil dieses Fixes:** Bereinigung der bereits vorhandenen 907
Geister-Vorgänge (inkl. der 107 echten, angehängten Käufe) auf betroffenen
Geräten — `Einkaufsvorgang.kaufEintraege` hat `deleteRule: .cascade`, ein
blindes Löschen der Vorgänge würde die 107 echten Käufe unwiderruflich
mitlöschen. Auf Nutzerwunsch zunächst nur der Root-Cause-Fix; eine
Datenrettung (KaufEinträge auf einen echten Vorgang derselben Liste
umhängen) ist ein separater, noch zu planender Schritt.

**Offen:** Der genaue Entstehungsmechanismus der URSPRÜNGLICHEN baumelnden
Referenz (auf welchem Gerät, durch welche Aktion, wurde die allererste
Einkaufsliste-Referenz eines Einkaufsvorgangs baumelnd?) ist nicht
abschließend geklärt — einziger Konstruktor-Aufrufer mit frischer `UUID` ist
``EinkaufenView/einkaufSicherstellen()``, der aber immer eine konkrete
`ausgewaehlteListe` voraussetzt; die Nullness trat erst beim EXPORT auf
(``sichereID``-Dangling-Schutz). Möglicher Zusammenhang mit der vom Nutzer
beschriebenen Situation „auf beiden Geräten wurde Einkauf abschließen
gewählt, obwohl der abgehakte-Artikel-Count unterschiedlich war" — noch nicht
verifiziert.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Noch
nicht mit echten Geräten nachverifiziert.

### 21. Nachtrag: Beobachtbarkeit statt „nie destruktiv" aufgeben — zwei konkrete Bausteine

Nachtrag zur Diskussion in Abschnitt 20 („DB-Sync ist korrupt — wie automatisiert
wieder herauskommen"): die additive „nie destruktiv"-Merge-Regel bleibt bestehen
— sie ist nicht in erster Linie eine Korruptions-Absicherung, sondern die
laufende Korrektheits-Grundlage für gleichzeitiges Bearbeiten auf mehreren
Geräten ohne Feld-Zeitstempel/Lamport-Uhr für Bereich B (siehe Typ-Doku
``SyncSnapshotImportService``). Der hier untersuchte Vorfall entstand nicht,
weil additives Mergen versagte, sondern weil ein Bug im ERZEUGEN (Abschnitt 20)
Datenmüll produzierte, den additives Mergen anschließend korrekt replizierte.
Die beiden einzigen Stellen, an denen dieses Projekt überhaupt Daten verlieren
kann, sind (a) Bugs, die fälschlich erzeugen, und (b) der eine bewusst
destruktive Pfad, ``SyncErsetzenService`` (Ersetzen/Neuaufbau) — beide jetzt
zusätzlich abgesichert:

**1. Vorher-/Nachher-Zusammenfassung beim Neuaufbau
(``SyncErsetzenService/NeuaufbauZusammenfassung``):** Ein „Gerät zurücksetzen
und von Sync-Gerät neu aufbauen" lieferte bisher keinerlei Rückmeldung darüber,
was tatsächlich zurückkam — der auslösende Live-Test-Fund (3 statt 2
Einkaufslisten nach einem Neuaufbau) blieb deshalb tagelang unbemerkt und wurde
als „Datenfehler, hat aber nicht gestört" abgetan. Da ``erstelleBackup``
ohnehin einen vollständigen Vorher-Snapshot sichert, kostet der Vergleich
nichts Neues: ``fuehreAusstehendeAktionAus(context:)`` berechnet nach einem
`.ersetzenDurchPeer`-Neuaufbau direkt einen frischen Nachher-Snapshot und
vergleicht beide je Bereich (``BereichsZaehler``). Das Ergebnis wird
persistiert und in ``DebuggingView`` (dort, wo der Reset auch ausgelöst wird)
als Karte mit Zeile je verändertem Bereich angezeigt, Rückgänge rot
hervorgehoben — bis zum expliziten Ausblenden. Das bestehende „Backup
wiederherstellen" (Backup wird bei `.ersetzenDurchPeer` bewusst NICHT
gelöscht) bleibt direkt daneben als Rückgängig-Option sichtbar.

**2. Erkennung listenloser Einkaufsvorgänge + Wachstums-Warnung
(``DatenintegritaetsService``):** Die bestehende Prüfung auf baumelnde
Referenzen (``istBaumelnd``) erkennt eine baumelnde `persistentModelID`
(Absturzrisiko), nicht aber einen gültigen `nil`-Bezug — genau das, was
Abschnitt 20 als eigentliche Fehlerabteilung „orphaned" (semantisch
unerreichbar, aber crash-sicher) identifiziert hat. ``pruefe(context:)``
prüft jetzt zusätzlich auf ``Einkaufsvorgang``e ohne ``Einkaufsliste`` — als
EINE aggregierte Zeile (nicht eine je betroffenem Vorgang, damit ein
künftiger ähnlicher Bug den Bericht nicht selbst wieder unbrauchbar macht,
siehe die 907 Einträge aus Abschnitt 20), inklusive der Anzahl real
angehängter ``KaufEintrag``e. Zusätzlich wird die Anzahl zwischen zwei
Prüfungen verglichen: eine reine Bestandszahl verrät für sich genommen nicht,
ob sie über Wochen langsam getröpfelt ist oder gerade akut wächst
(beobachtet: 875 an einem einzigen Tag) — ein Zuwachs über
``DatenintegritaetsService/warnschwelleSchnellesWachstum`` (Standard: 10)
seit der letzten Prüfung wird deshalb zusätzlich sichtbar markiert (⚠️).
Bewusst an der bestehenden, immer aktiven „läuft bei jedem App-Start"-Stelle
verankert statt als neue, tief in der Merge-Hot-Path verankerte Instrumentierung
— einfacher, robuster, und misst direkt die Größe, die eigentlich interessiert
(Anzahl unerreichbarer Objekte), statt einen Proxy dafür (Erzeugungen je
Merge-Durchlauf).

**Bewusst nicht Teil dieses Nachtrags:** eine automatische Reparatur/Bereinigung
der bereits vorhandenen 907 Geister-Vorgänge (siehe Abschnitt 20, dort auf
Nutzerwunsch zurückgestellt) sowie eine generische, geräteübergreifende Sperre
gegen gleichzeitiges Zurücksetzen mehrerer Geräte — bei nur zwei real
genutzten Geräten wird das als unverhältnismäßig eingeschätzt; ein deutlicherer
Warnhinweis im bestehenden Bestätigungsdialog wäre die proportionale Antwort,
sofern gewünscht.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Neue
Tests in `SyncErsetzenServiceTests` (Vorher-/Nachher-Zusammenfassung) und
`DatenintegritaetsServiceTests` (aggregierte Meldung, Wachstums-Warnung). Noch
nicht mit echten Geräten nachverifiziert.

## 22. Behobener Bug: neu beigetretenes Gerät synchronisiert keine Bestandsdaten (GitHub #52); teilbehobenes Problem: langsamer App-Start (GitHub #55)

*(Verschoben aus `docs/DATABASE_CONCURRENCY.md` — thematisch Bereich-A/B-Import,
gehört hierher statt in die lokale Schreibkoordinations-Doku.)*

**Symptom (#52):** Tritt ein Gerät einem bereits genutzten geteilten
Sync-Ordner neu bei (`SyncOrdnerSettingsView.ordnerFestlegen`, löst sofort
einen ersten Sync-Zyklus aus), wurden trotz vorhandener Peer-Daten im Ordner
keine Daten auf das neue Gerät übernommen. Bereits länger im Share aktive
Geräte waren von dem Bug nicht betroffen.

**Ursache:** Die Schreibpfade (`SyncExportService`, `SyncSnapshotExportService`)
nutzten bereits `NSFileCoordinator`, um File-Provider-Erweiterungen (iCloud
Drive, Synology Drive, …) korrekt einzubinden. Die Lesepfade
(`SyncImportService.importiereNeueEvents`, `SyncSnapshotImportService.importiereSnapshots`)
lasen dagegen ungeschützt per `Data(contentsOf:)`. Eine Datei, die von einer
File-Provider-Erweiterung verwaltet wird, aber auf einem Gerät noch nie
heruntergeladen wurde, liegt dort nur als Cloud-Platzhalter vor — ein
direktes `Data(contentsOf:)` schlägt dafür sofort fehl (per `try?` still
verschluckt), statt auf die Materialisierung zu warten. Bestehende Geräte
hatten alle Peer-Dateien durch frühere Sync-Zyklen längst lokal
zwischengespeichert, ein neu beitretendes Gerät sah sie zum allerersten Mal
— daher trat der Bug ausschließlich beim ersten Sync auf.

**Fix:** Neuer Helfer `SyncDateiZugriff.leseKoordiniert(_:)`, der die Datei
über `NSFileCoordinator.coordinate(readingItemAt:...)` liest — das löst bei
Bedarf zuverlässig den Download/die Materialisierung aus, bevor gelesen wird
(providerunabhängig, im Gegensatz zum iCloud-spezifischen
`startDownloadingUbiquitousItem`). Da dieser Aufruf für die Dauer eines
Downloads blockieren kann, läuft er in beiden Importpfaden in einem
`Task.detached`, damit dabei nicht der `MainActor` blockiert wird.

**Symptom (#55):** Der App-Start (und jede Rückkehr aus dem Hintergrund)
fühlte sich kurzzeitig träge an — `SyncPollingService.starten(context:)` löst
dabei bewusst sofort einen ersten Sync-Zyklus aus (Nutzerentscheidung für
möglichst aktuelle Daten), der direkt mit dem initialen SwiftUI-Rendering um
den `MainActor` konkurriert.

**Umgesetzte Teilmaßnahme:** Der Polling-Loop läuft mit expliziter
`.utility`-Priorität statt der ererbten Standardpriorität — signalisiert dem
kooperativen Scheduler, konkurrierende UI-Arbeit vorzuziehen. Ergänzt die
oben beschriebene Auslagerung der Datei-I/O in `Task.detached`.

**Bewusst nicht umgesetzt (größere Änderung, eigene Entscheidung nötig):**
Die eigentliche Merge-/Speicherlogik (`SyncSnapshotImportService.merge`,
`context.save()`, `SyncSnapshotExportService.erstelleSnapshot`) bleibt
synchrone, `MainActor`-gebundene Arbeit — bei umfangreichem lokalem Bestand
kann ein einzelner Sync-Zyklus dadurch weiterhin spürbar Zeit auf dem
Hauptthread beanspruchen. Eine vollständige Lösung bräuchte einen zweiten,
hintergrundgebundenen `ModelContext` für die Merge-Berechnung mit
anschließendem Rücktransfer der Ergebnisse — ein größerer Architektur-Eingriff,
der eine eigene Bewertung verdient, sollte die Priority-Maßnahme allein nicht
ausreichen. Die Zyklusdauer-Protokollierung (`SyncDebugLogger`,
`sync_zyklus_start`/`-ende`) liefert dafür bei Bedarf echte Messdaten statt
Vermutungen — die DB-Optimierungsrunde in Abschnitt 14 dürfte die tatsächlich
gemessene Zyklusdauer bereits spürbar gesenkt haben, unabhängig von diesem
weiterhin zurückgestellten Eingriff.

## 23. Sichere automatische Bereinigung der leeren Geister-Vorgänge

Nachtrag zu Abschnitt 20/21: von den dort gefundenen 907 listenlosen
Einkaufsvorgängen auf einem Testgerät waren 800 leer (keine angehängten
`KaufEintrag`e) — deren Löschung ist beweisbar verlustfrei, anders als die
„baumelnde Referenz"-Fälle, die `DatenintegritaetsService` seit jeher nur
meldet, nie repariert (siehe Typ-Doku dort): ein `nil`-Bezug ist kein
Absturzrisiko, das Löschen muss also keine bereits ungültige Gegenseite
auffalten.

`DatenintegritaetsService.raeumeLeereListenloseVorgaengeAuf(context:)` läuft
jetzt automatisch bei jedem App-Start, direkt vor `pruefe(context:)` (siehe
`ShopWithMeApp.init()`), löscht ausschließlich Vorgänge ohne Liste UND ohne
Käufe, und protokolliert die Anzahl über `DatenintegritaetsLogger`. Vorgänge
MIT angehängten Käufen (im beobachteten Fall 107) werden bewusst NICHT
automatisch gelöscht (`Einkaufsvorgang.kaufEintraege` hat `deleteRule:
.cascade` — ein blindes Löschen würde die echten Käufe mitlöschen) und
bleiben Gegenstand des Berichts, bis eine gezielte Wiederherstellung
(KaufEintraege auf einen echten Vorgang derselben Liste umhängen) separat
entschieden ist.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Neuer
Test `raeumtNurLeereListenloseVorgaengeAufUndBehaeltSolcheMitKaeufen` in
`DatenintegritaetsServiceTests`. Noch nicht mit echten Geräten
nachverifiziert.

## 24. Reparaturstrategie für baumelnde Referenzen ohne SQLite-Direktzugriff

`DatenintegritaetsService` konnte baumelnde Referenzen seit jeher nur melden,
nie reparieren (siehe dessen Typ-Doku) — jede schreibende Operation auf eine
bereits baumelnde `@Relationship(inverse:)`-Beziehung crasht, weil SwiftData
beim Nullen/Löschen die alte Gegenseite auffalten muss, und genau die ist ja
bereits ungültig. `docs/DATABASE_CONCURRENCY.md` schätzte eine echte
rückwirkende Reparatur deshalb als „bräuchte einen direkten Zugriff auf die
SQLite-Datei unterhalb von SwiftData/CoreData (nicht trivial, noch nicht
umgesetzt)" ein.

**Erkenntnis: dieser Zugriff ist gar nicht nötig — die Lösung existiert
bereits, nur an einer anderen Stelle im Code.**
``SyncSnapshotExportService/erstelleSnapshot(context:)`` liest jede
Relationship über ``sichereID(_:gueltigeIDs:)``, das ausschließlich die
sicher lesbare `persistentModelID` prüft und bei einer baumelnden Referenz
still `nil` statt der `id` liefert — ein frischer Export des AKTUELLEN, ggf.
bereits korrumpierten Bestands enthält baumelnde Referenzen dadurch
strukturell nicht mehr, ganz ohne sie aktiv zu „reparieren". Und
`SyncErsetzenService` hat mit „Store-Datei löschen, dann ausschließlich aus
einem Snapshot neu aufbauen" (Abschnitt 13) bereits einen getesteten,
sicheren Mechanismus dafür — bisher nur für Peer-Snapshots und für zuvor
explizit erstellte eigene Backups genutzt.

**Fix:** Neue, drei Zeilen lange Funktion
``SyncErsetzenService/planeBereinigungBaumelnderReferenzen(context:)`` —
erstellt JETZT ein Backup (= frischer, dangling-freier Snapshot des aktuellen
Bestands) und merkt dessen Wiederherstellung für den nächsten Start vor,
identischer Mechanismus wie `planeWiederherstellenAusBackup()`, nur mit
einem eben erst statt irgendwann früher erstellten Snapshot. Neuer
UI-Einstiegspunkt in `DebuggingView.DatenintegritaetSection`, nur sichtbar,
wenn `pruefe(context:)` tatsächlich etwas gemeldet hat: „Baumelnde Referenzen
bereinigen (ohne Sync-Gerät)…" — funktioniert unabhängig von einem
konfigurierten Sync-Ordner, da nichts von einem Peer gebraucht wird.

**Bewusst kein Test, der den vollständigen Reparatur-Rundlauf gegen eine
echte baumelnde Referenz verifiziert** — aus demselben Grund wie in
`DatenintegritaetsServiceTests` dokumentiert: seit den
`@Relationship(inverse:)`-Deklarationen lässt sich eine echte baumelnde
Referenz mit dem aktuellen Modell nicht mehr über eine normale
Programmoperation künstlich erzeugen, sie betrifft ausschließlich
Alt-Bestände von vor deren Einführung. Verifiziert wird stattdessen der
Mechanismus selbst (Backup wird erstellt, richtige Aktion vorgemerkt,
aktueller Store unverändert) — analog zum bestehenden Test für
`planeErsetzenDurchPeer`.

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Neuer
Test in `SyncErsetzenServiceTests`. Der volle Ablauf (echte baumelnde
Referenz auf einem Altbestand → Bereinigung → Neustart → repariert) ist
mangels künstlich erzeugbarer Testreferenz nicht automatisiert verifizierbar
und bräuchte eine manuelle Prüfung auf einem betroffenen Altgerät.

## 25. Systematischer Audit aller Merge-Pfade (nach Nutzeranfrage: "könnte das wieder passieren?")

Auslöser: nach dem Live-Test der Abschnitt-20/24-Fixes verlor ein bereits
betroffener Einkaufsvorgang unerwartet seine `endZeit` (wurde von
"geschlossen" zu "offen"), obwohl `endZeit` im gesamten Code nur an EINER
Stelle je gesetzt wird (`Einkaufsvorgang.abschliessen(am:)`) und nirgends
genullt — der Verdacht auf einen zusätzlichen, noch unentdeckten Merge-Bug
lag nahe. Systematisch geprüft: jede `mergeX`-Funktion in
`SyncSnapshotImportService` sowie die analogen Bereich-A-Auflösungspfade in
`SyncImportService`, gegen vier Kriterien:

1. Validiert der "neu anlegen"-Zweig alle strukturell erforderlichen
   Referenzen, bevor ein neues, sonst unerreichbares Objekt entsteht
   (Abschnitt-20-Klasse)?
2. Überschreibt irgendein Zweig einen bereits gesetzten Wert, statt nur
   Lücken zu füllen (verletzt "nie destruktiv")?
3. Sind Relationship-Neuzuweisungen bedingt (vermeidet unnötiges
   `context.hasChanges`, Abschnitt 19-Klasse)?
4. Kann ein `nil`-Optional auf beiden Seiten eines Vergleichs fälschlich als
   "Treffer" gewertet werden, obwohl `nil` für dieses Feld tatsächlich
   *kaputt* statt *legitim leer* bedeutet?

**Gefunden und behoben — Kriterium 4, echter Bug:**
`mergeEinkaufsvorgaenge`s `offenerTreffer`-Zweig verglich
`$0.einkaufsliste == remoteListe`, OHNE zu prüfen, ob `remoteListe`
überhaupt einen echten Wert hat. Da `nil == nil` in Swift `true` ist, konnte
ein lokal bereits offener, selbst schon kaputter (`einkaufsliste == nil`)
Vorgang als "derselbe reale Einkauf" für einen völlig unabhängigen
Fremd-Eintrag durchgehen, dessen `einkaufslisteID` aus demselben Grund wie in
Abschnitt 20 unauflösbar war (baumelnd auf dem sendenden Gerät) — zwei
voneinander unabhängige, je für sich schon kaputte Referenzen wurden dadurch
fälschlich zusammengeführt (Alias registriert, `endZeit` vom fremden Eintrag
übernommen). Das erklärt sehr wahrscheinlich (nicht abschließend mit Zugriff
auf das Gerät verifiziert) den beobachteten Fall, in dem ein Vorgang nach
einem Reparaturlauf plötzlich eine fremde `endZeit` verlor bzw. gewann.

**Fix:** Der Guard „ohne auflösbare `remoteListe` nicht verarbeitbar" (bisher
nur im „neu anlegen"-Zweig, Abschnitt 20) greift jetzt VOR jedem Matching-
Versuch (`offenerTreffer` eingeschlossen) — nur der bereits ID-/Alias-basiert
gefundene `bekannter`-Zweig bleibt davon unberührt, da ein expliziter
ID-Treffer unabhängig von der aktuellen Listen-Auflösbarkeit vertrauenswürdig
bleibt. Neuer Test
`bereitsBaumelnderLokalerVorgangWirdNichtMitUnabhaengigemFremdeintragOhneListeVermischt`.

**Geprüft und als unbedenklich eingestuft (keine Änderung nötig):**
- `Einkaufsvorgang.offenerNachfolger(fuerListe:...)` verlangt einen
  konkreten, nicht-optionalen `Einkaufsliste`-Parameter — kann strukturell
  nicht auf dieselbe Art fälschlich `nil` gegen `nil` matchen.
- `SyncImportService.aufOffenenNachfolgerUmgeleitet` (Bereich-A-Pendant)
  entpackt `vorgang.einkaufsliste` explizit vor dem Aufruf desselben
  `offenerNachfolger`-Helfers — dieselbe Absicherung, unabhängig geprüft.
- `mergeWarengruppenDistanzen`s Matching auf `$0.geschaeft == geschaeft`
  vergleicht ebenfalls zwei Optionals, aber `WarengruppenDistanz.geschaeft`
  ist ein bewusst legitim-optionales Feld (geschäftsunabhängige,
  „stadtweite" Distanz) — anders als bei `Einkaufsvorgang.einkaufsliste`
  bedeutet `nil` hier keine Kaputtheit, sondern einen echten fachlichen
  Zustand. Kein Bug.
- `mergeGeschaefte`/`mergeArtikel`/`mergeAbteilungen`/
  `mergeEinkaufslisten`: alle vier Entitätstypen sind IMMER eigenständig
  über ihre jeweilige Verwaltungsansicht erreichbar (keine „braucht X, um
  sichtbar zu sein"-Abhängigkeit wie bei `Einkaufsvorgang`) — ein „neu
  anlegen" ohne vollständige Zusatzdaten erzeugt hier höchstens ein
  unvollständiges, aber niemals ein unerreichbares Objekt.
- `mergeKaufEintraege`: `artikel`/`geschaeft`/`abteilung`/`einkaufsvorgang`
  dürfen alle `nil` sein (behält dafür bewusst die Schnappschuss-Namen) —
  bleibt trotzdem in der Preishistorie sichtbar, keine Unerreichbarkeit.
- `mergeWarengruppenDistanzen`s „neu anlegen"-Zweig validiert bereits
  korrekt VOR dem Anlegen (`guard let abteilungA = ..., let abteilungB = ...
  else { continue }`) — ein bereits existierendes gutes Beispiel für
  Kriterium 1, an dem sich der Abschnitt-20-Fix orientiert hat.
- Alle `vereinigeGeordnetFallsNoetig`-Aufrufstellen (Kriterium 3) wurden
  bereits in Abschnitt 19 vollständig auf die bedingte Variante umgestellt,
  keine verbliebene unbedingte Zuweisung gefunden.

**Bewusst nicht abschließend geklärt:** ob dieser Fund die BEOBACHTETE
`endZeit`-Änderung vollständig erklärt, bleibt ohne erneuten Live-Test auf
demselben (inzwischen ohnehin für einen Neuaufbau vorgesehenen) Datenbestand
unverifizierbar — die Vermengung aus historisch bereits kaputten Daten
(vor Abschnitt 20/24) und aktivem Code macht eine nachträgliche Rekonstruktion
unzuverlässig. Ein Neuaufbau ab einem sauberen Bestand schafft hierfür die
nötige Eindeutigkeit: jede ab jetzt neu auftretende Anomalie ist dann
zweifelsfrei ein noch aktiver Bug, keine Altlast.

**Genereller Hinweis für künftige Merge-Regeln:** „vergleicht zwei Optionals
auf Gleichheit" ist immer ein Prüfpunkt wert — die entscheidende Frage ist
jeweils, ob `nil` für dieses konkrete Feld ein legitimer Fachzustand ist
(dann ist ein `nil==nil`-Treffer korrekt) oder ob es „nicht auflösbar/kaputt"
bedeutet (dann muss `nil` von jedem Matching-Versuch ausgeschlossen werden,
siehe Abschnitt 20).

**Verifikationsstand:** `xcodebuild build`/`build-for-testing` grün. Neuer
Test in `SyncSnapshotImportServiceTests`. Noch nicht mit echten Geräten
nachverifiziert — geplant nach dem vom Nutzer angekündigten Neuaufbau.

## 26. Lesbare Peer-Ordnernamen (GitHub #81)

**Anforderung:** Peer-Ordner unter `peers/` sollten sich im geteilten
Sync-Ordner (Finder/Dateien-App) schneller einem Gerät zuordnen lassen —
bisher trug der Ordner ausschließlich die rohe `geraeteID` (eine UUID), ohne
jeden Bezug zum vom Anwender vergebenen Gerätenamen. Zwei Alternativen
erwogen: (A) Ordnername = reiner Gerätename, UUID/Kurz-Suffix nur bei
tatsächlicher Namenskollision angehängt — issue-nah, aber erfordert eine
Kollisionsprüfung über den Inhalt anderer Peer-Ordner sowie eine zusätzliche
Identitäts-Referenz je Ordner. (B) Ordnername = Gerätename + Kurz-Suffix aus
der Geräte-ID, das Suffix **immer**, nicht nur bei Kollision — gewählt, da
dadurch jede Kollisionsprüfung strukturell entfällt, bei kaum schlechterer
Lesbarkeit.

**Wichtiger Fund vor der Umsetzung:** `SyncSnapshotImportService.merge(_:peerGeraeteID:context:)`
erhielt seine `peerGeraeteID` bisher aus dem **Ordnernamen**
(`peerOrdner.lastPathComponent`), nicht aus dem dafür vorgesehenen
`SyncSnapshot.geraeteID`-Feld — funktionierte nur, weil beide bislang
zufällig identisch waren (Ordnername == rohe UUID). `peerGeraeteID` ist
darüber die interne Peer-Identität von `SyncPeerInfo`/`SyncPeerZaehlerStand`
(Abgleich gegen `SyncEvent.autorGeraeteID`, siehe Abschnitt 2 in
`docs/DATENSYNCHRONISATION.md`) — hätte man den Ordnernamen wie geplant vom
Gerätenamen abhängig gemacht, OHNE diese Stelle zu korrigieren, wäre für
jeden Peer, der auf das neue Ordnerschema umgestellt hat, eine NEUE,
unpassende `peerGeraeteID` entstanden: `SyncPeerInfo.geraeteName(fuer:
autorGeraeteID:)` hätte den Peer nicht mehr gefunden (falsche
Anzeigenamen bei „bereits abgehakt von …"), und der additive
Cross-Device-Zähler (`SyncPeerZaehlerStand`, siehe Abschnitt 14) hätte den
Zählerstand dieses Peers als „neu, noch nie gesehen" behandelt und dessen
kompletten aktuellen Wert einmalig addiert statt nur das seit dem letzten
Abgleich entstandene Delta — ein Doppelzählungs-Bug derselben Klasse, vor der
Abschnitt 14 bereits einmal warnt. Fix im selben Schritt: `merge(...)`
verwendet jetzt `snapshot.geraeteID` statt des Ordnernamens; der Ordnername
ist seither vollständig entkoppelt von jeder internen Identität.

**Umsetzung:**
- `PeerOrdnerName` (neuer Typ): `kurzeID(_:)` (6 Hex-Zeichen der UUID),
  `bereinigterName(_:)` (dateisystem-sichere Zeichen, max. 40 Zeichen,
  Fallback „Geraet" bei restlos leerem Namen), `name(geraeteID:geraeteName:)`,
  `gehoertZu(_:geraeteID:)` (erkennt sowohl das neue Schema als auch alte,
  reine UUID-Ordner von vor diesem Issue).
- `SyncOrdnerService.eigenerPeerOrdnerName(in:)`: liefert den aktuellen
  Zielnamen, zwischengespeichert in `UserDefaults`. Weicht der neu berechnete
  Zielname vom zwischengespeicherten (oder, beim allerersten Aufruf nach
  einem Update, von der alten reinen `geraeteID`) ab, wird der **bestehende**
  Ordner umbenannt (`FileManager.moveItem`), nicht neu angelegt — sonst
  blieben dort noch nicht von Peers abgeholte Event-Dateien verwaist liegen
  (vgl. Abschnitt „Kein Aufräumen alter Event-Dateien" in
  `SyncExportService`). Läuft synchron im bereits bestehenden
  Security-Scope-Block der Export-Funktionen.
- `SyncExportService.eigenerEventsOrdner(in:)`/`SyncSnapshotExportService.eigeneExportURL(in:)`:
  jetzt `@MainActor` (wie `DatabaseLeaseService.geraeteName`), nutzen den
  neuen Ordnernamen statt der rohen `geraeteID`.
- Alle „eigenen Ordner überspringen"-Filter (`SyncOrdnerService.hatVorhandenePeers`,
  `SyncImportService.importiereNeueEvents`, `SyncSnapshotImportService.importiereSnapshots`/
  `raeumeVerwaisteFremdeExportsAuf`) verwenden jetzt `PeerOrdnerName.gehoertZu(_:geraeteID:)`
  statt eines exakten String-Vergleichs mit der rohen `geraeteID`.
- `DebuggingView.peerEntfernen`: baute den zu löschenden Ordner bisher direkt
  aus `peer.peerGeraeteID`; scannt jetzt `peers/` und löscht per
  `PeerOrdnerName.gehoertZu(_:geraeteID:)` den tatsächlich passenden Ordner
  (kann nach obigem Fix vom Ordnernamen abweichen).
- Die reine Foreign-Peer-Lesepfad-Konstruktion (`eventsOrdner(fuerPeer:)`/
  `exportURL(fuerPeer:)`, aufgerufen mit `peerOrdner.lastPathComponent` aus
  einer bereits vorliegenden Ordnerliste) brauchte KEINE Änderung — sie baut
  ohnehin nur denselben, bereits enumerierten Ordnernamen zu einem Unterpfad
  zusammen, unabhängig vom gewählten Namensschema.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build` grün. Neue
Tests `PeerOrdnerNameTests`, `SyncOrdnerServiceTests` (Umbenennung ohne
Datenverlust, `hatVorhandenePeers` erkennt neues und altes Schema). Kein
eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention). Noch
nicht mit echten Geräten live nachverifiziert.

## 27. Verwaiste KaufEintraege durch unauflösbare Vorgangs-Referenz im Snapshot-Merge

**Anlass:** Nutzer-Analyse zweier realer `export.json`-Dateien (Peers
„Bernhard"/„Backup"), nachdem trotz ausgelöster `KaufEintragBereinigungService`-
und Event-Auflösungs-Läufe die Datei weiter wuchs statt zu schrumpfen. `kaufEintraege`
machte 56% der Dateigröße aus; davon hatten 53% (Peer „Bernhard") bzw. 59%
(Peer „Backup") `einkaufsvorgangID == nil` — konsistent auf beiden Geräten, und
nicht auf alte Daten beschränkt (die meisten verwaisten Einträge waren wenige
Tage alt).

**Root Cause (zwei Teile, siehe auch Audit-Checkliste in dieser Session unter
„Merge-/Abgleichslogik: `nil` gegen `nil` niemals blind als Treffer werten" im
Skill `ios-swift-engineering`):**

1. `KaufEintragBereinigungService.bereinigen` filterte bisher ausschließlich
   über `($0.einkaufsvorgang?.endZeit).map { $0 < stichtag } ?? false` — für
   `einkaufsvorgang == nil` liefert das immer `false`. Ein einmal verwaister
   Eintrag war dadurch **strukturell unlöschbar**, unabhängig vom Alter.
2. Die eigentliche Entstehung: `SyncSnapshotImportService.mergeKaufEintraege`
   setzte `neuer.einkaufsvorgang = eintrag.einkaufsvorgangID.flatMap {
   einkaufsvorgangZuordnung[$0] }` bedingungslos. War der referenzierte
   `Einkaufsvorgang` auf diesem Gerät nicht auflösbar (z.B. bereits per
   Tombstone gelöscht — `mergeEinkaufsvorgaenge` überspringt einen solchen
   Vorgang bewusst, siehe Abschnitt 20, nimmt ihn aber dadurch auch nicht in
   die zurückgegebene `einkaufsvorgangZuordnung` auf), wurde der `KaufEintrag`
   trotzdem angelegt — nur eben verwaist. Bei geteilten Listen/Vorgängen
   zwischen zwei Geräten mit unterschiedlich schneller Aufräum-Karenzzeit
   entstehen dadurch laufend neue Waisen, nicht nur einmalig historische.

**Fix:**
- `mergeKaufEintraege`: überspringt einen Remote-Eintrag jetzt vollständig,
  wenn er einen `einkaufsvorgangID` referenziert, der in
  `einkaufsvorgangZuordnung` fehlt — analog dazu, wie sein Vorgang selbst
  übersprungen wird, statt ihn wie seinen Vorgang orphaned anzulegen.
- `KaufEintragBereinigungService.bereinigen`: der Filter erfasst jetzt
  zusätzlich jeden Eintrag mit `einkaufsvorgang == nil` — sofort, ohne
  Karenzzeit, da ein solcher Eintrag nie eine fachliche Funktion hatte (anders
  als ein gerade erst abgeschlossener Vorgang, bei dem die Karenzzeit einem
  nachträglichen Belegscan Zeit gibt).

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build-for-testing`
grün, keine neuen Warnungen. Neue Regressionstests:
`KaufEintragBereinigungServiceTests.bereinigenLoeschtVerwaisteEintraegeOhneEinkaufsvorgangSofortMitTombstone`,
`SyncSnapshotImportServiceTests.kaufEintragMitUnaufloesbaremEinkaufsvorgangWirdNichtVerwaistAngelegt`.
Kein eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention).
Der bestehende Datenbestand in den beiden analysierten `export.json`-Dateien
wird durch den Fix NICHT rückwirkend bereinigt, bevor die App auf den
Geräten neu gestartet wird und `KaufEintragBereinigungService` erneut läuft.

## 28. Nicht-deterministischer Sync-Fingerabdruck (GitHub #78) + manueller Sofort-Bereinigungs-Button

**Anlass:** Nutzer-Nachfrage, nachdem drei zeitnah hintereinander erzeugte
`export.json`-Kopien desselben Geräts trotz Abschnitt-27-Fix weiterhin groß
blieben und sich die Datei bei jedem Zyklus änderte. Vergleich der drei
Dateien nach ID-Sortierung: **inhaltlich zu 100% identisch** (einzige
Differenz `erzeugtAm`) — trotzdem unterschied sich die Top-Level-
Schlüsselreihenfolge zwischen den Dateien.

**Zwei getrennte Befunde:**

1. **Größe unverändert (278 KaufEintraege, 147 verwaist):** kein neuer Bug —
   der Abschnitt-27-Fix war bereits im Code, aber `bereinigen(context:)` läuft
   ausschließlich über `automatischBereinigenFallsFaellig`, dessen 24h-Sperre
   (`letzteBereinigung` in `UserDefaults`) durch einen bereits VOR dem Fix
   ausgelösten Lauf desselben Tages blockiert war. Ein Neustart der App am
   selben Tag löst dadurch keinen erneuten automatischen Lauf aus, unabhängig
   vom Codestand.
2. **Datei wird trotzdem bei jedem Zyklus neu geschrieben (GitHub #78):**
   `SyncSnapshotExportService` nutzte an drei Stellen (Datei-Schreiben,
   `inhaltsFingerabdruck(of:)`, `diagnoseText(of:)`) jeweils eine eigene
   `JSONEncoder()`-Instanz ohne `.sortedKeys`. Die *inneren* Arrays werden
   zwar bereits vor dem Encoding deterministisch sortiert
   (`normalisiertFuerVergleich`, siehe Abschnitt 22-Nachfolgefund oben), aber
   Foundations `JSONEncoder` garantiert die *äußere* (Top-Level-)
   Schlüsselreihenfolge nur mit `.sortedKeys` — bestätigt am realen
   Datenmaterial: zwei der drei Kopien begannen mit unterschiedlichen
   Schlüsseln trotz identischem Inhalt. Der Fingerabdruck-Vergleich
   (GitHub #70/#71) erkannte dadurch praktisch jeden Zyklus fälschlich als
   „geändert" und schrieb `export.json` neu, obwohl sich am Bestand nichts
   geändert hatte.

**Fix:**
- `SyncSnapshotExportService`: ein einziger `private static let encoder`
  (`JSONEncoder` mit `.outputFormatting = [.sortedKeys]`) ersetzt alle drei
  bisherigen `JSONEncoder()`-Instanzen — Single-Source-of-Truth für die
  Encoding-Konfiguration statt dreifacher Duplikation.
- Neuer Debug-Button „KaufEintraege jetzt bereinigen"
  (`StatuskonsolidierungSection` in `DebuggingView`, neben „Events aufräumen"/
  „Export.json aufräumen"): ruft `KaufEintragBereinigungService.bereinigen(context:)`
  **direkt** auf, nicht über `automatischBereinigenFallsFaellig` — umgeht
  bewusst dessen 24h-Sperre, damit ein frisch behobener Bug in der
  Bereinigung selbst sofort verifizierbar ist, ohne auf den nächsten
  automatischen Zeitpunkt zu warten. Lässt `letzteBereinigung` unangetastet
  (rein additiv zur automatischen Terminierung, kein Ersatz dafür).

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build-for-testing`
grün, keine neuen Warnungen. Neuer Regressionstest
`SyncSnapshotExportServiceTests.exportiertesJsonHatAlphabetischSortierteTopLevelSchluessel`
prüft direkt im rohen JSON-Text (nicht über `JSONDecoder`/`JSONSerialization`,
die die geschriebene Reihenfolge beim Parsen verwerfen), dass die
Top-Level-Schlüssel alphabetisch sortiert geschrieben werden. Kein
eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention). Der
Debug-Button selbst (reine SwiftUI-Verdrahtung eines bereits getesteten
Service-Aufrufs) wurde nicht mit dem Simulator nachverifiziert — dafür wäre
gemäß Projektregel vorab eine explizite Freigabe nötig.

## 29. Sync-Paket statt export.json-Monolith (GitHub #82)

**Umsetzungsplan zuerst erstellt** (siehe Anforderung des Nutzers, Issue #82
per Roadmap-Eintrag angelegt, dann Umsetzungsplan im Plan-Modus erarbeitet und
bestätigt) — vollständiges Layout, Begründung und Detailentscheidungen stehen
in der neuen `docs/EXPORT_PAKET_UMBAU.md`, hier nur die Kurzfassung samt
während der Umsetzung gefundener Korrektur.

**Layout:** `manifest.json` (immer geschrieben, Peer-Alters-Gate),
`tombstones.json`, `stamm.json`, `lernen.json`, `vorgaenge.json`, `preise.json`
(je unabhängig fingerabdruck-geprüft) sowie `kaeufe/` als Append-Log (ein
`<uuid>.json` pro `KaufEintrag`, neuer `SyncKaeufeExportService`) statt einer
einzigen `export.json`.

**Korrektur während der Umsetzung:** Der ursprünglich geplante Plan bündelte
Tombstones mit `vorgaenge.json`. Erneute Durchsicht von
`SyncSnapshotImportService.merge` zeigte: `mergeTombstones` muss laut
bestehendem Kommentar „bewusst zuerst" laufen, VOR jedem Stammdaten-Merge —
Tombstones gelten aber nicht nur für Bereich C (Einkaufsvorgang/KaufEintrag/
Preispunkt), sondern auch für Geschäft/Artikel/Abteilung/Einkaufsliste
(Stammdaten). In `vorgaenge.json` gebündelt wären sie erst NACH `stamm.json`
gelesen worden — zu spät. Fix: eigene, immer zuerst gelesene `tombstones.json`.
Dem Nutzer vor der weiteren Umsetzung vorgelegt und bestätigt, statt still
korrigiert.

**Bestehender `SyncSnapshot`-Monolith bleibt erhalten** — dient seither
ausschließlich dem lokalen Backup-/Wiederherstellungs-Pfad
(`SyncErsetzenService`, GitHub #63, Abschnitt 8 oben), der weiterhin einen
einzelnen vollständigen In-Memory-Snapshot braucht. Alle `mergeX`-Funktionen
(`mergeGeschaeftsTypen` … `mergeWarengruppenDistanzen`, `loescheFallsVorhanden`)
unverändert und von beiden Pfaden (`mergePaket`, neu, und `merge`, Backup-Pfad)
gemeinsam genutzt — nur die Herkunft der Teil-Arrays unterscheidet sich.

**Im selben Zug** (Analyse-Fund, unabhängig vom Datei-Layout): `mergeKaufEintraege`/
`mergePreispunkte` nutzten bislang einen vollen Fetch + linearen Scan
(`alleLokalen.first(where: { $0.id == eintrag.id })`) statt eines indexierten
Existenz-Checks (Muster wie `SyncEventService.istBereitsBekannt`) — O(n·m)
statt O(n) pro Merge-Zyklus, wachsend mit der Gesamthistorie statt nur mit
tatsächlich neuen Einträgen. `mergeEinkaufsvorgaenge` bewusst nicht angefasst
(`alleLokalen` dort zusätzlich für den `offenerTreffer`-Scan gebraucht, kein
mit der Historie wachsendes Problem).

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/`build-for-testing`
grün, keine neuen Warnungen. Bestehende Tests (`SyncSnapshotImportServiceTests`,
~40 Funktionen) unverändert lauffähig — der gemeinsame Test-Helper
`schreibeFremdenSnapshot` wurde intern auf das neue Paket-Format umgestellt,
ohne dass einzelne Testkörper angepasst werden mussten (`SyncSnapshot` bleibt
als bequemer Test-Baustein, wird nur beim Schreiben in Paket-Teile zerlegt).
Neue Tests: `nurGeaenderterTeilWirdNeuGeschrieben`, `stammNormalisierungIstUnabhaengigVonReihenfolgeAeussererUndInnererArrays`
(`SyncSnapshotExportServiceTests`), `raeumeVerwaisteFremdeExportsAufLoeschtAllePaketDateien`
(`SyncSnapshotImportServiceTests`), neue `SyncKaeufeExportServiceTests`,
`bereinigenLoeschtAuchDieEigeneKaeufeDateiDesGeloeschtenEintrags`
(`KaufEintragBereinigungServiceTests`). Kein eigenständiger `xcodebuild test`-Lauf
durch Claude (Projektkonvention) — noch nicht mit echten Geräten/realem
Mehrgeräte-Sync nachverifiziert.

## 30. Live-Test-Fund: kompletter Sync-Stillstand durch verschachtelte Security-Scope-Zugriffe

**Erster echter Mehrgeräte-Test nach Abschnitt 29** (zwei reale Geräte
„Bernhard"/„Backup"): nach einem `Ersetzen`-Neuaufbau auf Bernhard stimmte der
Stand zunächst — aber danach lösten weder ein Abhaken auf Backup noch auf
Bernhard, noch ein neuer Artikel auf einer neuen Liste, irgendein Update auf
dem jeweils anderen Gerät aus. Kompletter, beidseitiger Stillstand, nicht nur
für die neuen Paket-Teile, sondern auch für das unveränderte Bereich-A-Eventlog
(`SyncEvent`/`SyncExportService`/`SyncImportService`) — ein Hinweis, dass der
gesamte Sync-Zyklus scheiterte, nicht eine einzelne Merge-Funktion.

**Diagnose per `Sync-Debug-Modus`-Protokoll** (vom Nutzer bereitgestellt):
durchgehend `sync_ordner_zugriff_fehlgeschlagen` für JEDEN Teilschritt
(`importiereSnapshots`, `importiereNeueEvents`, `exportiereNeueEvents`,
`exportierePaket`, `exportiereNeueKaeufe`) — `startAccessingSecurityScopedResource()`
lieferte `false`. Zunächst funktionierten einzelne Zyklen noch (ein
`sync_snapshot_empfangen`/`sync_einkaufslisten_stand`-Paar um 13:16-13:19 Uhr),
danach dauerhaft nicht mehr.

**Root Cause:** Die in Abschnitt 29 (Pruning bei Löschung) beschriebene
`kaeufe/`-Datei-Aufräumung wurde ursprünglich auch aus
`SyncSnapshotImportService.loescheFallsVorhanden` aufgerufen — einmal PRO
empfangenem Tombstone, innerhalb der Schleife von `mergeTombstones`, die
selbst wieder VERSCHACHTELT im bereits offen gehaltenen Security-Scope von
`importiereSnapshots` läuft (dieser hält den Scope über mehrere `await`-Punkte
je Peer offen, siehe `importiereSnapshots`). Jeder dieser
`entferneDatei`-Aufrufe öffnete/schloss den Security-Scope zusätzlich selbst.
Backups `tombstones.json` enthielt ~190 Einträge — ein einziger Sync-Zyklus
löste damit ~190 verschachtelte Öffnen/Schließen-Zyklen auf demselben
Security-Scoped-Bookmark aus. Wiederholtes/verschachteltes Öffnen und
Schließen desselben Bookmarks destabilisiert dessen Zugriffsberechtigung auf
echten Geräten nachweisbar dauerhaft — nicht nur für den auslösenden Aufruf,
sondern für JEDEN nachfolgenden Zugriffsversuch in der App-Sitzung, exakt das
beobachtete Muster.

**Fix:**
- `SyncKaeufeExportService.entferneDatei(fuerKaufEintragID:)` (Einzelaufruf,
  eigener Security-Scope pro Datei) ersetzt durch
  `entferneDateien(fuerKaufEintragIDs:)` (Batch, EIN Security-Scope für die
  gesamte Liste).
- `KaufEintragBereinigungService.bereinigen` ruft den Batch-Aufräumer jetzt
  einmal nach seiner Löschschleife auf (unverändert bündelnd, jetzt zusätzlich
  ohne verschachtelten Scope-Zugriff).
- Der Aufruf aus `loescheFallsVorhanden` wurde vollständig entfernt, nicht nur
  gebündelt — dieser Pfad läuft strukturell immer verschachtelt in einem
  fremden, bereits offenen Scope und sollte grundsätzlich keinen eigenen
  Scope-Zugriff mehr versuchen. Eine dadurch verwaist liegenbleibende eigene
  `kaeufe/`-Datei eines fremd-tombstoneten Eintrags ist weiterhin nur
  Platzersparnis (der Tombstone selbst schützt bereits vor Wiederbelebung),
  keine Korrektheitsfrage — bewusst in Kauf genommen statt das Risiko erneut
  einzugehen.

**Allgemeinere Lehre (auch für künftigen Code):** Jede neue Stelle, die
`SyncOrdnerService.gewaehlterOrdner()` + `startAccessingSecurityScopedResource()`
verwendet, muss geprüft werden, ob sie potenziell verschachtelt in einem
bereits von einer aufrufenden Funktion offen gehaltenen Scope läuft (alle
bestehenden Top-Level-Sync-Funktionen — `exportiereSnapshot`/`exportierePaket`,
`importiereSnapshots`, `exportiereNeueEvents`, `importiereNeueEvents` — halten
ihren Scope über den gesamten Funktionskörper, teils über mehrere `await`-Punkte
hinweg, offen). Neue Low-Level-Helfer, die von TIEF innerhalb dieser
Funktionen aufgerufen werden (wie `loescheFallsVorhanden`, selbst mehrfach
verschachtelt über `mergeTombstones`/`merge`/`mergePaket`), dürfen keinen
eigenen Scope öffnen — entweder den bereits offenen Scope voraussetzen, oder
(wie hier gelöst) die Datei-I/O ganz an eine Stelle verschieben, die
nachweislich NICHT verschachtelt läuft.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build-for-testing`
grün, keine neuen Warnungen. Test `SyncKaeufeExportServiceTests.entferneDateienLoeschtVorhandeneKaeufeDateien`
an den Batch-Aufruf angepasst. Noch nicht erneut auf den beiden betroffenen
echten Geräten nachverifiziert — dafür muss die App dort neu gebaut/installiert
werden.

## 31. Live-Test-Fund: Paket-Teile fehlten dauerhaft nach Reaktivieren der Synchronisierung

**Nach Build 181** (Abschnitt 30-Fix bereits auf beiden Geräten installiert)
meldete der Nutzer: nach Deaktivieren der Synchronisierung auf beiden
Geräten, Neustart und Reaktivieren legt der Sync-Zyklus im Peer-Ordner nur
noch `manifest.json` und den `kaeufe/`-Ordner an — `tombstones.json`/
`stamm.json`/`lernen.json`/`vorgaenge.json`/`preise.json` fehlen komplett,
dauerhaft, auch nach mehreren Zyklen.

**Erster Schritt: Sichtbarkeit fehlte.** `schreibeTeilFallsGeaendert` (aus
Abschnitt 29) protokollierte anders als die alte `exportiereSnapshot`-Funktion
nicht, ob ein Teil geschrieben oder als unverändert übersprungen wurde —
nachgerüstet (`.snapshotGeschrieben`/`.snapshotUnveraendertUebersprungen` je
Teilname), ohne diese Sichtbarkeit wäre die eigentliche Ursache nicht
auffindbar gewesen.

**Mit der Sichtbarkeit sofort erkennbar:** das Protokoll zeigte
`sync_snapshot_unveraendert_uebersprungen` für alle fünf Teile, mit
**identischem, stabilem Fingerabdruck bereits im ersten Zyklus nach dem
Neustart** — der in `UserDefaults` gespeicherte Fingerabdruck aus einer
früheren Sitzung wurde also als „unverändert" erkannt. Der Nutzer bestätigte
danach explizit: die fünf Dateien fehlen im neu verbundenen Peer-Ordner
tatsächlich komplett, nicht nur „nicht aktualisiert".

**Root Cause:** `schreibeTeilFallsGeaendert` verglich ausschließlich den
Fingerabdruck, nie ob die Zieldatei überhaupt noch existiert. Der
`UserDefaults`-Fingerabdruck ist bewusst so gebaut, dass er einen
App-Neustart übersteht (soll er auch) — er beantwortet aber nur „hat sich der
lokale Datenbestand seit dem letzten Schreiben verändert", nicht „liegt die
Datei auch tatsächlich noch am erwarteten Ort". Nach
Deaktivieren/Reaktivieren der Synchronisierung war genau das nicht mehr der
Fall (die fünf Dateien im neu verbundenen Peer-Ordner existierten schlicht
nicht) — der unveränderte lokale Bestand + der unveränderte Fingerabdruck
verhinderten dadurch dauerhaft jedes erneute Schreiben. `manifest.json`
(bedingungslos jeden Zyklus geschrieben) und `kaeufe/` (Existenz-Check direkt
auf die Datei, kein Fingerabdruck-Umweg) waren strukturell gegen genau diese
Fehlerklasse immun — was den Befund von Anfang an auf die fünf
Fingerabdruck-geprüften Teile eingrenzte.

**Fix:** `schreibeTeilFallsGeaendert` überspringt das Schreiben jetzt nur noch,
wenn Fingerabdruck-Übereinstimmung UND `FileManager.default.fileExists`
beide zutreffen — fehlt die Datei, wird unabhängig vom Fingerabdruck neu
geschrieben.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build-for-testing`
grün, keine neuen Warnungen. Neuer Regressionstest
`SyncSnapshotExportServiceTests.teilWirdErneutGeschriebenWennDateiTrotzUnveraendertemFingerabdruckFehlt`
(Datei nach erstem Export manuell entfernt, Bestand unverändert gelassen,
zweiter Export muss die Datei trotz identischem Fingerabdruck neu schreiben).
Kein eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention) —
noch nicht auf den beiden betroffenen echten Geräten nachverifiziert.

## 32. Sync-Merge-Fehlmerge (GitHub #86) + Härtung des Neuaufbau-Pfads gegen eindeutigen Fehlschlag

**Auslöser:** Nutzerfrage, warum Geschäfte beim Sync-Merge überhaupt anhand
des Radius zusammengeführt werden — daraus entwickelte sich im Gespräch ein
zweiter, tieferliegender Fund (Namensgleichheit allein reichte beim Merge
schon aus, unabhängig von der Distanz) und anschließend eine breitere
Bewertung, ob die vielen einzelnen Sonderfall-Fixes in diesem Dokument (31
Abschnitte) durch strengere Regeln an wenigen, klar abgegrenzten
Kontrollpunkten (Migration, Sync-Ordner-Beitritt, Backup/Ersetzen) reduzierbar
wären, statt jedes Mal einzeln nachzupatchen.

**Ergebnis der Bewertung:** Migration ist bereits streng genug (nur additive
Attribute, siehe `docs/DECISIONS.md`). Der laufende Betrieb (Vorgangs-
Umleitung, baumelnde Referenzen, Event-Retry) ist NICHT durch striktere
Checkpoints reduzierbar — das ist der Preis für gleichzeitiges Bearbeiten
mehrerer Geräte während eines laufenden Einkaufs, keine vermeidbare
Sonderfall-Anhäufung. Zwei konkrete Verbesserungen blieben: der Sync-Merge-Bug
selbst (#86) und eine fehlende harte Erfolgsprüfung beim Neuaufbau-Pfad.

**#86, Teil 1 — Merge-Regel verschärft:** `mergeGeschaefte` verglich Geschäfte
bisher mit der für interaktive, bestätigbare Fälle gedachten großzügigen
Regel (Name exakt ODER Teilstring ODER reine Koordinaten-Nähe, fester
75m-Standardwert statt des individuellen `erkennungsradius` aus #41). Neue,
strengere `istGleicherOrtFuerSyncMerge`-Regel nur für diesen automatischen,
unbestätigten Pfad: Name muss EXAKT übereinstimmen UND beide Koordinaten
innerhalb der strengeren der beiden individuellen Radien liegen.

**#86, Teil 2 — aktive Rückfrage beim Ordner-Beitritt:** Der Beitritt zu
einem Sync-Ordner mit bestehenden Peer-Daten ist ein einmaliger,
nutzerinitiierter Moment — dort lohnt sich eine Rückfrage, die im laufenden
Hintergrund-Betrieb bewusst nicht eingeführt wurde (kein wiederkehrender
Dialog). `mehrdeutigeGeschaeftsKandidatenBeimBeitritt` scannt vorab (reines
Lesen) auf Kandidaten, die nach der alten, lockeren Regel übereinstimmen
würden, aber nicht nach der neuen strengen; `GeschaeftsBeitrittsAbgleichSheet`
fragt bei Treffern aktiv nach ("gleicher Laden" mit Namenswahl, oder
"unterschiedliche Läden" als Standard ohne Aktion). Im laufenden Betrieb
danach bewusst keine neue Zusammenführungs-Funktion — seltene Duplikate
fallen sichtbar auf und werden über die bereits bestehende Löschfunktion
bereinigt (Tombstone propagiert automatisch).

**Härtung des `SyncErsetzenService`-Neuaufbau-Pfads:** Die bestehende
Vorher-/Nachher-Zusammenfassung (Abschnitt 21) zeigte einen Rückgang nur an,
verhinderte ihn aber nicht — ein EINDEUTIGER Totalverlust (Ordnerzugriff
gescheitert, oder kein einziger erreichbarer Peer bringt irgendetwas zurück)
wurde bisher genauso nur angezeigt wie ein harmloser TEILWEISER Rückgang
(kann legitim sein, z.B. bereits verarbeitete Peer-Löschungen). Da
`nachherZaehler.gesamt == 0` bei vorher nicht leerem Bestand eindeutig auf
einen kompletten Fehlschlag hinweist (nie ein legitimer Fall), importiert
`fuehreAusstehendeAktionAus(context:)` bei dieser Konstellation jetzt
automatisch das ohnehin vorhandene Vorher-Backup zurück, statt den leeren
Neuaufbau stehen zu lassen — `DebuggingView` zeigt dafür zusätzlich einen
roten Hinweis. Ein teilweiser Rückgang bleibt bewusst nur informativ, da
"legitim vs. Bug" dort nicht zuverlässig automatisierbar ist.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Neue Tests:
`SyncSnapshotImportServiceTests.geschaeftMitAehnlichemNamenAberNaheKoordinatenWirdNichtGemergt`,
`.mehrdeutigerBeitrittsKandidatWirdGefundenUndNachBestaetigungGemergt`,
`SyncErsetzenServiceTests.fuehreAusstehendeAktionAusRolltBeiKomplettLeeremNeuaufbauAutomatischZurueck`.
Kein eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention) —
nicht auf echten Geräten nachverifiziert.

## 33. GitHub #67-Erweiterung: deterministische Kanon-Wahl bei mehreren offenen Vorgangs-Kandidaten

**Auslöser:** Nutzerfrage, ob abgehakte Artikel während eines noch laufenden
gemeinsamen Einkaufs für alle Geräte konsistent als durchgestrichen
erscheinen. Antwort: das Entfernen von der Einkaufsliste selbst
(„ich muss es nicht mehr kaufen") war schon immer sicher, unabhängig davon,
an welchem `Einkaufsvorgang` ein `KaufEintrag` technisch hängt — aber die
Live-Anzeige während des Einkaufs (`zeigeAbgehakteArtikel`-Umschalter) hing
an einer tieferen, bis dahin unentdeckten Lücke.

**Fund:** Drei unabhängige Stellen —
`Einkaufsvorgang.offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)`,
`EinkaufenView.aktuellerEinkauf` und `SyncSnapshotImportService.mergeEinkaufsvorgaenge`s
`offenerTreffer`-Zweig — wählten bei MEHREREN gleichzeitig passenden offenen
Kandidaten für dieselbe (Geschäft, Liste)-Kombination jeweils per `.first(where:)`
einen beliebigen, von der (nicht garantierten) SwiftData-Fetch-Reihenfolge
abhängigen Treffer, statt einer für alle Geräte identischen Regel zu folgen.

**Konkretes Szenario:** Zwei Geräte betreten fast gleichzeitig denselben
Laden mit derselben gemeinsamen Liste, vor dem ersten Sync-Zyklus — beide
legen unabhängig ihren eigenen offenen Vorgang an (V-A, V-B). Nach dem ersten
Sync erkennt `mergeEinkaufsvorgaenge`s `offenerTreffer`-Zweig das zwar und
registriert einen Alias V-B→V-A — aber `EinkaufenView.aktuellerEinkauf` fragt
diese Zuordnung nie ab und kann bei Gerät B weiterhin dessen eigenen,
inzwischen vom Merge "verlorenen" V-B liefern. Neue Häkchen landen über den
Sync-Pfad korrekt bei V-A, Gerät B schaut aber auf V-B und sieht sie nie.

**Fix:** Neue gemeinsame Regel `Einkaufsvorgang.kanonischer(unter:)` — unter
mehreren Kandidaten gewinnt immer der älteste `startZeit`, bei exaktem
Gleichstand die lexikographisch kleinere `id` als stabiler Tiebreaker (analog
`LamportTimestamp`). Da `startZeit` beim Sync unverändert übernommen wird
(nie lokal neu gesetzt), kommen alle Geräte nach der Synchronisation
zuverlässig auf denselben Vorgang, unabhängig von lokaler Fetch-Reihenfolge.
An allen drei betroffenen Stellen eingesetzt.

**Bewusst nicht abgedeckt:** #69 (store-loser Fallback bei fehlendem
passendem Geschäft) bleibt eigenständig offen — die neue Regel macht die
Auswahl unter bereits mehrdeutigen Kandidaten nur deterministisch/konsistent,
löst aber nicht das Kernproblem, dass der Fallback ein Geschäft treffen kann,
das gar nicht passt.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Neue Tests:
`EinkaufsvorgangTests.kanonischerWaehltImmerDenAeltestenUnabhaengigVonDerReihenfolge`,
`.kanonischerEntscheidetBeiGleicherStartZeitUeberDieId`,
`.offenerNachfolgerWaehltBeiMehrerenKandidatenDenAeltesten`. Kein
eigenständiger `xcodebuild test`-Lauf durch Claude (Projektkonvention) —
nicht auf echten Geräten nachverifiziert.

## 34. GitHub #66: Geschäft kommt jetzt aus der Event-Nutzlast statt aus dem Umleitungs-Container

**Fund:** `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` legte den
neuen `KaufEintrag` bisher immer mit `self.geschaeft` an — nach einer
Vorgangs-Umleitung (Abschnitt 4.3) war `self` aber der NACHFOLGE-Vorgang, der
fast immer ein anderes (oder gar kein) Geschäft hat als der Vorgang, in dem
der Kauf laut sendendem Gerät tatsächlich stattfand.

**Fix:** `SyncEventNutzlast` bekommt ein additiv-optionales `geschaeftID`
(nie eine Migration nötig, reiner JSON-Payload). `Einkaufsvorgang.artikelAbhaken`
zeichnet beim lokalen Abhaken `self.geschaeft?.id` mit auf.
`SyncImportService.materialisiere`s `.artikelAbgehakt`-Fall löst diese ID
(über den Bereich-B-Alias, GitHub #86) zu einem lokalen `Geschaeft?` auf und
übergibt sie als Override an
`artikelAbhakenOhneEventAufzeichnung(...:geschaeft:)` — analog dem bereits
bestehenden `abteilung`-Override, aber bewusst doppelt optional (`Geschaeft??`),
um „kein Override" von „Override auf explizit kein Geschäft" zu
unterscheiden. `geschaeftNameSnapshot` (bei `KaufEintrag`-Anlage aus
demselben Parameter abgeleitet) wird dadurch automatisch mitkorrigiert, ohne
eigene Fundstelle.

**Auswirkung auf #69 geprüft und dokumentiert:** Der store-lose
Umleitungs-Fallback aus #69 kann dadurch keine zwei Käufe unterschiedlicher
Geschäfte mehr inhaltlich vermischen — vollständig durchgegangen (Distanzlernen,
Listenzustand, Preishistorie, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt
4.3), kein verbleibender Schadpfad gefunden. #69 bleibt trotzdem als eigenes
Issue offen für die verbleibende, rein kosmetische Container-Gruppierungsfrage.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Neuer Regressionstest:
`SyncImportServiceTests.artikelAbgehaktFuerBereitsAbgeschlossenenVorgangBehaeltUrspruenglichesGeschaeft`
(Nachfolger hat ein ANDERES Geschäft als der ursprüngliche Vorgang, nicht nur
`nil`, um sicherzustellen, dass die Korrektur nicht zufällig nur den
„kein Geschäft ausgewählt"-Fall abdeckt). Kein eigenständiger
`xcodebuild test`-Lauf durch Claude (Projektkonvention) — nicht auf echten
Geräten nachverifiziert.

## 35. Einkaufsvorgang entkoppeln: keine geteilte Vorgangs-Identität mehr nötig

**Auslöser:** Nutzerfrage zur Architektur, nach Abschnitt 33/34: „Brauchen wir
überhaupt das Konzept eines Einkaufsvorgangs, der geteilt werden muss, oder
reicht es, diesen nur lokal pro Benutzer zu führen?"

**Erkenntnis:** `Einkaufsvorgang` spielt mehrere Rollen (Behälter für
`KaufEintrag`e, Lerngrundlage fürs Distanzlernen, Besuchszähler, historischer
Protokolleintrag, „aktuell laufende Sitzung" für die Live-Ansicht). Bei
genauer Prüfung brauchen alle Rollen außer der Live-Ansicht überhaupt keine
geräteübergreifend übereinstimmende Vorgangs-Identität — Distanzlernen
schließt Fremdeinträge ohnehin aus, der Besuchszähler läuft über einen
unabhängigen G-Counter, Besuchsprotokoll und -häufigkeit zählen bereits pro
Vorgangs-*Objekt*. Nur die Live-Ansicht „was ist gerade abgehakt" brauchte
bislang eine geteilte Identität — und genau dafür existierte die gesamte
„Vorgangs-Umleitung" (`offenerNachfolger`, `aufOffenenNachfolgerUmgeleitet`,
der `bekannter`-geschlossen-Zweig in `mergeEinkaufsvorgaenge`): historisch mit
Abstand der fehleranfälligste Teil der gesamten Synchronisation (Abschnitt
11/11a, 15, 16, 19, 20, 21, 22, 25 — „Geister"-Einkaufsvorgänge,
`endZeit`-Verfälschung, Phantom-Zähler) und Auslöser für #66/#67/#69.

**Fix:** Die Live-Ansicht löst sich stattdessen über die **Einkaufsliste**
(die ist ohnehin schon geteilt) statt über einen von allen Geräten
übereinstimmend gewählten Vorgang — siehe
`docs/DATENSYNCHRONISATION.md` Abschnitt 4.3 für den vollständigen neuen
Mechanismus (`Einkaufsvorgang.abgehakteKaufEintraege(fuerListe:seit:unter:)`).
Damit entfällt die komplette Umleitungs-Maschinerie ersatzlos:
`Einkaufsvorgang.offenerNachfolger`, `SyncImportService.aufOffenenNachfolgerUmgeleitet`
und der `aufOffenenNachfolgerUmleiten`-Parameter sind gelöscht;
`.artikelAbgehakt` löst sich in `SyncImportService.materialisiere` jetzt
identisch zu `.artikelAbgewaehlt`/`.artikelDauerhaftEntfernt` auf (einfacher
ID-/Alias-Lookup). `SyncSnapshotImportService.istBereitsAbgehakt` vereinfacht
sich analog (kein `context`-Parameter, kein `offenerNachfolger`-Aufruf mehr
nötig). Übrig bleibt einzig `offenerTreffer` (Identitäts-Abgleich beim
erstmaligen Zusammentreffen zweier unabhängig angelegter Vorgänge, s.
Abschnitt 4.3) — der bleibt unverändert bestehen, weil er weiterhin
Doppelzählung im Besuchszähler/-protokoll verhindert; `kanonischer(unter:)`
bleibt ebenfalls bestehen (jetzt für `offenerTreffer` und den lokalen Anker
`aktuellerEinkauf`, nicht mehr für die Live-Sichtbarkeit).

`EinkaufenView.umschalten(_:abteilung:)`/`entferneDauerhaft(_:)` mussten dafür
zusätzlich angepasst werden: sie dürfen die Mutation nicht mehr blind auf dem
lokalen Anker-Vorgang aufrufen, sondern müssen per frischem, liste- und
zeitfenster-beschränktem Fetch den tatsächlichen Besitzer-Vorgang des
`KaufEintrag`s ermitteln — sonst würde `entferneDauerhaft` bei einem fremd
materialisierten Eintrag still nichts tun (kein Treffer in
`self.kaufEintraege`) bzw. `umschalten` fälschlich einen zweiten Eintrag für
denselben Artikel anlegen.

**Warum die historischen Bugs aus Abschnitt 11/11a/15/16/19/20/21/22/25 dadurch
nicht wieder auftreten können:** Keine dieser Stellen betraf `offenerTreffer`
selbst — der bleibt exakt unverändert bestehen. Die entfernte Umleitung war
eine zusätzliche, zur Live-Sichtbarkeit gedachte Sicherung, die durch die neue
listenbasierte Anzeige komplett überflüssig geworden ist, nicht durch eine
robustere Variante ersetzt werden musste. Weniger bewegliche Teile statt eines
komplexeren Ersatzes.

**Tests:** `SyncImportServiceTests.artikelAbgehaktFuerBereitsAbgeschlossenenVorgangLandetAufOffenemNachfolger`
→ umbenannt zu `.artikelAbgehaktFuerBereitsAbgeschlossenenVorgangBleibtAufDiesemVorgang`,
Erwartung umgedreht (Eintrag bleibt am ursprünglichen Vorgang).
`.artikelAbgehaktFuerBereitsAbgeschlossenenVorgangBehaeltUrspruenglichesGeschaeft`
(Abschnitt 34) → umbenannt zu `.artikelAbgehaktBehaeltUrspruenglichesGeschaeftAusDerNutzlast`,
Fixture vereinfacht (kein Nachfolger mehr nötig).
`.beiMehrerenOffenenNachfolgernWirdDerMitGleichemGeschaeftBevorzugt` → gelöscht
(testete ausschließlich die entfernte Umleitung).
`SyncSnapshotImportServiceTests.bereitsAbgeschlossenerBekannterVorgangWirdBeiSnapshotMergeAufOffenenNachfolgerUmgeleitet`
→ umbenannt zu `.bereitsAbgeschlossenerBekannterVorgangBehaeltKaufEintragBeiSnapshotMerge`,
Erwartung umgedreht. `EinkaufsvorgangTests.offenerNachfolgerWaehltBeiMehrerenKandidatenDenAeltesten`
(Abschnitt 33) → gelöscht (testete die gelöschte Funktion); neuer Test
`.abgehakteKaufEintraegeFiltertNachListeUndZeitfenster` für die neue
liste-/zeitfenster-basierte Anzeigelogik. Alle `offenerTreffer`-bezogenen
Tests unverändert.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Kein eigenständiger `xcodebuild test`-Lauf durch
Claude (Projektkonvention). **Wichtiger Vorbehalt:** Dies ist der historisch
mit Abstand fehleranfälligste Teil der gesamten Synchronisation — ein echter
Zwei-Geräte-Test (ein Gerät schließt „Einkauf abschließen" mitten im
gemeinsamen Einkauf, während das andere weiter abhakt) sollte vor
endgültigem Vertrauen in diese Änderung real durchgeführt werden, wie bei
allen bisherigen Änderungen an dieser Stelle in diesem Projekt.

## 36. Live-Test-Fund (2026-08-03, echter Zwei-Geräte-Test zu Abschnitt 35): „dauerhaft entfernen“/„Abwählen“ wurden nach Vorgangs-Rotation zum stillen No-op

**Auslöser:** Der in Abschnitt 35 geforderte echte Zwei-Geräte-Test (Geräte
„Bernhard“ und „Backup“). Beobachtung: ein per „Einkauf abschließen“
abgeschlossener Artikel wurde anschließend über die Geschäftsansicht (Edeka)
per Wisch-Geste „dauerhaft entfernt“ — blieb aber auf der geschäftsneutralen
Ansicht weiterhin als „abgehakt“ stehen.

**Diagnose per Debug-Log statt Vermutung:** Weder in `sync-debug.log` (Gerät
Bernhard) noch in `sync-debug 2.log` (Gerät Backup) taucht über den gesamten
Testzeitraum auch nur EIN `sync_event_empfangen art=artikelDauerhaftEntfernt`
auf — nur `artikelHinzugefuegt`/`artikelAbgehakt`/`artikelAbgewaehlt`. Das
belegt: die Löschung fand nie tatsächlich statt (kein Event wurde je
aufgezeichnet), unabhängig vom Sync selbst.

**Root Cause:** Der in Abschnitt 35 eingeführte „frische, zeitfenster-
beschränkte Fetch“ in `EinkaufenView.umschalten(_:abteilung:)`/
`entferneDauerhaft(_:)` (siehe dort) filterte nach
`$0.datum >= zeitfensterStart`, wobei `zeitfensterStart =
einkaufsvorgang.startZeit` — die Startzeit des GERADE ANGEZEIGTEN Vorgangs.
„Einkauf abschließen“ legt aber sofort einen NEUEN, offenen Vorgang mit
späterer `startZeit` an (``EinkaufenView/einkaufSicherstellen()``). Wurde
danach in derselben Geschäftsansicht auf „dauerhaft entfernen“ getippt, war
`einkaufsvorgang` bereits der NEUE Vorgang — der Fetch filterte den echten,
ÄLTEREN `KaufEintrag` (aus dem gerade abgeschlossenen Vorgang) damit
versehentlich heraus. `vorhandenerEintrag` wurde `nil`,
`artikelDauerhaftEntfernen`/`artikelAbwaehlen` liefen dadurch ins Leere —
exakt dieselbe Fehlerklasse, vor der die Doku-Kommentare in Abschnitt 35
warnten, nur eine Ebene tiefer als dort angenommen: nicht nur bei fremd
(peer-)materialisierten Einträgen, sondern bei JEDER Vorgangs-Rotation der
eigenen Geschäftsauswahl.

**Fix:** Der zeitfenster-basierte Rate-Fetch entfällt vollständig. Beide
Funktionen ermitteln den zu mutierenden `KaufEintrag` jetzt direkt über
``EinkaufslisteView/kaufEintrag(fuer:)`` — dieselbe Quelle, die auch
``istAbgehakt(_:)``/die Sichtbarkeit des „dauerhaft entfernen“-Buttons
bestimmt (dedupliziert bereits korrekt aus ``abgehakteKaufEintraege``, ohne
Zeitfenster-Annahme). Ein ``ModelReference<KaufEintrag>`` sichert diese
Identität über die `await`-Grenze des Micro-Lease hinweg (analog Artikel/
Vorgang/Abteilung). Da diese Anzeige-Quelle per Konstruktion IMMER exakt den
Eintrag liefert, der auch als „abgehakt“ gerendert wurde, kann die Mutation
nicht mehr von dem abweichen, was der Anwender tatsächlich sieht.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Kein neuer automatisierter Test — `EinkaufenView`s
private Methoden sind ohne SwiftUI-Testharness nicht direkt testbar; die
Korrektheit wurde stattdessen genau über den Log-Befund oben verifiziert
(Abwesenheit von `artikelDauerhaftEntfernt`-Events als Beweis des Bugs). Ein
erneuter Zwei-Geräte-Test desselben Szenarios (abschließen → in der
ursprünglichen Geschäftsansicht dauerhaft entfernen → auf einem zweiten
Gerät/der geschäftsneutralen Ansicht prüfen) bleibt vor endgültigem Vertrauen
empfohlen.

## 37. Live-Test-Fund (2026-08-03, Fortsetzung des Tests aus Abschnitt 36): Sichtbarkeit „abgehakt“ hing am falschen Kriterium — Zeitfenster statt Vorgangs-Status

**Auslöser:** Derselbe Zwei-Geräte-Test, nächste Runde nach dem Fix aus
Abschnitt 36. Zwei Beobachtungen, die sich als EIN Fund entpuppten:

1. Trotz erzwungenem Sync zeigten beide Geräte für die Liste „Urlaub“
   unterschiedliche Artikel — Gerät Backup zusätzlich „Gnocchi“.
2. Wurde auf einem Gerät „Einkauf abschließen“ getippt, blieben dessen
   abgehakte Artikel auf der GESCHÄFTSNEUTRALEN Ansicht (kein Geschäft
   gewählt) weiterhin sichtbar — die Liste wurde dort nicht aufgeräumt.

**Root Cause:** Die in Abschnitt 35 eingeführte Sichtbarkeits-Regel
(`Einkaufsvorgang.abgehakteKaufEintraege(fuerListe:seit:unter:)`) filterte
nach `KaufEintrag.datum >= aktuellerEinkauf.startZeit` — einem Zeitpunkt aus
der rein LOKALEN, gerade zufällig aktiven Vorgangs-Historie des
BETRACHTENDEN Geräts. Das hat mit dem tatsächlichen Zustand des Vorgangs, dem
der Kaufeintrag gehört, nichts zu tun: ein Gerät mit „Kein Geschäft“ und
einem seit Stunden offenen, alten Vorgang zeigt so ziemlich jeden späteren
Kauf als „abgehakt“ — auch nach dessen Abschluss auf einem anderen Gerät
(Fund 2). Ein Gerät, das zwischenzeitlich selbst einen neuen Vorgang anlegt
(z.B. durch Geschäftswechsel), rückt seinen eigenen Fensteranfang dagegen
nach vorne und verliert dieselben Käufe aus dem Blick (Fund 1 — Bernhard und
Backup hatten schlicht unterschiedliche eigene Fenster-Startzeiten für
dieselbe Liste). Der ursprüngliche fachliche Auftrag (vor Abschnitt 35)
lautete unmissverständlich: „sichtbar, SOLANGE DER EINKAUF NICHT
ABGESCHLOSSEN IST“ — das ist ``Einkaufsvorgang/endZeit``, kein
Zeitpunkt-Vergleich. Das Zeitfenster war ein Fehlgriff bei der Umsetzung
dieses an sich richtigen Auftrags aus Abschnitt 35.

**Fix:** `abgehakteKaufEintraege(fuerListe:unter:)` (Parameter `seit`
entfernt) filtert jetzt schlicht auf `$0.endZeit == nil` — sichtbar ist ein
Kaufeintrag genau dann, wenn sein Container-Vorgang (egal auf welchem Gerät
angelegt) noch offen ist. Sobald irgendein Gerät „Einkauf abschließen“
ausführt und das per Sync ankommt, verschwindet der Eintrag auf JEDEM Gerät
aus der „abgehakt“-Ansicht — unabhängig von dessen eigener, unabhängiger
Vorgangs-Historie. Die Funktion filtert `vorgaenge` dabei defensiv selbst
zusätzlich auf `endZeit == nil`, statt sich auf eine bereits gefilterte
Aufrufer-Liste zu verlassen (Schutz gegen genau diese Fehlerklasse bei
künftigen Aufrufern). `EinkaufenView.aktuellerEinkauf` bleibt bestehen, aber
ausschließlich als lokaler Anker für NEUE eigene Häkchen — seine `startZeit`
spielt für die Anzeige keine Rolle mehr.

**Tests:** `EinkaufsvorgangTests.abgehakteKaufEintraegeFiltertNachListeUndZeitfenster`
(Abschnitt 35) → ersetzt durch
`.abgehakteKaufEintraegeZaehltNurOffeneVorgaenge`: prüft, dass ein Eintrag
eines offenen Vorgangs zählt, ein Eintrag eines (soeben erst) geschlossenen
Vorgangs derselben Liste NICHT mehr zählt, und Einträge anderer Listen
unabhängig vom Status ausgeschlossen bleiben.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Ein erneuter Zwei-Geräte-Test (Einkauf auf Gerät A
abschließen, prüfen dass abgehakte Artikel auf Gerät B — sowohl in der
ursprünglichen Geschäftsansicht als auch geschäftsneutral — konsistent
verschwinden) bleibt vor endgültigem Vertrauen empfohlen.

## 38. Live-Test-Fund (2026-08-03, in unterschiedlichen Läden eingekauft): Dedupe-Schutz galt nur pro Vorgang statt listenweit — Artikel ließ sich nicht mehr reaktivieren

**Auslöser:** Zwei-Geräte-Test, Fortsetzung von Abschnitt 36/37: „in
unterschiedlichen Läden eingekauft, Artikel können nicht wieder aktiviert
werden … das ist eigentlich für den Fall da: ich habe mich vertippt, Artikel
wurde fälschlicherweise als gekauft markiert." Bestätigt per Rückfrage: das
Problem trat erst NACH Sync eines von einem anderen Gerät abgehakten
Artikels auf — nicht rein lokal auf einem Gerät ohne Sync. Meine erste
Vermutung (Vorgang war bereits „Einkauf abschließen"-abgeschlossen) wurde
per Log widerlegt: im fraglichen Zeitfenster fand keine einzige neue
Vorgangs-Abschluss-Übernahme statt.

**Root Cause:** `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`s
Dedupe-Schutz gegen doppeltes Abhaken prüfte nur `self.kaufEintraege` — also
PRO VORGANG, nicht listenweit. Seit die „abgehakt"-Anzeige listenweit über
alle offenen Vorgänge gilt (Abschnitt 35/37), konnte derselbe Artikel
unabhängig unter zwei unterschiedlichen, beide offenen Vorgängen (hier: zwei
Geschäften, „Edeka" und „Rewe") abgehakt werden — das erzeugte ZWEI separate
`KaufEintrag`e für denselben Artikel. Die Anzeige zeigte trotzdem nur eine
(deduplizierte) Zeile, aber `EinkaufenView.umschalten(_:abteilung:)`/
`kaufEintrag(fuer:)` griffen nur auf den per `.first` zufällig ERSTEN Treffer
zu — ein „Abwählen" entfernte nur einen der beiden Einträge, der andere
blieb bestehen, der Artikel erschien weiterhin „abgehakt". Aus Nutzersicht:
Tippen auf „Abwählen" schien wirkungslos.

**Fix, zwei Ebenen:**
1. **Root Cause behoben:** Der Dedupe-Schutz in
   `artikelAbhakenOhneEventAufzeichnung` prüft jetzt listenweit über alle
   noch offenen Vorgänge (`$0.einkaufsvorgang?.einkaufsliste == einkaufsliste
   && $0.einkaufsvorgang?.endZeit == nil`) statt nur gegen `self` — ein
   zweiter Abhak-Versuch für denselben Artikel unter einem ANDEREN offenen
   Vorgang derselben Liste wird jetzt korrekt als `.bereitsAbgehaktVon`
   erkannt, kein zweiter `KaufEintrag` entsteht mehr. Der
   Überkauf-Hinweis-Gewinner (`SyncEventService.aktuellerGewinner`) wird
   dabei mit der `bezugsID` des TATSÄCHLICHEN Besitzer-Vorgangs abgefragt,
   nicht mehr blind mit `self.id`.
2. **Selbstheilend gegen bereits bestehende Duplikate:**
   `EinkaufenView.umschalten(_:abteilung:)`/`entferneDauerhaft(_:)` nutzen
   jetzt `alleAbgehaktenEintraege(fuer:)` (statt `kaufEintrag(fuer:)`, das nur
   den ersten Treffer liefert) und wirken auf ALLE gefundenen Einträge — ein
   einzelner Tap räumt damit auch schon bestehende Duplikate (z.B. aus der
   Testphase vor diesem Fix) vollständig auf, statt mehrere Taps zu
   erfordern.

**Tests:** Neuer Test
`EinkaufsvorgangTests.abhakenInZweitemOffenemVorgangDerselbenListeErzeugtKeinDuplikat`:
Artikel wird in einem offenen Edeka-Vorgang abgehakt (liefert `.abgehakt`),
ein zweiter Abhak-Versuch im ebenfalls offenen Rewe-Vorgang derselben Liste
liefert `.bereitsAbgehaktVon`, erzeugt keinen zweiten `KaufEintrag`, und ein
einzelnes Abwählen setzt den Artikel vollständig zurück.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün. Ein erneuter Zwei-Geräte-Test mit genau diesem
Szenario (Artikel in zwei unterschiedlichen Läden für dieselbe Liste
abhaken, danach auf einem Gerät wieder abwählen) bleibt vor endgültigem
Vertrauen empfohlen.

## 39. GitHub #91: Aktiver iCloud-Weckimpuls vor jedem Sync-Zyklus

**Beobachtung (Live-Test):** Mehrgeräte-Sync lief erst zuverlässig, sobald man
den Sync-Ordner in der Files-App öffnete — das stößt aktiv einen
iCloud-Abgleich an. Ohne diesen manuellen Trigger blieben neue
Peer-Änderungen teils deutlich verzögert oder blieben ganz aus.

**Root Cause:** Alle Sync-Services (`SyncImportService`,
`SyncSnapshotImportService`, `SyncExportService`, `SyncOrdnerService`,
`SyncKaeufeExportService`) listen den Ordner über schlichtes
`FileManager.default.contentsOfDirectory(...)` — das liest nur, was iCloud auf
diesem Gerät bereits lokal zwischengespeichert hat, ohne selbst einen Abgleich
anzustoßen. `SyncDateiZugriff.leseKoordiniert` (GitHub #52) löst zwar bereits
zuverlässig den Download EINER bekannten Datei aus, hilft aber nicht gegen das
eigentliche Problem: die Enumeration NEUER, dem Gerät noch unbekannter
Peer-Dateien.

**Fix:** Neuer ``SyncICloudWeckerService`` — eine kurz laufende
`NSMetadataQuery`, gescoped auf den Sync-Ordner, läuft als erster Schritt
jedes ``SyncPollingService/syncZyklus()`` (automatisch wie manuell über
„Jetzt synchronisieren"). Wartet höchstens `timeout` (Standard 2s, per
`static var` testbar) auf `.NSMetadataQueryDidFinishGathering`, blockiert den
Zyklus aber nie länger — ein Timeout wird protokolliert
(`sync_icloud_wecker_abgeschlossen`), aber nicht als Fehlschlag des Zyklus
gewertet.

**Bewusst `NSMetadataQuery`, nicht `NSFilePresenter`:** Der in Build 128
eingeführte und in Build 133 wegen eines Deadlocks (`presentedItemOperationQueue
= .main` gegen bestehende synchrone `NSFileCoordinator`-Schreibzugriffe)
zurückgenommene `SyncOrdnerBeobachter`-Ansatz war providerunabhängig, aber
main-thread-gebunden. `NSMetadataQuery.operationQueue` läuft hier bewusst auf
einer eigenen Queue, nicht `.main` — vermeidet denselben Deadlock-Mechanismus.

**Geprüft, kein Sonderfall für andere Anbieter nötig:** `NSMetadataQuery` ist
auf iOS fest an iCloud gebunden — auch mit URL-gescopten `searchScopes` (seit
iOS 14) werden Ordner anderer File-Provider-Erweiterungen (Synology Drive u.ä.,
selbst über die Files-App/FileProvider-Framework eingebunden) nicht erfasst.
Bei solchen Ordnern liefert die Query einfach nichts, das Timeout greift
wirkungslos — bestätigt gegen aktuelle Apple-Dokumentation/-Foren, nicht nur
angenommen.

**Nachtrag (Live-Test-Fund direkt nach Einführung):** Crash mit `[CRIT] API
MISUSE: running a NSMetadataQuery with maxConcurrentOperationCount != 1 is not
supported`. `NSMetadataQuery.operationQueue` verlangt zwingend eine serielle
Queue — ein unkonfiguriertes `OperationQueue()` hat aber standardmäßig
unbegrenzte Nebenläufigkeit (`maxConcurrentOperationCount == -1`). Fix: die
Queue vor der Zuweisung explizit auf `maxConcurrentOperationCount = 1` setzen.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build` grün. Ein
echter Zwei-Geräte-Live-Test (insbesondere: verkürzt sich die beobachtete
Verzögerung bis zum Sichtbarwerden einer Peer-Änderung tatsächlich?) steht
noch aus — der Timeout-Wert von 2s ist eine Annahme, die anhand der neuen
`sync_icloud_wecker_abgeschlossen`-Protokolldaten empirisch nachjustiert
werden soll.

**Nachtrag (Zwei-Geräte-Live-Test, 2026-08-03): Ansatz wirkungslos, komplett
zurückgenommen.** Der `NSMetadataQuery`-Weckimpuls brachte im echten Test
keinerlei Verbesserung — Geräte synchronisierten weiterhin nur, wenn der
Sync-Ordner manuell in der Files-App geöffnet wurde, exakt wie vor diesem
Feature. Nachträgliche Recherche erklärt, warum die Grundannahme falsch war
(zwei unabhängige Apple-Doku-/Forenbelege, nicht nur eine nachträgliche
Vermutung):

1. **`NSMetadataQuery` triggert selbst keinen Download unbekannter
   Objekte** — "it's the application's responsibility to trigger downloads
   from iCloud" via `startDownloadingUbiquitousItem`. Die Query beobachtet
   nur bereits bekannte Metadaten, zwingt iCloud nicht, unbekannte
   Peer-Dateien vom Server zu holen.
2. **`NSMetadataQuery` beobachtet zuverlässig nur die Wurzel des gescopten
   Ordners, nicht Unterordner** — Forenbefund: Änderungen in Unterordnern
   gelten nur als Änderung des direkten Elternobjekts. Der Sync-Ordner hat
   aber genau diese Struktur (`peers/<Gerät>/…`), die eigentlichen
   Event-/Snapshot-Dateien liegen zwei Ebenen unter dem gescopten
   Wurzelordner.

`SyncICloudWeckerService` wurde komplett entfernt (Datei gelöscht, Aufruf aus
`SyncPollingService.syncZyklus()` entfernt, Debug-Event
`sync_icloud_wecker_abgeschlossen` aus `SyncDebugLogger` entfernt) — kostete
nur ~2s pro Zyklus ohne Nutzen. Der tatsächliche, unabhängig recherchierte
Fix-Versuch steht in Abschnitt 40.

**Lehre:** Diese Fehleinschätzung entstand, weil die ursprüngliche
Kernannahme ("`NSMetadataQuery` signalisiert iCloud aktiv, ich beobachte
diesen Ordner, und löst denselben Abgleich wie das Öffnen in der Files-App
aus") nie gegen Dokumentation verifiziert wurde, sondern nur plausibel
klang — anders als die Detailfrage zum File-Provider-Scoping, die vor der
Implementierung tatsächlich recherchiert wurde. Siehe
`ios-swift-engineering`-Skill, Abschnitt „Bei weniger gebräuchlichen APIs
vorher aktuelle Dokumentation prüfen".

## 40. GitHub #91 (Fortsetzung): Koordinierte Verzeichnis-Listings statt ungeschütztem `contentsOfDirectory`

**Ausgangslage:** Nach dem wirkungslosen `NSMetadataQuery`-Versuch (Abschnitt
39) war die eigentliche Root Cause weiterhin offen: Peer-Änderungen wurden
erst nach manuellem Öffnen des Sync-Ordners in der Files-App sichtbar.

**Root Cause (vor Umsetzung recherchiert, nicht nur angenommen):** Alle
Sync-Services listen Verzeichnisse innerhalb des Sync-Ordners
(`peers/`, je Peer `events/`/`kaeufe/`/Paket-Ordner) über schlichtes
`FileManager.default.contentsOfDirectory(...)` — ein ungeschützter,
unkoordinierter Zugriff. Apples iCloud-File-Management-Doku verlangt explizit
File-Coordination für jeden Zugriff außerhalb von Document-Objekten:
„Document objects use file coordinators … If you are not using document
objects to access files, you must handle the file coordination yourself."
`SyncDateiZugriff.leseKoordiniert(_:)` befolgt das bereits für einzelne
Dateien (GitHub #52) — für die Verzeichnis-**Listing**-Aufrufe selbst galt
das bisher nicht, obwohl genau dort neue Peer-Dateien erstmals sichtbar
werden müssten.

**Fix:** Neue Funktion ``SyncDateiZugriff/listeKoordiniert(_:)`` — derselbe
`NSFileCoordinator`-Zugriff wie ``leseKoordiniert(_:)``, nur für
`contentsOfDirectory` statt `Data(contentsOf:)`. Alle acht Aufrufstellen in
`SyncImportService`, `SyncSnapshotImportService`, `SyncOrdnerService`,
`SyncKaeufeExportService`, `SyncExportService` umgestellt. Aus
`@MainActor`-Kontext heraus jeweils per `Task.detached(priority: .utility)`
vom Main-Thread ferngehalten (blockierender Aufruf, Netzwerk-Download kann
mehrere Sekunden dauern) — analog zur bestehenden Doku-Empfehlung an
``leseKoordiniert(_:)``. Die einzige synchrone, nicht-async Aufrufstelle
(`SyncOrdnerService.hatVorhandenePeers(in:)`, nur einmalig beim
Ordner-Verknüpfen) bleibt bewusst blockierend, da dort ohnehin ein kurzer
UI-Wartezustand erwartet wird.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build` grün. Ein
echter Zwei-Geräte-Live-Test steht noch aus — anders als beim
`NSMetadataQuery`-Versuch ist diese Änderung diesmal gegen offizielle Apple-
Dokumentation zum genau vorliegenden Szenario (Verzeichnis-Zugriff auf einen
File-Provider-verwalteten, außerhalb der App-Sandbox liegenden Ordner)
verifiziert, keine unbelegte Analogie-Vermutung — aber ob das reicht, um die
beobachtete Verzögerung tatsächlich zu beheben, kann nur der reale Test
zeigen.

## 41. GitHub #87: WarengruppenDistanz-Merge reihenfolgeabhängig (naive statt gewichtete Mittelung)

**Befund:** `SyncSnapshotImportService.mergeWarengruppenDistanzen` mittelte
einen bereits vorhandenen lokalen `WarengruppenDistanz`-Eintrag beim Merge
naiv im Verhältnis 50/50 mit dem Peer-Wert (`(vorhandener.distanz +
eintrag.distanz) / 2`) — unabhängig davon, wie viele Beobachtungen
(Einkäufe) hinter jeder der beiden Zahlen bereits steckten. Eine reine
Zwei-Werte-Mittelung ist nicht assoziativ: das Ergebnis hängt von der
Sync-Reihenfolge ab, ein einzelner Ausreißer eines frisch synchronisierten
Geräts kann einen auf vielen stabilen Beobachtungen beruhenden Wert
unverhältnismäßig stark verschieben. Der Code-Kommentar an der Stelle
benannte das bereits selbst als bewusste Vereinfachung ggü. dem im
#39-Vorschlag skizzierten „gewichteten Mittelwert", mangels einer bis dahin
mitgeführten Beobachtungszahl je Eintrag.

**Fix — G-Counter-Muster für die Beobachtungszahl:** exaktes Gegenstück zur
Lösung aus Abschnitt 17 (`SyncPeerZaehlerStand`/`Geschaeft.anzahlEinkaufsvorgaenge`):
- `WarengruppenDistanz.eigeneBeobachtungsAnzahl` — rein lokaler, bei jedem
  `AbteilungsDistanzService.lerne(...)`-Aufruf direkt inkrementierter
  Anteil (additiv-optionaler Rohwert, Fallback `1` für vor der Änderung
  angelegte Zeilen — eine bestehende Zeile beruht per Definition auf
  mindestens einer Beobachtung).
- `WarengruppenDistanz.beobachtungsAnzahl` (computed) — Summe aus dem
  eigenen Anteil plus allen über das neue Modell `WarengruppenDistanzPeerZaehlerStand`
  gespeicherten, zuletzt bekannten EIGENEN Beiträgen jedes Peers (nicht
  dessen bereits gemergtem Gesamtwert — sonst exakt derselbe
  Doppelzähl-Fehler wie in Abschnitt 17, da Snapshots immer den kompletten
  aktuellen Bestand exportieren, keine Deltas).
- `WarengruppenDistanzSnapshot.eigeneAnzahlBeobachtungen` (neu,
  `SyncSnapshot.aktuelleFormatVersion` 4 → 5) trägt nur den rein lokalen
  Anteil des exportierenden Geräts, analog `GeschaeftSnapshot.eigeneAnzahlEinkaufsvorgaenge`.

**Zusätzliche Erkenntnis ggü. Abschnitt 17 — reine Zähler-Summe reicht hier
NICHT:** anders als ein reiner Zähler ist die gewichtete Mittelung von
`distanz` selbst nicht allein durch Überschreiben-statt-Addieren sicher. Ein
Merge, der bei jedem Sync-Zyklus mit dem VOLLEN aktuellen Peer-Gewicht
mischt, wäre nicht idempotent: ein unveränderter, wiederholt gesyncter
Peer-Wert würde den lokalen Wert bei jedem weiteren Zyklus erneut in seine
Richtung ziehen, obwohl keine einzige neue Beobachtung dazukam. Der Merge
blendet deshalb nur das Gewicht des tatsächlichen ZUWACHSES seit dem
zuletzt bekannten Stand dieses Peers ein
(`WarengruppenDistanzPeerZaehlerStand.zuletztGesehenerWert(peerGeraeteID:distanzID:context:)`,
vor dem Überschreiben des Ledger-Eintrags ausgelesen) — gegen das aktuelle
Gesamtgewicht der lokalen Seite (`WarengruppenDistanz.mergeGewichtung`).

**Deckelung des Merge-Gewichts (`WarengruppenDistanz.maximaleMergeGewichtung`,
≈ `1 / AbteilungsDistanzService.lernrate` ≈ 10):** das lokale Lernen selbst
ist ein exponentiell gleitender Durchschnitt mit fester Lernrate 0.1 — ältere
Beobachtungen verblassen geometrisch, das tatsächliche „Gedächtnis" reicht
nur rund 10 Beobachtungen zurück. Ein Gerät mit z.B. 100 historischen
Beobachtungen ist inhaltlich nicht 10× verlässlicher als eines mit 10 (die
ältesten 90 sind im aktuellen EMA-Wert längst verblasst). Ohne Deckelung
hätte ein Gerät mit sehr vieler Historie beim Merge eine Dominanz bekommen,
die sein aktueller Wert gar nicht mehr trägt — die Deckelung beantwortet
damit auch die ursprünglich im Issue offene Frage nach einer Obergrenze
(u.a. relevant, damit ein alter, etablierter Wert nach einem echten
Ladenumbau nicht quasi unveränderlich wird).

**Bewusst nicht umgesetzt (Scope-Entscheidung im Vorfeld, siehe Chat):** eine
Variante ganz ohne neuen Zustand (Merge über die bestehende EMA-Formel
`distanz * (1 - Lernrate) + peerDistanz * Lernrate` statt Zähler) wäre
deutlich kleiner gewesen, hätte Reihenfolgenunabhängigkeit aber nur
näherungsweise (starke Dämpfung statt echter Konvergenz) erreicht. Auf
Wunsch des Nutzers („mathematisch korrekt ist besser") stattdessen die
vollständige, mathematisch korrekte Variante mit Peer-Ledger umgesetzt.

**Verifikationsstand:** Code geschrieben, drei neue Unit-Tests in
`SyncSnapshotImportServiceTests.swift` (gleiche Beobachtungsanzahl →
identisch zur alten 50/50-Mittelung; unterschiedliche Beobachtungsanzahl →
Gewichtung statt 50/50; wiederholter Sync desselben Peer-Standes →
idempotent, keine erneute Verschiebung). `xcodegen generate`/Build noch
ausständig.

## 42. GitHub #91 (Fortsetzung): Koordinierte Verzeichnis-Listings wirkungslos, langlebiger `NSMetadataQuery`-Beobachter + koordinierte Schreibzugriffe

**Live-Test-Fund:** Auch der Abschnitt-40-Fix (koordinierte Verzeichnis-
Listings statt ungeschütztem `contentsOfDirectory`) brachte laut Live-Test
keine Verbesserung. Nutzer erinnerte sich an eine frühere Beobachtung: Gerät
A fügte einen Artikel hinzu, Gerät B bemerkte nichts — bis B selbst ebenfalls
etwas hinzufügte, danach lief der Sync.

**Root Cause (jetzt gegen Apples offiziellen „Designing for Documents in
iCloud"-Guide verifiziert, nicht nur vermutet):** Der erste `NSMetadataQuery`-
Versuch (Abschnitt 39) erzeugte jeden Sync-Zyklus eine NEUE Query, ließ sie
maximal 2s laufen und stoppte sie sofort wieder — erreichte dadurch nie
`enableUpdates()` und bekam praktisch nie eine echte
`NSMetadataQueryDidUpdateNotification`. Apples Guide dokumentiert stattdessen
explizit: „In iOS, employ an `NSMetadataQuery` object … to actively track the
locations of your documents" — früh erzeugen, **dauerhaft laufen lassen**,
auf `NSMetadataQueryDidUpdateNotification` reagieren. Zusätzlich bestätigt
(unbeantworteter Apple-Forenthread #783958, exakt unser Szenario — externer,
per Dokumenten-Picker gewählter Ordner): die Query beobachtet zuverlässig nur
die WURZEL jedes gescopten Ordners, nicht dessen Unterordner — der erste
Versuch scopte nur die Sync-Ordner-Wurzel, nicht `peers/<Gerät>/…`, wo die
eigentlichen Dateien liegen.

**Fix, zwei Teile:**

1. **Neuer ``SyncICloudAenderungsBeobachter``** (langlebig, kein
   Einzelaufruf mehr): gescoped auf den `peers/`-Ordner selbst sowie je
   bekanntem Peer dessen Ordner plus `events/`/`kaeufe/`-Unterordner.
   `enableUpdates()` nach dem ersten Gathering, danach dauerhaft auf
   `NSMetadataQueryDidUpdateNotification` reagieren und einen zusätzlichen
   Sync-Zyklus anstoßen. Neue Peers/ein gewechselter Sync-Ordner werden
   sowohl reaktiv (bei jeder eigenen Benachrichtigung) als auch periodisch
   (bei jedem regulären Sync-Zyklus) neu abgeglichen. Lifecycle an
   `SyncPollingService.starten(context:)`/`stoppen()` gekoppelt.
2. **Bei der Gelegenheit geprüft, ob auch alle SCHREIBzugriffe koordiniert
   sind** (Apples iCloud-Doku verlangt das für JEDEN Dateizugriff, nicht nur
   Lesen) — sechs Lücken gefunden und behoben: `createDirectory` (eigener
   `events/`-, `kaeufe/`-, Paket-Ordner) und `removeItem`/`moveItem` (alte
   eigene Event-Dateien aufräumen, eigene Kauf-Dateien löschen, eigenen
   Peer-Ordner bei Geräteumbenennung verschieben) liefen bisher direkt über
   `FileManager`, ungeschützt. Neue gemeinsame Funktionen
   ``SyncDateiZugriff/erstelleVerzeichnisKoordiniert(_:)``,
   ``SyncDateiZugriff/loescheKoordiniert(_:)``,
   ``SyncDateiZugriff/verschiebeKoordiniert(von:nach:)`` — Letztere nutzt
   exakt das im `NSFileCoordinator.h`-Header dokumentierte Move-Pattern
   (Quelle mit `.forMoving`, Ziel mit `.forReplacing`, ein einziger
   Koordinationsaufruf). Die bereits vorhandene private
   `loescheKoordiniert`-Dublette in `SyncSnapshotImportService` auf die neue
   gemeinsame Funktion umgestellt (Single Source of Truth).

**Gegen aktuellste SDK-Doku statt veralteter Quellen verifiziert:** API-Namen
(`startQuery`/`stopQuery` → Swift `start()`/`stop()`, `enableUpdates`/
`disableUpdates` nesten, exakter Wortlaut der `WritingOptions`-Fälle) direkt
gegen den lokal installierten `iPhoneOS26.5.sdk`-Header geprüft, nicht gegen
einen veralteten iOS-13-Header-Mirror — siehe `ios-swift-engineering`-Skill,
Abschnitt „Bei weniger gebräuchlichen APIs vorher aktuelle Dokumentation
prüfen". Dabei auch eine Nutzer-Vermutung (`.forReplacing` für normale
Inhalts-Updates) widerlegt: der Header sagt explizit "Don't use this when
simply updating the contents of a file" — `.forReplacing` ist nur für
Move-Ziele bzw. Save-As-artiges Ersetzen vorgesehen, nicht für unsere
Export-Datei-Updates (die bleiben bei `options: []`).

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build`/
`build-for-testing` grün, keine neuen Warnungen. Neue Debug-Events
`sync_icloud_beobachter_ausgeloest`/`sync_icloud_beobachter_scope_aktualisiert`
als Beleg, ob die Query im nächsten Live-Test tatsächlich feuert.

**Live-Test-Ergebnis (2026-08-03, nach Löschen alter Testdaten auf beiden
Geräten):** Sieht laut Nutzer „tatsächlich ganz gut aus" — deutliche
Verbesserung gegenüber den beiden vorherigen, wirkungslosen Anläufen
(Abschnitt 39/40). Bewusst vorsichtig formuliert: das Löschen alter
Testdaten VOR diesem Lauf ist ein nicht ausgeschlossener Nebenfaktor (z.B.
weniger/kleinere zu übertragende Dateien, kein Ballast aus vorherigen
Fehlversuchen) — ein weiterer, gezielter Vergleichstest ohne diese
Variable stünde noch aus, um den Effekt eindeutig auf den
`NSMetadataQuery`-Beobachter zurückzuführen. Für den Moment als
vorläufig funktionierend eingestuft, Untersuchung hier abgeschlossen.

## 43. GitHub #92: #91-Fix wirkt nur temporär — Recherche + `startDownloadingUbiquitousItem`-Fix + experimenteller Dokumenten-Picker-Trigger

**Praxisbeobachtung nach §42:** Der langlebige `NSMetadataQuery`-Beobachter
half laut Nutzer nur vorübergehend — nach einer Weile blieb der Sync wieder
hängen, obwohl die Implementierung (dauerhaft laufende Query, korrekt
gescopt, `enableUpdates()` nach `.gatheringComplete`) soweit erkennbar
korrekt war. Statt weiter zu spekulieren: gezielte Recherche gegen aktuelle
Apple-Doku, Entwicklerforen und einen einschlägigen Deep-Dive-Blogpost.
Vollständiges Ergebnis als Kommentar an [Issue
#92](https://github.com/McBoerny/ShopWithMe/issues/92#issuecomment-5170742717)
dokumentiert, hier nur die für die Umsetzung relevanten Punkte.

**Bestätigt, keine Änderung nötig:**
- Keine offizielle Force-Sync-API existiert — Sync-Timing bleibt
  vollständig system-/ML-gesteuert.
- `NSMetadataQuery` beobachtet bei externen (Bookmark-)Ordnern zuverlässig
  nur die Wurzel jedes gescopten Pfads, nie Unterordner — unabhängig
  bestätigt durch Apple-Forum-Thread #783958 (exakt unser Szenario). Der
  bestehende Scope-pro-Peer-Ordner-Ansatz (§42) ist damit strukturell
  bereits die richtige Antwort.
- `NSFilePresenter` bleibt ungeeignet — der Blogpost bestätigt unabhängig
  den bereits in `SyncPollingService.swift` dokumentierten Deadlock-Fund
  (teure IPC-Objekte, Hauptthread-Deadlock-Risiko).
- `BackgroundTasks`/`BGAppRefreshTask` bleibt kein tragfähiger Weg (30s-Cap,
  bis zu 7 Tage ML-Anlaufzeit, keine Weckung nach Force-Quit) — die
  bestehende bewusste Beschränkung auf Vordergrund-Sync (Abschnitt 9 in
  `docs/DATENSYNCHRONISATION.md`) bleibt richtig.

**Neuer, umgesetzter Fund:** Ein Apple-Forum-Thread (#785030, FB17662379,
unbeantwortet) beschreibt eine seit iOS 18.4 beobachtete Regression — eine
Datei kann dauerhaft im Status
`NSMetadataUbiquitousItemDownloadingStatusDownloaded` verharren, ohne dass
eine neuere Remote-Version automatisch nachgeladen wird, obwohl das laut
Doku automatisch passieren sollte. Einziger dokumentierter Workaround:
explizit `FileManager.startDownloadingUbiquitousItem(at:)` aufrufen, auch
für eine bereits als "downloaded" geltende Datei. Codeabgleich: die
bestehenden koordinierten Zugriffe in `SyncDateiZugriff` riefen diese
Methode nirgends auf — koordiniertes Lesen erzwingt laut Apples Doku
zuverlässig nur den Erstdownload eines noch nie materialisierten
Platzhalters, nicht das Nachziehen einer neueren Version einer bereits
lokal vorhandenen Datei. Das passt gut zum beobachteten Muster "läuft eine
Weile, bleibt dann hängen": Peer-Datei einmal gelesen → lokal als
"downloaded" markiert → spätere Remote-Änderungen wurden nicht mehr
zuverlässig nachgezogen.

**Umgesetzt:** `SyncDateiZugriff.leseKoordiniert(_:)`/`.listeKoordiniert(_:)`
rufen jetzt vor der Koordination `try? FileManager.default.startDownloadingUbiquitousItem(at: url)`
auf — Fire-and-forget ohne Abschluss-Callback (die API bietet keinen),
wirkt sich also bestenfalls erst im nächsten Zyklus aus. Passt zum ohnehin
bestehenden Best-Effort-Design ohne Fehler-Backoff (Abschnitt 5). `try?`
verträgt sich mit Nicht-iCloud-Ordnern (Synology Drive u.ä.), für die die
Methode fehlschlägt, ohne dass das ein Sonderfall sein muss.

**Nutzeridee, umgesetzt als bewusst unbelegtes Experiment:** Der manuelle
„Jetzt synchronisieren"-Button blendet jetzt zusätzlich kurz (0,4s) einen
`UIDocumentPickerViewController` auf den Sync-Ordner ein und schließt ihn
automatisch wieder (``ICloudSyncTriggerPicker`` in
`SyncOrdnerSettingsView.swift`) — Testidee: das Öffnen des Sync-Ordners in
der Files-App löst nachweislich einen Abgleich aus (§39/42), ein
`UIDocumentPickerViewController` nutzt dieselbe
File-Provider-Enumerationslogik wie die Files-App. Weder Apple-Doku noch
Entwicklerforen noch der Deep-Dive-Blogpost bestätigen oder widerlegen den
Effekt — bleibt ein zu verifizierendes Experiment, kein bekanntes Pattern.

Bewusst nur hinter diesem einen expliziten Button-Tap (nicht in den übrigen
internen Aufrufstellen von `SyncOrdnerSettingsView.jetztSynchronisieren()`
wie dem Bootstrap-Sync nach Ordnerauswahl oder dem Beitritts-Abgleich, und
nie im automatischen Hintergrund-Poll aus `SyncPollingService`) — ein
Sheet, das ohne Nutzerinteraktion von selbst wieder verschwindet, ist nur
als Reaktion auf einen expliziten Tap vertretbar (Accessibility-/App-Review-
Risiko sonst, siehe Issue #92). Neues Debug-Event
`sync_icloud_picker_trigger_ausgeloest` (`docs/LOGGING.md`) als Beleg, dass
der Trigger ausgelöst wurde — keine Aussage über dessen Wirkung, dafür der
zeitliche Abstand zu nachfolgenden Empfangs-Ereignissen im selben Protokoll
heranzuziehen.

**Nachträglich dokumentiert:** `sync_icloud_beobachter_ausgeloest`/
`sync_icloud_beobachter_scope_aktualisiert` (§42 eingeführt) fehlten bisher
in `docs/LOGGING.md` — bei dieser Gelegenheit nachgetragen (Single Source
of Truth).

**Verifikationsstand:** `xcodegen generate` + `xcodebuild clean build` grün,
keine neuen Warnungen. Beide Fixes sind reine Ergänzungen ohne
Verhaltensänderung im Fehlerfall — kein Unit-Test nötig (Live-Test-only,
wie der Rest von #91/#92: keine automatisierte Prüfung kann iCloud-Sync-
Latenz simulieren).

**Live-Test-Ergebnis (2026-08-03), zwei Szenarien:**

1. **Kernfrage aus §42 direkt geprüft** — nach einer bewussten Pause von
   über 30 Minuten (genau das Szenario, das §42 als "wirkt nur temporär"
   beschrieb) fanden sich beide Geräte im selben WLAN von selbst wieder und
   glichen ab, **ohne** manuellen Trigger. Das spricht dafür, dass der
   `startDownloadingUbiquitousItem`-Fix (oder das Zusammenspiel mit dem
   bereits bestehenden `SyncICloudAenderungsBeobachter` aus §42) das
   eigentliche §42-Problem behebt.
2. **Manueller Button über 5G-Hotspot:** gefühlt nochmals kürzere
   Abgleichszeit nach explizitem Tap auf "Jetzt synchronisieren" (inkl.
   Dokumenten-Picker-Flash) gegenüber dem Warten auf den nächsten
   automatischen Zyklus.

**Einordnung, bewusst vorsichtig:** Szenario 1 ist ein sauberer Test genau
der ursprünglichen Beschwerde und deutlich der aussagekräftigere Beleg.
Szenario 2 bleibt subjektiv ("gefühlt") und lässt sich nicht vom
Picker-Trigger isolieren — ein manueller Sync-Zyklus wäre über denselben
Button auch ganz ohne Picker sofort statt erst beim nächsten Intervall
gelaufen, das allein würde bereits schneller wirken. Beide Fixes liefen im
selben Build (218), eine saubere A/B-Trennung fand nicht statt. Nutzer
stuft den Befund dennoch als ausreichend ein, um dieses Issue zu schließen
— der Picker-Trigger bleibt als risikoarme, aber in ihrer eigenständigen
Wirkung unbestätigte Ergänzung im Code, für einen späteren gezielten
Vergleichstest (Picker kurz deaktivieren, sonst gleiche Bedingungen)
offen.

## 44. GitHub #68: `KaufEintrag.ursprungsGeraeteID` — Ursprungs-Unterdrückung zentral im Typ statt an zwei Call-Sites

**Ausgangslage:** Die Regel „ein von einem anderen Gerät materialisierter/
gemergter `KaufEintrag` bekommt nie einen `abteilungBesuchsIndex`" (siehe
Abschnitt oben zu `SyncEventNutzlast.geschaeftID`/GitHub #66, sowie
`docs/DATENSYNCHRONISATION.md`) war nur an zwei unabhängigen, von Hand
gepflegten Call-Sites umgesetzt: `SyncImportService.materialisiere`
(`indexFuerDistanzlernen: false`) und `SyncSnapshotImportService.
mergeKaufEintraege` (hartcodiertes `abteilungBesuchsIndex: nil`). `KaufEintrag`
selbst führte — anders als `SyncEvent.autorGeraeteID` — keine Information
darüber, ob er lokal oder remote entstanden ist. Bei Prüfung des Issues
zeigte sich, dass die befürchtete Gefahr ("ein künftiger dritter
Entstehungsweg vergisst die Regel") bereits eingetreten war: `BelegScanView`
legt seit einer früheren Änderung einen dritten, direkten
`KaufEintrag(...)`-Konstruktionsort an, der außerhalb beider bekannten
Unterdrückungsstellen liegt (zufällig unschädlich, da kein
`abteilungBesuchsIndex`-Argument übergeben wurde).

**Fix:** Neues additiv-optionales Attribut `KaufEintrag.ursprungsGeraeteID:
String?` (`nil` = lokal entstanden, sonst die Geräte-ID des Peers, von dem
der Eintrag per Sync-Event oder Snapshot übernommen wurde — analog
`SyncEvent.autorGeraeteID`). `KaufEintrag.init` erzwingt jetzt zentral:
`abteilungBesuchsIndex` wird verworfen, sobald `ursprungsGeraeteID != nil`,
unabhängig davon, was der Aufrufer übergibt. Die beiden bisherigen
Call-Sites übergeben jetzt die tatsächliche Urheber-Geräte-ID
(`SyncEventExportDarstellung.autorGeraeteID` bzw. `manifest.geraeteID`/
`peerGeraeteID`) statt eines reinen Bool-Flags — ein künftiger vierter
Entstehungsweg kann den ursprünglichen Fehler dadurch nicht mehr machen.
Keine neue `SchemaVN`/`MigrationStage` nötig (additiv-optionales Attribut,
siehe `docs/BUILD_WORKFLOW.md`).

## 45. GitHub #80: SyncEvent-„bereits gesehen"-Zustand übersteht Wipe-und-Neuaufbau nicht

**Fund:** Ein Live-Test-Log direkt nach einem Neuaufbau über
`SyncErsetzenService` (egal ob `.ersetzenDurchPeer` oder
`planeBereinigungBaumelnderReferenzen`) zeigte einen Burst von
`sync_event_nicht_anwendbar`-Einträgen für viele unterschiedliche,
teils Wochen alte `bezugsID`s direkt nach dem Neustart.

**Ursache:** Der Wipe löscht die komplette Store-Datei — inklusive der
lokalen `SyncEvent`-Tabelle, die trackt, welche Bereich-A-Events
(`SyncEventService.istBereitsBekannt`) bereits verarbeitet wurden. Die
Peer-Event-Dateien selbst werden dadurch nicht angetastet (seit GitHub #89
nach 30 Tagen automatisch gelöscht, Abschnitt 9). Nach einem Neuaufbau hat
das Gerät keine Erinnerung mehr daran, welche Events es schon gesehen hat —
der nächste Sync-Zyklus liest und verarbeitet jede noch nicht abgelaufene
Peer-Event-Datei jedes Peers erneut, statt sie über den Dateinamens-Vorfilter
(`SyncEventService.alleAktuellenGewinnerUndBekannteIDs`) zu überspringen.

**Warum relevanter als beim ursprünglichen Melden:** Ursprünglich war der
Wipe-Mechanismus ein seltener Sonderfall (Korruptions-Recovery,
Erstbeitritt). GitHub #89 führte kurz danach einen erzwungenen
Voll-Abgleich ein, der `planeErsetzenDurchPeer` automatisch auslöst, sobald
ein Gerät länger als 30 Tage nicht synchronisiert hat
(`SyncAktualitaetsService`/`RootView.vollAbgleichAusloesen()`) — derselbe
Pfad, der die `SyncEvent`-Tabelle verliert. Der Wipe ist damit kein seltener
Recovery-Sonderfall mehr, sondern kann routinemäßig automatisch ausgelöst
werden.

**Erwogene Alternative — Zeitstempel-Cutoff statt exakter ID-Liste:**
naheliegend wäre, `SyncEvent.wallClock` gegen `SyncSnapshot.erzeugtAm` zu
vergleichen und alles Ältere zu ignorieren. Verworfen aus zwei Gründen: (1)
`wallClock` ist laut eigener Typ-Doku bewusst „nie für Ordnung zwischen
Geräten verwendet" — Geräteuhren können auseinanderlaufen, ein Event mit
leicht nachgehender Fremd-Uhr würde fälschlich für immer als „schon
enthalten" ignoriert und ginge damit still verloren. (2) Ein Snapshot ist
kein linearer Ausschnitt eines Event-Logs, sondern das Ergebnis einer
Konfliktauflösung mit eigenen Vorrangregeln (`SyncKonfliktAufloesung`: z.B.
„Dauerhaft entfernen schlägt alles"), die nicht rein durch einen Lamport-
Zähler oder Zeitpunkt geordnet ist — es gibt daher keinen einzelnen,
gültigen Cutoff-Wert pro Peer, den ein Snapshot hergibt.

**Fix:** `SyncErsetzenBackup` (bereits bestehendes, lokal-privates
Backup-Format für den Wipe-Mechanismus, GitHub #63) bekommt ein zusätzliches
Feld `bekannteSyncEvents: [SyncEventBackupEintrag]?` — wrapt die bereits
vorhandene Peer-Wire-Darstellung `SyncEventExportDarstellung` um den
gerätelokalen `hochgeladen`-Status. `erstelleBackup(context:)` sichert damit
vor jedem Wipe den kompletten lokalen `SyncEvent`-Bestand;
`fuehreAusstehendeAktionAus(context:)` stellt ihn danach über die neue
`stelleSyncEventsWiederHer(_:context:)` wieder her (nutzt intern das
bestehende `SyncEventService.uebernehmen(_:context:)`, das Einfügen +
Lamport-Abgleich vom regulären Peer-Empfangspfad übernimmt).

**Wichtige Randbedingung beim Restore:** `uebernehmen` setzt `hochgeladen`
sonst pauschal auf `true` (korrekt für ein tatsächlich von einem Peer
empfangenes Event) — beim Restore des eigenen Bestands würde das ein noch
nicht exportiertes eigenes Event fälschlich als „bereits geteilt" markieren
und dauerhaft von `SyncExportService.exportiereNeueEvents` (Filter
`hochgeladen == false`) ausschließen. `stelleSyncEventsWiederHer` setzt den
Wert deshalb explizit auf den gesicherten Originalwert zurück.
`formatVersion` von `SyncErsetzenBackup` auf 2 erhöht; `bekannteSyncEvents`
ist bewusst optional (`nil` statt `[]` als Default), damit ein noch im alten
Format auf der Platte liegendes Backup weiterhin decodierbar bleibt.

## 46. Race Condition: Hintergrund-Sync lief bis zum Neustart unbegrenzt mit dem alten Bestand weiter

**Gemeldet vom Nutzer:** Beim Neu-Setzen des Sync-Ordners fragt die App nach
einem Neustart, aber unabhängig davon scheint schon vor dem Neustart im
Hintergrund synchronisiert zu werden — je länger man mit dem Neustart
wartet, desto mehr. Verdacht: Vermischung von aktuellem Datenbestand und
Sync-Bestand.

**Ursache:** Zwei Zustandsebenen wechseln beim Ersetzen-/Wiederherstellen-
Mechanismus (``SyncErsetzenService``, Abschnitt 13) zu unterschiedlichen
Zeitpunkten:

| Zustand | Wechselt wann |
|---|---|
| Sync-Ordner-Bookmark (`UserDefaults`, `SyncOrdnerService.ordnerFestlegen`) | sofort beim Verknüpfen |
| In-Memory-Datenbestand (`ModelContainer`) | erst beim nächsten Prozessstart (`ShopWithMeApp.init()`) |
| `SyncPollingService`/`SyncICloudAenderungsBeobachter`/`MultipeerSyncService` | liefen bis zu diesem Fix ununterbrochen weiter, nur an `scenePhase` gekoppelt, nicht an eine ausstehende `SyncErsetzenService`-Aktion |

Abschnitt 13 löste bereits eine frühere, andere Sorge (physisches Löschen der
Store-Datei bei noch laufendem Sync-Zyklus, Absturzrisiko) durch die
Verschiebung des eigentlichen Datenaustauschs auf den nächsten Prozessstart.
Diese Lösung deckt aber NICHT den hier gemeldeten Fall ab: der
`SyncPollingService`-Loop (5s/60s-Intervall) sowie der reaktive
`SyncICloudAenderungsBeobachter` liefen bis zum tatsächlichen Neustart
weiter unverändert mit dem alten `ModelContext` — jeder Zyklus liest den
Ordnerpfad frisch (kein Caching pro Session, siehe Zeile 146-150 in
`SyncPollingService.syncZyklus()`, bewusst so für den Zusammenführen-Fall)
und exportierte damit bei jedem Tick den alten, gleich zu verwerfenden
Bestand in den neuen Ordner bzw. importierte fremde Daten in den alten,
gleich zu verwerfenden Context. Zusätzlich blieb im „Ersetzen"-Fall der
Button „Jetzt synchronisieren" in ``SyncOrdnerSettingsView`` sichtbar und
aktiv, ein manueller Tap hätte denselben Effekt unabhängig vom Loop-Zustand
ausgelöst.

**Fix:** An allen sechs Aufrufstellen, die `SyncErsetzenService.planeErsetzenDurchPeer`/
`planeWiederherstellenAusBackup`/`planeBereinigungBaumelnderReferenzen`
aufrufen (``SyncOrdnerSettingsView`` dreimal, ``RootView/vollAbgleichAusloesen()``,
``DebuggingView``s `DatenintegritaetSection` zweimal), wird unmittelbar
danach `syncPollingService.stoppen()` und `multipeerSyncService.stoppen()`
aufgerufen — nicht erst beim Neustart. Da diese Aktionen ohnehin nicht mehr
rückgängig gemacht werden (der jeweilige "Neustart nötig"-Alert hat nur
„OK", kein „Abbrechen"), ist ein erneutes Starten der Dienste vor dem
Neustart nicht nötig. Zusätzlich merkt sich ``SyncOrdnerSettingsView`` den
Zustand über ein aus ``SyncErsetzenService/ausstehendeAktion`` initialisiertes
`neustartAusstehend`-Flag (Single Source of Truth, übersteht auch ein
Verlassen/Wiederbetreten der View ohne Neustart) und blendet „Jetzt
synchronisieren", „Ordner wählen…" und „Synchronisierung deaktivieren" bis
zum Neustart aus bzw. deaktiviert sie, damit auch ein manueller Trigger die
Lücke nicht mehr offen lässt.

**Restliches, bewusst nicht geschlossenes Zeitfenster:** Ein zum Zeitpunkt
des Stopps bereits laufender Sync-Zyklus wird (wie in Abschnitt 13
begründet) nur kooperativ zum Abbruch aufgefordert, nicht abgewartet — es
kann also noch genau EIN begonnener Zyklus zu Ende laufen. Anders als vorher
skaliert das Zeitfenster damit nicht mehr mit der Wartezeit bis zum
Neustart, sondern ist auf diesen einen, bereits laufenden Zyklus begrenzt.

## 47. Live-Fund direkt nach Abschnitt 46: Neustart-Schleife durch Rückkehrer-Erkennung vor dem ersten eigenen Export

**Gemeldet vom Nutzer** (Logs von zwei Geräten, „Backup" und „Bernhard"):
Nach „Ersetzen" beim (Wieder-)Verknüpfen eines Sync-Ordners und dem
angeforderten Neustart erkennt sich das Gerät fälschlich als „aus der
Sync-Gruppe entfernt". Wählt der Nutzer „Wieder beitreten", öffnet sich
wieder die Ordnerauswahl, führt wieder zu „Ersetzen" → „Neustart nötig" →
wieder fälschliche Entfernung — eine Endlosschleife. Die Store-Debug-Logs
zeigen sechs `store_open_start`-Einträge (= sechs echte Prozessneustarts)
innerhalb von vier Minuten auf demselben Gerät.

**Ursache:** Zwei unabhängige Mechanismen liefen in der falschen Reihenfolge
gegeneinander:

1. `SyncSnapshotExportService.exportierePaket(context:importErfolgreich:)`
   legt den eigenen Peer-Unterordner (`peers/<eigenerName>/`) im Sync-Ordner
   erst beim ERSTEN eigenen Export-Zyklus an (unbedingt, sobald der
   Ordnerzugriff klappt) — vorher existiert er schlicht nicht.
   `exportierePaket` wird ausschließlich aus `SyncPollingService.syncZyklus()`
   aufgerufen, also nur als Teil eines echten Sync-Zyklus.
2. `ShopWithMeApp.body.task` ruft nach einem Neustart erst
   `SyncErsetzenService.fuehreAusstehendeAktionAus(context:)` auf (reiner
   Import des Peer-Snapshots in den frischen, leeren Context — schreibt
   nichts nach `peers/<eigenerName>/`), DANACH
   `syncPollingService.starten(context:)`. Dessen allererster Schritt, VOR
   der eigentlichen Sync-Schleife, ist die Rückkehrer-Erkennung
   (`SyncOrdnerService.binIchNochMitglied(in:)`, Abschnitt zu GitHub #89):
   listet `peers/` im Sync-Ordner und prüft, ob der eigene Unterordner
   existiert. Direkt nach einem frischen Ersetzen-Neustart existiert er
   noch nicht (Punkt 1) → die Prüfung liefert `false` statt des für
   „unentscheidbar" vorgesehenen `nil` → das Gerät hält sich für
   ausgeschlossen, sichert ein (bereits redundantes) Backup, entfernt lokal
   den Sync-Ordner und zeigt „Aus der Sync-Gruppe entfernt" — noch bevor
   auch nur ein einziger eigener Sync-Zyklus lief.

**Verschärft (nicht verursacht) durch Abschnitt 46:** Vor dem Abschnitt-46-Fix
lief der Hintergrund-Sync zwischen „Ersetzen"-Tap und tatsächlichem Neustart
noch weiter und hatte damit oft schon (sofern mind. ein 5s/60s-Intervall
verging) einen Export-Zyklus samt eigenem Peer-Unterordner ausgelöst — das
maskierte diesen Ordnungsfehler bisher zufällig. Der Abschnitt-46-Fix stoppt
den Hintergrund-Sync jetzt korrekt sofort, wodurch dieser vorbestehende,
unabhängige Bug bei JEDEM „Ersetzen" deterministisch auftrat statt nur
gelegentlich.

**Wichtige Nebenwirkung der Schleife (Datenverlust-Risiko):** Jede
Schleifen-Iteration ruft erneut `SyncErsetzenService.erstelleBackup`
auf — sowohl explizit in `planeErsetzenDurchPeer` als auch implizit in der
fälschlich ausgelösten Rückkehrer-Erkennung selbst. Da genau eine
Backup-Datei geführt wird (ein erneuter Aufruf überschreibt die vorherige,
siehe Abschnitt 13), überschreibt jede weitere Iteration das vorherige
Backup mit dem Stand der jeweils letzten (fälschlichen) Runde. Ein
ursprünglich VOR dem allerersten „Ersetzen" noch nicht synchronisierter
lokaler Stand ist dadurch nach mehreren Schleifendurchläufen über das lokale
Backup nicht mehr rekonstruierbar — betrifft nur lokal-exklusive, noch nicht
zum Zeitpunkt des ersten „Ersetzen" synchronisierte Änderungen dieses einen
Geräts, nicht den Gruppen-Datenbestand auf anderen Geräten.

**Fix:** `SyncErsetzenService.fuehreAusstehendeAktionAus(context:)` gibt jetzt
`Bool` zurück (`true`, falls tatsächlich eine Aktion ausgeführt wurde).
`SyncPollingService.starten(context:ueberspringeRueckkehrerErkennung:)`
bekommt einen neuen Parameter (Default `false`), der die Rückkehrer-Erkennung
für genau diesen einen Aufruf auslässt. `ShopWithMeApp.body.task` reicht den
Rückgabewert von `fuehreAusstehendeAktionAus` direkt als
`ueberspringeRueckkehrerErkennung` durch. Bei jedem regulären
Vordergrund-Wechsel (`onChange(of: scenePhase)`, kein frischer
Wipe-und-Neuaufbau vorausgegangen) bleibt die Prüfung unverändert aktiv —
eine echte Entfernung aus der Gruppe während App im Hintergrund war, wird
weiterhin normal erkannt.

## 48. „Zusammenführen“-Wahl beim Sync-Beitritt entfernt (Nutzerentscheidung)

**Entscheidung (2026-08-06):** Direkt im Anschluss an den Live-Fund in
Abschnitt 47 hat der Nutzer entschieden, die „Zusammenführen"-Option in der
„Bestehende Daten gefunden"-Wahl beim Sync-Ordner-Beitritt ganz zu entfernen
(`SyncOrdnerSettingsView`, GitHub #63). Der Beitritt zu einer Gruppe mit
bereits vorhandenen Peer-Daten läuft seither ausschließlich über „Ersetzen"
(+ „Abbrechen") — der lokale Bestand wird vorher lokal gesichert
(wiederherstellbar über „Backup wiederherstellen") und danach vollständig
durch den Gruppenstand ersetzt.

**Warum (Nutzerkontext):** Kein technischer Bug, sondern eine bewusste
Vereinfachung nach den beiden aufeinanderfolgenden Live-Funden in Abschnitt
46/47 rund um den „Ersetzen"-Pfad — ein einziger, klar definierter
Beitritts-Ablauf statt zweier unterschiedlich riskanter Pfade.

**Entfernter Code (vollständig, nicht nur der UI-Button):**
- `SyncOrdnerSettingsView.swift`: der „Zusammenführen"-Button im
  `confirmationDialog` „Bestehende Daten gefunden", die Funktion
  `beitrittsAbgleichPruefenUndSynchronisieren()`, die zugehörigen `@State`-
  Variablen (`beitrittsKandidaten`, `zeigeBeitrittsAbgleich`,
  `pruefeBeitrittsAbgleich`), das `.sheet(isPresented: $zeigeBeitrittsAbgleich)`
  sowie das `.overlay` mit dem Lade-Indikator „Prüfe auf mögliche gleiche
  Geschäfte…".
- `SyncSnapshotImportService.swift`: `GeschaeftsAbgleichKandidat`,
  `mehrdeutigeGeschaeftsKandidatenBeimBeitritt(context:)`,
  `geschaeftsKandidatBestaetigen(_:gewaehlterName:context:)` — allesamt nur
  vom entfernten Beitritts-Pfad genutzt.
  `GeschaeftErkennungService.istMehrdeutigerBeitrittsKandidat(...)` selbst
  bleibt bestehen (weiterhin genutzt vom laufenden Hintergrund-Sync, siehe
  `docs/GESCHAEFTSERKENNUNG.md`).
- `SyncSnapshotImportServiceTests.swift`: der zugehörige Test
  `mehrdeutigerBeitrittsKandidatWirdGefundenUndNachBestaetigungGemergt` —
  der zugrunde liegende Mechanismus bleibt indirekt weiterhin über
  `geschaeftMehrdeutigerKandidatWirdZurueckgestelltUndAufgeloest` (laufender
  Sync, unverändert bestehende Testreihe) abgedeckt.
- `docs/GESCHAEFTSERKENNUNG.md`: Abschnitt „Aktive Rückfrage beim
  Sync-Ordner-Beitritt (GitHub #86, Teil 2)" auf „Status: Entfernt"
  umgestellt statt gelöscht (historische Nachvollziehbarkeit).

**Nicht betroffen:** Die laufende Hintergrund-Sync-Ambiguitätsprüfung
(``SyncAbgleichKandidat``-Warteschlange, „N mögliche Duplikate prüfen" in
den Sync-Einstellungen) bleibt vollständig unverändert bestehen — sie deckt
einen strukturell anderen Fall ab (laufender Betrieb, nicht der einmalige
Beitritts-Moment) und war von Abschnitt 47 nicht betroffen.

## 49. Live-Fund: Abschnitt-47-Fix wirkungslos — Race Condition zwischen `.task` und `.onChange(of: scenePhase)`

**Gemeldet vom Nutzer:** Trotz Abschnitt 47 trat exakt dieselbe
Neustart-Schleife weiterhin auf — nach dem Neustart war der gesetzte
Sync-Ordner sofort wieder undefiniert, „Wieder beitreten" öffnete erneut die
Ordnerauswahl, derselbe Kreislauf von vorn.

**Ursache:** Der Abschnitt-47-Fix übergab die Information „gerade einen
Wipe-und-Neuaufbau ausgeführt, Rückkehrer-Erkennung diesmal überspringen"
ausschließlich als Parameter über EINEN der beiden Aufrufer von
``SyncPollingService/starten(context:)``. `ShopWithMeApp.swift` hat aber
zwei voneinander unabhängige Aufrufer ohne garantierte Reihenfolge — genau
das dokumentierte der bestehende Kommentar in `SyncPollingService.starten`
bereits vorher, ohne dass die Konsequenz für den neuen Parameter erkannt
wurde:

```swift
.task {
    await SyncErsetzenService.fuehreAusstehendeAktionAus(context: ...)   // asynchron, wartet auf Datei-I/O
    syncPollingService.starten(context: ..., ueberspringeRueckkehrerErkennung: true)  // kommt SPÄT
}
...
.onChange(of: scenePhase) { _, neuePhase in
    case .active:
        syncPollingService.starten(context: ...)   // KEIN Parameter, Default false — kommt beim App-Start fast immer ZUERST
}
```

`scenePhase` wechselt beim App-Start typischerweise sehr früh von
`.inactive`/`.background` zu `.active` und feuert `.onChange` praktisch
sofort — deutlich bevor der asynchrone Peer-Import in `.task` fertig ist.
Der `.onChange`-Aufruf gewinnt das Rennen fast immer, startet die
Polling-Schleife (`schleife == nil` beim ersten Aufruf) OHNE den Skip, die
Rückkehrer-Erkennung greift ungeschützt, entfernt lokal den Sync-Ordner.
Wenn `.task` danach seinen eigenen `starten(...)`-Aufruf MIT dem Skip
nachreicht, greift `guard schleife == nil else { return }` bereits — die
Schleife läuft ja schon (vom `.onChange`-Aufruf gestartet) — der Aufruf ist
also ein wirkungsloses No-Op. Der Skip-Parameter kam damit in der Praxis so
gut wie nie zum Zug.

**Fix:** Die Information wird nicht mehr als Parameter zwischen zwei
nebenläufigen Aufrufern durchgereicht, sondern als
`nonisolated(unsafe) static var ueberspringeRueckkehrerErkennungBeimNaechstenStart`
auf ``SyncPollingService`` synchron in `ShopWithMeApp.init()` gesetzt —
BEVOR `body` (und damit `.task`/`.onChange(of: scenePhase)`) überhaupt
existiert, also raceunabhängig egal welcher der beiden Aufrufer zuerst
`starten(context:)` aufruft. `starten(context:)` selbst konsumiert das Flag
beim ersten Aufruf dieser Sitzung (liest + setzt auf `false`, geschützt vom
ohnehin bestehenden `schleife == nil`-Guard, `@MainActor`-seriell). Der
Parameter `ueberspringeRueckkehrerErkennung` entfällt wieder;
`SyncErsetzenService.fuehreAusstehendeAktionAus(context:)` liefert wieder
`Void` statt `Bool` zurück, da der Rückgabewert nicht mehr gebraucht wird.

**Lehre:** Ein Fix, der eine Race Condition beheben soll, aber die
Information nur über EINEN von mehreren nebenläufigen, gleichrangigen
Aufrufern weiterreicht, behebt die Race nicht — er verlagert sie nur
dorthin, welcher Aufrufer zuerst drankommt. Statt jedem Aufrufer dieselbe
Information einzeln beizubringen, muss die Information race-unabhängig
VOR allen möglichen Aufrufern feststehen (hier: `init()`, vor `body`).

## 50. Nutzerbericht (2026-08-09): frischer Beitritt zeigte auf einem Gerät Dutzende längst abgehakte Artikel als aktuell abgehakt

**Gemeldet vom Nutzer:** Nachdem Gerät „Backup" frisch dem Sync-Ordner
beigetreten war (Beitritt mit „Ersetzen" — lokaler Bestand verworfen, aus dem
Peer-Bestand von „Bernhard" neu aufgebaut, Abschnitt 8), zeigte die Liste
„Einkaufsliste" auf „Backup" 9 abgehakte Einträge, auf „Bernhard" dagegen
korrekt 0 von 8. Diagnose per `SyncDebugLogger`-Protokoll beider Geräte
(`docs/LOGGING.md`): direkt nach dem Neuaufbau protokollierte „Backup" für
VIER unterschiedliche `vorgangID`s in Folge
`sync_einkaufsvorgang_abschluss_nicht_uebernommen grund=endZeitVorStartZeit`
— auffällig war, dass alle vier denselben lokalen `startZeit`-Wert nannten,
exakt den Zeitpunkt des gerade laufenden Sync-Zyklus.

**Ursache:** `SyncSnapshotImportService.mergeEinkaufsvorgaenge`s
`offenerTreffer`-Zweig (Abschnitt 4.3 in `docs/DATENSYNCHRONISATION.md`, für
das Race „zwei Geräte legen vor ihrem ersten Sync unabhängig je einen
frischen Vorgang für dieselbe Kombination an") prüfte bislang nur
Eigenschaften des LOKALEN Kandidaten (`endZeit == nil`,
`kaufEintraege.isEmpty`, passendes Geschäft/Liste) — nicht, ob der REMOTE-
Eintrag selbst überhaupt noch offen war. Sobald die frisch importierte Liste
sichtbar wurde, legte `EinkaufenView.einkaufSicherstellen()` sofort einen
eigenen, leeren lokalen Platzhalter-Vorgang an (`geschaeft=nil`,
`endZeit=nil`, `startZeit=jetzt`) — und DIESER erfüllte die
`offenerTreffer`-Kriterien für JEDEN der vier bereits abgeschlossenen
Peer-Vorgänge gleichermaßen, da neu angelegte Kandidaten laut Abschnitt-20-
Fix sofort in `alleLokalen` nachgetragen werden, aber `mergeKaufEintraege`
(das den Platzhalter mit eigenen Käufen befüllt hätte) erst in einem
SPÄTEREN Merge-Schritt läuft. Alle vier fremden, echten Einkäufe wurden
dadurch fälschlich auf denselben einen Platzhalter aliasiert. Die defensive
Plausibilitätsprüfung aus Abschnitt „Live-Test-Fund" (`remoteEndZeit >=
vorhandener.startZeit`, siehe `docs/DATENSYNCHRONISATION.md` §4.3) griff
danach bei JEDEM der vier — der Platzhalter war ja „gerade eben" angelegt,
jede echte historische `endZeit` lag zwangsläufig davor —, verwarf also
jeden Abschluss und ließ den zusammengeführten Vorgang dauerhaft offen.
`mergeKaufEintraege` hängte im nächsten Schritt die `KaufEintrag`e ALLER
VIER vergangenen Einkäufe an diesen einen, weiterhin offenen Vorgang — und
`EinkaufenView.abgehakteKaufEintraegeFuerAktuelleListe` (liste-, nicht
vorgangsbezogen, Abschnitt „Live-Ansicht: liste- und statusbasiert" oben)
zeigte sie alle als aktuell abgehakt an, obwohl sie zu vier verschiedenen,
längst abgeschlossenen Einkäufen von „Bernhard" gehörten. „Bernhard" selbst
blieb unberührt, da sein eigener Datensatz nie Teil dieses Merges war —
daher die Diskrepanz zwischen beiden Geräten.

**Fix:** `offenerTreffer` matcht jetzt zusätzlich nur, wenn der REMOTE-
Eintrag selbst noch offen ist (`eintrag.endZeit == nil`) —
`SyncSnapshotImportService.swift`, `mergeEinkaufsvorgaenge`. Ein bereits
abgeschlossener Peer-Vorgang ist per Definition kein Kandidat für das
Vor-dem-ersten-Sync-Race, das der Zweig abdecken soll, sondern ein
eigenständiger historischer Einkauf — er bekommt stattdessen (wie ein
normaler neuer Vorgang) einen eigenen lokalen Datensatz mit
`startZeit = eintrag.startZeit`, gegen den die Plausibilitätsprüfung
korrekt besteht. Regressionstest:
``SyncSnapshotImportServiceTests/mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert()``.

**Lehre:** Der `offenerTreffer`-Zweig wurde bereits zweimal nachträglich
präzisiert (Abschnitt „Nutzerbericht 2026-08-06": Filter auf
`kaufEintraege.isEmpty`; Abschnitt 25: Filter auf eine echte, nicht-`nil`
`remoteListe`) — beide Male, weil die ursprüngliche Formulierung nur den
lokalen Kandidaten einschränkte, nie die Eigenschaften des REMOTE-Eintrags
selbst. Ein Matching-Zweig, der ein enges Race zwischen zwei gleichrangigen,
noch offenen Zuständen behandeln soll, muss auf BEIDEN Seiten prüfen, dass
der jeweils andere Zustand wirklich zum Race passt — eine Prüfung nur der
lokalen Seite lässt sich von einer beliebigen, zufällig passenden Remote-
Eigenschaft (hier: bereits abgeschlossen) unterlaufen.

## 51. Nutzerbericht-Folgefund (2026-08-10): Backup nach Abschnitt-50-Fix korrekt 0 abgehakt, aber dauerhaft 2 Einträge weniger als Bernhard

**Gemeldet vom Nutzer:** Nach dem Abschnitt-50-Fix zeigte „Backup" nach einem
erneuten Neuaufbau korrekt 0 abgehakte Artikel (bestätigt per Protokoll: alle
vier `sync_einkaufsvorgang_abschluss_uebernommen` mit je eigener, korrekter
`lokaleID` statt eines gemeinsamen Platzhalters) — aber die Liste
„Einkaufsliste" blieb bei 6 Einträgen, während „Bernhard" weiterhin 8 zeigte.
Wiederholte Sync-Zyklen änderten daran nichts, auch nicht über mehrere
Stunden hinweg (Protokoll-Zeitstempel bis 2026-08-10T02:58 Uhr).

**Ursache:** Bernhards eigenes Debug-Protokoll aus der vorherigen Sitzung
zeigte bereits wiederholt `sync_baumelnde_referenz_gefunden typ=Artikel
referenz=…/Artikel/p29` — eine auf seinem Gerät seit längerem bestehende
baumelnde Referenz, vermutlich ein Altbestand von vor Einführung der
`@Relationship(deleteRule: .cascade, inverse:)`-Deklarationen auf
`Einkaufsliste.eintraege`/`Artikel.einkaufslistenEintraege` (seitdem über
normale App-Operationen strukturell nicht mehr neu entstehbar, siehe
Typ-Doku von `DatenintegritaetsServiceTests`). `SyncSnapshotExportService`s
Aufbau von `einkaufslistenEintraege` verwirft einen `EinkaufslistenEintrag`
beim Export komplett, sobald `sichereID` für `artikel` ODER `einkaufsliste`
`nil` liefert (Zeile „`guard let einkaufslisteID = …, let artikelID = … else
{ return nil }`" in `SyncSnapshotExportService.erstelleSnapshot`) — anders
als bei den meisten übrigen Bereich-B-Feldern wird hier nicht nur das
einzelne Feld genullt, sondern der GANZE Eintrag ausgelassen, weil ein
`EinkaufslistenEintrag` ohne Artikel oder Liste fachlich sinnlos wäre. Zwei
von Bernhards Einträgen auf „Einkaufsliste" referenzierten (vermutlich) den
baumelnden Artikel — sie fehlten dadurch in JEDEM Export, den Bernhards
Gerät je erzeugte, unabhängig davon, wie oft „Backup" neu synchronisierte
oder sich komplett neu aufbaute. Zusätzlicher Befund: `DatenintegritaetsService.pruefe(context:)`
prüfte `EinkaufslistenEintrag.artikel`/`.einkaufsliste` bisher gar nicht —
der Zustand war auf Bernhards eigenem Gerät dadurch komplett unsichtbar, nur
über das Sync-Debug-Protokoll (nicht die reguläre Datenintegritäts-Anzeige)
indirekt erkennbar.

**Fix:** `DatenintegritaetsService.pruefe(context:)` erkennt und meldet
jetzt zusätzlich `EinkaufslistenEintrag`e mit baumelndem `artikel`- oder
`einkaufsliste`-Bezug (inkl. Hinweis, dass der Eintrag beim Sync-Export
stillschweigend übersprungen wird) — sichtbar in
`DebuggingView` → „Datenintegrität" auf dem betroffenen Gerät (hier:
Bernhard, nicht Backup). Der bestehende Reparaturweg
(`SyncErsetzenService.planeBereinigungBaumelnderReferenzen`, „Baumelnde
Referenzen bereinigen" in `DebuggingView`) heilt die Referenz bereits
korrekt (ein frischer Export löst sie beiläufig zu `nil` auf, siehe
Abschnitt 8/§4.5 in `docs/DATENSYNCHRONISATION.md`) — das Problem war nicht
fehlende Reparatur-Funktionalität, sondern fehlende Sichtbarkeit, die den
Nutzer nie zu dieser Funktion geführt hätte. Kein Regressionstest mit einer
echten baumelnden Referenz (siehe Typ-Doku von
`DatenintegritaetsServiceTests`, warum das mit den aktuellen `inverse:`-
Deklarationen nicht mehr sicher konstruierbar ist) — die bestehende
„vollständig intakte Daten melden nichts"-Testabdeckung wurde um einen
`EinkaufslistenEintrag` erweitert.

**Empfohlene Abhilfe für den konkreten Fall:** Auf Bernhards Gerät
Einstellungen → Debugging → „Baumelnde Referenzen bereinigen" ausführen
(kein Sync-Gerät nötig, siehe Abschnitt 8) — danach exportiert sein Gerät
wieder den vollständigen Bestand, und der nächste reguläre Sync-Zyklus
bringt „Backup" (und jeden anderen Peer) auf den korrekten Stand, ohne dass
dafür ein erneuter Neuaufbau auf „Backup" selbst nötig ist.

**Lehre:** Ein Diagnose-Werkzeug, das gezielt für „Nutzer meldet Datenverlust,
Ursache unklar" gebaut wurde (`DatenintegritaetsService`), muss mit jeder
neuen sync-relevanten Beziehung mitwachsen — `EinkaufslistenEintrag` bestand
bereits seit Langem, `sichereID`s Alles-oder-nichts-Verhalten dafür war
bekannt und bewusst dokumentiert (Abschnitt 4.5), aber die Lücke zwischen
„der Export-Code behandelt diesen Fall defensiv" und „der Nutzer bekommt
das im Diagnose-Bericht angezeigt" blieb unbemerkt, bis ein echter
Zwei-Geräte-Vergleich sie aufdeckte.

**Nachtrag (2026-08-10): tatsächliche Ursache war doch keine baumelnde
Referenz.** Der Nutzer prüfte nach diesem Fix erneut — auf keinem der beiden
Geräte meldete `DatenintegritaetsService` irgendetwas. Der wirkliche Grund
für die 2 fehlenden Einträge: eine rein LOKAL auf Bernhards Gerät entstandene
Artikel-Dublette (zwei unabhängig angelegte Artikel exakt gleichen Namens),
die sich nie von selbst zusammenführte — der namensbasierte Merge (Abschnitt
4.2 in `docs/DATENSYNCHRONISATION.md`) läuft nur beim Import eines fremden
Snapshots, nie auf rein lokalen Daten. Backup deduplizierte die zwei
Fremd-Artikel beim eigenen Import korrekt zu einem, wodurch auch nur einer
seiner beiden Listen-Einträge übrig blieb — Backups (kleinere) Zahl war die
tatsächlich korrekte. Fix: Warnung in `ArtikelEditView` beim Anlegen eines
Artikels mit bereits vergebenem Namen (kein Speicher-Block), siehe
`ShopWithMe/Models/Artikel.swift` → `dublette(name:alle:ausgenommen:)`. Die
in diesem Abschnitt oben beschriebene `EinkaufslistenEintrag`-Prüfung bleibt
trotzdem sinnvoll (eigenständige, unabhängig entdeckte Lücke) — war hier nur
nicht die Ursache dieses konkreten Falls.

## 52. Nutzerbericht (2026-08-10): eigener Fix aus Abschnitt 50 verursachte neue Regression beim gemeinsamen Live-Einkaufen

**Gemeldet vom Nutzer:** Nach den Fixes aus Abschnitt 50/51 (neuer Testlauf,
„Backup zurückgesetzt und neu aufgesetzt") stimmten die Einkaufslisten-Zahlen
endlich überein — aber: Bernhard schloss seinen Einkauf ab (`Einkauf
abschließen`), das kam bei Backup nie an. Backup zeigte weiterhin 3 abgehakte
Einträge als aktuell offen, und „Einkauf abschließen" blieb dort aktiv
anklickbar, obwohl der reale Einkauf laut Bernhard bereits fertig war.

**Ursache: der Abschnitt-50-Fix selbst, zu grob gefasst.** Das dortige Gate
(`offenerTreffer` matcht nur, wenn `eintrag.endZeit == nil`, also nur ein
selbst noch offener Remote-Eintrag) verhinderte zwar zuverlässig das damals
gemeldete Problem (mehrere längst abgeschlossene, historische Peer-Vorgänge
aliasieren sich fälschlich auf einen frischen Platzhalter) — blockierte aber
auch den eigentlich vorgesehenen Regelfall des Zweigs: Gerät A (Bernhard)
schließt seinen Einkauf ab, Gerät B (Backup) hat für dieselbe Liste einen
eigenen, noch offenen Platzhalter (entstanden z.B., weil Backups vorheriger
Vorgang gerade erst selbst abgeschlossen wurde und `einkaufSicherstellen()`
sofort einen neuen anlegte — Backups eigenes `einkauf_abschluss_durchgefuehrt`-
Protokoll um 03:59:57 Uhr bestätigt genau das). Der erste Snapshot, den
Backup von Bernhard danach empfängt, zeigt dessen Vorgang bereits als
`endZeit != nil` — das pauschale Gate verwarf ihn deshalb komplett, Backups
Platzhalter blieb dauerhaft unverändert offen hängen.

Zusätzlicher Beleg aus dem Protokoll: die parallel beobachteten
`dedupe_conflict_detected`-Einträge (`Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`,
GitHub-Bezug siehe `docs/DATABASE_CONCURRENCY.md`) zeigen, dass Backup
dieselben drei Artikel (Breze, Bananen, Bertoli Olivenöl) zusätzlich über den
schnellen Multipeer-Kanal empfing und korrekt als „bereits selbst abgehakt"
erkannte, keine Duplikate anlegte — dieser Mechanismus arbeitete also
korrekt. Er betrifft aber nur einzelne `KaufEintrag`e, nie die
Vorgangs-Identität/den Abschluss-Status selbst — dafür ist ausschließlich
`mergeEinkaufsvorgaenge` (Bereich C, langsamerer Datei-Kanal) zuständig, und
genau dort griff das zu grobe Gate.

**Fix:** Das pauschale „Remote muss selbst offen sein"-Gate weicht einer
präziseren Zeit-Plausibilitätsprüfung, angewendet VOR statt NACH der
Aliasierung — derselbe Vergleich, der weiter unten ohnehin schon über die
Anwendung der `endZeit` entscheidet (`remoteEndZeit >= vorhandener.startZeit`),
nur jetzt zusätzlich als Bedingung fürs Matching selbst:

```swift
guard let remoteEndZeit = eintrag.endZeit else { return true }  // noch offen → matcht wie bisher
return remoteEndZeit >= kandidat.startZeit  // plausibel dieselbe Sitzung vs. eindeutig historisch
```

Ein Remote-Eintrag ohne `endZeit` matcht weiterhin uneingeschränkt (Regelfall
„beide noch offen"). Ein bereits abgeschlossener Remote-Eintrag matcht nur,
wenn seine `endZeit` NICHT vor dem `startZeit` des lokalen Kandidaten liegt —
für Abschnitt 50s historische Vorgänge (Stunden vor dem frischen Platzhalter)
weiterhin `false` (unverändert repariert), für den hier neu gemeldeten Fall
(Bernhards Abschluss liegt NACH Backups Platzhalter-Start, plausibel dieselbe
laufende Sitzung) jetzt korrekt `true`.

Regressionstest:
``SyncSnapshotImportServiceTests/bereitsAbgeschlossenerVorgangDerselbenSitzungMatchtNochOffenenLokalenPlatzhalter()``
— per `git stash` gegen den Abschnitt-50-Stand verifiziert, dass er dort
reproduzierbar fehlschlägt (zwei separate Vorgänge statt einer, Platzhalter
bleibt offen), mit dem neuen Fix grün. Der bestehende Abschnitt-50-
Regressionstest (``mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert()``)
bleibt unverändert grün — seine drei Remote-Einträge liegen mit ihrer
`endZeit` weiterhin klar vor dem `startZeit` des dortigen Platzhalters.

**Lehre:** Ein Fix, der ein zu weites Matching auf ein zu enges eingrenzt
(hier: „egal ob offen oder geschlossen" → „nur noch offen"), sollte den
tatsächlich zugrunde liegenden Unterscheidungsgrund abbilden (hier: „plausibel
dieselbe Sitzung" vs. „eindeutig historisch, viel früher"), nicht das nächst-
gröbere verfügbare Merkmal (hier: „offen/geschlossen" als grobe Näherung für
„aktuell/historisch"). Ein binäres Merkmal, das nur zufällig mit der
eigentlichen Unterscheidung korreliert, bricht in genau den Randfällen, in
denen die Korrelation nicht mehr gilt — hier: ein Remote-Eintrag kann bereits
geschlossen UND trotzdem Teil derselben laufenden Sitzung sein, wenn der
Abschluss einfach schneller war als der nächste Sync-Zyklus des anderen
Geräts. Die bereits vorhandene, unten ohnehin genutzte
Zeit-Plausibilitätsprüfung war die eigentlich richtige Grundlage von Anfang
an — hätte der erste Fix (Abschnitt 50) sie direkt wiederverwendet statt ein
neues, gröberes Kriterium einzuführen, wäre diese Regression vermeidbar
gewesen.

## 53. Nutzerbericht-Folgefund (2026-08-10, direkt nach Abschnitt 52): eigener Platzhalter zu spät angelegt lässt Plausibilitätsprüfung erneut fälschlich verwerfen

**Gemeldet vom Nutzer:** Testlauf mit umgekehrter Rollenverteilung: „Backup"
zurückgesetzt und App komplett beendet, WÄHREND „Bernhard" allein
weiterarbeitete (Artikel hinzugefügt, 3 abgehakt, Einkauf abgeschlossen —
Bernhards Liste danach korrekt 0 von 4). Erst danach wurde „Backup" wieder
aktiviert. Der erste Sync-Zyklus übernahm zwar alle aktuellen Artikel korrekt
— zeigte aber weiterhin die 3 bereits von Bernhard abgehakten Artikel als
aktiv an und wartete auf „Einkauf abschließen": „3 von 7" statt korrekt „0
von 7".

**Ursache: derselbe Mechanismus wie Abschnitt 52, aber eine zweite,
unabhängige Lücke in der Plausibilitätsprüfung selbst.** Protokoll-Beleg:
`vorgangID=501558A7… grund=endZeitVorStartZeit remoteEndZeit=2026-08-10
04:43:03 startZeit=2026-08-10 04:43:08` — Bernhards Abschlusszeit
(04:43:03) liegt nur 5 Sekunden VOR dem `startZeit` des lokalen Vorgangs auf
„Backup" (04:43:08). Rekonstruiert: „Backup" war während Bernhards
Änderungen vollständig offline; sein eigener, per `einkaufSicherstellen()`
neu angelegter Platzhalter für dieselbe Liste bekam deshalb zwangsläufig ein
`startZeit`, das ERST NACH Bernhards App-seitigem `endZeit` liegt (Backup kam
ja gerade erst wieder online). Trotzdem war Bernhards Vorgang der
tatsächlich REALE, gemeinsame Einkauf — sein `startZeit` (der reale Beginn)
lag klar VOR Backups Platzhalter. Der Vorgang war bereits per
`offenerTreffer` korrekt zusammengeführt (in einem früheren, hier noch
offenen Zyklus), aber die Plausibilitätsprüfung
(`remoteEndZeit >= vorhandener.startZeit`) verglich weiterhin gegen Backups
EIGENES, zu spät gesetztes `startZeit` — nicht gegen den tatsächlich
früheren, über die Aliasierung bereits bekannten realen Beginn.

**Fix:** Sobald ein Vorgang aufgelöst ist (über `bekannter`, `offenerTreffer`
oder Neuanlage), wird sein `startZeit` auf das Minimum aus bisherigem und
`eintrag.startZeit` angehoben — genauer: nur nach VORNE (früher) korrigiert,
nie zurück. Ein `eintrag.startZeit` vor dem bisherigen `vorhandener.startZeit`
beweist, dass der reale gemeinsame Einkauf tatsächlich früher begann, als
dieses Gerät wusste. Die bestehende Plausibilitätsprüfung greift danach auf
das jetzt korrigierte, früheste bekannte `startZeit` zurück und lässt
Bernhards `endZeit` korrekt durch. Rein additiv/permissiv, ändert nichts an
der Abwehr aus Abschnitt 50/52 (die dortigen historischen Vorgänge matchen
weiterhin gar nicht erst, ihre `startZeit`-Korrektur greift also nie).
Regressionstest:
``SyncSnapshotImportServiceTests/vorhandenerVorgangUebernimmtFruehereEintragStartzeitBeimAliasieren()``
— Zwei-Zyklen-Aufbau analog dem bestehenden Alias-Testmuster (Abschnitt-„2026-08-02"-
Diagnose): erster Zyklus matcht offen per `offenerTreffer`, zweiter Zyklus
liefert die `endZeit` — schlägt ohne den Fix reproduzierbar fehl (per `git
stash` gegen den Abschnitt-52-Stand verifiziert), mit Fix grün.

**Lehre:** `Einkaufsvorgang.kanonischer(unter:)` nutzt bereits „ältester
`startZeit` gewinnt" als Tiebreaker zwischen mehreren offenen Kandidaten —
derselbe Grundsatz (das kanonische Objekt sollte den TATSÄCHLICH frühesten
bekannten Beginn tragen, nicht den zufälligen Zeitpunkt der eigenen
Objekterzeugung) fehlte bisher an der Stelle, wo zwei bereits als „derselbe
reale Einkauf" erkannte Vorgänge über mehrere Zyklen hinweg weiter
Informationen austauschen. Sobald zwei Objekte als identisch behandelt
werden, müssen alle ihre Felder, die für spätere Plausibilitätsentscheidungen
herangezogen werden, das jeweils aussagekräftigere (hier: frühere) Extrem
übernehmen — nicht nur das des zufällig als „lokal" gewählten Objekts.

## 54. Nutzerbericht (2026-08-10, nächster Testlauf nach Abschnitt 53): Vorgangs-Abschluss synchronisiert jetzt sauber, aber ein Artikel fehlt nach frischem Neuaufbau

**Gemeldet vom Nutzer:** Gleicher Testaufbau wie zuvor (Backup zurückgesetzt,
Bernhard fügt einen Artikel hinzu und schließt seinen Einkauf ab, Backup
synchronisiert danach). Diesmal blieb **kein** Kaufvorgang mehr hängen (die
Fixes aus Abschnitt 50/52/53 halten) — aber auf „Einkaufsliste" fehlte bei
Backup der Artikel „Backmischung Muffins", den Bernhard hinzugefügt hatte.
Ob es sich um einen echten Neuzugang oder ein erneutes Hinzufügen eines
früher schon einmal gekauften Artikels handelte, ließ sich vom Nutzer aus
nicht sicher sagen. Der Sync-Kanal selbst wurde gezielt gegengeprüft (Artikel
auf einer anderen Liste, „Urlaub", auf Backup hinzugefügt — kam bei Bernhard
korrekt an), das Problem betrifft also nicht die Übertragung allgemein,
sondern etwas listen-/artikelspezifisches.

**Verdacht (noch nicht abschließend bestätigt):** `SyncSnapshotImportService.mergeEinkaufslistenEintraege`
(Bereich-A-Sicherheitsnetz, §4.7) verwirft einen vom Peer aktuell gemeldeten
Listen-Eintrag bedingungslos, sobald `ArtikelListenKauf`
(`jemalsAbgehakteSchluessel`, GitHub #99) diesen Artikel auf dieser Liste
bereits als „jemals gekauft" führt (`istBereitsAbgehakt`,
`SyncSnapshotImportService.swift` Zeile ~1127) — ANDERS als der ältere
`vorgaengeFuerListe`-Fallback direkt darunter prüft dieser neuere,
GitHub-#99-Zweig `istAusDerZeitGefallen` gar nicht erst. Der Typ-Doku-Absatz
direkt über dieser Funktion begründet das explizit mit „für ein NORMAL
SYNCHRONISIERENDES Gerät ein dauerhaft belastbares Faktum" — implizit
vorausgesetzt, ein solches Gerät hätte ein legitimes Neu-Hinzufügen längst
über den direkten `artikelHinzugefuegt`-Event-Pfad erfahren, bevor es
überhaupt am Sicherheitsnetz vorbeikommt. Ein Gerät, das gerade erst per
`SyncErsetzenService` komplett neu aufgebaut wurde, ist aber das genaue
Gegenteil eines „normal synchronisierenden" Geräts: es hat in diesem Moment
noch KEINE eigene Bereich-A-Ereignis-Historie mit diesem Peer — weder aktuell
(`SyncAktualitaetsService.istAusDerZeitGefallen` misst nur „wie lange her ist
mein letzter ERFOLGREICHER Zyklus", und ein frisch aktives, gerade
erfolgreich synchronisierendes Gerät ist per Definition NICHT „aus der Zeit
gefallen", selbst wenn es Sekunden zuvor komplett leer war) noch
grundsätzlich (ein direktes Ereignis für einen länger zurückliegenden Zugang
kann längst aus dem `events/`-Ordner des Peers bereinigt sein, Peer-
Lebenszyklus Baustein C). Trifft „Backmischung Muffins" beide Bedingungen
(schon einmal auf „Einkaufsliste" gekauft, UND das ursprüngliche
`artikelHinzugefuegt`-Ereignis für den erneuten Zugang bereits verfallen),
würde genau dieser Zweig ihn dauerhaft blockieren — unabhängig davon, wie oft
„Backup" danach noch synchronisiert.

**Noch offen:** ob das tatsächlich zutrifft, ließ sich aus den vorhandenen
Protokollen nicht abschließend belegen — `mergeEinkaufslistenEintraege` war
bisher komplett stumm, weder ein Überspringen mangels Auflösbarkeit noch eins
wegen `istBereitsAbgehakt` hinterließ irgendeine Spur.

**Fix (bisher nur Diagnose, keine Verhaltensänderung):** neues
Protokollereignis `sync_listeneintrag_sicherheitsnetz_uebersprungen`
(Details: `artikel=… liste=… istAusDerZeitGefallen=…`), siehe
`docs/LOGGING.md`. Bewusst noch KEINE Verhaltensänderung an
`istBereitsAbgehakt`/dem `jemalsAbgehakteSchluessel`-Zweig selbst — dieser
Zweig ist eine mehrfach live-getestete, bewusst scharf gezogene Schutzregel
gegen einen anderen, bereits bestätigten Bug (GitHub #99, oszillierende
Mitgliederzahl der Liste „Urlaub"); eine Lockerung ohne Bestätigung, DASS das
hier tatsächlich die Ursache ist, riskiert, genau diesen alten Bug
wiederzubeleben. Nächster Schritt: denselben Testaufbau wiederholen und das
neue Protokollereignis auswerten — bestätigt es sich, ist die naheliegende
Korrektur, `istAusDerZeitGefallen` (oder ein neues, treffenderes Signal wie
„gerade erst per `SyncErsetzenService` neu aufgebaut") auch vor dem
`jemalsAbgehakteSchluessel`-Zweig zu prüfen, nicht nur vor dem älteren
Fallback.

**Lehre:** Ein Diagnose-Werkzeug, das für genau diese Klasse Bug gebaut wurde
(„Nutzer meldet fehlenden Artikel, Ursache unklar"), darf an der Stelle, wo
der wahrscheinlichste Verdacht sitzt, nicht komplett stumm sein — bevor eine
scharfe, dokumentiert-bewusste Schutzregel angetastet wird, muss ihr
tatsächliches Zuschlagen im konkreten Fall erst belegt werden, nicht nur aus
dem Quellcode plausibel hergeleitet.

**Update (noch selbe Sitzung): Verdacht durch das neue Protokollereignis
vollständig bestätigt.** Der nächste Testlauf (Backup erneut zurückgesetzt,
auf Bernhard mehrere Artikel abgehakt/neu hinzugefügt) zeigte
`sync_listeneintrag_sicherheitsnetz_uebersprungen` wiederholt für genau die
vom Nutzer als fehlend gemeldeten Artikel („Breze", „Äpfel", „Bananen",
„Blume", „Berner Würstl", „Bertoli Olivenöl - Braten", „Backmischung
Muffins", „Brille", „Butter"), durchgehend mit `istAusDerZeitGefallen=false`
— der Verdacht aus diesem Abschnitt war exakt zutreffend. Der eigentliche Fix
folgt in Abschnitt 55.

## 55. Fix zu Abschnitt 54: `ArtikelListenKauf.zuletztAbgehaktAm` statt pauschalem Veto

**Ausgangslage:** `istAusDerZeitGefallen` (die in Abschnitt 54 vermutete
naheliegende Korrektur) misst „wie lange her ist mein letzter erfolgreicher
Sync-Zyklus" — ein Gerät, das gerade erst per `SyncErsetzenService` neu
aufgebaut wurde UND jetzt aktiv, erfolgreich synchronisiert, ist damit per
Definition NICHT „aus der Zeit gefallen", egal wie leer sein Bestand
Sekunden zuvor war. Dieses Signal allein hätte den Bug also NICHT behoben —
die Live-Bestätigung in Abschnitt 54 zeigte `istAusDerZeitGefallen=false` bei
jedem einzelnen blockierten Artikel.

**Tatsächlicher Fix: Zeitstempel statt Zeit-seit-Sync.** `ArtikelListenKauf`
bekommt ein neues, additiv-optionales Feld `zuletztAbgehaktAm: Date?` —
bewusst KEIN Tombstone-artiger Aufräum-Zeitstempel (die Zeile bleibt
weiterhin für immer bestehen, unabhängig davon, ob dieses Feld gesetzt ist),
sondern reine Vergleichsbasis. `EinkaufslistenEintragSnapshot` bekommt
symmetrisch ein neues Feld `erstelltAm: Date?` (spiegelt
`EinkaufslistenEintrag.erstelltAm`, das lokale Modell hatte dieses Feld
bereits, es wurde bisher nur nie exportiert). `istBereitsAbgehakt` lässt
einen vom Peer gemeldeten Listen-Eintrag jetzt durch, wenn dessen
`erstelltAm` NACH dem bekannten `zuletztAbgehaktAm` liegt — nachweislich ein
JÜNGERES, legitimes erneutes Hinzufügen, keine stale Resurrektion einer
veralteten Momentaufnahme (dem eigentlichen GitHub-#99-Fall). Fehlt einer der
beiden Zeitpunkte (Altbestand vor diesem Feld, oder ein Peer auf einer
älteren App-Version ohne `erstelltAm` im Snapshot — beide Felder sind
`Codable`-optional, Swifts synthetisierter Decoder liest einen fehlenden
Schlüssel für ein optionales Feld automatisch als `nil` statt abzubrechen),
bleibt es beim alten, strengeren Verhalten.

**Warum nicht einfach gegen noch existierende `KaufEintrag.datum` vergleichen
(vermeintlich einfacher, keine neuen Felder nötig):** Genau das war die
ürsprüngliche, durch GitHub #99 ersetzte Prüfung — `KaufEintragBereinigungService`
löscht `KaufEintrag`e 48h nach Abschluss ihres Vorgangs. Ein Vergleich gegen
diese Daten wäre nur innerhalb dieses 48h-Fensters verlässlich und würde
danach exakt denselben Datenverlust reproduzieren, den `ArtikelListenKauf`
ursprünglich beheben sollte (oszillierende Mitgliederzahl der Liste
„Urlaub", siehe Abschnitt zu GitHub #99 oben). `zuletztAbgehaktAm` lebt
deshalb dauerhaft auf `ArtikelListenKauf` selbst, unabhängig von dessen
48h-Zyklus.

**Cross-Device-Sync des Zeitstempels:** `ArtikelListenKaufSnapshot` bekommt
ebenfalls `zuletztAbgehaktAm: Date?`; `mergeArtikelListenKaeufe` mergt ihn
additiv als Maximum (G-Counter-artig, wie an anderen Stellen dieses
Dokuments — ein älterer Peer-Wert verdrängt nie einen bereits bekannten
neueren). Ohne diesen Cross-Device-Merge hätte jedes Gerät nur seine EIGENEN,
lokal miterlebten Käufe als Vergleichsbasis — ein frisch per
`SyncErsetzenService` neu aufgebautes Gerät hätte dadurch (genau wie beim
GitHub-#99-Ausgangsproblem) einen systematisch dünneren Kenntnisstand als
ein durchgehend aktives Gerät.

**API-Umbau:** `ArtikelListenKaufService.vermerkeAbgehakt`/`vermerkeAbgehaktFallsNoetig`
akzeptieren jetzt einen `am:`-Zeitpunkt und aktualisieren `zuletztAbgehaktAm`
eines bestehenden Eintrags (nur nach vorne, nie zurück) statt bei bereits
bekanntem Paar ein reines No-op zu sein. `vermerkeAbgehaktFallsNoetig`s
`bekannt`-Cache wechselt von `Set<Schluessel>` auf
`[Schluessel: ArtikelListenKauf]` (Objektreferenz statt nur Existenz), damit
ein zweiter Treffer desselben Paares im selben Merge-Batch dessen Zeitstempel
ebenfalls aktualisieren kann. Alle drei Aufrufstellen (lokales Abhaken,
Bereich-C-`KaufEintrag`-Merge, Bestandsmigration) übergeben jetzt den
tatsächlichen Kaufzeitpunkt (`eintrag.datum`) statt implizit „jetzt".

**Verifiziert:** vier neue Regressionstests in `SyncSnapshotImportServiceTests.swift`
(legitimes späteres Wiederhinzufügen wird übernommen; ein früherer/stale
Eintrag bleibt weiterhin blockiert — direktes Gegenstück, belegt dass der
ursprüngliche GitHub-#99-Schutz erhalten bleibt; Zeitstempel-Merge als
Maximum über drei aufeinanderfolgende Sync-Zyklen) plus drei neue Tests in
`ArtikelListenKaufServiceTests.swift` (Zeitstempel wird gesetzt, nur nach
vorne aktualisiert, `alleZeitstempel` unterscheidet „bekannt ohne
Zeitstempel" klar von „komplett unbekannt"). Alle bestehenden Tests
(inklusive der ursprünglichen GitHub-#99-Regressionstests) bleiben
unverändert grün — die neuen Felder sind additiv-optional, bestehende
Konstruktionsaufrufe ohne die neuen Parameter kompilieren unverändert (Swifts
synthetisierter Memberwise-Initialisierer gibt optionalen Properties
automatisch `nil` als Default).

**Lehre:** Die in Abschnitt 54 naheliegend erscheinende Korrektur
(„`istAusDerZeitGefallen` auch hier prüfen") wäre die FALSCHE gewesen — sie
hätte den konkret gemeldeten Fall gar nicht behoben, da das betroffene Gerät
per Definition nicht „aus der Zeit gefallen" war. Ein Signal, das für eine
ANDERE Frage gebaut wurde („kann ich mich noch auf mein eigenes
Event-Lesen verlassen", Peer-Lebenszyklus Baustein C), beantwortet nicht
automatisch eine oberflächlich ähnlich klingende, aber inhaltlich andere
Frage („hat dieses Gerät jemals eine belastbare Historie mit diesem Peer für
DIESES Artikel/Liste-Paar aufgebaut"). Der naheliegende Name eines
bestehenden Flags ist kein Ersatz dafür, genau zu prüfen, was es tatsächlich
misst.

## 56. Fund beim eigenen Code-Review direkt nach Abschnitt 55: `erstelltAm` wurde nie weitergegeben

**Ausgangslage:** Nutzertest nach Build 274 (zunächst fälschlich als „Build
269" gemeldet — tatsächliche Ursache: die generierte `.xcodeproj` war seit
Build 269 nicht mehr neu erzeugt worden, `CURRENT_PROJECT_VERSION` in der
Anzeige war dadurch veraltet, obwohl Xcode bereits aus den aktuellen
Quelldateien kompilierte — behoben durch erneutes `xcodegen generate`).
Positiv: nach einem frischen Beitritt von „Backup" stimmten die Listen
überein. Negativ, bei wiederholten Tests: „Backup" holte auf „Bernhard"
Artikel zurück auf die offene Liste, die dort bereits VOR dem Sync abgehakt
UND abgeschlossen waren — ein Rückschritt gegenüber dem in Abschnitt 55
gerade erst reparierten Zustand.

**Ursache, beim eigenen Review von `mergeEinkaufslistenEintraege` gefunden
(noch bevor der Nutzer das Ergebnis eines erneuten Tests mit korrekt
anzeigtem Build melden konnte):** Abschnitt 55 fügte `erstelltAm` zu
`EinkaufslistenEintragSnapshot` hinzu und EXPORTIERT es korrekt
(`eintrag.erstelltAm`) — aber beim IMPORT, wenn das Sicherheitsnetz einen
neuen lokalen `EinkaufslistenEintrag` anlegt, blieb `neu.erstelltAm` beim
`EinkaufslistenEintrag.init`-Default `Date()` („jetzt", der lokale
Import-Zeitpunkt) stehen, statt den vom Peer gemeldeten, tatsächlichen
Zeitpunkt zu übernehmen. Konsequenz: Bei JEDEM Neuaufbau „altert" ein
Artikel künstlich auf „gerade eben hinzugefügt" zurück. Exportiert dieses
Gerät seinen Bestand später an ein DRITTES Gerät weiter (oder empfängt ein
Gerät, das den Artikel zwischenzeitlich selbst gekauft hat, diesen jetzt
künstlich verjüngten Eintrag), sieht der in Wahrheit längst vor dem Kauf
hinzugefügte Artikel für die Abschnitt-55-Prüfung
(`eintrag.erstelltAm > zuletztAbgehaktAm`) fälschlich JÜNGER aus als der
Kauf — das Sicherheitsnetz holt ihn dadurch fälschlich zurück auf die
offene Liste. Exakt das vom Nutzer beobachtete Muster: „Backup" (das
„Blume"/vergleichbare Artikel bei einem früheren Neuaufbau geerbt und dabei
unbeabsichtigt verjüngt hatte) holte sie auf „Bernhard" zurück, obwohl
Bernhard sie in der Zwischenzeit bereits gekauft hatte.

**Fix:** `mergeEinkaufslistenEintraege` setzt `neu.erstelltAm =
eintrag.erstelltAm`, sobald der Peer einen Zeitpunkt mitliefert (`EinkaufslistenEintrag.erstelltAm`
ist ein normaler, nicht `private(set)` deklarierter `var`, direktes Setzen
nach der Konstruktion ist deshalb sicher). Fehlt der Zeitpunkt (Peer auf
älterer App-Version ohne dieses Feld), bleibt der Default „jetzt" bewusst
stehen — keine Verschlechterung gegenüber dem Vorzustand, nur kein
zusätzlicher Schutz.

**Verifiziert:** neuer Regressionstest
``vonSicherheitsnetzGeerbterEintragTaeuschtBeiWeitergabeKeineFrischeVor()``
simuliert das Szenario über ZWEI ECHTE `ModelContext`s (Gerät A/Gerät B,
analog ``zaehlerWaechstNichtDurchWiederholtesHinUndHerSynchronisieren()``,
nicht über einen einzelnen Context mit im Test hartcodierten Werten): Gerät
A kauft den Artikel; getrennt davon erbt Gerät B denselben Artikel über das
Sicherheitsnetz von einem alten Fremd-Snapshot (Gerät C); Gerät B liest
anschließend sein TATSÄCHLICH lokal entstandenes `erstelltAm` zurück und
meldet genau diesen Wert an Gerät A weiter. Schlägt ohne den Fix
reproduzierbar fehl (der Artikel kommt fälschlich zurück auf Gerät As
Liste), mit Fix grün — per `git stash` gegengeprüft. Der bestehende Test
für den einfachen Fall (einmaliges Wiederhinzufügen) wurde um eine Prüfung
auf das korrekt übernommene `erstelltAm` erweitert.

**Lehre:** Ein additiv-optionales Feld, das eine bestehende Momentaufnahme
(hier: „wann wurde dieser Eintrag ursprünglich angelegt") über mehrere
Hops hinweg TRANSPORTIEREN soll, muss an JEDER Stelle, die eine neue lokale
Kopie dieser Momentaufnahme erzeugt, explizit weitergegeben werden — nicht
nur beim Export. Der Modell-Konstruktor selbst bietet dafür keinen
Parameter (`erstelltAm` wird intern immer auf `Date()` gesetzt), was die
Lücke beim ersten Schreiben dieses Fixes unauffällig gemacht hat: der Code
kompilierte anstandslos und die vorherigen Tests (die jeweils nur EINEN Hop
prüften) deckten die Weitergabe über einen ZWEITEN Hop nicht ab.

**Zweite Lehre (eigener Red-Check direkt bei der Testerstellung):** Die
erste Fassung dieses Regressionstests simulierte den Zwei-Geräte-Hop
innerhalb EINES `ModelContext` und trug in Schritt 3 denselben, im Test
hartcodierten `erstelltAm`-Wert wie in Schritt 1 ein, statt den tatsächlich
importierten lokalen Wert zurückzulesen — dadurch prüfte der Test in
Wahrheit nur den bereits anderweitig abgedeckten Fall „explizit alter,
unveränderter Peer-Wert bleibt blockiert" erneut und schlug beim
Red-Check (Fix per `git stash` entfernt) fälschlich NICHT fehl. Erst der
Umbau auf zwei echte `ModelContext`s mit Rücklesen des real entstandenen
lokalen Werts deckte die Lücke sauber ab.

## 57. Nutzerbericht (2026-08-10, Folgefund zu Abschnitt 56): `mergeKaufEintraege` entfernt den offenen Listen-Eintrag nie

**Ausgangslage:** Backup zurückgesetzt, auf Bernhard neue Artikel angelegt,
einige abgehakt, Einkauf abgeschlossen (Endzustand auf Bernhard: 0 von 6,
alles erledigt). Nach dem nächsten Sync zeigte Backup „2 von 8" statt der
erwarteten „2 von 6" — zwei Artikel, die Bernhard bereits abgehakt hatte,
standen auf Backup gleichzeitig noch offen auf der Liste.

**Ursache:** Das lokale Abhaken
(``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:abteilung:geschaeft:)``)
löscht explizit den zugehörigen `EinkaufslistenEintrag`, sobald ein
`KaufEintrag` entsteht. `mergeKaufEintraege` (Bereich C, legt `KaufEintrag`e
direkt aus einem Peer-Snapshot an, ohne über jene Funktion zu laufen) tat das
nie — ein Artikel, der auf EINEM Gerät noch als offener Listen-Eintrag
geführt wurde (z.B. weil dessen Bereich-B-„listen"-Snapshot vom selben Peer
zu diesem Zeitpunkt noch den älteren, offenen Stand zeigte), blieb nach dem
Merge dauerhaft GLEICHZEITIG „offen" UND „abgehakt". Exakt der Zustand, den
``EinkaufenView/offeneArtikel`` bereits seit GitHub #52 aus der Anzeige
herausfiltert (dortiger Kommentar: „auch wenn … noch ein
`EinkaufslistenEintrag` für sie existiert") — der Filter verhinderte zwar die
doppelte Anzeige des Artikels selbst, aber die verwaiste Zeile blieb in
``Einkaufsliste/eintraege`` bestehen und zählte im „X von Y"-Gesamtwert
(`offeneArtikel.count + abgehakteArtikel.count`) weiter mit.

**Fix:** `mergeKaufEintraege` löscht jetzt, analog zum lokalen Abhaken-Pfad,
den passenden `EinkaufslistenEintrag` (falls vorhanden), bevor es den neuen
`KaufEintrag` einträgt. Siehe
`ShopWithMe/Services/SyncSnapshotImportService.swift`.

**Verifiziert:** neuer Regressionstest
``mergeKaufEintragEntferntEntsprechendenOffenenListenEintrag()`` — ein Gerät
mit noch offenem Listen-Eintrag empfängt per Snapshot einen abgeschlossenen
Peer-Einkaufsvorgang samt `KaufEintrag` für denselben Artikel; ohne den Fix
bleibt der Artikel fälschlich weiter auf der Liste, mit Fix verschwindet er
korrekt — per `git stash` gegengeprüft.

**Offen, separat untersucht (derselbe Testlauf):** Bernhards Sync-Ordner-
Zugriff schlug für mehrere Minuten durchgehend fehl
(`sync_ordner_zugriff_fehlgeschlagen` für JEDEN Teilschritt) — dasselbe
Symptombild wie Abschnitt 30 (verschachtelte/überlappende
Security-Scope-Zugriffe destabilisieren den Bookmark dauerhaft für den Rest
der App-Sitzung). Die dort behobene konkrete Ursache (ungebündeltes
`kaeufe/`-Datei-Aufräumen) ist nachweislich nicht regressiert — der einzige
verbleibende Aufrufer ist weiterhin `KaufEintragBereinigungService.bereinigen`
mit gebündeltem Einzelzugriff. `SyncOrdnerZugriffsDiagnose` (`gleichzeitigOffen`)
zeigte für jeden Fehlschlag in diesem Fenster „keine" — kein AKTUELL
überlappender Zugriff aus dieser App-Sitzung zum Fehlschlagzeitpunkt, was zu
Abschnitt 30s Befund passt, dass die Destabilisierung EINMALIG (irgendwann
früher in derselben, seit Stunden durchgehend laufenden App-Sitzung von
Bernhard) ausgelöst wird und danach bis zum nächsten vollständigen
Neustart bestehen bleibt. Nicht weiter code-seitig untersucht, da kein neuer
Aufrufer identifiziert werden konnte — nächster Schritt ist ein sauberer
Test nach vollständigem Neustart von Bernhard (nicht nur Hintergrund/
Vordergrund).

## 58. Nutzerbericht (2026-08-10, Folgefund zu Abschnitt 57): sync-übernommener Abschluss schließt andere offene Vorgänge derselben Liste nicht mit

**Ausgangslage:** Backup schließt einen Einkauf ab; `sync_einkaufsvorgang_abschluss_uebernommen`
bestätigt auf Bernhard die korrekt übernommene `endZeit` — sogar über einen
App-Neustart hinweg (Store-Ebene also nachweislich korrekt) — trotzdem
erscheint der Einkauf auf Bernhards Bildschirm weiterhin aktiv, mit denselben
abgehakten Artikeln.

**Diagnose zuerst, dann Fix** (analog Abschnitt 53): das bereits vorhandene
`andereOffeneVorgaengeDerListe`-Logging (aus Abschnitt 57 für einen anderen
Zweig übernommen) bestätigte `andereOffeneVorgaengeDerListe=2` auf Bernhard
genau im Moment der Abschluss-Übernahme — ein zweiter, unabhängig offener
Vorgang für dieselbe Liste, an dem tatsächlich ``EinkaufenView/aktuellerEinkauf``
hing.

**Ursache:** `mergeEinkaufsvorgaenge` übernahm bisher nur die `endZeit` des
per ID getroffenen Vorgangs — anders als der lokale „Einkauf
abschließen"-Button (`EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten`),
der bewusst ALLE offenen Vorgänge derselben Liste mitschließt.

**Fix:** der Sync-Merge schließt jetzt ebenfalls alle plausibel gleichzeitigen
(`startZeit <= remoteEndZeit`, dasselbe Zeit-Gate wie beim
`offenerTreffer`-Matching) offenen Vorgänge derselben Liste mit,
`zaehleAlsBesuch: false`. Das Zeit-Gate ist notwendig, nicht kosmetisch:
ohne es schloss ein historischer Catch-up-Import (viele längst
abgeschlossene Alt-Vorgänge eines frisch beigetretenen Geräts) einen danach
frisch angelegten, unabhängigen Platzhalter fälschlich mit — bestätigt durch
den bereits bestehenden Regressionstest
`mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert()`.
Neuer Test: `andererOffenerVorgangDerselbenListeWirdBeiSyncAbschlussMitgeschlossen()`.

## 59. Direkter Folgefund (derselbe Testlauf): `mergeKaufEintraege`s Zeit-Gate reichte nicht — Architektur-Review statt vierter Einzelpatch

Ein weiterer Testlauf zeigte dieselbe Symptom-Familie noch zweimal, jeweils
mit anderer Geräte-/Zyklus-Verkettung:

1. **„Kurzzeitiges Flackern"**: Bernhards `Einkaufsliste`-Zähler fiel binnen
   eines Zyklus von 5 auf 1 (Backups eigener sogar auf 0), bevor er sich
   selbst korrigierte. Ursache: `mergeKaufEintraege` (Abschnitt 57) löschte
   den passenden `EinkaufslistenEintrag` bedingungslos — auch wenn der
   `KaufEintrag` ein längst historischer Nachzügler aus einem großen
   Nachhol-Merge war und der Artikel (wiederkehrend) danach erneut auf die
   Liste gesetzt wurde. Erster Fix: nur löschen, wenn
   `EinkaufslistenEintrag.erstelltAm <= KaufEintrag.datum`.
2. **Derselbe Fehler erneut, andere Verkettung**: trotz bestandener
   `erstelltAm <= datum`-Prüfung verschwand „Backmischung Muffins" noch
   einmal. Backups eigenes Log zeigte die Ursache direkt: ein Listen-Eintrag
   wurde binnen 15 Sekunden über das Sicherheitsnetz neu materialisiert
   UND von einem nachfolgenden Merge-Zyklus bereits wieder gelöscht.

Der Nutzer stellte an dieser Stelle explizit die richtige Frage: „Prüfe den
Algorithmus an sich, statt weiter herumzuprobieren." Analyse ergab: siehe
Abschnitt 60 — `EinkaufslistenEintrag.erstelltAm` ist keine verlässliche
Vergleichsbasis für „wurde seither erneut hinzugefügt", weil der
Sicherheitsnetz-Merge bewusst den ORIGINAL-Zeitpunkt eines (beliebig oft
weitergereichten) Peers übernimmt, ohne jede monotone Absicherung. Jeder
Fix gegen diesen Rohwert war dadurch strukturell zum Scheitern verurteilt.

## 60. Architektur-Review (2026-08-10): `ArtikelListenKauf.zuletztHinzugefuegtAm` — robustes Gegenstück zu `zuletztAbgehaktAm`

**Befund:** die „schon gekauft"-Seite hatte mit `zuletztAbgehaktAm` (Abschnitt
55) bereits ein additiv gemergtes, monoton nur vorwärts laufendes Faktum —
robust unabhängig davon, in welcher Reihenfolge/über wie viele Zwischenstationen
Geräte synchronisieren. Die „hinzugefügt"-Seite hatte KEIN Äquivalent. Jeder
der drei vorangegangenen Funde (Abschnitte 57, 59) war strukturell dieselbe
Asymmetrie mit anderer konkreter Geräte-Verkettung.

**Fix:** neues additiv-optionales Feld `ArtikelListenKauf.zuletztHinzugefuegtAm`,
exakt dieselbe Monotonie-Garantie, gepflegt an beiden Stellen, an denen ein
Artikel auf eine Liste kommt. Beide Vergleichsstellen (`istBereitsAbgehakt`,
`mergeKaufEintraege`) nutzen jetzt dieselbe einheitliche Regel
`ArtikelListenKaufService.istOffen(hinzugefuegtAm:abgehaktAm:)`. Zusätzlich
über den eigenen `ArtikelListenKauf`-Sync-Kanal repliziert und rückwirkend für
Bestandsdaten befüllt.

**Regressionsfund während der Umsetzung selbst** (Verifizierung deckte ihn
auf, bevor er live beobachtet wurde): die erste Fassung des Gates in
`istBereitsAbgehakt` prüfte nur `bekannterEintrag != nil` — da der Aufrufer
das `hinzugefügt`-Faktum bereits VOR diesem Aufruf vermerkt, existiert für
JEDES gemeldete Hinzufügen ab sofort eine `ArtikelListenKauf`-Zeile, auch auf
einem Gerät ganz ohne Kauf-Historie. Das Gate behandelte diese Zeile
fälschlich wie einen bekannten Kauf und blockierte über den konservativen
Nil-Fallback von `istOffen` ein legitimes Erst-Hinzufügen. Aufgedeckt durch
`vonSicherheitsnetzGeerbterEintragTaeuschtBeiWeitergabeKeineFrischeVor()`
(zwei ECHTE, getrennte `ModelContext`s statt hartcodierter Zeitstempel, damit
der reale Wert — nicht ein im Test vorgetäuschter — die Lücke zeigt). Fix:
Gate prüft gezielt `bekannterEintrag?.zuletztAbgehaktAm != nil`.

**Architektur-Audit:** alle 19 `mergeX`-Funktionen in
`SyncSnapshotImportService` durchgesehen — dieselbe Asymmetrie kommt sonst
nirgends vor. Sichere, bereits etablierte Muster: Union-nach-ID für
unveränderliche Historie, „nur fehlende Werte ergänzen, nie überschreiben"
für optionale Skalare, Mengen-Vereinigung für Relationships, G-Counter für
Zähler, gewichteter Zuwachs-seit-zuletzt-gesehen für
`WarengruppenDistanz.distanz`, Tombstones für Löschungen.

**Verifiziert:** volle Suite (390 Tests, 46 Suiten) grün, inkl. drei neuer/
angepasster Regressionstests für diesen Abschnitt.

## 61. Live-Ersetzen statt Neustart-Aufforderung (zweiter Anlauf, Build 308)

**Vorgeschichte:** Ein erster Versuch, den lokalen Store-Austausch
(„Ersetzen durch Peer", „Backup wiederherstellen", „Baumelnde Referenzen
bereinigen") zur Laufzeit statt per Neustart-Aufforderung durchzuführen
(Build 138, `ModelContainerController`), stürzte auf einem echten Gerät ab
(`BUG IN CLIENT OF libsqlite3.dylib: vnode unlinked while in use`, Build 139,
Commit `6af943c`) und wurde durch den seitdem gültigen Neustart-Mechanismus
ersetzt (siehe Abschnitt 13a, `SyncErsetzenService`). Ein zweiter,
funktionierender Anlauf entstand kurz darauf (Anfang August, Commits
`e691d03`/`2729eab`), landete aber nie auf `main` — der Branch wurde vor dem
Merge zurückgesetzt, ohne dass ein Bug dokumentiert wurde. Dieser Abschnitt
beschreibt die Wiedereinführung desselben Mechanismus, neu aufgesetzt gegen
den seither divergierten Stand (`SyncConnector`-Abstraktion, `v0.15`;
`SyncImportService`-Re-Entranz-Sperre, `v0.14`).

**Root-Cause-Korrektur ggü. dem ersten Versuch:** nicht der
`ModelContainer`-Tausch selbst war die Ursache des Absturzes — laut Apple-DTS
(Developer-Forum-Thread 806191) offiziell unterstützt: der `ModelContext` der
View-Hierarchie wechselt beim Umhängen von `.modelContainer(_:)` automatisch
mit. Die tatsächliche Ursache war die **Wiederverwendung derselben, kurz
zuvor noch offenen Store-Datei**: SwiftData legt den zugrundeliegenden
`NSPersistentStoreCoordinator` nie öffentlich frei, ein sauberes
`removePersistentStore`/`destroyPersistentStore` VOR dem physischen Löschen
ist über die SwiftData-API nicht möglich — auch ein bloßes ARC-Deallozieren
der letzten `ModelContainer`-Referenz ist keine Garantie, dass SwiftData/
CoreData intern bereits fertig ist.

**Mechanismus (`ModelContainerController`, `ShopWithMe/App/ModelContainerController.swift`):**
- Jeder Austausch legt den Ersatz-Store an einer **neuen, nie zuvor
  dagewesenen Datei-URL** an (`ersetzt-<UUID>.store`) statt die alte Datei
  wiederzuverwenden — ein vorheriges Löschen entfällt dadurch strukturell.
- Die jetzt verwaiste alte Datei wird nur vorgemerkt und erst am Anfang des
  nächsten Kaltstarts (`ModelContainerController.raeumeVerwaisteStoreDateienAuf()`,
  vor jedem `ModelContainer`-Öffnen in `ShopWithMeApp.init()`) physisch
  gelöscht — dem einzigen Zeitpunkt, an dem garantiert kein Prozess sie noch
  offen hat.
- `@Published var modelContainer` + `@Published var generation` ersetzen das
  bisherige `let modelContainer` in `ShopWithMeApp`; `RootView().id(generation)`
  erzwingt einen kompletten View-Baum-Neuaufbau (fängt tief verschachtelte
  `@State`-Modellobjekte aus dem verlassenen Store ab), `.task(id: generation)`
  statt `.task {}` bindet den Neustart von `SyncPollingService`/
  `MultipeerSyncService` zuverlässig an jeden Tausch (ein `.task` ohne
  explizite `id:` ist nicht zuverlässig an ein vorher angewandtes `.id(_:)`
  gekoppelt — Live-Fund aus dem zweiten Anlauf, `2729eab`).
- `vergangeneContainer: [ModelContainer]` hält jeden verlassenen Container
  für den Rest der Prozesslaufzeit am Leben — `ModelContext` hält seinen
  erzeugenden `ModelContainer` nicht stark; ohne das crasht ein zum
  Umhäng-Zeitpunkt noch laufender Sync-Zyklus mit dem alten Context.
- `wirdErsetzt`-Sperre gegen überlappende `ersetzeLiveMitNeuemStore`-Aufrufe
  (z.B. „Wiederherstellen" direkt gefolgt von erneutem „Ersetzen", beides
  live ohne Neustart dazwischen) — ebenfalls Live-Fund aus dem zweiten
  Anlauf.

**`SyncErsetzenService`:** die bisherigen `plane…()`-Funktionen (nur
Vormerken für den nächsten Start) bleiben als Fallback bestehen — für den
seltenen Fall, dass kein `ModelContainerController` verfügbar ist. Neue,
sofort ausführende Gegenstücke `fuehreErsetzenDurchPeerLive(controller:)`/
`fuehreWiederherstellenAusBackupLive(controller:)`/
`fuehreBereinigungBaumelnderReferenzenLive(controller:)` nehmen den
`ModelContainerController` explizit als Parameter entgegen (statt intern über
eine `weak static`-Referenz zu greifen, wie im zweiten Anlauf) — dadurch in
Unit-Tests ohne globalen Zustand/Test-Serialisierung nutzbar. Der
Neustart-Mechanismus (`ausstehendeAktion`, `loescheStoreDateiFallsAusstehend`)
bleibt unverändert exklusiv für GitHub #119 (Store beim Boot bereits
unlesbar — dort existiert per Definition noch kein offener Container, ein
Live-Tausch ist nicht anwendbar).

**Aufrufer umgestellt:** `SyncOrdnerSettingsView` (Ersetzen/Wiederherstellen/
Backup-Wiederherstellen), `DebuggingView` (Gerät zurücksetzen/Baumelnde
Referenzen bereinigen), `RootView.vollAbgleichAusloesen()` (automatischer
Voll-Abgleich nach 30 Tagen Inaktivität) — alle vier liefen bisher über den
Neustart-Mechanismus. Jeder Aufrufer fällt auf den alten Neustart-Pfad
zurück, falls `ModelContainerController.aktuell` `nil` ist.

**Getestet (`SyncErsetzenServiceTests.swift`):** anders als beim ersten
Anlauf (siehe Suite-Kopfkommentar dort) ist der Live-Pfad innerhalb eines
einzelnen Testprozesses sicher testbar — er löscht nie eine im selben
Prozess noch offene Datei, sondern legt immer eine neue an. Abgedeckt: voller
Ersetzen-/Bereinigen-Rundlauf inkl. „alter Context bleibt unberührt lesbar",
neue Datei statt Wiederverwendung, sowie die `wirdErsetzt`-Sperre bei
künstlich erzwungener Überlappung zweier Aufrufe.

**Noch ausstehend:** manuelle Verifikation auf einem echten Gerät (wie bei
beiden Vorgänger-Anläufen dokumentiert nicht im Simulator reproduzierbar) —
insbesondere, dass `SyncPollingService`/`MultipeerSyncService` nach einem
Tausch nachweislich am neuen Context weiterlaufen und kein Datenverlust bei
schneller Aufeinanderfolge mehrerer Aktionen auftritt.

### Live-Fund (Build 308, echtes Gerät): `EinkaufenView` stürzte beim „Ersetzen“ ab

**Symptom:** `SIGABRT` unmittelbar nach einem „Ersetzen“, Stack-Trace über
`EinkaufenView.einkaufSicherstellen()` → `DatabaseLeaseService.performMicroLease`
→ `NSManagedObjectContext.save()` → nicht abfangbare Objective-C-Exception
(`objc_exception_rethrow`).

**Ursache:** `ausgewaehlteListe`/`ausgewaehltesGeschaeft` sind `@State`-
gehaltene `@Model`-Objektreferenzen. Laut Apple DTS (siehe oben) wechselt der
per `@Environment(\.modelContext)` injizierte Context für eine BESTEHENDE
View-Instanz automatisch mit dem `ModelContainer` — auch ohne
`.id(generation)`-Neuaufbau, der `@State` erst mit etwas Verzögerung
zurücksetzt. In diesem kurzen Fenster kann ein bereits reaktiver Trigger
(hier `.onChange(of: offeneEinkaufsvorgaenge.count)`, ein `@Query` das
ebenfalls sofort auf den neuen Context reagiert) einen neuen `Einkaufsvorgang`
mit Relationships auf die noch alten, `@State`-gehaltenen Objekte in den
NEUEN Context einfügen — eine store-übergreifende Relationship, die CoreData
beim `save()` mit einer nicht per `do/catch` fangbaren Exception quittiert.

**Fix:** `einkaufSicherstellen()` prüft jetzt vor dem Insert
`ausgewaehlteListe.modelContext == modelContext` (und analog für
`ausgewaehltesGeschaeft`) — `PersistentModel.modelContext` identifiziert den
Context, der das Objekt aktuell verwaltet; weicht er vom aktuellen
`@Environment`-Context ab, bricht die Funktion sauber ab, statt abzustürzen.
Der nächste reguläre Trigger (spätestens der `.id(generation)`-Neuaufbau
selbst) wählt dann frische, zum aktuellen Context passende Objekte.

**Nachtrag — Audit der übrigen acht Verdachtsstellen (noch Build 308):**
Dasselbe Grundmuster (`@State`-gehaltene `@Model`-Referenz +
`DatabaseLeaseService.performMicroLease`/`modelContext.insert`) kam in
mindestens acht weiteren Views vor. Auf Nutzeranfrage systematisch geprüft:

- **Bereits sicher, unverändert:** `PreispunktZuordnenSheet`,
  `ArtikelHinzufuegenView`, der Haupt-Übernahme-Pfad in `BelegScanView`
  (`uebernehmen()`) sowie das Löschen in `ArtikelListView`/`GeschaeftListView`
  — alle nutzen bereits `ModelReference`/`resolved(in:)` (siehe
  `ShopWithMe/Models/ModelReference.swift`, ursprünglich gegen eine ANDERE
  Race eingeführt: ein nebenläufiger Sync-Zyklus kann ein Objekt zwischen
  Lease-Erwerb und Verwendung löschen). Da `resolved(in:)` das Objekt
  IMMER frisch aus dem übergebenen `context` neu lädt statt eine alte
  Referenz weiterzureichen, schließt derselbe Mechanismus zufällig auch das
  Live-Ersetzen-Problem aus — kein zusätzlicher Fix nötig.
- **Neuer Guard ergänzt** (`DatabaseLeaseService.gehoertZuAktuellemContext(_:context:)`,
  neu eingeführter zentraler Helfer statt Duplikat-Prüfungen je Aufrufer):
  `ProduktVerwaltungView` (`NeuesProduktSheet`), `ArtikelEditView`/
  `ProduktEditView` (jeweils `istNeu`-Insert-Zweig), `GeschaeftStammdatenEditView`
  (`istNeu`-Insert-Zweig, per Sheet aus `GeschaeftListView` erreichbar),
  `MilkForUsImportView` (`uebernehmen()`), `BelegScanView`
  (`artikelDauerhaftIgnorieren(_:)`, ein zweiter, per `IgnorierterArtikel`
  isolierter Insert-Pfad neben dem bereits sicheren Haupt-Übernahme-Pfad).
  Der Helfer behandelt sowohl `nil` als auch ein noch KEINEM Context
  zugeordnetes, frisch für einen Insert konstruiertes Objekt
  (`objekt.modelContext == nil`) als unbedenklich — abgelehnt wird
  ausschließlich ein Objekt, das bereits einem ANDEREN, nicht-`nil` Context
  zugeordnet ist.
- **`ArtikelListView`:** kein eigener Fix nötig — Neuanlage läuft über das
  bereits abgesicherte `ArtikelEditView`.

**Weiterhin bewusst NICHT geschlossen (Restrisiko, out of scope für diesen
Durchgang):** Der neue Guard prüft nur die TOP-LEVEL-Objektreferenz selbst,
nicht rekursiv deren Relationships. Beispiel `GeschaeftStammdatenEditView`:
ein frisch konstruiertes, noch nicht eingefügtes `Geschaeft` hat
`modelContext == nil` (besteht den Guard), kann aber bereits eine
Relationship auf ein VORHER (z.B. beim Öffnen des „+"-Buttons in
`GeschaeftListView`) über `GeschaeftTyp.mitNamen(context:)` geladenes, seither
potenziell veraltetes `GeschaeftTyp`-Objekt enthalten. Dieses schmalere
Zeitfenster (Sekunden bis der Nutzer ein Formular ausfüllt, statt der
Millisekunden-Lease-Erwerbsverzögerung beim ursprünglichen `EinkaufenView`-
Fund) wurde als unverhältnismäßig für eine vollständige rekursive
Relationship-Validierung eingeschätzt und bewusst nicht adressiert.

### Live-Fund (Build 308+, echtes Gerät): Kreislauf zurück zur Ordnerauswahl nach „Ersetzen"

**Symptom:** Nach „Ersetzen durch Peer" beim Verknüpfen eines Sync-Ordners
läuft der Live-Tausch sichtbar korrekt durch (Fortschrittsanzeige, danach
aktualisierte Einkaufsliste) — kurz danach erscheint aber „Aus der Sync-
Gruppe entfernt" mit „Erneut beitreten", was zurück zur Ordnerauswahl führt.
Erneutes Einrichten löst denselben Ablauf wieder aus — Endlos-Kreislauf.

**Ursache:** `.task(id: modelContainerController.generation)` in
`ShopWithMeApp` ruft nach jedem Live-Tausch `SyncPollingService.starten(context:)`
erneut auf. Dessen Rückkehrer-Erkennung (Peer-Lebenszyklus,
`connector.binIchNochMitglied()`) prüft dabei, ob der EIGENE Peer-Ordner im
geteilten Verzeichnis existiert — direkt nach einem frischen „Ersetzen durch
Peer"-Beitritt existiert er aber noch nicht, der wird erst vom nächsten
`syncZyklus()` (Export-Schritt) angelegt. Die Prüfung interpretiert das
fälschlich als „von der Gruppe entfernt" und löst automatisch Backup +
`SyncOrdnerService.ordnerEntfernen()` aus.

Der bereits bestehende Schutzmechanismus dagegen
(`SyncPollingService.ueberspringeRueckkehrerErkennungBeimNaechstenStart`,
race-frei in `ShopWithMeApp.init()` für den NEUSTART-basierten Weg gesetzt)
hatte für den neuen LIVE-Pfad noch kein Gegenstück — dort gibt es kein
`init()`, das vor `.task(id:)` läuft.

**Fix:** `ModelContainerController.ersetzeLiveMitNeuemStore(befuellen:)`
setzt dasselbe Flag jetzt selbst, unmittelbar vor dem eigentlichen Umhängen
(`generation = UUID()`) — nicht früher, damit ein fehlgeschlagener oder
per `wirdErsetzt` übersprungener Aufruf (kein `generation`-Bump, `.task(id:)`
feuert nicht erneut) das Flag nicht fälschlich für den nächsten,
unabhängigen regulären Start stehen lässt. Gilt einheitlich für alle drei
Live-Pfade (Ersetzen/Wiederherstellen/Bereinigen) — dieselbe Großzügigkeit,
die der alte Neustart-Mechanismus bereits für jede beliebige
`ausstehendeAktion` gewährte.

### Live-Fund: Solo-Gerät räumt Events/Tombstones/Kaeufe-Dateien nie auf

**Symptom:** Auf einem Gerät, das aktuell das einzige Mitglied im Sync-Ordner
ist, bleiben alte Sync-Event-Dateien, `SyncTombstone`-Einträge und
`kaeufe/{id}.json`-Dateien dauerhaft liegen — auch Tage/Wochen später und
auch nach Betätigen der Aufräum-Buttons in `DebuggingView`.

**Ursache 1 (Events/Tombstones):**
``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)`` liefert
bewusst `nil`, wenn aktuell kein anderer Peer-Ordner existiert (siehe
`docs/PEER_LEBENSZYKLUS.md`, Baustein C — Absicht: „kein Peer zum Abgleich
bekannt" soll nicht automatisch als „für alle sicher" gelten). Für ein
dauerhaftes Solo-Gerät bedeutet das aber: der Wasserstand bleibt für immer
`nil`, jeder automatische Aufräumlauf bricht sofort ab, und der „Jetzt
aufräumen"-Button in `DebuggingView` ist für genau diesen Fall sogar
deaktiviert.

**Fix:** Automatisches Verhalten bewusst NICHT geändert (weiterhin
konservativ `nil` bei fehlendem Peer). Stattdessen neuer, manueller
Bestätigungsweg: ``SyncSnapshotImportService/istAktuellEinzigerPeer(in:)``
unterscheidet „kein anderer Peer, aber Ordnerzugriff war erfolgreich" von
echten Fehlerfällen. `DebuggingView`s `AufraeumWasserstandSection` zeigt in
genau diesem Fall den Button „Ich bin sicher, dass ich der einzige Peer
bin" mit Bestätigungsdialog; nach Zustimmung räumen
``SyncExportService/raeumeAlteEigeneEventDateienAufFallsFaellig(erzwungenerWasserstand:)``
und ``SyncTombstoneService/raeumeAlteTombstonesAufFallsFaellig(context:erzwungenerWasserstand:)``
einmalig mit `.distantFuture` als erzwungenem Wasserstand auf. Normale
automatische Aufrufe übergeben weiterhin `nil` und bleiben unverändert.

**Ursache 2 (Kaeufe-Dateien):** Unabhängig vom Wasserstand — zwei Stellen
löschten einen `KaufEintrag` direkt (Artikel-Abwählen/dauerhaftes Entfernen,
`Einkaufsvorgang.artikelAbwaehlenOhneEventAufzeichnung`/
`artikelDauerhaftEntfernenOhneEventAufzeichnung`), ohne die bereits
exportierte `kaeufe/{id}.json` mitzulöschen — anders als
`KaufEintragBereinigungService.bereinigen`, das dafür extra
`SyncKaeufeExportService.entferneDateien(fuerKaufEintragIDs:)` aufruft. Der
einzige Catch-all dafür (`SyncKaeufeExportService.raeumeVerwaisteDateienAuf`)
lief bisher ausschließlich aus dem täglichen
`KaufEintragBereinigungService.automatischBereinigenFallsFaellig` — nicht aus
dem manuellen „KaufEintraege jetzt bereinigen"-Button in `DebuggingView`,
weshalb der beim Debuggen benutzte Button diese Altlasten nie erreichte.

**Fix:** Beide `Einkaufsvorgang`-Methoden rufen `entferneDateien` jetzt
sofort selbst auf (verhindert das Entstehen neuer Waisen, statt auf den
täglichen Catch-all zu warten); der manuelle Debug-Button ruft zusätzlich
`raeumeVerwaisteDateienAuf` auf, um bereits vorhandene Altlasten
mitzunehmen.

## 62. Mehrere Backup-Versionen statt Einzel-Slot, Löschen, Export/Import ins Dateisystem (2026-08-23)

**Vorherige Design-Entscheidung (Abschnitt 13) aufgehoben:** „Genau ein
Backup, wird bei jedem Ersetzen/Beitritt überschrieben" war bewusst gewählt,
um die Frage „welches Backup beim Austritt" durch Konstruktion auszuschließen
(es gab nur eins). Auf Nutzerwunsch erweitert: mehrere gleichzeitig
vorhandene Backup-Versionen, mit Löschen einzelner Versionen sowie Export/
Import als eigenständige Datei außerhalb der App-Sandbox (Dateien-App/
iCloud Drive).

**Umsetzung:**
- `SyncErsetzenService` legt bei jedem `erstelleBackup(context:grund:)` eine
  NEUE Datei an (`Backups/backup-<ISO8601-Zeitstempel>-<UUID-Suffix>.json`)
  statt die einzige feste `ersetzen-backup.json` zu überschreiben.
  `alleBackups()` listet alle vorhandenen Backups (neuestes zuerst),
  `vorhandenesBackup()` bleibt als Convenience für „existiert überhaupt eins"
  (= das neueste) erhalten, um den alten Einzel-Backup-Aufrufstil an mehreren
  Stellen unverändert zu lassen.
- Automatische Obergrenze `maximaleAnzahlBackups = 10` (Nutzerentscheidung):
  nach jedem `erstelleBackup`/`importiereBackup` wird das älteste Backup
  entfernt, falls die Grenze überschritten ist — außer es ist gerade das
  Ziel einer noch ausstehenden Aktion (`ausstehendeAktionBackupDateiname`,
  siehe unten).
- **Neustart-Fallback-Pfad musste auf ein konkretes Backup zeigen können:**
  Der bestehende Mechanismus (`plane…()` merkt eine Aktion in `UserDefaults`
  vor, `fuehreAusstehendeAktionAus(context:)` führt sie beim nächsten
  App-Start aus) kannte bisher implizit „das eine" Backup. Mit mehreren
  Versionen reicht das nicht mehr — ergänzt um
  `ausstehendeAktionBackupDateiname` (ebenfalls `UserDefaults`, übersteht den
  Neustart genau wie `ausstehendeAktion` selbst), das den Dateinamen des
  gemeinten Backups festhält. Bei `.ersetzenDurchPeer` ist das weiterhin das
  direkt zuvor als Sicherheitsnetz erstellte Backup (für die Vorher-/
  Nachher-Zusammenfassung), bei `.wiederherstellenAusBackup` das tatsächlich
  gewählte. Fällt defensiv auf das neueste Backup zurück, falls kein
  Dateiname hinterlegt ist.
- Der automatische Sicherheits-Backup vor „Ersetzen durch Peer" (bereits
  bestehender Mechanismus, `SyncPollingService` beim Gruppen-Ausschluss
  eingeschlossen) ist jetzt bewusst Teil derselben Liste — kein separater
  Slot mehr, sondern ein Eintrag mit sprechendem `grund` („Vor Ersetzen durch
  Peer", „Bereinigung baumelnder Referenzen", „Vor Gruppen-Ausschluss",
  „Manuell", „Importiert (…)"). Nutzerentscheidung: vereinfacht das Modell
  auf eine einzige Liste, statt Sonderfälle für „das automatische" vs. „die
  manuellen" Backups zu pflegen. Nebenwirkung: `wiederherstellenUndDeaktivieren()`
  in `SyncOrdnerSettingsView` (Austritt mit „vorherigen Stand wiederherstellen")
  nutzt weiterhin `vorhandenesBackup()` (= neuestes Backup insgesamt) — falls
  zwischen Beitritt und Austritt zusätzliche manuelle Backups erstellt
  wurden, ist das nicht mehr zwingend exakt der Vor-Beitritt-Stand. Bewusst in
  Kauf genommen, da die Alternative (separater Slot) genau die Vereinheit-
  lichung wieder aufgehoben hätte, die hier gewünscht war.
- `SyncErsetzenBackup.grund: String?` (neu, Formatversion 3) trägt die
  Herkunftsbezeichnung im Backup selbst mit — rein informativ für die Liste,
  ohne Einfluss auf den Restore-Ablauf, `nil`-sicher für ältere Backups.
- `importiereBackup(von:)` validiert durch Decodieren als `SyncErsetzenBackup`
  (keine blinde Datei-Kopie einer beliebigen JSON-Datei), markiert den
  `grund` als „Importiert (…)" und legt die Datei als zusätzliches Backup in
  `Backups/` ab — unterliegt danach denselben Regeln (Liste, Limit, Löschen)
  wie jedes andere Backup.
- `SyncOrdnerSettingsView`: die bisherige Einzel-Backup-Section (nur
  „Erstellt am" + „Backup wiederherstellen") ersetzt durch eine Liste aller
  Backups (Datum, Größe, Grund), je Eintrag Tippen = Wiederherstellen
  (Bestätigungsdialog), nach links wischen = Löschen (Bestätigungsdialog),
  nach rechts wischen = Export über `.fileExporter` (System-Dateiauswahl,
  z.B. Dateien-App/iCloud Drive). Zusätzlich „Backup jetzt erstellen" (manuell,
  ohne Ersetzen-Anlass) und „Backup importieren…" über `.fileImporter`.
  Export nutzt einen minimalen `FileDocument`-Wrapper (`BackupExportDocument`),
  der die bereits auf der Platte vorhandenen JSON-Rohdaten unverändert
  durchreicht; Import setzt `startAccessingSecurityScopedResource()` um den
  Lesezugriff auf die vom System gelieferte, außerhalb der eigenen Sandbox
  liegende URL, da `fileImporter` sonst je nach Quelle stumm fehlschlagen
  kann.

## 63. Live-Fund: dauerhafter Sandbox-Zugriffsverlust nach ca. 14 Minuten Dauerbetrieb (GitHub #171)

**Symptom:** Nach ca. 10–15 Minuten Dauerbetrieb im aktiven Einkaufsmodus
(kurzes Polling-Intervall) begann das Debug-Protokoll bei jedem Sync-Zyklus
`sandbox_extension_consume error=[12: Cannot allocate memory]` zu melden,
gefolgt von `sync_scope_zugriff: FileShareSyncConnector.beginneZugriff
erfolgreich=false`. Ab diesem Zeitpunkt scheiterte **jeder** weitere
Sync-Zyklus für den Rest der App-Sitzung — keine Selbstheilung, nur ein
App-Neustart half.

**Root Cause:** dasselbe Fehlerbild wie Abschnitt 30 (verschachteltes
wiederholtes Öffnen/Schließen desselben Security-Scoped-Bookmarks
destabilisiert den Zugriff auf echten Geräten dauerhaft), diesmal aber nicht
innerhalb eines einzelnen Zyklus verschachtelt, sondern **über viele Zyklen
hinweg wiederholt**: praktisch jede Sync-Teilfunktion öffnete und schloss
ihren eigenen Security-Scope auf demselben Bookmark — 6–7 unabhängige
Öffnungen pro Zyklus (`SyncPollingService`, `SyncICloudAenderungsBeobachter`,
`SyncSnapshotImportService`, `SyncImportService`, `SyncExportService`,
`SyncSnapshotExportService`, `SyncKaeufeExportService`), alle 2–60s. Eine
reine Reduktion der Öffnungen pro Zyklus hätte die Erschöpfung nur zeitlich
verschoben (verifiziert: Abschnitt 30s Fund trat nach ~190 Öffnungen in
einem Zyklus auf, dieser Fund nach mehreren hundert Öffnungen über ~14
Minuten — dieselbe Größenordnung, nur anders verteilt).

**Fix:** neuer Typ ``SyncOrdnerZugriffsSitzung`` (`Services/SyncOrdnerZugriffsSitzung.swift`)
verwaltet den Security-Scope sitzungsweit statt pro Operation — geöffnet
genau einmal pro App-Vordergrund-Sitzung (`SyncPollingService.starten(context:)`),
geschlossen bei `stoppen()` bzw. bei Ordnerwechsel/-entfernen
(zentral in `SyncOrdnerService.ordnerFestlegen(_:)`/`ordnerEntfernen()`
verankert, damit auch Testfälle, die direkt gegen diese Funktionen
aufsetzen, automatisch einen offenen Scope bekommen). Alle zuvor
unabhängig öffnenden Stellen (10 Dateien: die sieben oben, dazu
`MultipeerSyncService`, `DebuggingView`, sowie mehrere Debug-/Aufräum-
Funktionen in `SyncImportService`/`SyncSnapshotImportService`/
`SyncKaeufeExportService`) lesen jetzt nur noch den bereits offenen Ordner
(``SyncOrdnerZugriffsSitzung/offen``) bzw. öffnen bei Bedarf idempotent
(``SyncOrdnerZugriffsSitzung/sicherstellenOffen()``) für einmalige,
nutzerausgelöste Aktionen außerhalb des Polling-Loops. Drei Dateien öffnen
bewusst weiterhin einen eigenen, kurzlebigen Scope auf einer GANZ ANDEREN,
vom Nutzer frisch gewählten Einzeldatei (Backup-Restore in
`SyncOrdnerSettingsView`, `MilkForUsImportView`, `BelegScanView`) — kein
Bezug zum Sync-Ordner-Bookmark, unverändert gelassen.

**Verifikationsstand:** `xcodegen generate` + `xcodebuild build` sauber,
keine neuen Warnungen. Vollständiger Testlauf (448 Tests, 49 Suiten) grün
bis auf `BelegScanIntegrationTests` (22 vorbestehende, vom Refactor
unabhängige Fehlschläge — bestätigt per Vergleichslauf auf unverändertem
`main`). Noch nicht auf einem echten Gerät über einen längeren Zeitraum
(30–45 Minuten Dauerbetrieb) nachverifiziert.
`ausstehendeAktion` gewährte.

## 64. Live-Fund: Artikel mit mehreren Produkten verschwinden beim Sync-Merge (GitHub #172)

**Symptom (Nutzerbericht 2026-08-25):** Batterien wurden mit Produkt „Babycell
LR14" zur Einkaufsliste hinzugefügt und verschwanden kurz danach wieder,
ohne abgehakt worden zu sein. Issue #172 („Artikel verschwinden") beschreibt
denselben Effekt allgemeiner: „Aufgefallen: Artikel werden leise gelöscht.
Scheinbar diejenigen die einzelne Produkte haben."

**Root Cause, per Live-Log rekonstruiert** (`Bernhard DB Debug.log`,
`sync-debug.log`):

```
[2026-08-25T08:03:41Z] [Bernhard] [sync_kaufeintrag_merge_listeneintrag_entfernt]
artikel=Batterie liste=Einkaufsliste listenEintragGefunden=true entfernt=true
zuletztHinzugefuegtAm=2026-08-25 08:00:44 +0000 kaufDatum=2026-08-25 08:02:46 +0000
```

``KaufEintrag`` kannte bis zu diesem Fix **kein** ``Produkt`` — eine bewusste
Vereinfachung aus GitHub #76, die zum damaligen Zeitpunkt korrekt war (die
Preishistorien-Rolle, für die Produkt relevant war, wanderte komplett zu
``Preispunkt``). Seit GitHub #47 kann ein ``EinkaufslistenEintrag`` aber
sehr wohl ein konkretes ``Produkt`` desselben generischen ``Artikel``s tragen
(z.B. „Batterie" mit Produkt „Babycell LR14"). Dadurch waren drei
Stellen, die „schon gekauft" feststellen, **produktblind**:

1. Der Dedupe-Schutz in ``Einkaufsvorgang/artikelAbhakenKern`` (matchte
   `KaufEintrag`e nur über `artikel`, nie über `produkt`).
2. Das ``ArtikelListenKauf``-Sicherheitsnetz (GitHub #99): Schlüssel war
   `(Artikel, Einkaufsliste)`, nie `(Artikel, Produkt, Einkaufsliste)`.
3. Die Bereich-C-Merge-Löschung in
   ``SyncSnapshotImportService/mergeKaufEintraege(...)`` — Zeile
   `einkaufsliste.eintrag(fuer: artikel)` (ohne `produkt`-Parameter) suchte
   den zu löschenden Listeneintrag rein artikelweit.

Konkret rekonstruiert: ein Peer legte „Batterie" um 08:00:44 auf die
gemeinsame Liste und kaufte (eigenständig, unabhängig von Bernhards
späterer Ergänzung) irgendeine Batterie um 08:02:46. Bernhards Gerät
fügte kurz danach „Batterie"/„Babycell LR14" hinzu. Beim nächsten Merge
(08:03:41) verglich der Bereich-C-Zweig das fremde Kaufdatum (08:02:46) nur
gegen den **artikelweiten** `zuletztHinzugefuegtAm`-Zeitstempel (08:00:44)
— sah „Kauf ist neuer als letztes bekanntes Hinzufügen" und löschte den
Listeneintrag, obwohl der mit dem fremden Kauf inhaltlich nichts zu tun
hatte.

**Fix:** ``Produkt`` durchgängig durch die komplette Kauf-Pipeline
nachgerüstet, additiv-optional (kein neues `SchemaVN` nötig, siehe
`docs/BUILD_WORKFLOW.md` → „SwiftData-Migration"):

- `KaufEintrag.produkt: Produkt?` (+ `KaufEintragSnapshot.produktID`) —
  wird jetzt beim Abhaken (`artikelAbhakenKern`) und beim Bereich-C-Merge
  gesetzt.
- `ArtikelListenKauf.produkt: Produkt?` (+
  `ArtikelListenKaufSnapshot.produktID`), `ArtikelListenKaufService.Schluessel`
  jetzt `(artikelID, produktID, einkaufslisteID)` statt nur
  `(artikelID, einkaufslisteID)` — durchgereicht durch alle
  `vermerkeAbgehakt(FallsNoetig)`/`vermerkeHinzugefuegt(FallsNoetig)`/
  `alleEintraege`/`alleZeitstempel`-Pfade sowie durch
  `ArtikelZusammenfuehrungsService.referenzenUmhaengen` (Artikel-Alias-Merge).
- Dedupe-`FetchDescriptor` in `artikelAbhakenKern` vergleicht jetzt zusätzlich
  `produkt?.persistentModelID`.
- `mergeKaufEintraege`s Löschzeile nutzt jetzt `einkaufsliste.eintrag(fuer:
  artikel, produkt: neuer.produkt)` statt der artikelweiten Suche;
  `istBereitsAbgehakt` bekommt denselben Produkt-Parameter für seinen
  `KaufEintrag`-Fallback-Zweig.
- Nebenbefund derselben Wurzelursache in
  `DatenintegritaetsService.bereinigeDoppelteKaufEintraegeFallsNoetig`
  (GitHub #126): gruppierte Duplikat-Erkennung bislang nur nach
  `(Vorgang, Artikel)` — hätte zwei ECHTE, unterschiedliche Produkte
  desselben Artikels im selben Einkauf fälschlich als Duplikat gelöscht.
  Jetzt zusätzlich nach `produkt` gruppiert.
- Bereich-A (`SyncEventNutzlast`, Echtzeit-Event-Kanal) bleibt bewusst
  weiterhin ohne Produkt-Feld — dort wird `produkt` durchgängig als `nil`
  behandelt (unverändertes Verhalten, kein Rückschritt), eine Erweiterung
  wäre eine eigene, größere Änderung (neues Snapshot-Feld auf `SyncEvent`
  selbst).

**Verifikationsstand (2026-08-25):** `xcodegen generate` +
`xcodebuild build` (App-Target) sauber, `xcodebuild build-for-testing`
(Test-Target inkl. UI-Tests) sauber, keine neuen Warnungen. Kein
automatisierter Testlauf durch die KI (Nutzer-Vorgabe) — noch nicht auf
einem Gerät im Mehrgeräte-Betrieb nachverifiziert.

**Nachtrag:** die im letzten Punkt offen gelassene Bereich-A-Lücke wurde
im selben Zyklus noch geschlossen, siehe Abschnitt 65.

## 65. Nachtrag zu GitHub #172: Produkt jetzt auch über Bereich-A-Events (Echtzeit-Kanal)

**Ausgangsfrage (Nutzer, 2026-08-25):** Abschnitt 64 ließ Bereich-A bewusst
ohne Produkt-Feld — Begründung war, ein referenziertes Produkt sei „nur
eine Verfeinerung" und ein stiller Fallback auf „kein Produkt" beim
Materialisieren sei unkritisch. Der Nutzer widersprach: aus Anwendersicht
macht es keinen Unterschied, ob ein Artikel oder ein konkretes Produkt auf
die Liste gesetzt wird — beides ist gleichermaßen das, was der Nutzer
tatsächlich wollte. Ein Produkt ist hauptsächlich für die dedizierte
Preisbeobachtung besonders, nicht für die Frage „was steht auf der Liste".

**Konsequenz:** Produkt wird jetzt exakt wie Artikel behandelt — dieselbe
Auflösungs-/Retry-/Aufgeben-Pipeline, kein Sonderfall „bei Zeitüberschreitung
trotzdem ohne Produkt anwenden". Das ist sogar einfacher als der ursprünglich
diskutierte Zwischenweg (Produkt weich behandeln + Bereich-B repariert
später nach), weil kein zweiter Materialisierungs-Pfad nötig ist — Produkt
reiht sich einfach neben Artikel in dieselbe, bereits bestehende
`fehlendeReferenz`/Retry/Tombstone-Kette ein
(``SyncImportService``-Typ-Doku, „Bekannte Grenze dieser Phase").

**Umsetzung:**

- `SyncEventNutzlast.produktID: UUID?` (additiv-optional) — gesetzt für
  `.artikelHinzugefuegt`/`.artikelEntfernt`/`.artikelAbgehakt`
  (`Einkaufsliste.artikelHinzufuegen`/`artikelEntfernen`,
  `Einkaufsvorgang.artikelAbhaken` reichen `produkt?.id` jetzt an
  `SyncEventService.aufzeichnen(...)` durch).
- Neuer `MaterialisierungsErgebnis.produktFehlt`-Fall, gleichrangig zu
  `artikelFehlt` behandelt (derselbe Retry bei jungem, dasselbe Aufgeben bei
  per Tombstone gelöschtem oder über `maximalesEventAlterFuerRetry` altem
  Produkt).
- Neuer `SyncImportService.produkt(mitID:aliase:context:)`-Resolver (Alias-
  Auflösung analog `artikel(mitID:aliase:context:)`) sowie
  `aufgeloestesProdukt(_:aliase:context:)`, der „kein Produkt referenziert"
  (gültig, sofort weiter) von „referenziert, aber noch nicht bekannt"
  (→ `.produktFehlt`) unterscheidet.
- `referenzDauerhaftGeloescht` prüft jetzt zusätzlich einen Produkt-Tombstone,
  wenn `produktID` gesetzt ist.
- `materialisiereKern`s `artikelHinzufuegen`/`artikelAbhaken`-Closures
  (beide Varianten: Einzelevent über `materialisiere`, Batch über
  `materialisiereAlsBatch`) bekommen `Produkt?` als zusätzlichen Parameter
  und reichen ihn an `artikelHinzufuegenOhneEventAufzeichnung`/
  `artikelHinzufuegenAlsEventReplay`/`artikelAbhakenOhneEventAufzeichnung`/
  `artikelAbhakenAlsEventReplay` durch.

**Bewusst AUSGENOMMEN: `.artikelAbgewaehlt`/`.artikelDauerhaftEntfernt`.**
Kein Widerspruch zur obigen Gleichrangigkeit — diese beiden lokalen
Mutationen (`Einkaufsvorgang.artikelAbwaehlenOhneEventAufzeichnung(_:context:)`/
`artikelDauerhaftEntfernenOhneEventAufzeichnung(_:context:)`) matchen den zu
entfernenden `KaufEintrag` schon rein artikelweit, nie über ein konkretes
Produkt — konsistent mit der „abgehakt"-Ansicht (`EinkaufenView.abgehakteArtikel`),
die bereits bewusst nach Artikel-Identität dedupliziert (mehrere gekaufte
Produkte desselben Artikels erscheinen dort als EINE Zeile, siehe
GitHub #52-Nachfolgefund). Ein Produkt-Feld in der Nutzlast hätte hier
nichts aufzulösen, was die lokale Mutation überhaupt verwendet — eine
produktscharfe „abwählen"/„dauerhaft entfernen"-Funktion wäre eine eigene,
separate Design-Entscheidung (müsste zuerst die Anzeige selbst auf
produktscharfe Zeilen umstellen), nicht Teil dieses Fixes.

**Verifikationsstand (2026-08-25):** `xcodegen generate` + `xcodebuild build`
(App-Target) sauber, `xcodebuild build-for-testing` (Test-Target inkl.
UI-Tests) sauber, keine neuen Warnungen. Kein automatisierter Testlauf durch
die KI (Nutzer-Vorgabe) — noch nicht im Mehrgeräte-Betrieb nachverifiziert.

## 66. GitHub #175: Mehrgeräte-Nachverifikation von Abschnitt 64/65 deckt Artikel-Dubletten nach Geräte-Neuaufbau auf

**Symptom (Nutzerbericht 2026-08-25):** genau die in Abschnitt 64/65 als
„noch nicht im Mehrgeräte-Betrieb nachverifiziert" offen gelassene Probe —
zwei Geräte kaufen gemeinsam an derselben Liste ein — zeigte nach einem
Geräte-Neuaufbau Artikel doppelt/wiederbelebt auf der offenen Liste. Zwei
angehängte Test-Läufe (`Backup DB Debug*.log`, `sync-debug*.log`).

**Root Cause, per Log-Korrelation rekonstruiert:** Im ersten Testlauf schloss
das „Backup"-Gerät um 10:00:13 UTC seinen eigenen Einkauf ab — „Einkaufsliste"
fiel korrekt auf 0 offene Artikel. Um 10:01:27 UTC wurde ein zweiter,
zeitgleich vom Peer „Bernhard" an derselben Liste abgeschlossener
Einkaufsvorgang gemerged (per Alias auf einen bereits lokal existierenden
Vorgang abgebildet) — direkt danach sprang „Einkaufsliste" von 0 auf 23,
ohne dass für diese 23 Artikel ein `sicherheitsnetz_uebersprungen`-Log
auftauchte. Bis zum Ende des aufgezeichneten Zyklus (mehrere weitere
Sync-Durchläufe später) blieb der Stand unverändert bei 23 — keine
Selbstheilung, obwohl genau die in Abschnitt 4.7 („Bewusst in Kauf
genommener Randfall") beschriebene Selbstheilung das eigentlich hätte
auflösen sollen.

Ursache: `SyncSnapshotImportService.mergeKaufEintraege` löscht den
zugehörigen offenen `EinkaufslistenEintrag`, sobald es einen neuen
`KaufEintrag` eines Peers importiert (Abschnitt 4.7, Nachtrag 2026-08-10).
Diese Löschung stand aber komplett innerhalb des
`!bekannteIDs.contains(eintrag.id)`-Zweigs — lief also NUR beim
allerersten Auftauchen eines gegebenen `KaufEintrag`s. Da beide Geräte in
diesem Testlauf schon zuvor (in einem früheren Zyklus) voneinander erfahren
hatten, war der jeweils andere Kauf zum Zeitpunkt der Resurrektion bereits
`bekannt` — die Aufräumfunktion sprang für jeden weiteren Zyklus komplett,
inklusive der Löschung, per `continue` ganz oben in der Schleife. Der als
„selbst auflösender Randfall" akzeptierte Kompromiss aus Abschnitt 4.7 setzt
implizit voraus, dass diese Aufräumung bei jedem weiteren Zyklus erneut
liefe — genau das war nicht der Fall.

**Fix:** `mergeKaufEintraege` trennt jetzt „lege ich einen neuen lokalen
`KaufEintrag` an" (weiterhin `bekannteIDs`-gegated, damit keine ID doppelt
eingefügt wird) von „räume ich den zugehörigen offenen Listeneintrag auf"
(läuft jetzt für JEDEN auflösbaren Remote-Eintrag, unabhängig davon, ob der
`KaufEintrag` selbst neu ist). Beide Teilschritte sind für sich idempotent —
ein bereits fehlender Listeneintrag löst kein erneutes Löschen aus,
`ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig` bewegt den
Vergleichszeitstempel nur nach vorne, nie zurück. Laufzeit unkritisch: die
`remote`-Liste ist wie `bekannteIDs` durch `KaufEintragBereinigungService`s
48h-Karenzzeit begrenzt (`SyncKaeufeExportService` exportiert je Peer nur
dessen eigene, noch nicht bereinigte `KaufEintrag`e), nicht durch die volle
Kaufhistorie.

**Verifikationsstand (2026-08-25):** `xcodegen generate` + `xcodebuild build`
— siehe Checkpoint-Commit für den aktuellen Stand.

## 67. Nachtrag zu GitHub #175: Fix aus Abschnitt 66 reicht nicht — oszillierendes Muster, Logging erweitert

**Nutzerbericht (2026-08-25, Retest mit dem Fix aus Abschnitt 66):** Artikel
tauchten weiterhin nach Geräte-Neuaufbau doppelt auf. Neue Logs
(`Backup DB Debug 3.log`, `sync-debug 3.log`) zeigen aber ein verändertes
Bild gegenüber dem Ausgangsbefund: `Einkaufsliste`-Stand oszilliert jetzt
wiederholt zwischen 0 und 23 (`12:54:21`→0, `12:55:21`→23, `12:56:23`→0,
`12:57:24`→23, danach stabil bei 23 bis Logende `13:03:12`) — der Fix aus
Abschnitt 66 räumt eine Resurrektion also nachweislich auf (die Rückkehr zu 0
wäre ohne ihn nicht möglich gewesen), aber irgendetwas legt dieselben 23
Artikel danach IMMER WIEDER neu an.

**Blinder Fleck identifiziert:** `mergeEinkaufslistenEintraege` (Bereich-B-
Sicherheitsnetz) protokollierte bis dahin ausschließlich den Fall, dass eine
Resurrektion VERHINDERT wurde (`sync_listeneintrag_sicherheitsnetz_uebersprungen`).
Der tatsächliche Anlage-Fall (Sicherheitsnetz lässt die Resurrektion zu) war
komplett stumm — in den Logs sichtbar nur als der rohe `Einkaufsliste`-
Stand-Sprung, ohne jede Angabe, welcher Peer welchen Artikel mit welcher
Begründung erneut angelegt hat. Von den 23 betroffenen Artikeln waren zudem
nur 4 (Abdeckstift, Abflussfrei, Anzünder, Flohsamen) über IRGENDEIN
bestehendes Diagnose-Ereignis sichtbar — für die übrigen ~19 gibt es bislang
keinerlei Log-Spur, weder auf der Anlage- noch auf der Aufräum-Seite.

**Arbeitshypothese (noch nicht bestätigt):** `istBereitsAbgehakt` lässt ein
erneutes Hinzufügen zu, wenn der von einem Peer gemeldete
`EinkaufslistenEintragSnapshot.erstelltAm` NACH dem lokal bekannten
`ArtikelListenKauf.zuletztAbgehaktAm` liegt (Abschnitt 55, „legitimes
erneutes Hinzufügen"). Ist der meldende Peer selbst schon einmal von
derselben Resurrektion betroffen gewesen und hat dabei (auf seiner Seite,
über einen bisher nicht lokalisierten Pfad) einen künstlich verjüngten statt
den tatsächlichen historischen `erstelltAm`-Wert übernommen, würde jede
Merge-Runde dem jeweils anderen Gerät einen „neueren" Zeitstempel vorspielen
— ein sich selbst aufschaukelnder Resurrektions-Kreislauf zwischen zwei
Geräten, der nie konvergiert. Nicht verifiziert, da dafür Sicht auf den
sendenden Peer („Bernhard") nötig wäre, die die bisherigen Logs (nur vom
Gerät „Backup") nicht liefern.

**Logging erweitert, um die Hypothese beim nächsten Testlauf zu prüfen:**

- Neues Ereignis `sync_listeneintrag_sicherheitsnetz_angelegt`
  (Gegenstück zu `..._uebersprungen`) — protokolliert bei JEDER
  tatsächlichen Neuanlage über dieses Sicherheitsnetz: Artikel, Liste,
  meldender Peer, dessen `erstelltAm`-Angabe, sowie die zu diesem Zeitpunkt
  bekannten `zuletztAbgehaktAm`/`zuletztHinzugefuegtAm`-Werte — macht für
  alle ~23 Artikel (nicht nur die bisher zufällig sichtbaren 4) nachvollziehbar,
  ob tatsächlich ein neuerer `erstelltAm`-Wert gemeldet wird und woher er kommt.
- `sync_kaufeintrag_merge_listeneintrag_entfernt` trägt jetzt zusätzlich
  `peer=…`, um beide Ereignisse über den meldenden Peer korrelieren zu
  können.
- `mergeEinkaufslistenEintraege` bekommt dafür `peerGeraeteID` als neuen
  Parameter (bisher nicht durchgereicht).

Details: `docs/LOGGING.md`. Erwartung für den nächsten Testlauf: das neue
Ereignis sollte für die bisher unsichtbaren ~19 Artikel erstmals eine
Log-Zeile liefern und zeigen, ob `peerErstelltAm` tatsächlich auffällig
„frisch" ist (Hinweis auf die obige Hypothese) oder etwas anderes vorliegt
(z.B. ein Alias-/Namensmatching-Problem, das denselben Artikel auf zwei
lokale Objekte verteilt).

**Verifikationsstand (2026-08-25):** `xcodegen generate` + `xcodebuild build`
sauber, bestehende `SyncSnapshotImportServiceTests`-Suite (69 Tests) weiterhin
grün, kein neuer Regressionstest (reines Logging, keine Verhaltensänderung).
Noch nicht mit einem dritten Testlauf verifiziert.
