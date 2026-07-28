# Geteilte Datenbank für gemeinsames Einkaufen — Architektur (GitHub #50)

**Bezug:** [Issue #50](https://github.com/McBoerny/ShopWithMe/issues/50).

**Korrektur gegenüber der ursprünglichen Fassung dieses Dokuments:** Die erste
Fassung ging von „lokal bleibt immer die aktive Datenbank, Remote nur für
gelegentliches Backup" aus. Das war falsch priorisiert. Das eigentliche Ziel von
#50 ist **gemeinsames Einkaufen mit geteiltem, aktuellem Datenstand** — mehrere
Personen sehen dieselbe Einkaufsliste, denselben Abhak-Fortschritt. Dafür müssen
lokal und remote **synchron bleiben**, nicht nur gelegentlich abgeglichen werden.
Reines Backup/Restore (ohne laufende gemeinsame Nutzung) bleibt ein Nebennutzen,
aber nicht der Entwurfstreiber.

**Status: Architektur festgelegt, Umsetzung ausstehend (siehe Phasenplan, Abschnitt 8).**

---

## 1. Erneute Prüfung: Was #39 dazu bereits gezeigt hat

Zur Erinnerung, `docs/DATENSYNCHRONISATION_BEWERTUNG.md` Abschnitt 1–2: „Synchron
bleiben" ist in dieser App **bereits gelöst** — und zwar nicht durch Nachrichten
zwischen zwei Datenbanken, sondern dadurch, dass es bei gemeinsamem Einkaufen
**gar keine zwei Datenbanken gibt**:

- `DatabaseLocationService` kann den aktiven SwiftData-Store in einen vom Nutzer
  gewählten, lokal gespiegelten Cloud-Ordner (iCloud Drive, Synology Drive, …)
  verlegen. Zeigen zwei Geräte auf **denselben** Ordner, greifen beide auf
  **dieselbe** Datei zu — der Cloud-Anbieter synchronisiert sie dateisystemseitig,
  die App selbst muss nichts synchronisieren.
- `DatabaseLeaseService` (`docs/DATABASE_CONCURRENCY.md`) verhindert, dass zwei
  Geräte gleichzeitig in diese eine Datei schreiben und sie beschädigen
  (Single-Writer-Micro-Lease, Sekundenbruchteile Sperrdauer).
- Ergebnis: „synchron bleiben" ist kein Merge-Problem, weil nichts divergiert —
  es ist ein Schreibkoordinations-Problem, und das ist bereits gelöst.

**Das bestätigt sich erneut: Für den Anwendungsfall „gemeinsam einkaufen" ist
NICHT die in der ersten Doku-Fassung entworfene Backup/Merge-Architektur die
Lösung, sondern die bereits existierende „gemeinsamer Ordner + Lease"-Architektur.**
#50 muss diese also nicht ersetzen, sondern an einer konkreten Lücke ergänzen —
Abschnitt 2.

## 2. Die tatsächliche Lücke: das „Beitreten" ist heute ungeschützt

Code-Prüfung von `DatabaseLocationService.ordnerFestlegen(_:aktuelleStoreURL:)`
und `kopiereStoreDateien(von:nachOrdner:)`: Beim Verknüpfen eines Ordners wird der
lokale Store **immer** dorthin kopiert — existiert am Ziel bereits eine Datei
(gleichen Namens, `ShopWithMe.store`), wird sie ohne jede Prüfung oder Rückfrage
gelöscht und überschrieben:

```swift
if dateiManager.fileExists(atPath: zielDatei.path) {
    try dateiManager.removeItem(at: zielDatei)   // ← keine Prüfung, keine Rückfrage
}
try dateiManager.copyItem(at: quellDatei, to: zielDatei)
```

**Das ist der konkrete, heute schon bestehende Fehler, den #50 mit
„Ersetzen/Merge-Abfrage" beheben will:** Wenn Person A bereits einen geteilten
Ordner mit ihrer Einkaufsliste eingerichtet hat und Person B diesen Ordner in
ihren eigenen Einstellungen auswählt, um beizutreten, **löscht die App
stillschweigend Person As gesamte Datenbank** und ersetzt sie durch eine Kopie von
Person Bs (meist leerer oder anderer) lokaler Datenbank — Totalverlust ohne
Warnung. Das ist kein theoretisches Risiko, sondern der Standardfall beim
Onboarding einer zweiten Person.

## 3. Zielverhalten

Beim Verknüpfen eines Ordners (`ordnerFestlegen`) prüfen, ob dort bereits eine
**fremde** Datenbank liegt (siehe Abschnitt 3.1 zur Erkennung „fremd" vs. „eigene,
bereits verknüpfte"), und falls ja, statt stillem Überschreiben:

| Wahl | Verhalten |
|---|---|
| **Ersetzen** | Wie heute — lokale Kopie überschreibt das Ziel. Für den Fall, dass die Zieldatei nur eine leere Platzhalter-Struktur oder veraltete Daten ist, die bewusst verworfen werden sollen. |
| **Merge** | Lokale und Remote-Daten werden zusammengeführt (Abschnitt 5), das Ergebnis wird die neue geteilte Datei. Für den eigentlich erwarteten Fall: beide Personen hatten schon eigene Einkaufslisten/-historie. |
| **Abbrechen** | Ordner wird nicht verknüpft, nichts verändert. |

Nach Ersetzen oder Merge läuft **ab sofort alles über die bereits existierende
Lease-Architektur** — kein weiterer Sync-Mechanismus nötig, weil beide Geräte
danach dieselbe Datei verwenden (Abschnitt 1).

### 3.1 Woran erkennt die App „fremd" vs. „bereits meine eigene Verknüpfung"?

Wichtig, damit die Abfrage nicht bei jedem erneuten Öffnen der App am selben,
längst verknüpften Ordner nervt:

- Ist der gewählte Ordner **identisch** mit dem bereits über
  `gewaehlterOrdner()` hinterlegten (per Bookmark) → keine Abfrage, normales
  Verhalten (der Store dort ist ohnehin schon meiner).
- Ist der Ordner **neu** (noch nicht mein aktueller Speicherort) und enthält
  bereits eine `ShopWithMe.store`-Datei → das ist der Beitritts-/Konfliktfall,
  Abfrage erforderlich.
- Ist der Ordner neu und leer → keine Abfrage nötig, normales „an neuen Ort
  verschieben" wie heute.

## 4. Sicherheitsnetz

Vor **Ersetzen** und vor **Merge** automatisch eine Sicherungskopie des aktuellen
lokalen Stores anlegen (z.B. `Application Support/Backups/vor-beitritt-<Datum>.store`)
— macht eine unerwünschte Entscheidung rückgängig machbar. Nach den
Sicherheitsregeln dieses Environments zählen beide als schwer rückgängig zu
machende bzw. destruktive Aktionen und brauchen eine explizite Bestätigung in der
UI, keine stille Ausführung.

## 5. Merge — Design (aus der ersten Fassung übernommen, weiterhin gültig)

Der einzige Teil der ursprünglichen Analyse, der unverändert stimmt: *wie* man
zwei unabhängig entstandene Datenbanken zusammenführt, ändert sich nicht dadurch,
*wann* man es tut (beim Beitreten statt bei einem Backup-Restore).

### 5.1 Grundprinzip

Der Remote-Store (die Datei am Zielort) wird als **zweiter, read-only
`ModelContainer`** geöffnet (dieselbe `Schema`, andere `ModelConfiguration(url:)`).
Für jeden Modelltyp wird geprüft, ob ein „gleichwertiges" lokales Objekt bereits
existiert; wenn nicht, wird eine Kopie lokal angelegt. Referenzen zwischen
Objekten werden dabei auf die **lokalen** (ggf. schon vorhandenen) Gegenstücke
umgebogen. Das Ergebnis (der lokale Store nach dem Merge) wird anschließend an den
Zielort kopiert und wird dort zur neuen geteilten Wahrheit.

**Zentrale Erkenntnis, die das Risiko senkt:** Für fast jeden Modelltyp existiert
die nötige Gleichheits-Prüfung bereits im Code — Merge ist überwiegend eine
**Orchestrierung bestehender, bereits bewährter Bausteine**, keine neue
Fuzzy-Matching-Logik:

| Modell | Bereits vorhandenes Matching | Merge-Strategie |
|---|---|---|
| `GeschaeftTyp` | `GeschaeftTyp.mitNamen(_:symbolName:context:)` (fetch-or-create by name) | Direkt wiederverwendbar |
| `ArtikelKategorie` | `ArtikelKategorie.sonstige(context:)`-Muster (Name-Fetch) | Case-insensitiver Namensabgleich, sonst neu anlegen |
| `Geschaeft` | `GeschaeftErkennungService.istGleicherOrt(...)` (Name ODER Koordinaten) | Direkt wiederverwendbar |
| `Artikel` | `MilkForUsImportService`s Namensabgleich-Muster | Case-insensitiver Namensabgleich, sonst neu anlegen |
| `Einkaufsliste` | — (neu) | Namensabgleich; bei Konflikt beide behalten (unkritisch, Nutzer benennt danach um) |
| `EinkaufslistenEintrag` | `Einkaufsliste.artikelHinzufuegen(_:context:)` (idempotent) | Nach Artikel-/Listen-Merge einfach erneut „hinzufügen" aufrufen |
| `Einkaufsvorgang` | — (reine Historie) | Immer übernehmen (referenziert gemergtes `Geschaeft`/`Einkaufsliste`) |
| `KaufEintrag` | — (reine Historie) | Immer übernehmen, Referenzen (Artikel/Kategorie/Geschäft/Einkaufsvorgang) auf gemergte Ziele umbiegen |
| `WarengruppenDistanz` | `mergeDistanzMatrix`-Idee aus der #39-Analyse (§5.2) | Existiert der Eintrag lokal schon: gewichteter Mittelwert; sonst übernehmen |
| `IgnorierterArtikel` | — (neu) | Namens- + Geschäft-Abgleich, sonst übernehmen |
| `IgnorierterGeschaeftsVorschlag` | `GeschaeftErkennungService.istGleicherOrt(...)` | Direkt wiederverwendbar |

### 5.2 Reihenfolge (Abhängigkeiten zuerst)

1. `GeschaeftTyp`
2. `ArtikelKategorie` (referenziert `GeschaeftTyp`)
3. `Geschaeft` (referenziert `GeschaeftTyp`, `ArtikelKategorie`)
4. `Artikel` (referenziert `ArtikelKategorie`)
5. `Einkaufsliste`
6. `EinkaufslistenEintrag` (referenziert `Einkaufsliste`, `Artikel`)
7. `Einkaufsvorgang` (referenziert `Geschaeft`, `Einkaufsliste`)
8. `KaufEintrag` (referenziert `Artikel`, `Einkaufsvorgang`, `Geschaeft`, `ArtikelKategorie`)
9. `WarengruppenDistanz` (referenziert `Geschaeft`, `ArtikelKategorie`)
10. `IgnorierterArtikel` (referenziert `Geschaeft`)
11. `IgnorierterGeschaeftsVorschlag`

Während des Durchlaufs wird pro Typ eine Zuordnungstabelle
`[PersistentIdentifier (remote): PersistentIdentifier (lokal)]` aufgebaut — spätere
Schritte nutzen sie, um Relationship-Referenzen korrekt umzubiegen.

### 5.3 Bewusste Grenze

Zwei unabhängig entstandene Datenbanken können für „real dieselbe" Kategorie/denselben
Artikel unterschiedliche Namen verwenden (z.B. „Milch" vs. „Vollmilch") — das
Namens-Matching erkennt das nicht, es entstehen zwei separate Objekte. Für v1 wird
das bewusst in Kauf genommen (manuelles Zusammenführen danach über die ohnehin
vorhandene Kategorien-/Artikel-Verwaltung) statt eines fehleranfälligen
Ähnlichkeits-Abgleichs.

## 6. Voraussetzung, die jetzt an Bedeutung gewinnt

`docs/DATABASE_CONCURRENCY.md`s offener Punkt — ein echter Live-Test des
Lease-Verfahrens mit mehreren physischen Geräten gegen einen tatsächlich
installierten Cloud-Provider — war bisher „nice to have vor jeder Erweiterung".
Jetzt, wo #50 diese Architektur als **die** Grundlage für gemeinsames Einkaufen
festschreibt (statt einer bloß theoretischen Möglichkeit), sollte dieser Test
**vor oder parallel zu Phase 1** stattfinden — sonst wird eine Beitritts-Funktion
auf ein in der Praxis nie mit echten Geräten verifiziertes Fundament gebaut.

## 7. Was weiterhin nicht Ziel ist

- **Automatische, kontinuierliche Hintergrund-Synchronisation** über die
  bestehende Datei-Sync-des-Cloud-Anbieters hinaus — bewusst nicht Ziel (siehe
  #39-Bewertung). Für Latenzverbesserung siehe #49 (Multipeer, zurückgestellt,
  eigene Bedingungen).
- **Konfliktauflösung bei echtzeit-gleichzeitiger Bearbeitung** — das leistet
  weiterhin ausschließlich das Lease-Verfahren; Merge betrifft nur den einmaligen
  Beitritts-Moment.

## 8. Phasenplan

1. **Phase 0 — Live-Test (Voraussetzung, siehe Abschnitt 6):** bestehendes
   Lease-Verfahren mit zwei echten Geräten gegen einen echten Cloud-Ordner
   verifizieren, bevor darauf aufgebaut wird.
2. **Phase 1 — Konflikterkennung + Ersetzen:** `ordnerFestlegen` erkennt eine
   fremde Zieldatenbank (Abschnitt 3.1), fragt Ersetzen/Abbrechen (Merge noch
   nicht implementiert, aber schon als Option sichtbar mit „bald verfügbar" oder
   ausgegraut) — schließt sofort die in Abschnitt 2 beschriebene
   Datenverlust-Lücke, auch ohne fertigen Merge.
3. **Phase 2 — Merge, Stammdaten** (`GeschaeftTyp`, `ArtikelKategorie`, `Geschaeft`,
   `Artikel`, `Einkaufsliste`): nutzt ausschließlich bereits vorhandene
   Matching-Bausteine (Tabelle in 5.1).
4. **Phase 3 — Merge, abhängige/historische Daten**
   (`EinkaufslistenEintrag`, `Einkaufsvorgang`, `KaufEintrag`,
   `WarengruppenDistanz`, `IgnorierterArtikel`, `IgnorierterGeschaeftsVorschlag`):
   nutzt die in Phase 2 aufgebauten Zuordnungstabellen.
5. **Phase 4 — UI-Politur:** Zusammenfassung „X neue Kategorien, Y neue Artikel, Z
   neue Käufe übernommen" nach einem Merge, statt eines stillen Abschlusses.

**Phase 1 ist die dringendste** — sie behebt einen echten, bereits vorhandenen
Datenverlust-Bug im Beitritts-Weg, unabhängig davon, ob/wann Merge folgt. Bis
Merge fertig ist, bleibt „Ersetzen" (mit vorherigem automatischem Backup, Abschnitt 4)
die einzige Option für den Beitritts-Fall — nicht ideal, aber immnoch weit
sicherer als das heutige stille Überschreiben ohne jede Rückfrage.
