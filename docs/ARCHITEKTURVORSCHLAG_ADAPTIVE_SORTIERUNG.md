# Architekturvorschlag: Adaptive Einkaufslistenoptimierung
**Dokument:** Architekturvorschlag
**Version:** 1.0
**Status:** Zur Umsetzung
**GitHub:** Haupt-Feature #36, Regal-Entfernung als eigenständiges Vorgänger-/Folge-Issue #35

---

## 1. Kontext und Zielsetzung

### 1.1 Problemstellung
Bestehende Einkaufs-Apps sortieren Listen manuell oder alphabetisch. Nutzer laufen dadurch suboptimale Wege durch den Supermarkt – sie springen zwischen Bereichen, kehren um, und vergessen Artikel.

### 1.2 Ziel
Erweiterung der bestehenden App um ein selbstlernendes Modul, das:
- die Reihenfolge einer Einkaufsliste automatisch optimiert
- sich den Laufweg eines spezifischen Ladens durch Nutzungsverhalten erlernt
- ohne Ladenplan, GPS, Kamera oder externe Datenquellen auskommt
- ausschließlich auf der **Abhakreihenfolge von Abteilungen** basiert

### 1.3 Abgrenzung
Das Modul ersetzt keine bestehende Listenverwaltung. Es ist ein reines Sortier- und Lernmodul, das sich in den bestehenden Einkaufsfluss einbettet.

---

## 2. Kernkonzept

### 2.1 Das Lernprinzip
Jedes Mal, wenn ein Nutzer einen Artikel abhakt, entsteht ein implizites räumliches Signal: Artikel, die zeitlich nah abgehakt werden, liegen räumlich nah im Laden.

Aus der Abhakreihenfolge vieler Einkäufe lernt der Algorithmus eine **Distanzmatrix auf Abteilungs-Ebene** – eine numerische Annäherung daran, wie nah zwei Abteilungen im jeweiligen Laden beieinander liegen.

Diese Matrix ist:
- **ladenspezifisch** – jeder Laden bekommt seine eigene Matrix
- **selbstheilend** – Ladenumbauten werden durch neue Einkäufe automatisch korrigiert
- **robust** – einzelne Ausreißer (Rückläufer, Pausen) verfälschen das Modell nicht
- **anonym** – es werden keine Positionsdaten, nur Reihenfolgen gespeichert

### 2.2 Abteilungen als Abstraktionsebene
Individuelle Artikel wechseln (Sonderangebote, Neuprodukte). Abteilungen bleiben stabil. Die gesamte Lernlogik operiert auf Abteilungs-IDs, nicht auf Artikel-IDs. Die Zuordnung Artikel → Abteilung wird als bekannt vorausgesetzt und ist bereits in der App vorhanden.

---

## 3. Datenmodell

### 3.1 Neue Entitäten
```
LadenProfil
  ladenId:          string        // eindeutiger Bezeichner des Ladens
  name:             string
  distanzMatrix:    DistanzMatrix
  einkaufsAnzahl:   integer       // Anzahl abgeschlossener Einkäufe
  letzteAktualisierung: timestamp
  umbauVerdacht:    boolean       // Flag bei erkannter Layoutänderung

DistanzMatrix
  // Symmetrische Matrix: abteilungId → abteilungId → float [0..1]
  // 0 = sehr nah, 1 = sehr weit, 0.5 = unbekannt (Initialwert)
  eintraege: Map<string, Map<string, float>>

AbhakVorgang
  abteilungId:    string
  zeitstempel:      timestamp     // für Zeitgewichtung
```

### 3.2 Erweiterung bestehender Entitäten
```
Einkauf (bestehend, erweitert)
  + ladenId:            string
  + abhakvorgaenge:     AbhakVorgang[]  // wird während Einkauf aufgebaut
  + lernungAbgeschlossen: boolean
```

---

## 4. Algorithmen

### 4.1 Lernalgorithmus
Wird nach jedem abgeschlossenen Einkauf aufgerufen.

**Eingabe:** Geordnete Liste von `AbhakVorgang`-Objekten
**Ausgabe:** Aktualisierte `DistanzMatrix`

**Logik:**
Für jedes Paar `(i, j)` mit `i < j` aus der Abhakreihenfolge:

1. **Positionsbasierte Distanz** berechnen:
   ```
   posDistanz = (j - i) / Gesamtanzahl
   ```
2. **Zeitbasierte Distanz** berechnen:
   ```
   zeitDelta = zeitstempel[j] - zeitstempel[i]
   wenn zeitDelta > 5 Minuten:
     zeitDistanz = null  // Signal wertlos, verwerfen
   sonst:
     zeitDistanz = min(zeitDelta, 5min) / 5min  // normiert [0..1]
   ```
3. **Kombinierte Distanz:**
   ```
   wenn zeitDistanz == null:
     distanz = posDistanz
   sonst:
     distanz = 0.7 × posDistanz + 0.3 × zeitDistanz
   ```
4. **Gleitender Durchschnitt** in die Matrix eintragen:
   ```
   alterWert = matrix[a][b]  // default 0.5
   neuerWert = alterWert × (1 - lernrate) + distanz × lernrate
   matrix[a][b] = matrix[b][a] = neuerWert
   ```

**Lernrate:** `0.1` (entspricht ~10% Gewicht des neuen Einkaufs gegenüber der Erfahrung). Kann nach Umbau-Erkennung temporär auf `0.3` erhöht werden.

**Wichtig:** Nur Paare werden gelernt, bei denen beide Abteilungen auf der Einkaufsliste standen – kein Rauschen durch zufällige Beobachtungen.

---

### 4.2 Sortieralgorithmus
Wird beim Start jedes Einkaufs und nach jeder Abhakung aufgerufen.

**Eingabe:** Liste offener Abteilungen, aktuelle `DistanzMatrix`
**Ausgabe:** Sortierte Liste (optimale Reihenfolge)

**Phase 1 – Greedy Nearest Neighbor:**
```
startPunkt = erste Abteilung mit niedrigstem Durchschnittswert
             in der Matrix (= am wahrscheinlichsten nahe Eingang)
pfad = [startPunkt]
remaining = alle anderen Abteilungen
wiederhole bis remaining leer:
  aktuell = letztes Element in pfad
  naechster = Abteilung aus remaining mit kleinster distanz zu aktuell
  pfad.append(naechster)
  remaining.remove(naechster)
```

**Phase 2 – 2-opt Verbesserung:**
```
wiederhole bis keine Verbesserung mehr:
  für jedes Paar (i, j) im Pfad:
    tausche das Segment zwischen i und j (umkehren)
    wenn Gesamtdistanz kleiner: behalte Tausch
    sonst: rückgängig machen
```

**Laufzeit:** Für typische Einkaufslisten (5–30 Abteilungen) unter 10ms. Kein Performance-Problem.

**Konfidenz-Schwelle:** Wenn `einkaufsAnzahl < 3`, Liste unsortiert ausgeben mit UI-Hinweis „Noch zu wenig Daten für diesen Laden."

---

### 4.3 Dynamische Neusortierung während des Einkaufs
Nach jeder Abhakung wird der Sortieralgorithmus auf der **verbleibenden Liste** neu ausgeführt. Der aktuelle Standort des Nutzers ist implizit die zuletzt abgehakte Abteilung.

```
nach Abhakung von Abteilung X:
  startPunkt = X  // Nutzer ist hier
  sortiereNeu(verbleibendeListe, startPunkt, distanzMatrix)
```

Dies erlaubt Korrekturen wenn der Nutzer vom vorgeschlagenen Weg abweicht, ohne dass der Algorithmus in einen Fehlerzustand gerät. Abweichungen sind Lernsignal, kein Problem.

---

### 4.4 Umbau-Erkennung
Wird nach jedem Einkauf geprüft.

```
berechne erwartete Distanz für direkt aufeinanderfolgende Abhakpaare
berechne tatsächliche Distanz (normiert)
abweichung = Durchschnitt der Differenzen aller aufeinanderfolgenden Paare
wenn abweichung > 0.3:
  setze ladenProfil.umbauVerdacht = true
  erhöhe lernrate temporär auf 0.3
  zeige Hinweis im UI: "Hat sich im Laden etwas verändert?"
```

Nach 5 weiteren Einkäufen ohne hohe Abweichung: `umbauVerdacht = false`, Lernrate zurück auf `0.1`.

---

## 5. Systemarchitektur

### 5.1 Modulübersicht
```
┌─────────────────────────────────────────────────┐
│                   App (bestehend)               │
│                                                 │
│  ┌──────────────┐      ┌─────────────────────┐  │
│  │ Listenansicht│      │  Einkaufsmodus      │  │
│  │  (bestehend) │      │  (bestehend)        │  │
│  └──────┬───────┘      └──────────┬──────────┘  │
│         │                        │              │
│         ▼                        ▼              │
│  ┌──────────────────────────────────────────┐   │
│  │         NavigationsModul (NEU)           │   │
│  │                                          │   │
│  │  ┌─────────────┐  ┌──────────────────┐  │   │
│  │  │  Lernmodul  │  │  Sortiermodul    │  │   │
│  │  │             │  │                  │  │   │
│  │  │ lerneEinkauf│  │ sortiereList     │  │   │
│  │  │ erkenneUmbau│  │ neusortiereRest  │  │   │
│  │  └──────┬──────┘  └────────┬─────────┘  │   │
│  │         │                  │            │   │
│  │         ▼                  ▼            │   │
│  │  ┌──────────────────────────────────┐   │   │
│  │  │         DistanzMatrix-Store      │   │   │
│  │  │    (pro Laden, lokal persistent) │   │   │
│  │  └──────────────────────────────────┘   │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

### 5.2 Datenpersistenz
Die Distanzmatrix wird **lokal auf dem Gerät** gespeichert. Es ist kein Backend erforderlich für den Grundbetrieb.

Empfohlene Speicherung: strukturiertes JSON im lokalen App-Storage, indexiert nach `ladenId`.

Optional für spätere Erweiterung: serverseitiges Crowdsourcing (mehrere Nutzer eines Ladens teilen eine gemeinsame Matrix). Dieses Dokument beschreibt nur die lokale Variante.

---

## 6. Integration in den App-Fluss

### 6.1 Einkauf starten
```
Nutzer wählt Laden aus (oder legt neuen an)
  → LadenProfil laden oder neu erstellen
  → wenn einkaufsAnzahl ≥ 3:
      Liste sortieren via Sortiermodul
      UI zeigt sortierte Liste
  → sonst:
      Liste unsortiert anzeigen
      UI-Hinweis: "Sortierung verbessert sich mit jedem Einkauf"
```

### 6.2 Während des Einkaufs
```
Nutzer hakt Artikel ab
  → Abteilung des Artikels bestimmen
  → AbhakVorgang {abteilungId, timestamp} an aktuelle Session anhängen
  → Restliste neu sortieren (Startpunkt = aktuelle Abteilung)
  → UI aktualisieren
```

### 6.3 Einkauf abschließen
```
Nutzer beendet Einkauf
  → lerneEinkauf(abhakvorgaenge, distanzMatrix)
  → erkenneUmbau(abhakvorgaenge, distanzMatrix)
  → einkaufsAnzahl++
  → LadenProfil speichern
  → ggf. UI-Hinweis bei Umbau-Verdacht anzeigen
```

---

## 7. UI-Anforderungen
Das Modul erfordert minimale UI-Änderungen:

| Situation | UI-Element |
|---|---|
| Laden neu, < 3 Einkäufe | Hinweis: „Lernt noch – Reihenfolge unoptimiert" |
| Laden bekannt, ≥ 3 Einkäufe | Subtiles Icon zeigt „Reihenfolge optimiert" |
| Umbau erkannt | Dialog: „Hat sich etwas geändert? Wir passen uns an." |
| Neusortierung während Einkauf | Listenpositionen animiert neu sortieren |

Die Sortierung soll für den Nutzer sichtbar, aber nicht aufdringlich sein. Keine Erklärung des Algorithmus notwendig.

---

## 8. Nicht-funktionale Anforderungen

| Anforderung | Ziel |
|---|---|
| Laufzeit Sortierung | < 50ms für Listen bis 50 Artikel |
| Laufzeit Lernschritt | < 100ms nach Einkaufsabschluss |
| Speicherverbrauch Matrix | < 50KB pro Laden (bei ~50 Abteilungen) |
| Offline-Fähigkeit | vollständig offline, kein Backend erforderlich |
| Datenschutz | keine Positionsdaten, keine personenbezogenen Daten in Matrix |

---

## 9. Offene Punkte und Erweiterungsmöglichkeiten
Die folgenden Punkte sind bewusst ausgeklammert und können in späteren Iterationen adressiert werden:

**Crowdsourcing:** Mehrere Nutzer desselben Ladens könnten ihre Matrizen aggregieren, um die Lernphase zu verkürzen. Erfordert Backend und Datenschutzkonzept.

**Eingang als Ankerpunkt:** Wenn der Eingang eines Ladens als fester Startpunkt markiert wird, verbessert sich die Sortierung in der Anfangsphase deutlich. Könnte optional durch den Nutzer bestätigt werden.

**Abteilungs-Hierarchie:** Aktuell sind alle Abteilungen gleichwertig. Eine Hierarchie (z.B. „Kühlwaren" als Oberabteilung von „Milch" und „Joghurt") könnte die Matrix kompakter und robuster machen.

**Explizites Feedback:** Nutzer könnte Sortiervorschlag manuell korrigieren – diese Korrekturen wären hochwertige Lernsignale mit erhöhter Lernrate.

---

## 10. Zusammenfassung
Das Modul benötigt keine externen Daten, keine Infrastruktur und keinen Ladenplan. Es lernt ausschließlich aus dem, was bereits passiert: dem Abhaken von Artikeln. Die Implementierung ist in sich geschlossen, seiteneffektfrei gegenüber bestehenden Funktionen und jederzeit deaktivierbar.

Der einzige kritische Integrationspunkt ist die **Abteilungs-Zuordnung** je Artikel – diese wird als in der App vorhanden vorausgesetzt.

---

## 11. Umsetzbarkeitsprüfung gegen das aktuelle Datenmodell

**Ergebnis vorweg: umsetzbar, und deutlich günstiger als der Vorschlag annimmt** — ein großer Teil der vorausgesetzten Infrastruktur existiert bereits, nur auf einem einfacheren Aggregationsniveau (Einzelwert statt Distanzmatrix).

### 11.1 Direkte Entsprechungen (kein neues Modell nötig)

| Vorschlag | Entspricht in ShopWithMe | Bewertung |
|---|---|---|
| Abteilung | `Abteilung` | Exakte Entsprechung — bereits die "stabile Abstraktionsebene" (siehe `Artikel/abteilungen`, `Geschaeft/verfuegbareAbteilungen`). Artikel→Abteilung-Zuordnung ist erfüllt. |
| LadenProfil | `Geschaeft` | Bereits vorhanden. `einkaufsAnzahl` entspricht bereits `Geschaeft.anzahlEinkaufsvorgaenge` (GitHub #30). |
| Einkauf | `Einkaufsvorgang` | Bereits vorhanden, inkl. `geschaeft`-Bezug ("ladenId"). `lernungAbgeschlossen` ist unnötig als Feld: `ShelfOrderLearningService.lernenAus(_:context:)` wird bereits synchron beim `abschliessen()` aufgerufen (`EinkaufenView.einkaufAbschliessen()`), kein Zwischenzustand nötig. |
| AbhakVorgang | `KaufEintrag` | **Wichtigster Befund:** `KaufEintrag` trägt bereits `abteilung` (→ abteilungId), `datum` (→ zeitstempel, wird beim Abhaken automatisch mit `Date()` gesetzt) und `abteilungBesuchsIndex` (→ die Positions-Reihenfolge selbst, pro Abteilung eines Einkaufsvorgangs eindeutig und bereits dedupliziert über mehrere Artikel derselben Abteilung hinweg). Für den Lernalgorithmus reicht ein Fetch aller `KaufEintrag` eines `Einkaufsvorgang`s, gruppiert nach `abteilungBesuchsIndex`. |

### 11.2 Fehlende Bausteine (echte neue Arbeit)

- **DistanzMatrix** — existiert nicht. Die aktuelle `AbteilungBesuchsStatistik` speichert nur einen **einzelnen Skalar** (`durchschnittlichePosition` je Abteilung+Geschäft), keine paarweisen Distanzen. Das ist der Kern der neuen Arbeit: ein neues `@Model` (Arbeitstitel `WarengruppenDistanz`) mit `geschaeft`, `abteilungA`, `abteilungB` (kanonisch sortiertes Paar, um Symmetrie ohne doppelte Zeilen abzubilden) und `distanz: Double`.
- **Umbau-Erkennung** — existiert nicht, aber additiv ergänzbar: neues optionales Feld auf `Geschaeft` nach dem etablierten Muster (`private var umbauVerdachtRaw: Bool?` + Computed Property mit Fallback `false`), keine neue `VersionedSchema` nötig (siehe `docs/DECISIONS.md`).
- **Greedy-NN + 2-opt-Sortierung** — existiert nicht (aktuell nur eine einfache Sortierung nach Einzelwert, siehe `EinkaufenView.istVor(_:_:positionen:)`). Reine Swift-Logik ohne Datenmodell-Auswirkung, gut isolierbar.
- **Dynamische Neusortierung nach jedem Abhaken** — aktuell sortiert `EinkaufenView` die Abteilung-Gruppen zwar reaktiv (SwiftUI), aber ohne "aktueller Standort = zuletzt abgehakte Abteilung" als Startpunkt für die Restliste. Muss ergänzt werden.

### 11.3 Persistenz: SwiftData statt lokalem JSON

Der Vorschlag empfiehlt (§5.2) strukturiertes JSON im App-Storage. Für ShopWithMe ist ein natives `@Model` (wie bei `AbteilungBesuchsStatistik`) konsistenter mit dem Rest der App (SwiftData als einzige Quelle der Wahrheit, siehe `ios-swift-engineering`-Skill) und bringt automatisches iCloud-Backup/Synchronisation über denselben Store mit, ohne einen zweiten Persistenzmechanismus einzuführen. Empfehlung: **von §5.2 abweichen**, die Matrix als normalisierte SwiftData-Zeilen (eine je Abteilung-Paar) statt als JSON-Blob speichern.

### 11.4 Reibungspunkt: Verhältnis zu `Regal`/`ShelfOrderLearningService`

Der Vorschlag geht implizit von einer Abteilungs-Ebene ohne "Regal"-Zwischenschicht aus. Im aktuellen Datenmodell existiert aber `Regal` als zusätzliche, manuell zu pflegende Gruppierungsebene zwischen Abteilung und Sortierreihenfolge (`Geschaeft.regale`, `Regal.sortIndex`, `RegalSortierModus`). Die vorgeschlagene Distanzmatrix arbeitet direkt auf Abteilungen — ein `Regal`, das mehrere Abteilungen physisch bündelt, passt nicht zu einem Modell, das paarweise Distanzen *zwischen* Abteilungen lernt (zwei Abteilungen im selben Regal könnten trotzdem unterschiedlich "nah" zu einer dritten sein). Details und Entscheidung siehe Abschnitt 13.

---

## 12. Umsetzungsplan

Empfohlene Reihenfolge — jede Phase einzeln build- und testbar, damit die App zwischen den Phasen durchgehend funktionsfähig bleibt:

### Phase 1 — Datenmodell
- Neues `Models/WarengruppenDistanz.swift`: `@Model final class WarengruppenDistanz` mit `geschaeft: Geschaeft?`, `abteilungA: Abteilung?`, `abteilungB: Abteilung?`, `distanz: Double`. Fetch-or-create-Helfer analog `AbteilungBesuchsStatistik`/`Abteilung.sonstige(context:)`.
- `Geschaeft`: additives `private var umbauVerdachtRaw: Bool?` + Computed Property `umbauVerdacht` (Fallback `false`), analog `regalSortierModusRaw`.
- `SchemaDefinition.swift`: `WarengruppenDistanz.self` ergänzen.

### Phase 2 — Lern-Service
- Neuer `Services/AbteilungsDistanzService.swift` (eigene Datei statt Erweiterung von `ShelfOrderLearningService`, da fachlich ein neuer, in sich geschlossener Algorithmus): `lerneAusEinkauf(_:context:)` implementiert Abschnitt 4.1 (paarweise Positions-/Zeit-Distanz, gleitender Durchschnitt, Lernrate 0.1/0.3) unter Verwendung von `KaufEintrag.abteilung`/`.datum`/`.abteilungBesuchsIndex`.
- `erkenneUmbau(_:context:)` implementiert Abschnitt 4.4, setzt `Geschaeft.umbauVerdacht`.
- Aufruf aus `EinkaufenView.einkaufAbschliessen()` zusätzlich zum bestehenden `ShelfOrderLearningService.lernenAus(...)` (oder als dessen Ersatz, siehe Phase 5).

### Phase 3 — Sortier-Algorithmus
- Neue reine Funktion (z.B. `AbteilungsDistanzService.sortiere(offeneAbteilungen:startpunkt:distanzMatrix:)`), implementiert Greedy-Nearest-Neighbor + 2-opt (Abschnitt 4.2) auf `[Abteilung]`.
- Konfidenz-Schwelle: `einkaufsAnzahl < 3` → unsortiert + UI-Hinweis (Text nach Vorschlag §7). Hinweis: Der bestehende `ShelfOrderLearningService.mindestEinkaeufeFuerVorschlag` verwendet aktuell `5`; für Konsistenz beide Schwellen angleichen oder bewusst als zwei unabhängige Konstanten dokumentieren.

### Phase 4 — Dynamische Neusortierung + UI
- `EinkaufenView.sonstigeGruppen` (bzw. deren Nachfolger nach Phase 5) nutzt den neuen Sortieralgorithmus statt `istVor(_:_:positionen:)`; Startpunkt = zuletzt abgehakte Abteilung (Abschnitt 4.3).
- UI-Hinweise gemäß Abschnitt 7 (Statuszeile "Lernt noch"/"optimiert", Umbau-Dialog).

### Phase 5 — Ablösung von `Regal`
- Siehe Abschnitt 13 — als **eigenständiges GitHub-Issue** behandelt, da der Umfang (siehe dort) den der eigentlichen Sortier-Funktion übersteigt und unabhängig sequenzierbar ist. Empfohlene Reihenfolge: Phase 1–4 zuerst abschließen (liefert bereits den vollen Nutzen für Geschäfte ohne Regale, ohne Funktionsverlust für Geschäfte mit Regalen), erst danach `Regal` entfernen, damit zu keinem Zeitpunkt eine Lücke ohne jede automatische Sortierung entsteht.

### Phase 6 — Tests & Doku
- Unit-Tests für `AbteilungsDistanzService` (Lernalgorithmus, Sortieralgorithmus, Umbau-Erkennung) nach demselben Muster wie `ShelfOrderLearningServiceTests.swift`.
- CHANGELOG/BEDIENUNGSANLEITUNG pflegen.

---

## 13. Entfernung von `Regal` aus der App

**Separates GitHub-Issue mit vollständiger Begründung: [#35](https://github.com/McBoerny/ShopWithMe/issues/35).** Diese Sektion dokumentiert nur die Kurzfassung der Entscheidung; die Begründung im Detail steht im Issue.

**Kernargument:** `Regal` ist eine manuell zu pflegende Zwischenschicht (Anlegen, Umbenennen, Abteilungen zuordnen, Reihenfolge ziehen) für genau das Problem, das die adaptive Sortierung aus Abschnitt 2–4 automatisch und ohne Pflegeaufwand löst — und zwar auf einer feineren, dynamischen Ebene (paarweise Distanzen statt starrer Gruppen). Nach Einführung der Abteilungs-Distanzmatrix hat `Regal` keinen Zweck mehr, den die neue Sortierung nicht besser abdeckt.

**Umfang der Entfernung** (Bestandsaufnahme, 26 betroffene Dateien): `Models/Regal.swift`, `RegalSortierModus`, `Geschaeft.regale`/`regalSortierModus`(Raw)/`regal(fuer:)`, `Abteilung.regale`, `Artikel.fuehrendeAbteilung`s Regal-Priorität, `Views/Geschaefte/RegalDetailView.swift`, `GeschaeftDetailView`s Regal-Sektion samt bedingtem `EditButton` (GitHub #28), `EinkaufenView.gruppen`/`sonstigeArtikel` (Regal-Pfad entfällt, `sonstigeGruppen`-Pfad wird der einzige), `NeueAbteilungSheet`/`AbteilungHinzufuegenSheet`/`ArtikelEditView`/`PreisschildScanView`/`AISuggestionService`/`ArtikelVerfuegbarkeitService`-Erwähnungen, `SchemaDefinition.swift`, sowie 6 betroffene Testdateien.

---

## 14. Geschäftsspezifisch gelernte Abteilung (GitHub-Nachfolgefund zu #36)

**Separates GitHub-Issue: [#93](https://github.com/McBoerny/ShopWithMe/issues/93).** Diese Sektion dokumentiert die Kurzfassung; Motivation und Diskussion stehen im Issue.

**Ausgangslage:** Seit Abschnitt 13/`fedf96b` (v0.9) zeigt `EinkaufenView` einen Artikel mit mehreren Abteilungen gleichzeitig in allen zugehörigen Abschnitten — bewusst, weil eine frühere Einzelauswahl über eine ungeordnete SwiftData-Relationship zwischen Sync-Zyklen sichtbar zwischen Abschnitten sprang. Nebeneffekt: der Fortschritts-Zähler im Titel (`<abgehakt>/<gesamt>`) zählt eindeutige Artikel, während die sichtbare Zeilenzahl durch die Mehrfachanzeige höher sein kann — Auslöser war ein Nutzerbericht „5 Artikel angezeigt, aber Zähler 0/4" auf der Liste „Urlaub".

**Beobachtung:** Seit derselben Änderung speichert jeder `KaufEintrag` bereits, aus welcher Abteilung tatsächlich abgehakt wurde (`abteilung`) sowie in welchem Geschäft (`geschaeft`) — die Rohdaten für eine geschäftsspezifische Auswertung lagen also vor, wurden aber nicht ausgewertet.

**Algorithmus** (`AbteilungsDistanzService.gelernteAbteilung(fuer:in:context:)`): zählt für ein (Artikel, Geschäft)-Paar die Häufigkeit je Abteilung über alle zugehörigen `KaufEintrag`e. Ergebnis nur, wenn:
- mindestens `mindestKaeufeFuerGelernteAbteilung` (5) Käufe vorliegen, UND
- die häufigste Abteilung mindestens `mehrheitsschwelleGelernteAbteilung` (80%) davon ausmacht.

Bewusst nicht rein prozentual ab dem ersten Kauf: ein einzelner Kauf wäre immer "100% Mehrheit" und würde einen einzelnen Fehltap (falsche Abteilung versehentlich angetippt) sofort ungefiltert übernehmen — die Mindestzahl von 5 zusammen mit der 80%-Schwelle filtert einen solchen Ausreißer heraus (5 Käufe mit 1 Fehltap ergeben 80% — genau an der Schwelle; 2 Fehltaps ergeben 60%, deutlich darunter). Bewusst kein gleitender Durchschnitt wie bei der Distanzmatrix (Abschnitt 4.1) — hier soll das Ergebnis jederzeit exakt der aktuellen Kaufhistorie entsprechen. Bewusst auch keine dauerhafte Speicherung: die Auswertung läuft bei jedem Aufruf neu über die aktuellen `KaufEintrag`e, sodass sich eine einmal fälschlich erkannte Mehrheit durch weitere (auch über Sync eintreffende) Käufe von selbst wieder korrigiert — zusätzlich zur manuellen Korrekturmöglichkeit über den Lernmodus (siehe Integrationspunkte).

**Herleitung der Schwellenwerte** (pragmatische Abschätzung, keine strenge Signifikanzprüfung — bei Haushalts-Kauffrequenz einzelner Artikel wäre eine klassische Stichprobengröße von ~30 unrealistisch, das würde Jahre dauern):
- Echte Vorliebe + ca. 10% gelegentliche Fehltap-Rate: P(≥4 von 5 korrekt) ≈ 92% — die Schwelle wird bei echtem Muster meist schon nach 5 Käufen erreicht.
- Tatsächlich 50/50 mehrdeutiger Artikel (kein echtes Muster): P(eine Seite erreicht ≥4/5 rein zufällig) ≈ 19% — ein spürbarer, aber tolerierbarer Anteil falscher Früh-Treffer. Bewusst in Kauf genommen: die Neuberechnung bei jedem Aufruf löst so einen Fehltreffer mit wachsendem `n` von selbst wieder auf, UND der Lernmodus bietet zusätzlich eine sofortige manuelle Korrekturmöglichkeit.

**Integrationspunkte:**
1. `EinkaufenView.abteilungenFuerAnzeige(_:)`: bei gewähltem Geschäft und gelernter Abteilung nur noch diese eine statt `Artikel.effektiveAbteilungen(context:)` vollständig — außer im Lernmodus (`zeigeAlleArtikel`, langer Tap auf die Schnellauswahl): dort bewusst immer ungefiltert wie alle zugeordneten Abteilungen, analog zum bestehenden Bypass in `verfuegbarkeitsgefiltert(_:)`. Der Lernmodus ist damit die manuelle Korrekturmöglichkeit, falls die gelernte Abteilung (noch) nicht (mehr) stimmt.
2. `Artikel.fuehrendeAbteilung(inGeschaeft:context:)`: gelernte Abteilung als Top-Priorität vor der bisherigen, rein statischen `sortIndex`-Sortierung — wirkt sich auf Belegscan-/Preisschild-Scan-/Sync-Import-Zuordnung aus, die ohne konkret getappten Abschnitt auskommen müssen. Kein Lernmodus-Bypass hier, da diese Aufrufer keinen Bezug zu diesem UI-Zustand haben.

Rein anzeigeseitig/lesend: `Artikel.abteilungen` (die globalen Tags) bleiben unverändert, nichts wird automatisch umgeschrieben oder gelöscht — bei fehlender/nicht mehr ausreichender Datenlage oder aktivem Lernmodus blendet sich die Mehrfachanzeige einfach wieder ein.

---

## 15. Vollständig abgehakte Abteilung ans Ende der Liste (GitHub #176)

**Separates GitHub-Issue: [#176](https://github.com/McBoerny/ShopWithMe/issues/176).**

Die Bereichs-Sortierung aus Abschnitt 4.2/4.3 (alphabetisch bzw.
Distanzmatrix-basiert per Greedy-NN + 2-opt) bestimmt weiterhin die
Grundreihenfolge der offenen Abteilungen. Zusätzlich dazu wandert eine
Abteilungsgruppe, in der kein offener Artikel mehr übrig ist
(`AbteilungGruppe.istVollstaendigAbgehakt`), als **stabiler Nachbearbeitungsschritt**
ans Ende der Gesamtliste — unabhängig davon, welcher der beiden Sortiermodi
gerade die Grundreihenfolge geliefert hat. Der Schritt sortiert nur nach dem
Boolean "vollständig abgehakt ja/nein"; da Swifts `sorted(by:)` stabil ist,
bleibt die vom jeweiligen Modus bestimmte relative Reihenfolge innerhalb beider
Gruppen (offen/vollständig abgehakt) unangetastet — die Distanzmatrix-Logik
selbst musste dafür nicht angepasst werden.

Zusätzlich führt derselbe Fix eine bislang fehlende Sortierung *innerhalb*
einer Abteilungsgruppe ein (offene Artikel vor abgehakten, jeweils
alphabetisch) — siehe `docs/EINKAUFSLISTE_INTERAKTION.md` für Details.
Implementiert in `EinkaufslistenAnzeigeService.abteilungGruppen(...)`, keine
Datenmodell-/Sync-Änderung nötig.
