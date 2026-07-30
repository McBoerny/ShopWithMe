# Datensynchronisation — Umsetzungsplan (GitHub #39, ohne Multipeer)

**Bezug:** [Issue #39](https://github.com/McBoerny/ShopWithMe/issues/39).

**Kursänderung gegenüber `docs/DATENSYNCHRONISATION_BEWERTUNG.md`:** Jenes Dokument
empfahl, den Großteil von #39 nicht umzusetzen, weil die bestehende
„ein geteilter Ordner + Lease"-Architektur für Mehrgeräte-Zugriff ausreiche. Nach
erneuter, ausdrücklicher Nutzervorgabe gilt das nicht mehr: Gewünscht ist die in
#39 vorgeschlagene **event-basierte, dynamische Architektur** — jedes Gerät führt
seine **eigene, lokale, live genutzte Datenbank**, ein Remote-Share hält
Kopien/Events aller Teilnehmer möglichst zeitnah synchron, darüber gleichen sich
alle Mitnutzer ab. **Bewusst ausgeklammert bleibt vorerst der
MultipeerConnectivity-Kanal** (WiFi/Bluetooth-Echtzeitaustausch im Laden, siehe
Issue #49) — dieser Plan deckt ausschließlich den FileProvider-Kanal
(iCloud Drive/Synology Drive o.ä.) ab. `docs/DATENSYNCHRONISATION_BEWERTUNG.md`
bleibt als Aufzeichnung der ursprünglichen Abwägung bestehen, ist für den
Mehrbenutzer-Anwendungsfall aber durch diesen Plan **ersetzt**.

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
Wiederverwendung der in `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5.1
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
| **B — Stammdaten** | `Artikel`, `ArtikelKategorie`, `GeschaeftTyp`, `Geschaeft` (inkl. `erkennungsradius`, `ausgeschlosseneKategorien`, `IgnorierterArtikel` — siehe Entscheidungen unten), `Einkaufsliste` (nur `id`/`name`, siehe 4.2a) | Export bei jedem Sync-Zyklus, weniger zeitkritisch | Namens-/Koordinaten-Matching (bereits vorhandene Bausteine, siehe `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5.1) |
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
   `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5 hergeleitet — der bleibt
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
