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

Phase 3+ noch nicht begonnen.

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
  Mehrbenutzer-Fall werden diese durch dieses neue Verfahren **abgelöst** — die
  lokale Datenbank bleibt immer am Standardpfad, der bisherige „aktiven
  Speicherort auf einen geteilten Ordner verschieben"-Weg entfällt für „gemeinsam
  einkaufen". Er bleibt nur noch für den unveränderten Einzelnutzer-Fall relevant
  (persönlicher Ordner-Umzug ohne Teilen, z.B. eigener Cloud-Backup-Ordner) — dann
  weiterhin ohne Sync-Zusatzlogik.

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
   wie heute schon für `DatabaseLocationService`).
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

- **#48 (Überkauf-Hinweis):** wird durch echte Events **einfacher** als ursprünglich
  geplant — `SyncEvent.autorGeraeteID` liefert direkt, wer einen Artikel abgehakt
  hat; kein zusätzliches `KaufEintrag.abgehaktVonGeraet`-Feld nötig, die
  Information steht schon im zugehörigen Event.
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
4. **Phase 3 — Import Bereich B/C/D:** Stammdaten-/Historien-/Lern-Merge beim
   Einlesen fremder `export.json`-Dateien.
5. **Phase 4 — Konsolidierung + adaptives Polling** (Abschnitt 5.4/5.5).
6. **Phase 5 — Gruppen-Setup-UX + Bootstrap** (Abschnitt 6), inkl.
   Wiederverwendung der #50-Merge-Logik.
7. **Phase 6 — #48 auf Basis echter Events** umsetzen.
8. **Phase 7 (separates Issue #49, weiterhin an Bedingungen geknüpft):**
   Multipeer als zusätzlicher Beschleunigungs-Kanal, falls nach Phase 0–6 im
   echten Gebrauch tatsächlich benötigt.

Empfehlung für den Einstieg: Phase 0 zuerst, in sich abgeschlossen und ohne
Auswirkung auf bestehendes Verhalten (reines Mitschreiben, noch kein Sync) — gute
Gelegenheit, das Event-Modell und die Mutations-Integration zu verproben, bevor
Dateisystem-Sync (Phase 1+) dazukommt.
