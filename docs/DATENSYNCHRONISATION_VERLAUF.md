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
`ArtikelKategorie`, `Geschaeft`, `Artikel`, `Einkaufsliste`; Bereich C: alle
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
und merged `GeschaeftTyp`/`ArtikelKategorie`/`Geschaeft`/`Artikel`/
`Einkaufsliste` dependency-geordnet in den lokalen Bestand, unter
Wiederverwendung der in `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2
hergeleiteten Matching-Bausteine (`GeschaeftTyp.mitNamen`,
`GeschaeftErkennungService.istGleicherOrt`, Namensabgleich für
`ArtikelKategorie`/`Artikel`). Grundprinzip aller Merge-Regeln: **nie
destruktiv** — ein bestehender lokaler Wert wird nie durch einen abweichenden
Remote-Wert überschrieben, nur fehlende Werte werden ergänzt und Mengen
(Kategorien, Typen, ignorierte Artikel, alternative Namen) vereinigt. Die
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
(`GeschaeftTyp`/`ArtikelKategorie`/`Geschaeft`/`Artikel`/`Einkaufsliste`) aus
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
| **B — Stammdaten** | `Artikel`, `ArtikelKategorie`, `GeschaeftTyp`, `Geschaeft` (inkl. `erkennungsradius`, `ausgeschlosseneKategorien`, `IgnorierterArtikel` — siehe Entscheidungen unten), `Einkaufsliste` (nur `id`/`name`, siehe 4.2a) | Export bei jedem Sync-Zyklus, weniger zeitkritisch | Namens-/Koordinaten-Matching (bereits vorhandene Bausteine, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2) |
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
   - **3a (umgesetzt):** Stammdaten (`GeschaeftTyp`, `ArtikelKategorie`,
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
   Gerät ein `Geschaeft`/`Artikel`/`ArtikelKategorie`/`Einkaufsliste`, brachte
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
  `Geschaeft`/`Artikel`/`ArtikelKategorie`/`Einkaufsliste`/`KaufEintrag` vor,
  wird im Snapshot mitgeführt (`SyncSnapshot.tombstones`) und beim Import
  zuerst verarbeitet (`mergeTombstones`): löscht ein dadurch als entfernt
  markiertes, lokal noch vorhandenes Objekt, und verhindert (über
  `SyncTombstoneService.geloeschteIDs`), dass die nachfolgenden
  Merge-Schritte es aus einem veralteten Peer-Snapshot neu anlegen. Alle
  UI-Löschstellen (`GeschaeftListView`, `ArtikelListView`,
  `KategorienVerwaltungView`, `EinkaufslistenVerwaltungView`,
  `GeschaeftPreisUebersichtView`) rufen `SyncTombstoneService.markiereGeloescht(...)`
  vor dem eigentlichen `context.delete(...)` auf.
- **`SyncEntitaetsAlias`-Erweiterung auf `Geschaeft`/`ArtikelKategorie`** —
  Voraussetzung dafür, dass ein Tombstone für ein per Namens-/
  Koordinatenmatching zusammengeführtes Objekt überhaupt auf die richtige
  lokale ID aufgelöst werden kann (vorher nur für `Artikel`/`Einkaufsliste`
  registriert). `Geschaeft`/`ArtikelKategorie` übernehmen jetzt außerdem
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
materialisierter `KaufEintrag` bewusst **keinen** `kategorieBesuchsIndex` — er
beschreibt die Laufreihenfolge des SENDENDEN Geräts, nicht die dieses
Geräts, und würde `WarengruppenDistanzService` sonst mit einer erfundenen
Besuchsposition füttern; `Einkaufsvorgang.naechsterKategorieBesuchsIndex`
ignoriert solche indexlosen Einträge bei der Suche nach einem bereits
vorhandenen Index, um keinen Duplikat-Index für dieselbe Kategorie zu
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
unterdrücken `kategorieBesuchsIndex`); store-loser Umleitungs-Fallback bei
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
   inklusive Lernschritt (`WarengruppenDistanzService.verarbeiteEinkauf`),
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
Kategorien/Artikel/Kaufeinträge über mehrere Zyklen hinweg stabil blieben.
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
Zyklen hinweg stabil blieben — nur `geschaefte` (und `artikelKategorien`,
`artikel`) zeigten bei jedem Zyklus einen anderen Kurz-Fingerabdruck.

**Ursache:** ``SyncSnapshotExportService/normalisiertFuerVergleich(_:)``
(Abschnitt 14) sortierte bisher nur die ÄUSSEREN Arrays (ein Eintrag je
Entität) nach ihrer `UUID`. Die ID-Arrays INNERHALB eines einzelnen
Eintrags — `GeschaeftSnapshot/typIDs`/`kategorieIDs`/
`ausgeschlosseneKategorieIDs`/`alternativeNamen`/`ignorierteArtikelNamen`,
``ArtikelKategorieSnapshot/geschaeftsTypIDs``,
``ArtikelSnapshot/kategorieIDs`` — sind ebenfalls aus SwiftData-
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
Geschäfte-Liste als auch der inneren `typIDs`/`kategorieIDs`/
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
als `ArtikelKategorie`/`Geschaeft`/`Artikel` hat `GeschaeftTyp` kein
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
Fragestellung hin:** ``mergeArtikelKategorien``/``mergeGeschaefte``/
``vervollstaendige`` wiesen `lokal.typen`/`lokal.kategorien`/
`lokal.ausgeschlosseneKategorien`/`lokal.geschaeftsTypen` bislang UNBEDINGT
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
Abschnitt 20 als eigentliche Fehlerkategorie „orphaned" (semantisch
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
- `mergeGeschaefte`/`mergeArtikel`/`mergeArtikelKategorien`/
  `mergeEinkaufslisten`: alle vier Entitätstypen sind IMMER eigenständig
  über ihre jeweilige Verwaltungsansicht erreichbar (keine „braucht X, um
  sichtbar zu sein"-Abhängigkeit wie bei `Einkaufsvorgang`) — ein „neu
  anlegen" ohne vollständige Zusatzdaten erzeugt hier höchstens ein
  unvollständiges, aber niemals ein unerreichbares Objekt.
- `mergeKaufEintraege`: `artikel`/`geschaeft`/`kategorie`/`einkaufsvorgang`
  dürfen alle `nil` sein (behält dafür bewusst die Schnappschuss-Namen) —
  bleibt trotzdem in der Preishistorie sichtbar, keine Unerreichbarkeit.
- `mergeWarengruppenDistanzen`s „neu anlegen"-Zweig validiert bereits
  korrekt VOR dem Anlegen (`guard let kategorieA = ..., let kategorieB = ...
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
Preispunkt), sondern auch für Geschäft/Artikel/ArtikelKategorie/Einkaufsliste
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
bestehenden `kategorie`-Override, aber bewusst doppelt optional (`Geschaeft??`),
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

`EinkaufenView.umschalten(_:kategorie:)`/`entferneDauerhaft(_:)` mussten dafür
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
