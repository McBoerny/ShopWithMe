# Bewertung: Vorschlag Datensynchronisation (GitHub #39)

**Korrektur/Überholt:** Nach erneuter, ausdrücklicher Nutzervorgabe wird die
zentrale Empfehlung dieses Dokuments — die bestehende „geteilter Ordner +
Lease"-Architektur reiche für Mehrgeräte-Zugriff aus, der Event-Sourcing-Teil von
#39 sei nicht nötig — **nicht mehr verfolgt**. Umgesetzt werden soll stattdessen
genau der hier in Abschnitt 3 als „nicht übernommen" bewertete
Event-Sourcing-/Lamport-Ansatz (FileProvider-Kanal), nur ohne den
MultipeerConnectivity-Teil. Der neue, maßgebliche Plan steht in
`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`. Dieses Dokument bleibt als
Aufzeichnung der ursprünglichen (inzwischen überholten) Abwägung erhalten.

**Bezug:** [Issue #39](https://github.com/McBoerny/ShopWithMe/issues/39) — vollständiger
Architekturvorschlag für Event-Sourcing/CRDT (GRDB, Lamport-Timestamps) plus
Dual-Channel-Sync (FileProvider + MultipeerConnectivity), Gruppen-/Vertrauensverwaltung
und Überkauf-Erkennung.

**Ergebnis vorweg:** Der Vorschlag löst ein Problem, das in dieser App aufgrund einer
bereits getroffenen, bewussten Architekturentscheidung **nicht existiert** — echte,
divergierende Datenkopien mehrerer Geräte, die gemerged werden müssten. Entsprechend
wird der überwiegende Teil des Vorschlags **nicht übernommen** (Abschnitt 3). Eine
einzelne Idee daraus — die Überkauf-Warnung (Abschnitt 10 des Vorschlags) — ist
eigenständig wertvoll und lässt sich ohne jede der vorgeschlagenen Infrastruktur auf
das bestehende Datenmodell aufsetzen (Abschnitt 5).

---

## 1. Ist-Zustand: Wie Mehrgeräte-Zugriff heute funktioniert

Siehe `docs/DATABASE_CONCURRENCY.md` (maßgeblich, Status: umgesetzt seit Build 30).
Kernpunkte, die für die Bewertung des Vorschlags entscheidend sind:

- Es gibt **keine separate lokale Datenbank pro Gerät**, die synchronisiert werden
  müsste. Alle Geräte einer Gruppe zeigen (über einen vom Nutzer gewählten,
  lokal gespiegelten Cloud-Ordner, z.B. iCloud Drive/Synology Drive) auf **dieselbe
  logische SQLite-Datei**. Der Cloud-Anbieter synchronisiert diese Datei
  dateisystemseitig — die App selbst betreibt keinen eigenen Sync-Mechanismus.
- Das einzige dadurch entstehende Risiko ist **Dateikorruption** durch
  gleichzeitiges Schreiben zweier Geräte in dieselbe (gerade hochladende) Datei —
  kein Merge-Problem, sondern ein Schreib-Koordinationsproblem.
- Gelöst über ein **Single-Writer-Micro-Lease-Verfahren**
  (`DatabaseLeaseService`, `NSFileCoordinator`), das den Schreibzugriff auf
  Sekundenbruchteile je Aktion beschränkt, plus eine **Dedupe-Prüfung** beim
  Artikel-Abhaken (`Einkaufsvorgang.artikelAbhaken`) als Auffangnetz für das
  verbleibende Sync-Latenz-Kollisionsfenster.
- Explizit dokumentierte, bewusst abgelehnte Alternativen: CloudKit Sharing,
  CloudKit private Database, eigener Server, Backend-as-a-Service — jeweils mit
  Begründung „kein Server/CloudKit jetzt, Cloud-Anbindung bleibt optionale
  Zukunft".
- **Offener Punkt, der vor jeder Erweiterung Priorität hat:** ein echter
  Live-Test mit mehreren physischen Geräten gegen einen tatsächlich installierten
  Cloud-Provider steht noch aus (`docs/DATABASE_CONCURRENCY.md` →
  „Umsetzungsstand"/„Bekannte Grenzen").

## 2. Kernannahme des Vorschlags — trifft nicht zu

Issue #39 geht davon aus, dass „Zwei Geräte mit denselben Events immer denselben
Zustand" haben müssen, weil sie **unabhängig voneinander** Events erzeugen, die erst
nachträglich zusammengeführt werden. Das ist die Grundvoraussetzung für den gesamten
Event-Sourcing/CRDT-Teil (Lamport-Clocks, Konfliktauflösungsregeln, materialisierter
Zustand aus Event-Log).

In der tatsächlichen Architektur dieser App gibt es diese Divergenz nicht: Es existiert
zu jedem Zeitpunkt **eine** Datei mit **einem** Zustand, für die Lese-/Schreibzugriff
koordiniert wird. Ein Merge-Algorithmus hat hier nichts zu tun — es gibt nichts, das
divergieren könnte, solange das Lease-Verfahren Schreibkonflikte verhindert (was es
laut Unit-Tests und Code-Review bereits tut; der reale Cloud-Live-Test steht noch aus,
s.o.).

Das bedeutet: Der komplette Aufwand für eigenes Event-Log-Schema, Lamport-Timestamps,
Konfliktauflösungsregeln, „materialisierter Zustand aus Events" und
Export-/Konsolidierungs-Zyklen (Abschnitte 2–6 des Vorschlags) hätte **keinen
Mehrwert** gegenüber dem bereits vorhandenen, getesteten Verfahren — nur erheblich
mehr Komplexität und einen kompletten Wechsel der Persistenzschicht (GRDB/rohes SQL
statt SwiftData).

## 3. Komponenten-Bewertung

| Vorschlag (Abschnitt in #39) | Bewertung | Begründung |
|---|---|---|
| **GRDB statt SwiftData** (§3) | ❌ Ablehnen | Kompletter Rewrite der gesamten Modellschicht (~15 `@Model`-Klassen, alle Relationships, alle Services/Views) für ein Problem, das nicht besteht. Unverhältnismäßiges Risiko für eine App, die laut Nutzervorgabe „nicht produktiv" ist. SwiftData nutzt intern ohnehin SQLite im WAL-Modus — die im Vorschlag angestrebten Eigenschaften (kleine inkrementelle Schreibvorgänge) hat die App über den WAL-Mechanismus bereits, siehe `docs/DATABASE_CONCURRENCY.md` → „Datentransfer-Schätzung". |
| **Event-Log + Lamport-Timestamps + CRDT-Merge** (§2–4) | ❌ Ablehnen | Löst Datendivergenz, die es bei „eine Datei, koordinierter Zugriff" nicht gibt (Abschnitt 2 oben). Würde zusätzlich ein eigenes, dauerhaft zu pflegendes Event-Schema samt Konsolidierung/Purging einführen — Wartungslast ohne Gegenwert. |
| **FileProvider-Export/Delta-Sync** (§5–6) | ❌ Ablehnen (bereits anders gelöst) | Der beschriebene `db_export.json`+Delta-Events-Mechanismus repliziert, was das bestehende Lease-Verfahren über die geteilte Datei selbst bereits erreicht — nur mit zusätzlicher Serialisierungsebene. |
| **MultipeerConnectivity Echtzeit-Kanal** (§7) | 🟡 Zurückstellen, nicht jetzt | Einzige Komponente mit echtem, eigenständigem Nutzen: Sichtbarkeit der Änderungen des Partners in <1s statt 5–30s Cloud-Sync-Latenz. Aber: Apple-exklusiv, hoher Neuentwicklungsaufwand (Discovery, Session-Handling, Reconnect, Vertrauensprüfung), und der zugrunde liegende Korrektheits-/Korruptionsschutz braucht sie nicht — das leistet bereits das Lease-Verfahren. Empfehlung: erst bei tatsächlich beobachtetem Bedarf (z.B. nach dem noch ausstehenden Live-Test, falls Cloud-Sync-Latenz beim gemeinsamen Einkaufen real als störend empfunden wird), siehe Abschnitt 6. |
| **Presence („wer ist gerade wo")** (§7.6) | 🟡 Zurückstellen | Nur mit Multipeer sinnvoll (Polling-Latenz über den Share macht „Live-Standort" witzlos). Hängt an obigem Punkt. |
| **Trusted-Peers/Gruppenverwaltung mit Revocation** (§8, Tabelle F) | ❌ Ablehnen | Redundant: Zugriff auf die geteilte Datei ist bereits über die Berechtigungen des Cloud-Anbieters (iCloud-/Synology-Ordnerfreigabe) gesteuert — ein Nutzer, der keinen Ordnerzugriff mehr hat, kann ohnehin nicht mehr lesen/schreiben. Eine zusätzliche App-eigene Vertrauensliste mit Public-Key-Speicherung wäre nur relevant, falls MultipeerConnectivity (mit eigener, ordnerunabhängiger Discovery) umgesetzt würde — und selbst dann reicht ein einfacherer Mechanismus (Abschnitt 6). |
| **Überkauf-Erkennung** (§10) | ✅ Übernehmen (adaptiert) | Eigenständig wertvoll, unabhängig von der übrigen Infrastruktur umsetzbar. Das bestehende Dedupe-Verfahren in `Einkaufsvorgang.artikelAbhaken` verhindert bereits einen doppelten `KaufEintrag` — es fehlt nur die **Rückmeldung an den Menschen**, dass das gerade passiert ist. Siehe Abschnitt 5. |
| **Mehrere Listen über `listId`** (§13) | ➖ Nicht relevant | Die App unterstützt bereits mehrere benannte Einkaufslisten (`Einkaufsliste`) unabhängig von diesem Vorschlag. |
| **Android/BLE** (§13) | ➖ Nicht relevant | App ist iOS-only (siehe `docs/PRODUCT_SPEC.md` → „Nicht-Ziele"). |

## 4. Warum „nicht produktiv" die Bewertung zusätzlich stützt

Die App wird aktuell nicht produktiv genutzt (Nutzervorgabe, siehe Session-Kontext).
Das spricht doppelt gegen den großen Umbau:

1. **Kein akuter Schmerzpunkt belegt.** Der eigentliche Live-Test des bestehenden
   Lease-Verfahrens mit mehreren echten Geräten steht noch aus — es ist nicht
   bekannt, ob die 5–30s-Cloud-Latenz beim gemeinsamen Einkaufen überhaupt als
   Problem auffällt, bevor dafür eine komplette Zweitarchitektur gebaut wird.
2. **Migrationsrisiko ohne Gegenwert.** Ein GRDB-Rewrite würde exakt die Art von
   stillem, schwer rückgängig zu machendem Datenverlust-Risiko erzeugen, das erst
   kürzlich beim Entfernen von `Regal` real aufgetreten ist (siehe
   `docs/DECISIONS.md` → „Regal-Entfernung") — nur diesmal für die komplette
   Datenbasis statt für ein einzelnes Feature.

## 5. Übernommene Idee: Überkauf-Hinweis (angepasst an die bestehende Architektur)

### 5.1 Warum das ohne CRDT/Event-Log funktioniert

Weil es nur **eine** geteilte Datei gibt (Abschnitt 2), ist die im Vorschlag
beschriebene Situation „zwei Geräte haken denselben Artikel im selben
Einkaufsvorgang ab" bereits heute strukturell auf **einen** `Einkaufsvorgang`
(dasselbe SwiftData-Objekt) bezogen, nicht auf zwei divergierende Kopien. Die
bestehende Dedupe-Prüfung in `Einkaufsvorgang.artikelAbhaken(_:context:)`
verhindert bereits zuverlässig einen doppelten `KaufEintrag` — sie tut das aber
**stillschweigend** (`return` ohne Rückmeldung an die UI). Genau diese fehlende
Rückmeldung ist die Lücke, die Vorschlag §10 eigentlich adressiert — nicht die
fehlende Datenintegrität.

### 5.2 Datenmodell (additiv, kein neues `SchemaVN` nötig)

**`ShopWithMe/Models/KaufEintrag.swift`** — ein neues optionales Feld, analog dem
bestehenden `alternativerName`/`produktName`-Muster:

```swift
/// Anzeigename des Geräts, auf dem dieser Kauf abgehakt wurde (siehe
/// ``DatabaseLeaseService/geraeteName``) — Grundlage für den Überkauf-Hinweis,
/// wenn ein anderes Gerät denselben Artikel kurz zuvor bereits abgehakt hat.
/// `nil` für vor diesem Feature angelegte Einträge (harmlos: kein Hinweis ohne
/// bekannten Verursacher).
var abgehaktVonGeraet: String?
```

Keine neue `SchemaVN`/`MigrationStage` nötig — rein additiv-optional, identisches
Muster wie bereits mehrfach in diesem Projekt verwendet (siehe
`docs/DECISIONS.md`).

### 5.3 Geräte-Identität wiederverwenden statt neu erfinden

`DatabaseLeaseService.geraeteName` (`UIDevice.current.name`) existiert bereits
und identifiziert das Gerät schon heute in der Lease-Lock-Datei. Für den
Überkauf-Hinweis wird exakt dieselbe Property wiederverwendet — kein neues
Einstellungsfeld, kein neuer Wiederholungscode.

### 5.4 Logikänderung

**`ShopWithMe/Models/Einkaufsvorgang.swift`**, `artikelAbhaken(_:context:)`:

- Beim Anlegen eines neuen `KaufEintrag`: `abgehaktVonGeraet:
  DatabaseLeaseService.geraeteName` setzen.
- Der bestehende Dedupe-Zweig (`if let anzahl = try? context.fetchCount(...),
  anzahl > 0`) liefert aktuell keine Information darüber, *wer* den Artikel
  bereits abgehakt hat. Funktion bekommt einen Rückgabewert:

```swift
enum AbhakErgebnis {
    case abgehakt
    case bereitsAbgehaktVon(geraet: String?)
}

@discardableResult
func artikelAbhaken(_ artikel: Artikel, context: ModelContext) -> AbhakErgebnis {
    // ... bestehende Dedupe-Prüfung ...
    if let anzahl = try? context.fetchCount(deskriptor), anzahl > 0 {
        DatabaseDebugLogger.log(.dedupeConflictDetected, details: "artikelAbhaken: \(artikel.name)")
        if let listenEintrag { context.delete(listenEintrag) }
        let bestehender = (try? context.fetch(deskriptor))?.first
        return .bereitsAbgehaktVon(geraet: bestehender?.abgehaktVonGeraet)
    }
    // ... bestehendes Anlegen, jetzt mit abgehaktVonGeraet: DatabaseLeaseService.geraeteName ...
    return .abgehakt
}
```

`@discardableResult`, damit bestehende Aufrufer (z.B. im Lernmodus-Pfad) ohne
Anpassung weiterlaufen.

### 5.5 UI

**`ShopWithMe/Views/Einkaufen/EinkaufenView.swift`**, `umschalten(_:)`
(Abhak-Handler): Bei `.bereitsAbgehaktVon(let geraet)` einen kurzen, nicht
blockierenden Hinweis zeigen (z.B. ein `Toast`/`Alert` „Bereits von
{Gerätename} abgehakt" bzw. „von einem anderen Gerät" falls `geraet == nil`).
Kein Bestätigungsdialog mit „behalten/zurückgelegt" wie im Originalvorschlag —
das wäre zusätzlicher Zustand ohne belegten Bedarf (YAGNI); ein reiner
Informations-Hinweis deckt den eigentlichen Zweck („nicht versehentlich doppelt
einkaufen") vollständig ab. Kann bei tatsächlichem Bedarf später ergänzt werden.

### 5.6 Tests

`ShopWithMeTests/EinkaufsvorgangTests.swift`: neuer Test, der zwei
`artikelAbhaken`-Aufrufe für denselben Artikel im selben `Einkaufsvorgang`
simuliert (wie der bestehende Dedupe-Test) und prüft, dass der zweite Aufruf
`.bereitsAbgehaktVon` mit dem beim ersten Aufruf gesetzten `abgehaktVonGeraet`
liefert.

### 5.7 Aufwand

Klein: eine additive Modell-Änderung, eine Funktionssignatur-Erweiterung
(rückwärtskompatibel), ein UI-Hinweis, ein Test. Kein neuer Service, keine neue
Infrastruktur, kein Migrationsrisiko.

## 6. Multipeer/Presence — Bedingung für spätere Aufnahme

Nicht Teil des jetzigen Umsetzungsplans. Sollte künftig erwogen werden, wenn:

1. der ausstehende Live-Test des Lease-Verfahrens mit echten Geräten
   durchgeführt wurde (Voraussetzung, um zu wissen, ob die Cloud-Sync-Latenz
   real ein Problem ist), **und**
2. beim tatsächlichen gemeinsamen Einkaufen wiederholt spürbare Verzögerung
   auftritt.

Fiele diese Entscheidung, wäre Multipeer als **zusätzlicher, rein
beschleunigender Kanal** neben dem bestehenden Lease-Verfahren sinnvoll (Events
sofort an verbundene Peers spiegeln, geteilte Datei bleibt Quelle der
Wahrheit) — nicht als Ersatz der Persistenzschicht. Die
Vertrauensprüfung könnte dabei einfacher als im Vorschlag ausfallen: der
Service-Name kann direkt (wie in §7.2 vorgeschlagen) von der `listId`
abgeleitet werden, ganz ohne eigene `trusted_peers`-Tabelle mit
Public-Key-Verwaltung — Zugriff auf die geteilte Datei (und damit Kenntnis der
`listId`) ist bereits das Vertrauensmerkmal.

## 7. Empfehlung für Issue #39

Issue #39 in seiner jetzigen Form (vollständiger GRDB/CRDT/Multipeer-Vorschlag)
nicht umsetzen. Vorschlag für die Bearbeitung des Issues selbst: mit Verweis auf
dieses Dokument kommentieren und den Scope auf die Überkauf-Erkennung (Abschnitt 5)
reduzieren — entweder durch Umbenennen/Anpassen von #39 selbst, oder durch Schließen
von #39 zugunsten eines neuen, klar umrissenen Issues „Überkauf-Hinweis beim
gemeinsamen Einkaufen". Multipeer/Presence (Abschnitt 6) als eigenständiges,
zurückgestelltes Issue mit expliziter Bedingung („nach Live-Test, nur falls
Cloud-Latenz real stört") festhalten, statt es unkommentiert fallen zu lassen.
