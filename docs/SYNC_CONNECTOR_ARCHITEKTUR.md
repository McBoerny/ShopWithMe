# Sync-Connector-Architektur (Vorbereitung)

Architektur-Review + Vorbereitung für eine austauschbare Sync-Backend-Architektur
(Nutzervorgabe, 2026-08-11): heute läuft die Synchronisation ausschließlich gegen
einen vom Anwender gewählten cloud-gestützten Dateiordner (iCloud Drive, Synology
Drive, OneDrive, Box Drive, …). Ziel ist ein `SyncConnector`-Schnitt, hinter dem
sich dieser Datei-Ordner als erste Implementierung verbirgt, damit weitere Backends
(zunächst cr-sqlite oder eine andere datenbankgestützte Lösung, perspektivisch
CloudKit) additiv ergänzt werden können, ohne die bestehende Merge-Logik
anzufassen.

**Präzisierung (Nutzer-Feedback 2026-08-11):** SwiftData bleibt in jedem Fall die
interne Persistenz — kein Connector ersetzt sie. Ein Connector ist ausschließlich
für den Transport zuständig und darf nichts über die interne Repräsentation
wissen. Mehrere Connectors existieren gleichzeitig im Code, registriert
nebeneinander; der Anwender wählt zur Laufzeit, welcher aktiv ist (Settings-Auswahl,
analog zur heutigen Sync-Ordner-Wahl). Der bestehende Datei-Connector wird bei
Einführung weiterer Connectors **nicht** entfernt, sondern bleibt eine gleichwertige
Option.

**Ergebnis vorweg:** Die Trennung ist möglich und sinnvoll — der bestehende Code
ist dafür in weiten Teilen bereits sauber genug geschnitten (Abschnitt 2–5). Ein
Connector-Registry mit Nutzerwahl (Abschnitt 6) ist eine überschaubare Erweiterung
des Schnitts. Für cr-sqlite gibt es einen technischen Sonderfall (Abschnitt 7):
cr-sqlite ist selbst eine Merge-Engine, kein bloßer Transport — es lässt sich mit
der Präzisierung oben trotzdem sauber einbauen, aber nur als **privater Sidecar
innerhalb eines Connectors**, nicht als Ersatz für SwiftData oder für die
bestehende Merge-Logik insgesamt. Abschnitt 9 vergleicht alle vier real
umsetzbaren Wege im Detail.

## 0. Theoretischer Hintergrund: Architekturmodelle für geteilte App-Daten

Dieser Abschnitt beantwortet die der Session zugrunde liegende allgemeine Frage:
Welche Architekturmodelle kommen einem App-internen Datenmodell entgegen, das
vollständig oder teilweise mit anderen Nutzern geteilt, nebenläufig bearbeitet
und auf allen Peers konsistent gehalten werden soll — unabhängig vom
Transportweg? Der Abschnitt dient als Rahmen, in den die konkreten Abschnitte
1–12 dieses Dokuments eingebettet sind.

### 0.1 Die Grundfrage: Was muss das Datenmodell leisten?

Sobald mehrere Peers dasselbe Datum gleichzeitig verändern dürfen, entsteht das
Problem der **nebenläufigen Aktualisierung ohne gemeinsamen Schreib-Lock**. Drei
Eigenschaften muss ein Modell dafür mitbringen:

1. **Stabile globale Identitäten** — jede Zeile/Entität trägt eine UUID oder
   ähnliche, peer-unabhängig erzeugte ID. Auto-Increment-Integer-Primärschlüssel
   sind für verteilte Systeme ungeeignet, weil zwei Peers dieselbe Zahl vergeben.
2. **Monotone, nie überschriebene Metadaten** — Versionszähler, logische Uhren,
   Zeitstempel werden nur vorwärts angepasst. Rückwärtssprünge (z.B. „Zeitstempel
   löschen und neu setzen") verhindern die meisten Merge-Strategien.
3. **Additive statt destruktive Operationen** — „Löschen" bedeutet einen
   Tombstone-Eintrag anlegen, nicht die Zeile entfernen. Nur so kann ein Peer,
   der den Delete noch nicht gesehen hat, beim nächsten Sync korrekt aufholen.

Diese drei Anforderungen sind unabhängig von der gewählten Merge-Strategie und
vom Transportweg — sie sind Voraussetzung für jede der unten genannten Lösungen.

### 0.2 Architekturmodelle im Überblick

| Paradigma | Kernidee | Konfliktmodell | Voraussetzung |
|---|---|---|---|
| **Event Sourcing / Op-Log** | Unveränderlicher, geordneter Log von Operationen; jeder Peer repliziert den Log, der Zustand ergibt sich aus dem Replay | Ordnung über logische Uhr (Lamport, Vektor); Konflikte durch Prioritätsregel oder manuelle Auflösung | Genau-einmal-Zustellung, oder idempotente Events |
| **State-basierte CRDT** | Vollständiger Zustand wird ausgetauscht; Merge-Funktion ist kommutativ, assoziativ, idempotent — Konvergenz ist mathematisch garantiert | Kein expliziter Konflikt; ungültige Zustände müssen im Datenmodell ausgeschlossen sein (z.B. OR-Set statt Add/Remove-Counter) | Merge muss für alle Felder/Typen definiert sein; nicht jede Domäne passt ohne Verlust in eine CRDT-Algebra |
| **Delta-CRDT** | Wie state-basiert, aber nur die „Deltas" (Änderungen seit letztem Sync) werden übertragen | Wie state-basiert | Effizienter bei großen Zuständen; komplexer zu implementieren als vollständige State-CRDTs |
| **Op-basierte CRDT** | Operationen (nicht Zustände) werden einmalig zugestellt; der Effekt ist Konflikt-frei, wenn Operationen kommutativ sind | Kaum expliziter Konflikt; aber „kommutative Operationen" sind für viele Domänen schwer zu garantieren | Zuverlässige Punkt-zu-Punkt-Zustellung (genau einmal, richtige Reihenfolge) — für unzuverlässige Transporte unpraktisch |
| **OT (Operational Transformation)** | Gleichzeitige Operationen werden gegeneinander „transformiert", bevor sie angewendet werden | Zentrale Server-Ordnung klassisch nötig; peer-to-peer OT ist korrekt, aber aufwändig | Heute größtenteils durch CRDT-Ansätze verdrängt (außer in kollaborativen Texteditoren) |
| **Shared Mutable Store** | Alle Peers schreiben in denselben Datenspeicher (gemeinsame SQLite-Datei, relationale DB mit Replikation) | Serialisierung durch Locks oder MVCC (Multi-Version Concurrency Control); Konflikte durch MVCC sichtbar gemacht | Gemeinsamer zuverlässiger Kanal (Server, geteilte Datei mit Locking-Garantie) |

**Faustregel:** Shared Mutable Store ist einfach zu verstehen, aber setzt einen
zentralen Koordinator (Server oder ein Dateisystem mit starken Konsistenzgarantien)
voraus. CRDTs sind aufwändiger im Datenmodell, aber peer-to-peer tauglich und ohne
gemeinsamen Lock auskommend — ideal für Apps, die auch offline funktionieren müssen.

### 0.3 Freie, lizenzfrei nutzbare Implementierungen

Alle genannten Optionen sind Open Source und können lizenzfrei in einer kommerziellen
iOS-App verwendet werden (Lizenz in Klammern):

| Lösung | Lizenz | Swift-Support | Ansatz | Stärke / Schwäche |
|---|---|---|---|---|
| **Automerge** (`automerge-swift`) | MIT | Ja — offizieller Swift-Port, aktiv gepflegt | Op-basierte CRDT (Peritext für Text, OR-Set für Listen, LWW für skalare Felder) | Größtes Ökosystem, einfachste Integration für JSON-artige Dokumente; proprietäres Dokumentenmodell — kein direktes SwiftData-Mapping |
| **cr-sqlite** | MPL-2.0 | Via C-FFI/`sqlite3`-API | State-basierte CRDT auf SQL-Ebene (LWW pro Zelle mit Site-ID-Tiebreaker) | Kein eigenes Wire-Format nötig — wer SQL schreibt, bekommt CRDT kostenlos; funktioniert nicht auf Core Data / SwiftData-eigener Store-Datei (Abschnitt 7) |
| **Y.js / y-crdt** | MIT | Kein offizieller Swift-Port | Op-basierte CRDT (hauptsächlich für kollaborative Texteditoren und Baumstrukturen) | Sehr ausgereift, aber Swift-only-Projekte müssen einen Rust-/C-Wrapper selbst pflegen |
| **`NSPersistentCloudKitContainer`** | Proprietär (Apple-Frameworks) | Ja — SwiftData `ModelConfiguration(cloudKitDatabase:)` | Automatische CloudKit-Replikation (LWW pro `CKRecord`-Feld, von Apple verwaltet) | Geringster Implementierungsaufwand; kein Einfluss auf Merge-Entscheidungen; bindet an iCloud (Abschnitt 8) |
| **Eigene Implementierung** | — | Ja | Projektspezifischer Hybrid | Vollständige Kontrolle über domänenspezifische Merge-Regeln; hoher Initialaufwand, iterative Härtung nötig (s.u.) |

**Kostenschätzung für eine Eigenimplementierung** (basierend auf dem ShopWithMe-
Verlauf, `docs/DATENSYNCHRONISATION_VERLAUF.md`):

- **Basis-Sync** (Snapshot-Export/Import, Lamport-Uhr, einfache additive Merges):
  2–4 Wochen Entwicklungszeit.
- **Mehrgeräte-Härtung** (Security-Scope-Stabilität, Re-Entranz-Schutz,
  Peer-Lebenszyklus, Tombstone-Kaskadenlogik): weitere 3–6 Monate auf echten
  Geräten — die meisten Bugs sind erst unter realen Bedingungen reproduzierbar,
  nicht in Unit-Tests.
- **Domänenspezifische Merge-Sonderfälle** (Heuristiken wie der
  `offenerTreffer`-Verbund-Match für Einkaufsvorgänge): kontinuierlich, nie
  „fertig" — ShopWithMe hat in einem Jahr ~20 dokumentierte solcher Fälle
  akkumuliert.

**Empfehlung für neue Apple-Apps:**
- Einfache strukturierte Daten ohne fachliche Merge-Heuristiken →
  `NSPersistentCloudKitContainer` oder Automerge-Swift.
- Dokumentenzentrierte Daten (Rich Text, verschachtelte Listen) → Automerge-Swift.
- Komplexe Geschäftslogik mit domänenspezifischen Konfliktregeln (der ShopWithMe-
  Fall: Einkaufslisten-Semantik, Preishistorie, Geschäftserkennung) → Eigenimplementierung,
  weil generische CRDT-Algebren diese fachliche Bedeutung nicht kennen.

### 0.4 Einordnung der ShopWithMe-Implementierung

ShopWithMe implementiert heute einen **Hybrid** aus zwei der oben genannten Paradigmen:

**Bereich A (Einkaufslisten-Zustand) = op-basiertes Event Sourcing mit
Lamport-Priorität:**
- Jede Aktion (Abhaken, Abwählen, Entfernen) wird als unveränderliches `SyncEvent`
  mit Lamport-Zähler aufgezeichnet.
- Konflikte zwischen zwei konkurrierenden Events für dasselbe Listenelement
  werden durch `SyncKonfliktAufloesung` mit fachlicher Prioritätsordnung aufgelöst
  (nicht bloßem LWW): „Entfernen schlägt alles, Abwählen schlägt Abhaken".
- `SyncEventNutzlast` ist das Wire-Format (Schicht 2); der Datei-Ordner ist der
  Transport (Schicht 3).

**Bereich B/C/D (Stammdaten, Historie, Lerndaten) = state-basierte Delta-CRDTs:**
- Jedes Gerät exportiert seinen vollständigen eigenen Stand als `SyncSnapshot`
  (der „State" im CRDT-Sinn, aufgeteilt in fünf Pakete seit #82).
- `SyncSnapshotImportService.mergePaket` ist die Merge-Funktion — sie ist
  kommutativ (Reihenfolge der Peer-Snapshots irrelevant), assoziativ und idempotent.
  Formell: ein state-basiertes CRDT über das gesamte Daten-Aggregat.
- Die 19 `mergeX`-Funktionen spezifizieren die Merge-Algebra pro Entitätstyp.

**Explizit realisierte CRDT-Bausteine im Code:**

| CRDT-Typ | Realisierung in ShopWithMe |
|---|---|
| **G-Counter** (Grow-only Counter) | `SyncPeerZaehlerStand` / `GCounterPeerZustand` — zählt Besuche pro Peer, nie dekrementierbar |
| **G-Counter** (zweiter Anwendungsfall) | `WarengruppenDistanzPeerZaehlerStand` — Gewichtszähler für Sortier-Lernen |
| **OR-Set** (Observed-Remove Set, add-wins) | `mergeEinkaufslistenEintraege` — ein Listeneintrag existiert, sobald irgendein Peer ihn angelegt hat; `istBereitsAbgehakt`-Gate verhindert Neuanlage für bereits abgeschlossene Einträge |
| **LWW-Register** (Last-Writer-Wins, monoton) | `ArtikelListenKauf.zuletztAbgehaktAm` / `zuletztHinzugefuegtAm` — Monoton-Max-Merge (`max(lokal, fremd)`) |
| **Weighted-Average-CRDT** (domänenspezifisch) | `mergeWarengruppenDistanzen` — gewichteter Mittelwert, delta-gegated und gewichts-gedeckelt, kein Standard-CRDT |
| **Tombstone** | `SyncTombstone` — markiert bewusst gelöschte Entitäten, verhindert Neuanlage durch einen nicht-synchronisierten Peer |
| **Ambiguitäts-Deferral** (human-in-the-loop) | `SyncAbgleichKandidat` — kein mathematisch konvergenter CRDT, sondern eine dritte Auflösungsstrategie: Bei echter Unsicherheit (Gleichnamigkeit, unklare Zuordnung) wird die Entscheidung an den Nutzer delegiert (`SyncOrdnerSettingsView`). Sinnvoll für Domänen, in denen ein falsches automatisches Merge schlimmer ist als eine kurze manuelle Bestätigung. |

Diese Tabelle ist die Grundlage für `docs/SYNC_MERGE_STRATEGIEN.md` (GitHub #75,
geplante generische Merge-Engine).

### 0.5 Connector-Architektur als Antwort auf Transportweg-Vielfalt

Aus der Übersicht in §0.2–0.3 folgt direkt die Motivation für die
`SyncConnector`-Architektur in den folgenden Abschnitten: Die Merge-Algebra
(§0.4, Schicht 1 in Abschnitt 2) ist **unabhängig** vom Transportweg — ob ein
Snapshot-Paket über einen geteilten Dateiordner, eine SQLite-Datei, einen
CloudKit-Record oder einen gehosteten Server reist, ändert nichts daran, wie
`mergePaket` dieses Paket verarbeitet. Der Connector-Schnitt macht diese bereits
heute faktisch bestehende Unabhängigkeit (Abschnitt 3) formal und austauschbar.

## 1. Ausgangslage

Diese Session hat vier verschiedene Mehrgeräte-Sync-Bugs aufgedeckt und behoben
(`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitte 55–60): zwei Ausprägungen einer
strukturellen Lücke (asymmetrisches „abgehakt"/„hinzugefügt"-Faktum bei
`ArtikelListenKauf`, siehe Typ-Doku) und eine echte Nebenläufigkeits-Race
(`syncZyklus()` konnte sich selbst überlappen, `docs/DATABASE_CONCURRENCY.md`
„Nachtrag"-Abschnitt). Beide Fixes waren generisch, nicht symptomatisch — die
Merge-Algorithmen selbst gelten nach dieser Härtung als stabil.

Die jetzige Frage ist eine andere: nicht *ob* die Merge-Logik korrekt ist, sondern
*wie eng* sie an ihren heutigen Transport (Cloud-Dateiordner) gekoppelt ist, und ob
sich das lösen lässt, ohne die gerade gehärtete Korrektheit zu riskieren.

## 2. Bestandsaufnahme: drei Schichten im heutigen Code

Der bestehende Sync-Code (14 Dateien, 5.381 Zeilen in `ShopWithMe/Services/Sync*.swift`)
lässt sich schon heute sauber in drei Schichten zerlegen — nur ist diese Trennung
bisher implizit, nicht durch ein Protokoll erzwungen.

### Schicht 1 — Merge-/Domänenlogik (transport-unabhängig)

Der wertvollste Teil des Systems und der, der diese Session am meisten Aufwand
gekostet hat:

- `SyncSnapshotImportService.swift` (1.995 Zeilen) — 19 `mergeX`-Funktionen
  (`mergeGeschaefte`, `mergeArtikel`, `mergeEinkaufslistenEintraege`,
  `mergeEinkaufsvorgaenge`, `mergeKaufEintraege`, `mergeArtikelListenKaeufe`, …)
  plus Orchestrierung (`importiereSnapshots`, `mergePaket`, `merge`).
- `SyncKonfliktAufloesung.swift` — Prioritätsordnung für konkurrierende
  Bereich-A-Events (`SyncKonfliktAufloesung.Kandidat`, arbeitet auf einem reinen
  Werttyp, nicht auf `URL`/`Data`).
- Die CRDT-artigen Bausteine: G-Counter (`SyncPeerZaehlerStand`,
  `WarengruppenDistanzPeerZaehlerStand`), das gerade gebaute symmetrische
  LWW-Faktum (`ArtikelListenKauf.istOffen`), Tombstones (`SyncTombstoneService`),
  Alias-/Identitätsauflösung (`SyncEntitaetsAlias`/`SyncEntitaetsAliasService`),
  Lamport-Uhr (`LamportClock`).
- Der Event-Anwendungsteil von `SyncImportService.swift` (`materialisiere`,
  `wendeAn`, `wendeEinzelnesEmpfangenesEventAn`).

**Entscheidender Befund:** Jede einzelne dieser Funktionen arbeitet ausschließlich
auf decodierten Swift-Werten (`SyncSnapshot`, `SyncEventNutzlast`, `ModelContext`)
— nirgendwo taucht `URL`, `FileManager` oder `NSFileCoordinator` auf. Diese
Schicht ist heute schon *faktisch* transport-unabhängig, nur nicht formal hinter
einem Protokoll gekapselt. Das ist die beste Nachricht dieses Reviews: der
schwierigste, am meisten gehärtete Teil des Systems muss für einen neuen Connector
nicht angefasst werden — und bleibt, wie unten präzisiert, für **jeden** Connector
identisch zuständig.

### Schicht 2 — Daten-Vertrag (Wire-Modelle)

Die `Codable`-Strukturen, die beschreiben, *was* zwischen Geräten wandern muss,
unabhängig von *wie*:

- `SyncSnapshot` (`Models/SyncSnapshot.swift`) und die fünf seit GitHub #82
  aufgeteilten Pakete `SyncStammSnapshot`/`SyncListenSnapshot`/
  `SyncVorgaengeSnapshot`/`SyncPreisSnapshot`/`SyncLernenSnapshot`
  (`docs/EXPORT_PAKET_UMBAU.md`) plus `SyncPeerManifest`.
- `SyncEventNutzlast`/die Export-Darstellung einzelner `SyncEvent`s.
- `KaufEintragSnapshot` als Append-Log-Eintrag (`kaeufe/<uuid>.json`).

Diese Schicht ist heute eng an JSON gekoppelt (`Codable` + `JSONEncoder`), aber
nicht an Dateien — sie beschreibt Werte, keine Pfade. Ein neuer Connector kann
dieselben Typen weiterverwenden; er muss nur selbst entscheiden, *wie* er sie
serialisiert/überträgt. **Ein Connector kennt ausschließlich diese Schicht —
niemals `ModelContext`, `@Model`-Typen oder SwiftData überhaupt.** Das ist die
technische Lesart von „Connector-Technologie soll agnostisch gegenüber der
internen Repräsentation sein": die Grenze verläuft exakt zwischen Schicht 2 und 3.

### Schicht 3 — Transport (heute: Cloud-Dateiordner)

Alles, was tatsächlich Bytes bewegt — vollständig ersetzbar, wenn ein neuer
Connector entsteht:

| Datei | Zeilen | Aufgabe |
|---|---|---|
| `SyncDateiZugriff.swift` | 186 | Low-Level-I/O: `NSFileCoordinator`-Lesen/Listen/Schreiben/Verschieben/Löschen + Zeitlimit-Wrapper. Bereits ein sauberer, wiederverwendbarer Baustein — praktisch schon „der Datei-Connector-I/O-Treiber", nur ohne eigenen Protokoll-Namen. |
| `SyncOrdnerService.swift` | 282 | Ordnerwahl (Security-Scoped Bookmark), `peers/<name>/`-Layout, eigene Peer-Ordner-Benennung/Umbenennung, Mitgliedschafts-Listing, Peer-Entfernung, Multipeer-Gruppen-ID-Markerdatei. |
| `SyncExportService.swift` | 188 | Bereich-A-Events als Einzeldateien schreiben (`peers/{id}/events/`), Lamport-gepolsterte Dateinamen für Sortierung, wasserstand-basiertes Aufräumen. |
| `SyncSnapshotExportService.swift` | 655 | Bereich-B/C/D-Pakete schreiben, Fingerabdruck-Vergleich zum Überspringen unveränderter Teile. |
| `SyncKaeufeExportService.swift` | 149 | `KaufEintrag`-Append-Log schreiben. |
| `SyncImportService.swift` (Lese-Teil) | ~250 von 570 | Peer-Ordner lesen, bereits-gesehene Event-IDs aus Dateinamen vorfiltern (reine Datei-Transport-Optimierung), JSON decodieren. |
| `SyncICloudAenderungsBeobachter.swift` | 132 | `NSMetadataQuery`-basierte iCloud-Änderungsbeobachtung — existiert für andere Connectors gar nicht. |
| `SyncErsetzenService.swift` | 451 | Korruptions-Recovery/Voll-Neuaufbau — liest den kompletten Peer-Zustand über Schicht-3-Primitiven. |

`SyncPollingService.swift` (Zyklus-Timing, 5s/60s-Intervalle, 20s-Zeitlimits) ist
größtenteils schichtunabhängig, aber seine konkreten Zahlen sind auf
Cloud-Datei-Latenz kalibriert — ein anderer Connector bräuchte eigene Werte.

`DatabaseLeaseService` gehört **nicht** zu dieser Betrachtung: das ist
lokale Schreibkoordination für die eigene SQLite-Datei, unabhängig davon, wie
Daten zwischen Geräten wandern (`docs/DATABASE_CONCURRENCY.md`).

## 3. Der Beweis, dass die Trennung schon trägt: `MultipeerSyncService`

Ein wichtiges, oft übersehenes Detail: Es gibt heute bereits **zwei** Transporte
für denselben Schicht-2-Inhalt. `MultipeerSyncService` verschickt exakt dieselbe
`SyncEventExportDarstellung`-Nutzlast direkt per `MCSession` an verbundene Peers
— völlig ohne Dateisystem — und beide Wege münden in derselben Funktion
(`SyncImportService.wendeEinzelnesEmpfangenesEventAn`, `session(_:didReceive:fromPeer:)`
Zeile ~253–256 in `MultipeerSyncService.swift`). Das ist kein Zufall, sondern der
lebende Beweis, dass Schicht 1/2 heute schon transportunabhängig funktionieren —
der Datei-Kanal bleibt dabei laut Typ-Doku bewusst „die verlässliche Zustellung",
Multipeer ist nur eine Beschleunigung obendrauf, aber die Entkopplung selbst ist
bereits produktiv im Einsatz.

## 4. Der `SyncConnector`-Schnitt

Konsequenz aus Abschnitt 2–3: Der Protokoll-Schnitt gehört zwischen Schicht 2 und
Schicht 3 — Schicht 1 bleibt komplett unverändert, Schicht 2 wird der gemeinsame
Vertrag, den jeder Connector transportieren muss, Schicht 3 wird pro Connector neu
implementiert. Grober Entwurf (Namenskonvention wie im übrigen Code — Typname
englisch/technisch wie `MultipeerSyncService`/`DatabaseLeaseService`,
Methodennamen deutsch wie in `SyncOrdnerService`):

```swift
protocol SyncConnector {
    // Peer-Erkennung und -Lebenszyklus (heute: SyncOrdnerService)
    func bekanntePeers() async -> [String]
    func binIchNochMitglied() async -> Bool?
    func entfernePeer(_ peer: String) async

    // Bereich A — Events (heute: SyncExportService/SyncImportService-Lese-Teil)
    func veroeffentlicheNeueEvents(_ events: [SyncEventExportDarstellung]) async -> Bool
    func empfangeNeueEvents(von peer: String, bekanntePraefixe: Set<String>) async -> [SyncEventExportDarstellung]

    // Bereich B/C/D — Snapshot-Pakete (heute: SyncSnapshotExportService)
    func veroeffentlichePaket(_ teile: SyncPaketTeile) async -> Bool
    func empfangePaket(von peer: String) async -> SyncPaketTeile?

    // Bereich C — KaufEintrag-Append-Log (heute: SyncKaeufeExportService)
    func veroeffentlicheNeueKaufEintraege(_ eintraege: [KaufEintragSnapshot]) async -> Bool
    func empfangeNeueKaufEintraege(von peer: String, bekannteIDs: Set<UUID>) async -> [KaufEintragSnapshot]

    // Liveness/Wasserstand (heute: SyncPeerManifest-Datei)
    func manifest(von peer: String) async -> SyncPeerManifest?

    // Korruptions-Recovery (heute: SyncErsetzenService)
    func vollstaendigerZustand(von peer: String) async -> SyncVollstaendigerZustand?

    // Stabile Gruppen-ID für den Multipeer-Beschleunigungskanal (heute:
    // SyncOrdnerService.multipeerGruppenID, aus der `.sync-gruppen-id`-Markerdatei) —
    // jeder Connector muss einen eigenen, für alle Mitglieder gleichen Wert liefern
    // können, siehe Abschnitt 6.
    func multipeerGruppenID() async -> UUID?
}
```

Drei bewusste Design-Entscheidungen an dieser Stelle:

- **`bekanntePraefixe`/`bekannteIDs` als Parameter statt Connector-interner
  Zustand:** Die ID-Vorfilterung ist heute eine reine Datei-Transport-Optimierung
  (Dateiname enthält die ID, spart Decodieren). Ein anderer Connector filtert
  vielleicht anders (z.B. ein Cursor/Watermark bei einer Datenbank) — das
  Protokoll gibt nur die *Absicht* vor („liefere mir nur Neues"), nicht die
  Technik dahinter.
- **`SyncPaketTeile`/`SyncVollstaendigerZustand` als neue, dünne
  Zusammenfassungstypen:** kapseln die fünf Einzelpakete bzw. den kompletten
  Peer-Zustand, damit der Connector nicht fünf/sechs Einzelmethoden für etwas
  anbieten muss, das logisch zusammengehört. Reine Bündelung bestehender
  Schicht-2-Typen, kein neuer Inhalt.
- **`PeerRef` ist konkret `String`, kein `associatedtype`:** Ein generischer
  Peer-Typ pro Connector wirkt zunächst sauberer, verhindert aber genau das in
  Abschnitt 6.1 vorausgesetzte Verhalten — ein zur Laufzeit austauschbares
  `any SyncConnector` kann keine Methode aufrufen, deren Signatur ein
  `associatedtype` referenziert (Swift-Existentials lösen das nur, wenn der
  Typ entweder gar kein `associatedtype` hat oder dieses über einen Primary
  Associated Type fest gebunden wird — beides widerspricht „ein Connector
  beliebigen Typs in derselben Variable"). Jede reale Peer-Identität ist heute
  bereits eine einfache String-UUID (`SyncPeerInfo.peerGeraeteID`), und auch
  ein künftiger CloudKit-Connector kann `CKRecord.ID` verlustfrei dorthin
  abbilden — die Konkretisierung kostet nichts und macht `any SyncConnector`
  aus Abschnitt 5/6 überhaupt erst compilierbar.

Was **nicht** ins Protokoll gehört: `SyncPollingService`s Zyklus-Steuerung
(Re-Entranz-Schutz, Intervall-Timing) bleibt Aufrufer-seitig — sie orchestriert
einen `SyncConnector`, ist aber selbst keiner. Ebenso bleibt
`SyncKonfliktAufloesung`/die gesamte Merge-Logik unangetastet in Schicht 1.

## 5. Referenzimplementierung: der bestehende Datei-Connector

Der heutige Code wird zu `FileShareSyncConnector` — überwiegend eine
Extraktion/Umbenennung des Bestehenden hinter das neue Protokoll, kein Rewrite:

- `SyncDateiZugriff` bleibt praktisch unverändert (interner I/O-Baustein des
  neuen Connectors).
- `SyncOrdnerService`, `SyncExportService`, `SyncSnapshotExportService`,
  `SyncKaeufeExportService`, der Lese-Teil von `SyncImportService` und
  `SyncICloudAenderungsBeobachter` wandern (mit leichten Signatur-Anpassungen
  an die Protokoll-Methoden) hinter `FileShareSyncConnector`.
- Sämtliche hart erarbeiteten Spezialfälle bleiben erhalten — jeder trägt heute
  bereits eine GitHub-Issue-Referenz und einen Grund im Code (`NSFileCoordinator`-
  Koordination für iCloud-Drive-Platzhalter #52, Verzeichnis-Listing-Fund #91,
  Zeitlimit gegen unbegrenzt hängende Aufrufe #49, Security-Scoped-Bookmark-
  Diagnose). Diese Härtung ist reines Schicht-3-Wissen und betrifft nur diesen
  einen Connector — jeder weitere Connector braucht nichts davon, hat aber
  vermutlich eigene, andere Spezialfälle (siehe Abschnitt 9, „Kosten" pro Weg).
- `SyncPollingService` und `SyncImportService`/`SyncExportService`s
  Aufrufer-Seite (`RootView`, `SyncOrdnerSettingsView`) wechseln von direkten
  Aufrufen auf `SyncOrdnerService`/`SyncDateiZugriff` zu einem injizierten
  `any SyncConnector` — der einzige Teil, der wirklich neuen Code statt nur
  Verschiebung braucht.

Risiko dieses Schritts: niedrig. Es entsteht keine neue Logik, nur eine neue
Naht. Die bestehende Testsuite (Merge-Funktionen, Konfliktauflösung) bleibt
unverändert gültig, da sie Schicht 1 testet. `FileShareSyncConnector` bleibt
danach dauerhaft im Code — er wird durch spätere Connectors ergänzt, nie ersetzt
(siehe Abschnitt 6).

## 6. Mehrere Connectors gleichzeitig, Wahl durch den Anwender

Das ist die zentrale Präzisierung gegenüber dem ursprünglichen Entwurf: Ziel ist
keine einmalige Migration von „Datei-Connector" zu „nächstem Connector", sondern
eine **Registry** mehrerer, gleichberechtigt nebeneinander existierender
`SyncConnector`-Implementierungen, aus denen der Anwender wählt — strukturell
identisch zur heutigen Sync-Ordner-Wahl, nur eine Ebene höher.

### 6.1 Auswahlmechanismus

- Eine neue, persistierte Einstellung (analog `syncOrdnerBookmark` in
  `SyncOrdnerService`) hält fest, welcher Connector aktiv ist — z.B. ein
  einfacher Identifier (`"datei"`/`"sqlite"`/`"cloudkit"`), aus dem eine Factory
  die passende `any SyncConnector`-Instanz baut.
- Settings-UI: ein neuer, übergeordneter „Sync-Backend"-Bildschirm listet alle
  registrierten Connectors; die Auswahl eines Connectors führt in dessen eigene
  Konfiguration (für `FileShareSyncConnector` bleibt das die heutige
  `SyncOrdnerSettingsView` unverändert; ein Datenbank- oder CloudKit-Connector
  bekäme eine eigene, kleinere Konfigurationsansicht).
- `SyncPollingService`, `RootView`, `SyncOrdnerSettingsView` und Co. greifen
  nie mehr direkt auf `SyncOrdnerService` zu, sondern auf „den aktuell gewählten
  Connector" — dieselbe Umstellung wie in Abschnitt 5 beschrieben, nur mit einer
  Factory statt einer festen Typreferenz dahinter.

### 6.2 Eine Sync-Gruppe = ein Connector

Wichtige Annahme, die an dieser Stelle explizit gemacht werden sollte: Zwei Geräte
können nur dann miteinander synchronisieren, wenn sie **denselben Connector**
gewählt haben — ein Gerät am Datei-Connector und eines am Datenbank-Connector
sehen sich gegenseitig nicht, es sei denn, es gibt eine eigens gebaute
Brücke zwischen genau diesen beiden Connectors. Das ist keine Einschränkung
gegenüber heute, sondern die naheliegende Verallgemeinerung des bestehenden
Modells: „einen Sync-Ordner wählen" ist heute bereits gleichzeitig Konfiguration
*und* Gruppenzugehörigkeit (wer denselben Ordner hat, ist in der Gruppe). Eine
künftige Connector-Wahl wäre genauso beides zugleich, nur eine Ebene abstrakter.
**Nicht Teil dieses Dokuments:** eine allgemeine Interop-Schicht zwischen
verschiedenen Connector-Typen — das wäre ein separates, deutlich größeres
Vorhaben und ist von der ursprünglichen Anfrage nicht gefordert.

### 6.3 Verhältnis zum Multipeer-Beschleunigungskanal

`MultipeerSyncService` ist heute **additiv** zum Datei-Connector, nicht
gleichrangig wählbar — es liefert Events zusätzlich und sofort, während der
Datei-Kanal weiterhin „die verlässliche Zustellung" bleibt (Abschnitt 3). Dieses
Muster überträgt sich unverändert auf jeden künftigen primären Connector: genau
ein primärer `SyncConnector` ist zur Zeit aktiv (Abschnitt 6.1), Multipeer bleibt
davon unabhängig immer verfügbar und bezieht seine Gruppen-ID künftig über die
neue `multipeerGruppenID()`-Protokollmethode (Abschnitt 4) vom jeweils aktiven
Connector statt fest verdrahtet aus `SyncOrdnerService`.

### 6.4 Konsequenz für „Weg A" (cr-sqlite)

Diese Präzisierung ändert die Bewertung von cr-sqlite grundlegend gegenüber der
ursprünglichen Fassung dieses Dokuments: **„SwiftData ablösen" steht nicht mehr
zur Debatte** — es war ohnehin nie gefordert, sondern eine zu weit gefasste
Interpretation von „cr-sqlite als nächster Connector". Die richtige Frage ist,
ob und wie sich cr-sqlite *innerhalb eines einzelnen, optionalen Connectors*
einsetzen lässt, ohne dass dieser Connector die interne Repräsentation (SwiftData)
kennt oder verändert. Das ist möglich — siehe Abschnitt 7.3 — aber nicht kostenlos.

## 7. cr-sqlite: Merge-Engine, kein Transport

### 7.1 Wie cr-sqlite arbeitet

cr-sqlite (vlcn.io) ist eine **SQLite-Laufzeit-Extension**. Man lädt sie in eine
`sqlite3`-Verbindung, markiert Tabellen per `SELECT crsql_as_crr('tabelle')` als
„Conflict-free Replicated Relation" — danach versioniert cr-sqlite jede normale
`INSERT`/`UPDATE`/`DELETE`-Anweisung gegen diese Tabelle automatisch, pro Zelle,
über Trigger. Zum Synchronisieren liest man Änderungssätze aus der virtuellen
Tabelle `crsql_changes` und spielt sie auf einem anderen Replikat wieder ein —
cr-sqlite löst Konflikte dabei selbst auf (im Kern ein Last-Writer-Wins pro
Zelle, mit Site-ID/Version als Tie-Breaker).

Der **Transport** dieser Änderungssätze ist tatsächlich beliebig — das passt in
ein Connector-Muster. Der Haken: cr-sqlite ist kein passiver Transport, sondern
ersetzt für jede Tabelle, die es verwaltet, direkt die Rolle von Schicht 1
(Merge-Entscheidung) und den JSON-Teil von Schicht 2 (Wire-Format) — beides auf
SQL-Ebene, nicht auf Swift-Werten.

### 7.2 Zwei technische Randbedingungen mit SwiftData/Core Data

1. **Keine unterstützte API, um eine Laufzeit-Extension in Core Datas eigene
   `sqlite3`-Verbindung zu laden.** SwiftData sitzt auf Core Data, Core Data
   verwaltet seine SQLite-Verbindung selbst und exponiert sie nicht für
   `sqlite3_load_extension`. Projekte, die cr-sqlite-artige Sync-Eigenschaften
   in Swift wollen, nutzen deshalb grundsätzlich GRDB.swift oder die rohe
   `sqlite3`-C-API — nie Core Data/SwiftData.
2. **cr-sqlite will das Tabellenschema selbst besitzen** (stabile, app-eigene
   Primärschlüssel, keine ORM-eigenen Schatten-Tabellen). Core Datas
   SQLite-Schema ist Core Datas eigene interne Repräsentation
   (`Z`-präfixierte Tabellen, ganzzahliger `Z_PK`, `Z_ENT`-Typisierung) — nicht
   etwas, worauf eine Extension sicher aufsetzen kann.

Wichtig: Beide Punkte verbieten cr-sqlite nur **auf Core Datas eigener
Store-Datei**. Sie verbieten cr-sqlite nicht grundsätzlich im Prozess — eine
zweite, separate `.sqlite`-Datei, komplett unabhängig von SwiftDatas Store und
nur über GRDB/rohes `sqlite3` angesprochen, ist technisch unproblematisch. Genau
das ist die Grundlage für Abschnitt 7.3.

### 7.3 Der gangbare Weg: cr-sqlite als privater Sidecar

Damit cr-sqlite eingesetzt werden kann, ohne SwiftData zu berühren oder den
bestehenden Datei-Connector zu verdrängen, müsste ein neuer, eigenständiger
`CrSqliteSyncConnector` intern **zwei** lokale Datenspeicher koordinieren:

1. **SwiftData** (unverändert, wie von allen anderen Connectors auch genutzt) —
   bleibt die einzige Datenquelle für UI (`@Query`) und alle Services.
2. **Eine private, ausschließlich diesem Connector gehörende `.sqlite`-Datei**
   mit geladener cr-sqlite-Extension, angesprochen über GRDB oder rohes
   `sqlite3` — für die App und alle anderen Connectors unsichtbar.

Ein **Brücken-Code** im Connector übersetzt in beide Richtungen: lokale
SwiftData-Änderungen werden in die Sidecar-Tabellen gespiegelt (damit cr-sqlite
sie versionieren kann), und von cr-sqlite aus einem Peer übernommene,
aufgelöste Änderungen werden zurück in SwiftData geschrieben (damit die UI sie
sieht). Das ist neuer Code, der heute nicht existiert — er ersetzt nicht
`SyncSnapshotImportService`, sondern tritt daneben.

**Der Umfang dieser Spiegelung ist ein Regler, kein Alles-oder-nichts:**

- *Minimal:* nur Bereich A (der `SyncEvent`-Log) wird gespiegelt — cr-sqlite
  übernimmt ausschließlich die Rolle von Lamport-Uhr + Ereignis-Reihenfolge/
  -Zustellung. `SyncKonfliktAufloesung` und alle `mergeX`-Funktionen bleiben
  exakt wie heute. Kleinster Eingriff, kleinster Nutzen.
- *Maximal:* alle synchronisierten Tabellen werden gespiegelt, cr-sqlite
  übernimmt die Zell-Merge-Entscheidung für praktisch alles. Größter Eingriff
  (Bridge-Code für alle ~28 Modelle), größter Nutzen (die meisten `mergeX`-
  Funktionen könnten entfallen).

**Was cr-sqlite in keinem Fall abnimmt**, unabhängig vom gewählten Umfang:

- **Alias-/Identitätsauflösung** (`SyncEntitaetsAlias`) — löst „zwei
  unabhängig angelegte Zeilen meinen dasselbe reale Geschäft" (Entity
  Resolution), nicht „dieselbe Zeile wurde unterschiedlich geändert" (das ist
  cr-sqlites Aufgabe). Bleibt eigener Code, vor- oder nachgeschaltet.
- **Domänenspezifische Prioritätsregeln** wie `SyncKonfliktAufloesung`s
  „Entfernen schlägt alles, Abwählen schlägt Abhaken" — cr-sqlites generisches
  Last-Writer-Wins kennt diese fachliche Bedeutung nicht.

**Der eigentliche Preis dieses Wegs:** ein zweiter lokaler Speicher, der mit
SwiftData konsistent gehalten werden muss. Das ist strukturell dieselbe
Fehlerklasse, die diese gesamte Session beschäftigt hat — zwei Repräsentanten
derselben Daten, die auseinanderlaufen können —, nur an einer neuen Stelle:
nicht mehr nur zwischen zwei Geräten, sondern zusätzlich zwischen SwiftData und
dem Sidecar auf ein und demselben Gerät. Dafür würde ein eigenes, kleines
Äquivalent zu genau der Sorgfalt nötig, die z.B. in
`docs/DATABASE_CONCURRENCY.md` für die Multi-Writer-Absicherung der einen,
heutigen Store-Datei dokumentiert ist.

## 8. Neubewertung: CloudKit

`docs/ROADMAP.md` nennt „Echter iCloud-/CloudKit-Sync" bereits unter
„Zukünftig", und `docs/DECISIONS.md` begründet die ursprüngliche Wahl von
SwiftData explizit auch damit, den Overhead von Core Data +
`NSPersistentCloudKitContainer` zu vermeiden, „den wir aktuell (kein
iCloud-Sync) ohnehin nicht brauchen". Diese Abwägung ist über ein Jahr und
diese komplette Sync-Härtungs-Session her — es lohnt sich, sie explizit
neu zu bewerten statt sie unverändert fortzuschreiben.

### 8.1 Zwei völlig verschiedene Bedeutungen von „CloudKit nutzen"

- **SwiftDatas native, automatische CloudKit-Anbindung** (`ModelConfiguration(
  cloudKitDatabase:)`) — Apple-gepflegt, kein Extension-Laden, kein
  Schema-Konflikt, aber SwiftData bestimmt dabei selbst die Konfliktauflösung
  (im Kern CloudKits eigenes Last-Writer-Wins pro Record). Das läuft **nicht**
  durch die eigene Merge-Engine und **nicht** durch das `SyncConnector`-Protokoll
  — es wäre ein komplett eigener, zum Registry-Modell aus Abschnitt 6
  inkompatibler Pfad (SwiftData selbst würde synchronisieren, nicht ein
  austauschbarer Connector). Passt aus genau diesem Grund nicht in die hier
  verfolgte Architektur, unabhängig von den Merge-Einbußen unten.
- **CloudKit über die rohe `CKRecord`/`CKContainer`-API**, selbst angesteuert —
  das ist ein echter `SyncConnector`: Schicht 1 bleibt unverändert zuständig,
  CloudKit ersetzt nur Schicht 3. Dieser Weg ist gemeint, wenn im Folgenden von
  „CloudKit-Connector" die Rede ist.

### 8.2 Kontrollverlust nur bei der automatischen Variante

Der Haken der automatischen Variante: sie würde genau die Kontrolle aufgeben,
die diese Session aufgebaut hat (G-Counter statt naives Delta-Merge,
symmetrische Fakten statt einseitiger Zeitstempel, Prioritätsordnung statt
reinem Lamport-Vergleich) — gegen CloudKits deutlich gröberes
Standardverhalten. Bei der rohen API-Variante entfällt dieser Nachteil
vollständig, da Schicht 1 unverändert bleibt; der Preis ist dort ausschließlich
Implementierungsaufwand (neues Auth-/Zonen-/Subscription-Modell), keine
aufgegebene Korrektheit.

## 9. Vier Wege im Vergleich

Alle vier Wege koexistieren dauerhaft (Abschnitt 6) — die Reihenfolge unten ist
eine Empfehlung für die Bau-Reihenfolge, keine Ausschluss-Entscheidung.

| Weg | Neuer Code | Schicht 1 unverändert? | Neue Abhängigkeit | Größtes Risiko |
|---|---|---|---|---|
| **Datei (`FileShareSyncConnector`)** | Extraktion des Bestehenden hinter das Protokoll | Ja | Keine (bestehend) | Gering — reine Umstrukturierung |
| **SQLite-Container** | Neuer Connector, schreibt/liest dieselben Schicht-2-Pakete als eine `.sqlite`-Datei statt viele JSON-Dateien | Ja | Keine (Standard-SQLite, kein Extension-Laden) | Gering-mittel — im Kern ein neues Serialisierungsformat |
| **cr-sqlite-Sidecar** | Neuer Connector + Bridge-Code SwiftData ↔ Sidecar-DB | Teilweise (siehe 7.3 — Alias-/Prioritätslogik bleibt) | cr-sqlite (kleineres OSS-Projekt), GRDB oder rohes `sqlite3` | Am höchsten — neue Konsistenz-Fehlerklasse zwischen zwei lokalen Speichern |
| **CloudKit (rohe API)** | Neuer Connector gegen `CKRecord`/`CKContainer` | Ja | Apple Developer Account/Entitlement, iCloud-Anmeldung als Voraussetzung | Mittel — neues Auth-/Zonen-Modell, aber gut dokumentierte Apple-API |

**Im Detail:**

- **SQLite-Container** ist der risikoärmste neue Connector: exakt dieselbe
  Merge-Logik, exakt dieselben Schicht-2-Typen, nur „eine Datei statt vieler
  JSON-Dateien" als Ablageformat — kleiner, SQL-abfragbar für Diagnose,
  potenziell weniger Cloud-Datei-Operationen pro Zyklus. Ehrlicher Nachteil:
  der Sprung ist inhaltlich bescheiden, solange er weiterhin über denselben
  Cloud-Ordner läuft wie heute — der Gewinn ist Format-Effizienz, keine neue
  Sync-Erfahrung.
- **cr-sqlite-Sidecar** bietet den größten potenziellen Gewinn (weniger
  handgeschriebene Merge-Fälle, ein battle-getestetes CRDT-Modul für die
  gespiegelten Tabellen) bei gleichzeitig größtem Neubau-Aufwand und einer
  echten neuen Risikoklasse (Bridge-Konsistenz). Realistisch der teuerste der
  vier Wege, unabhängig davon, dass „SwiftData bleibt" das ursprüngliche
  Vollmigrations-Szenario bereits ausschließt.
- **CloudKit** ist die einzige Option ohne Abhängigkeit von einem durch den
  Anwender verwalteten Ordner — dafür die einzige mit einer harten neuen
  Voraussetzung (Apple-Konto/iCloud), die die drei anderen Wege nicht haben.
  Das ist auch eine Produktfrage, nicht nur eine technische: heute funktioniert
  jeder beliebige Cloud-Dateianbieter, ein CloudKit-Connector bindet diese
  Nutzergruppe an Apple/iCloud.
- **Datei** bleibt in jedem Szenario die Referenz — sowohl als heute einzige
  Implementierung als auch später als der am längsten gehärtete, am wenigsten
  riskante Connector für Anwender ohne besonderen Bedarf an den anderen drei.

## 10. Bezug zu Issue #75

`docs/ROADMAP.md` führt unter „Zukünftig" bereits
[#75](https://github.com/McBoerny/ShopWithMe/issues/75) „Modell-unabhängige
Sync-Architektur": ein `SyncableModel`-Protokoll + generische Merge-Engine, die
die 19 handgeschriebenen `mergeX`-Funktionen durch eine einzige generische
Engine ersetzen würde. Das ist eine **andere Achse** als dieses Dokument:

- Dieses Dokument: *wohin* Daten transportiert werden (Schicht 3), Schicht 1
  bleibt unverändert entitätsspezifisch.
- #75: *wie generisch* Schicht 1 selbst ist, unabhängig vom Transport.

Beide sind unabhängig voneinander umsetzbar und würden sich gut ergänzen — #75
zuerst würde jeden Connector aus Abschnitt 9 leichter machen (weniger Code, der
pro neuem Feld gepflegt werden muss), ist aber keine Voraussetzung für den
`SyncConnector`-Schnitt selbst.

**Vorarbeit für #75:** `docs/SYNC_MERGE_STRATEGIEN.md` klassifiziert alle 19
Merge-Funktionen nach ihrer CRDT-Strategie und identifiziert, welche vollständig
generalisiert werden können, welche nur teilweise und welche einen domänenspezifischen
Custom-Hook benötigen werden.

## 11. Offene Fragen

Die ursprüngliche große Weggabelung („SwiftData ablösen oder nicht") ist durch
die Präzisierung in Abschnitt 6 bereits beantwortet — nicht ablösen, additive
Registry. Offen bleiben kleinere, aber konkrete Fragen für den Beginn der
Umsetzung:

1. **Bau-Reihenfolge:** SQLite-Container zuerst (niedrigstes Risiko, validiert
   den `SyncConnector`-Schnitt selbst), oder direkt der gewünschte
   cr-sqlite-Sidecar (mehr Aufwand, aber kein Zwischenschritt)?
2. **Spiegel-Umfang bei cr-sqlite**, falls dieser Weg gewählt wird: minimal
   (nur Bereich A) oder maximal (alle synchronisierten Tabellen), siehe
   Abschnitt 7.3.
3. **Multi-Connector-Gleichzeitigkeit über Multipeer hinaus:** bleibt es bei
   „ein primärer Connector, Multipeer additiv" (Abschnitt 6.3), oder soll ein
   Gerät später mehrere primäre Connectors parallel bedienen können (z.B. um
   während einer Migration von einem Connector zum anderen beide gleichzeitig
   zu nutzen)? Letzteres ist in diesem Dokument nicht vorgesehen und würde die
   Registry aus Abschnitt 6 nicht unwesentlich verkomplizieren.

## 12. Nicht-Ziele dieses Dokuments

- Keine Aussage zu `DatabaseLeaseService`/lokaler Schreibkoordination — bleibt
  unverändert, unabhängig vom gewählten Connector (Abschnitt 2, Schicht-3-Tabelle).
- Kein Beginn der eigentlichen `SyncConnector`-Protokoll-Implementierung — dieses
  Dokument bereitet die Entscheidung vor, setzt sie nicht um.
- Keine allgemeine Interop-Schicht zwischen unterschiedlichen Connector-Typen
  (Abschnitt 6.2) — außerhalb der vom Nutzer genannten Anforderung.
- Keine Bewertung weiterer denkbarer Backends (z.B. ein eigener kleiner Server)
  — außerhalb der vom Nutzer genannten drei Kandidaten (Dateiordner, cr-sqlite/
  Datenbank, CloudKit).
