# Datenbank-Backup, -Restore und -Merge — Architektur (GitHub #50)

**Bezug:** [Issue #50](https://github.com/McBoerny/ShopWithMe/issues/50). Auf ausdrücklichen
Wunsch mit derselben Gründlichkeit behandelt wie
`docs/DATENSYNCHRONISATION_BEWERTUNG.md` (GitHub #39) — als dauerhafte, nicht als
provisorische Lösung, und als erster Baustein für spätere Mehrgeräte-Fähigkeit
(siehe Abschnitt 10, Verhältnis zu #48/#49).

**Status: Architektur festgelegt, Umsetzung ausstehend (siehe Phasenplan, Abschnitt 12).**

---

## 1. Ausgangslage: Issue #50 vs. aktuelle Architektur

`DatabaseLocationService` **verschiebt** den aktiven SwiftData-Store aktuell
komplett an einen gewählten Ordner (`ordnerFestlegen(_:aktuelleStoreURL:)` kopiert
die Store-Dateien einmalig, danach ist der gewählte Ordner die alleinige aktive
`ModelConfiguration` — siehe `aktiveStoreURL(schema:)`). Es gibt zu jedem Zeitpunkt
**genau einen** aktiven Speicherort, lokal *oder* remote, nie beides.

Issue #50 will etwas anderes: lokal bleibt **immer** die aktive, führende Datenbank
(„Prio 1"); ein Remote-Ordner wird nur für zwei Zwecke verwendet:

1. **Wiederherstellung** (Backup einspielen).
2. **Teilen mit einem anderen Nutzer**, der auf denselben Ordner zugreift — mit
   Abfrage **Ersetzen** oder **Merge**, falls dort bereits eine Datenbank liegt.

Das ist ein **echter Architekturwechsel**, kein additives Feature — und passt sehr
gut zur Session-Entscheidung „wir bleiben bei der Default-Datenbank" für die
aktive Speicherort-Einstellung: In der #50-Architektur gibt es diese Wahl gar nicht
mehr — lokal ist immer aktiv, ein Ordnerwechsel des *aktiven* Stores (das bisherige
`DatabaseLocationService`-Feature) entfällt konzeptionell.

## 2. Warum das hier kein #39-Problem ist

#39 scheiterte an der Grundannahme divergierender, **kontinuierlich gleichzeitig
beschriebener** Geräte-Datenbanken, die per Event-Log/CRDT gemerged werden müssten
— dafür bräuchte es Lamport-Timestamps, eine eigene Event-Persistenz, laufende
Konfliktauflösung.

Backup/Restore/Merge nach #50 sind dagegen **einmalige, bewusst vom Nutzer
ausgelöste, im Vordergrund laufende Vorgänge** — nie zwei gleichzeitig geöffnete,
aktiv beschriebene Stores. Das umgeht die gesamte Lease-/Korruptionsproblematik aus
`docs/DATABASE_CONCURRENCY.md` von vornherein: Merge liest den Remote-Store einmal
komplett, verarbeitet ihn lokal, fertig — kein Dauerzustand, keine Wettlaufsituation.

Der schwierige Teil ist nicht *wann* gemerged wird, sondern *wie* — dazu Abschnitt 6.

## 3. Zielarchitektur im Überblick

```
┌─────────────────────┐         ┌──────────────────────┐
│  Lokaler Store       │  Export  │  Remote-Ordner        │
│  (immer aktiv,       │ ───────► │  (Backup-Kopie oder   │
│   Standardpfad)       │         │   Store eines anderen │
│                       │ ◄─────── │   Nutzers)             │
└─────────────────────┘  Import/  └──────────────────────┘
                          Merge
```

- **Export** („Sichern"): Kopie des lokalen Stores in den gewählten Ordner —
  bestehende `kopiereStoreDateien`-Logik, Richtung wie heute (lokal → Ziel).
- **Import „Ersetzen"**: Kopie vom Remote-Ordner **über** den lokalen Store —
  destruktiv, braucht Bestätigung (siehe „Explizite Genehmigung erforderlich" in
  den Sicherheitsregeln dieses Environments).
- **Import „Merge"**: Remote-Store zusätzlich zum lokalen einlesen, fehlende
  Objekte in den lokalen Store übernehmen (Abschnitt 6).

## 4. Baustein: Backup-Ziel merken (optional, eigene Entscheidung)

Getrennt von der (abgelehnten) Frage „soll der *aktive* Speicherort eine
Neuinstallation überleben" ist die neue, kleinere Frage: soll der **Backup-Zielordner**
dauerhaft gemerkt werden, damit man ihn nicht bei jedem Sichern/Wiederherstellen neu
auswählen muss?

**Vorschlag:** Ja, aber bewusst klein gehalten — ein Security-Scoped-Bookmark,
diesmal für das *Backup-Ziel* statt den *aktiven Store*. Speicherung im
Schlüsselbund (nicht `UserDefaults`), aus genau dem Grund, der die
Neuinstallations-Frage ursprünglich aufgeworfen hat: ein Backup ist gerade dafür
da, auch nach Geräteverlust/-wechsel/Neuinstallation nutzbar zu sein — ein
Bookmark, das selbst bei einer Neuinstallation verschwindet, wäre für genau den
Wiederherstellungsfall unbrauchbar, für den es gedacht ist. Kein Pflichtbestandteil
von Phase 1 (Abschnitt 12) — der Ordner lässt sich auch jedes Mal neu wählen, wenn
das vorerst reicht.

## 5. Export/Ersetzen — geringes Risiko, zuerst umsetzen

Beide Richtungen sind dieselbe Dateikopie, nur mit vertauschter Quelle/Ziel — die
bestehende `kopiereStoreDateien(von:nachOrdner:)`-Logik lässt sich direkt
wiederverwenden (Store + `-wal`/`-shm`-Sidecar-Dateien). Vor „Ersetzen" **immer**
automatisch eine Sicherungskopie des aktuellen lokalen Stores anlegen (z.B. in
`Application Support/Backups/vor-ersetzen-<Datum>.store`) — macht einen
versehentlichen/unerwünschten Restore rückgängig machbar, statt destruktiv-endgültig
zu sein.

## 6. Merge — der eigentlich schwierige Teil

### 6.1 Grundprinzip

Der Remote-Store wird als **zweiter, read-only `ModelContainer`** geöffnet
(dieselbe `Schema`, andere `ModelConfiguration(url:)`). Für jeden Modelltyp wird
geprüft, ob ein „gleichwertiges" lokales Objekt bereits existiert; wenn nicht, wird
eine Kopie lokal angelegt. Referenzen zwischen Objekten müssen dabei auf die
**lokalen** (ggf. schon vorhandenen) Gegenstücke umgebogen werden, nicht blind die
Remote-Relationship übernehmen.

**Zentrale Erkenntnis, die das Risiko deutlich senkt:** Für fast jeden Modelltyp
existiert die nötige Gleichheits-Prüfung bereits im Code — Merge ist überwiegend
eine **Orchestrierung bestehender, bereits bewährter Bausteine**, keine neue
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

### 6.2 Reihenfolge (Abhängigkeiten zuerst)

Merge muss in dieser Reihenfolge laufen, da spätere Typen frühere referenzieren:

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

### 6.3 Bewusste Grenze (nicht stillschweigend übergehen)

Zwei unabhängig entstandene Datenbanken können für „real dieselbe" Kategorie/denselben
Artikel unterschiedliche Namen verwenden (z.B. „Milch" vs. „Vollmilch") — das
Namens-Matching erkennt das nicht, es entstehen zwei separate Objekte. Für v1 wird
das bewusst in Kauf genommen (manuelles Zusammenführen/Löschen danach über die
ohnehin vorhandene Kategorien-/Artikel-Verwaltung) statt eines fehleranfälligen
Ähnlichkeits-Abgleichs — passt zum bisherigen Muster dieser Session (lieber einfach
und ehrlich begrenzt als scheinbar vollständig, aber fehleranfällig). Ein
automatischer Modus für „ähnliche, aber nicht exakt gleiche Namen anzeigen und
Nutzer entscheiden lassen" wäre ein sinnvoller, aber eigenständiger
Ausbauschritt — nicht Teil von v1.

## 7. Sicherheitsnetz

Vor **jedem** Ersetzen oder Merge automatisch eine Sicherungskopie des aktuellen
lokalen Stores anlegen (siehe Abschnitt 5) — macht beide Vorgänge im Zweifel
rückgängig machbar, statt einer einzigen, unwiderruflichen Aktion. Nach den
Sicherheitsregeln dieses Environments zählt „Ersetzen" als destruktive, „Merge" als
schwer rückgängig zu machende Aktion — beide brauchen eine explizite Bestätigung in
der UI, keine stille Ausführung.

## 8. UI/Auslöser

Ausschließlich manuell in den Einstellungen (`DatabaseLocationSettingsView` wird zu
einer neuen, z.B. `DatenbankSicherungView`): „Sichern" (Export), „Wiederherstellen…"
(öffnet Ordnerauswahl, erkennt automatisch, ob dort ein Store liegt, fragt dann
Ersetzen/Merge/Abbrechen). Kein Hintergrund-Trigger, kein automatischer Zeitplan in
v1 — passt zum bewusst seltenen, gezielten Charakter dieser Vorgänge.

## 9. Was hier NICHT gelöst wird

- **Gleichzeitige Bearbeitung durch zwei Personen während eines laufenden
  Einkaufs** — dafür bleibt (falls weiterhin gewünscht) das bestehende
  Lease-Verfahren (`docs/DATABASE_CONCURRENCY.md`) mit einem tatsächlich geteilten,
  aktiven Ordner zuständig. Das ist ein anderer Anwendungsfall (Dauerbetrieb) als
  Backup/Restore/Merge (gelegentliche, bewusste Aktion) — beide können
  nebeneinander bestehen, sind aber unabhängig.
- **Automatische, kontinuierliche Synchronisation** — bewusst nicht Ziel (siehe
  #39-Bewertung).

## 10. Verhältnis zu #48/#49

Dieser Baustein ist Voraussetzung für nichts an #48 (Überkauf-Hinweis, betrifft nur
den aktiven Lease-Store) — aber er **ist** die praktische Grundlage, um überhaupt
einen zweiten Nutzer/ein zweites Gerät mit sinnvollem Startzustand auszustatten
(„Wiederherstellen" von einem bestehenden Backup, statt bei null anzufangen), bevor
#49 (Multipeer, weiterhin an Bedingungen geknüpft) überhaupt relevant würde. In
diesem Sinn ist es tatsächlich der von dir genannte „erste Baustein".

## 11. Risiken

- **Merge-Komplexität** ist trotz Wiederverwendung bestehender Bausteine der mit
  Abstand aufwändigste Teil dieser Session-Arbeit bisher — realistisch mehrere
  Arbeitsschritte, nicht ein einzelner Commit.
- **Testbarkeit:** jeder Merge-Schritt braucht einen eigenen Unit-Test mit zwei
  In-Memory-`ModelContainer`n (lokal + „remote" simuliert) — umfangreicher
  Testaufwand, aber gut isolierbar pro Modelltyp (passt zur Reihenfolge aus 6.2).
- **Store-Kompatibilität:** ein Merge setzt voraus, dass Remote- und lokaler Store
  vom selben Schema (`SchemaV1`) sind — bei einer künftigen echten `SchemaVN` müsste
  Merge das prüfen und ggf. ablehnen statt falsch zu interpretieren.

## 12. Phasenplan

1. **Phase 1 — Export + Ersetzen** (Abschnitt 5): geringes Risiko, sofort
   nutzbarer Wert (Backup/Wiederherstellung für ein einzelnes Gerät, z.B. vor
   einem Geräte-/App-Wechsel). Inkl. automatischer Sicherungskopie vor „Ersetzen".
2. **Phase 2 — Merge, Stammdaten** (`GeschaeftTyp`, `ArtikelKategorie`, `Geschaeft`,
   `Artikel`, `Einkaufsliste`): nutzt ausschließlich bereits vorhandene
   Matching-Bausteine (Tabelle in 6.1).
3. **Phase 3 — Merge, abhängige/historische Daten**
   (`EinkaufslistenEintrag`, `Einkaufsvorgang`, `KaufEintrag`,
   `WarengruppenDistanz`, `IgnorierterArtikel`, `IgnorierterGeschaeftsVorschlag`):
   nutzt die in Phase 2 aufgebauten Zuordnungstabellen.
4. **Phase 4 — UI-Politur**: Zusammenfassung „X neue Kategorien, Y neue Artikel, Z
   neue Käufe übernommen" nach einem Merge, statt eines stillen Abschlusses.

Empfehlung: nach Phase 1 innehalten und im echten Gebrauch prüfen, ob Merge
(Phasen 2–4) tatsächlich gebraucht wird, oder ob Export+Ersetzen für den
eigentlichen Anwendungsfall schon ausreicht — Merge ist die mit Abstand teuerste
Phase, für einen Anwendungsfall (unabhängig entstandene zweite Datenbank
zusammenführen), der seltener vorkommen dürfte als reines Backup/Restore.
