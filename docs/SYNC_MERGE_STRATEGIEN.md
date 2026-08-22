# Sync-Merge-Strategien

**Zweck:** Vollständige Klassifizierung aller Merge-Funktionen in
`SyncSnapshotImportService.swift` nach ihrer CRDT-artigen Strategie. Vorarbeit für
GitHub [#75](https://github.com/McBoerny/ShopWithMe/issues/75) (generische
`SyncableModel`-Merge-Engine) und Grundlage der Connector-Abgrenzung in
`docs/SYNC_CONNECTOR_ARCHITEKTUR.md` §10.

**Bezug:** `docs/DATENSYNCHRONISATION.md` (Wie-es-heute-funktioniert),
`docs/DATENSYNCHRONISATION_VERLAUF.md` (Warum-Entscheidungen getroffen wurden),
`docs/SYNC_CONNECTOR_ARCHITEKTUR.md` §0.4 (CRDT-Einordnung) + §10 (Abgrenzung zu #75).

---

## 1. Haupttabelle — alle 18 Funktionen

Geordnet nach Aufrufposition in `mergePaket`/`merge` (= Abhängigkeitsreihenfolge).
Alle Angaben gegen den aktuellen Stand von `SyncSnapshotImportService.swift`
geprüft (2026-08-22, GitHub #128 — Zeilennummern ab Zeile 14 aktualisiert,
`mergeArtikelAliase` entfernt). Zeile 0 deckt Bereich A ab (eigene Datei, hier zur
Vollständigkeit); Zeilen 1–18 decken Bereich B/C/D ab.

| # | Funktion | Zeile | Strategie | Bereich | Seiteneffekte |
|---|---|---|---|---|---|
| 0 | `SyncKonfliktAufloesung.gewinnt(_:ueber:)` | — | **Priority-LWW**: „Entfernen schlägt alles" > „Abwählen schlägt Abhaken" > höherer Lamport-Zähler | A | Keine (reine Vergleichsfunktion) |
| 1 | `mergePaket(...)` | 374 | **Orchestrator** (Paket-Eingabeform seit #82): ruft alle Domain-Funktionen in Abhängigkeitsreihenfolge auf; keine eigene Merge-Logik | B/C/D | `SyncPeerInfo` aktualisieren |
| 2 | `merge(_ snapshot:...)` | 440 | **Orchestrator** (Legacy-Eingabeform, nur lokaler Backup-/Wiederherstellungspfad via `SyncErsetzenService`): identische Aufrufreihenfolge wie `mergePaket`, aber Einzel-`SyncSnapshot` statt Pakete | B/C/D | `SyncPeerInfo` aktualisieren |
| 3 | `mergeTombstones` | 497 | **Tombstone-gated-delete**: für jeden Remote-Tombstone lokalen Tombstone registrieren + Objekt löschen falls vorhanden; Alias-Auflösung vorgeschaltet | B | Löscht lokale Objekte (`Geschaeft`, `Artikel`, `ArtikelKategorie`, `Einkaufsliste`, `KaufEintrag`) |
| 4 | `mergeGeschaeftsTypen` | 594 | **Identity-Key fetch-or-create by Name**: kein Feld-Reconciliation — `GeschaeftTyp` existiert oder wird neu angelegt, kein Merge-Inhalt | B | — |
| 5 | `mergeArtikelKategorien` | 649 | **Name/ID-Match + Set-Union** (`geschaeftsTypen`): bestehende Kategorie bekommt Typen-Vereinigung; Alias-Auflösung | B | — |
| 6 | `mergeGeschaefte` | 687 | **Komplex**: Nil-Fill ×4 (`lat`/`lon`/`adresse`/`webseite`) + Set-Union ×5 (Kategorien, Typen, Öffnungszeiten…) + G-Counter (`SyncPeerZaehlerStand`) + OR-Merge (`umbauVerdacht`) + bewusst nicht gemergtes Feld (`unauffaelligeEinkaeufeInFolge`) + Ambiguitäts-Deferral | B | `SyncAbgleichKandidat` anlegen bei Ambiguität |
| 7 | `mergeArtikel` | 800 | **Name-Match + Set-Union** (`kategorien`) + Nil-Fill (`notiz`) + Ambiguitäts-Deferral | B | `SyncAbgleichKandidat` anlegen bei Ambiguität |
| 8 | `mergeProdukte` | 886 | **Match innerhalb `Artikel`** + zweistufiger Nil-Fill (`elternProdukt`, rekursiv); bewusst *kein* Ambiguitäts-Deferral (Produkte werden selten manuell angelegt, kein UX-Klärungsbedarf) | B | — |
| 9 | `mergeProduktnamen` | 930 | **Tupel-Union** nach (`produkt`, `geschaeft`, `name`): Existenz-Fakt, kein Inhalt zu mergen | B | — |
| 10 | `mergeEinkaufslisten` | 963 | **Name-Match** (seit #52 statt ID-Match) + Ambiguitäts-Deferral | B | `SyncAbgleichKandidat` anlegen bei Ambiguität |
| 11 | `mergeEinkaufslistenEintraege` | 1030 | **OR-Set add-wins**, gegated durch `istBereitsAbgehakt`; schreibt zusätzlich `ArtikelListenKauf.zuletztHinzugefuegtAm` (monotoner Max-Merge) | B | `ArtikelListenKauf.zuletztHinzugefuegtAm` aktualisieren |
| 12 | `mergeEinkaufsvorgaenge` | 1293 | **Komplexeste Funktion der Datei**: heuristischer Verbund-Match (`offenerTreffer`) + MIN-Merge (`startZeit`) + write-once-dann-immutable `endZeit` (plausibilitätsgegated, schließt zusätzlich `andereOffeneVorgaengeDerListe` mit) | C | Schließt andere offene Vorgänge derselben Liste |
| 13 | `mergeKaufEintraege` | 1599 | **Immutable-Log Union-by-ID**: unveränderliche Kaufhistorie; gegateter Lösch-Seiteneffekt auf `EinkaufslistenEintrag`; schreibt `ArtikelListenKauf.zuletztAbgehaktAm` | C | `EinkaufslistenEintrag` entfernen; `ArtikelListenKauf.zuletztAbgehaktAm` aktualisieren |
| 14 | `mergePreispunkte` | 1804 | **Immutable-Log Union-by-ID**: Preishistorie-Einträge sind unveränderlich; Pseudo-Geschäft-Fallback bei nicht auflösbarer `geschaeftID` seit GitHub #128 (Geschäfts-Pflicht) | C | — |
| 15 | `mergeWarengruppenDistanzen` | 1868 | **Gewichteter-Mittelwert-CRDT** (domänenspezifisch): `distanz = (lokal × lokalGew + fremd × peerZuwachs) / (lokalGew + peerZuwachs)`; delta-gegated (`peerZuwachs > 0`) und gewichts-gedeckelt (`maximaleMergeGewichtung`) — bewusst nicht naive 50/50 | D | `WarengruppenDistanzPeerZaehlerStand` aktualisieren |
| 16 | `mergeArtikelGeschaeftVerfuegbarkeiten` | 1915 | **Tupel-Union** nach (`artikel`, `geschaeft`): Existenz-Fakt, kein Tombstone nötig (wird nie direkt gelöscht) | D | — |
| 17 | `mergeGeschaeftBesuche` | 1933 | **Immutable-Log Union-by-ID**: historisches Ereignis, unveränderlich | D | — |
| 18 | `mergeArtikelListenKaeufe` | 1966 | **Direkter Sync-Kanal für beide monotone Max-Timestamp-Fakten**: schreibt `zuletztAbgehaktAm` UND `zuletztHinzugefuegtAm` via `ArtikelListenKaufService`; komplementär zu Zeile 11 und 13 (Abschnitt 2.2) | D | `ArtikelListenKauf.zuletztAbgehaktAm` und `zuletztHinzugefuegtAm` aktualisieren |

**GitHub #128:** `mergeArtikelAliase` (vormals Zeile 15, Case-insensitive-Name-Union
auf `ArtikelAlias`) entfällt ersatzlos — die Rolle übernimmt `mergeProduktnamen`
(Zeile 9) bereits vollständig mit, seit `Produktname.geschaeft == nil` dieselbe
geschäftsunabhängige Semantik trägt.

---

## 2. Besondere Befunde

### 2.1 Ambiguitäts-Deferral — ein drittes Auflösungsparadigma

Drei Funktionen (Zeilen 6, 7, 10) lösen Konflikte **nicht automatisch auf**, sondern
legen einen `SyncAbgleichKandidat` für eine manuelle Nutzerbestätigung in
`SyncOrdnerSettingsView` an. Das ist keine CRDT-Kategorie im engeren Sinn, sondern
ein bewusstes Human-in-the-Loop-Muster: wenn ein automatisches Merge zu einem falschen
Ergebnis führen könnte (z.B. zwei `Einkaufsliste "Wocheneinkauf"` auf verschiedenen
Geräten, die tatsächlich verschiedene Listen meinen), ist die Deferral-Entscheidung
sicherer als ein stiller, potenziell falscher Zusammenschluss.

Die drei Paradigmen im Überblick:

| Paradigma | Beispiele | Wann geeignet |
|---|---|---|
| **Automatischer Merge** (CRDT-artig) | Union, G-Counter, LWW, Weighted-Avg | Wenn eine falsche automatische Entscheidung klein oder reversibel ist |
| **Tombstone-gated-delete** | `mergeTombstones` | Wenn explizite Löschsemantik mit Peer-Propagation nötig ist |
| **Ambiguitäts-Deferral** | `mergeGeschaefte`, `mergeArtikel`, `mergeEinkaufslisten` | Wenn ein falsches automatisches Merge schwerwiegende, schwer rückgängig zu machende Folgen hätte |

### 2.2 `ArtikelListenKauf`s zwei Fakten laufen durch drei Funktionen

Das monotone „abgehakt"-Faktum (`zuletztAbgehaktAm`) und das monotone
„hinzugefügt"-Faktum (`zuletztHinzugefuegtAm`) von `ArtikelListenKauf` werden
durch **drei verschiedene Merge-Funktionen** gepflegt — nicht an einer Stelle:

| Funktion | Schreibt `zuletztAbgehaktAm` | Schreibt `zuletztHinzugefuegtAm` |
|---|---|---|
| `mergeEinkaufslistenEintraege` (11) | Nein | Ja (Sicherheitsnetz: Peer hat Eintrag gerade offen) |
| `mergeKaufEintraege` (13) | Ja (beim Einbuchen eines Kaufbelegs) | Nein |
| `mergeArtikelListenKaeufe` (18) | Ja (direkter dauerhafter Sync-Kanal) | Ja (direkter dauerhafter Sync-Kanal) |

Funktion 18 ist der symmetrische, robuste Pfad für beide Fakten; 11 und 13 pflegen
einen von beiden als Seiteneffekt ihres eigentlichen Auftrags mit. Diese Dreifachigkeit
ist ein konkretes Beispiel für die Duplikation, die GitHub #75 (generische Merge-Engine)
beseitigen würde — und deshalb ein gutes Leitbeispiel für das #75-Design.

**Architekturentscheidung (2026-08-10):** Der Seiteneffekt in Funktion 11 war
anfänglich einseitig (nur `zuletztAbgehaktAm`), was zu einem asymmetrischen Faktum
führte: das „hinzugefügt"-Faktum propagierte nur indirekt, wenn der Artikel beim
Peer gerade offen war. Funktion 18 schreibt jetzt symmetrisch beide Seiten. Details
in `ArtikelListenKauf`-Typ-Doku und `docs/DATENSYNCHRONISATION_VERLAUF.md` §55–60.

### 2.3 `Geschaeft.umbauVerdacht` — bekanntes Risiko, kein sofortiger Fix

`mergeGeschaefte` führt an Zeile ~783:

```swift
lokal.umbauVerdacht = lokal.umbauVerdacht || eintrag.umbauVerdacht
```

Das ist ein **Sticky-OR ohne synchronisierten „entwarnt"-Gegenfakt**: jeder Peer kann
den Verdacht auf jeden anderen übertragen, aber die Zurücksetzung (`AbteilungsDistanzService.
erkenneUmbau` → `umbauVerdacht = false`) ist lokal und wird nicht synchronisiert. Ein
Peer, der lokal entwarnt hat, kann von jedem anderen Peer ohne eigene bestätigte Entwarnung
zurückgesetzt werden.

Strukturell identisch mit dem `ArtikelListenKauf.istOffen`-Bug aus §60
(`docs/DATENSYNCHRONISATION_VERLAUF.md`), der in derselben Session behoben wurde.

**Status:** Kandidat für künftige Härtung, kein Fix in diesem Plan. Das Problem ist
klein (betrifft nur die Umbau-Warnung in der Abteilungs-Ansicht, nicht Datenverlust)
und bisher nicht durch einen Nutzerbericht aufgefallen.

---

## 3. Audit-Checkliste für neue Merge-Funktionen

Die folgende Vier-Punkt-Prüfung wurde in diesem Review an zwei Stellen angewendet
(§25 und §60 in `docs/DATENSYNCHRONISATION_VERLAUF.md`). Sie ist direkt
wiederverwendbar für das #75-Design:

1. **Referenzen zuerst anlegen:** Erstellt ein „neu anlegen"-Zweig alle strukturell
   nötigen Beziehungen, bevor er das neue Objekt einfügt? (Vermeidet lose Referenzen
   auf nicht-existente IDs.)
2. **Kein überschriebener Wert:** Überschreibt irgendein Zweig einen bereits gesetzten,
   nicht-nil Wert — also einen Wert, den der lokale Peer bewusst gesetzt hat? (Nur
   Nil-Fill ist sicher; jede andere Überschreibung muss mit einem LWW/Monoton-Merge
   begründet sein.)
3. **Bedingte Beziehungszuweisungen:** Sind Beziehungs-Neuzuweisungen (`lokal.x = y`)
   unter einer Bedingung (`if lokal.x != y`) gefasst? (Vermeidet unnötige
   SwiftData-`hasChanges`-Marks und damit unnötige Speicheroperationen.)
4. **`nil == nil` ist kein Match:** Wenn ein Feld optional ist, bedeutet `nil` nicht
   „dieselbe leere Menge" sondern oft „kaputt" oder „noch nicht migriert". Ein Check
   `lokal.x == nil && fremd.x == nil → gleich` ist fast immer falsch.

---

## 4. Abgrenzung zu GitHub #75

Dieses Dokument beschreibt, **welche** Strategie jede Funktion verfolgt. GitHub #75
fragt, **wie generisch** diese Funktionen implementiert werden können — ob eine
generische Merge-Engine den spezifischen Code ersetzen kann.

Die Tabelle oben liefert dafür drei Erkenntnisse:

- **Kandidaten für vollständige Generalisierung:** Zeilen 4, 9, 14, 15, 17, 18 —
  einfache Union-by-ID oder Tupel-Union ohne domänenspezifische Logik.
- **Kandidaten für Teile-Generalisierung:** Zeilen 5, 7, 8, 11, 13, 18 — haben einen
  generellen Kern (Union/LWW), aber domänenspezifische Seiteneffekte oder Gates.
- **Nicht-Kandidaten für vollständige Generalisierung:** Zeilen 6, 10, 12, 16 —
  domänenspezifisch genug (Ambiguitäts-Deferral, heuristischer Verbund-Match,
  Weighted-Average), dass eine generische Engine sie nicht ohne Domänenwissen umsetzen
  kann. Würden in #75 als „custom merge hook" verbleiben.

Zeile 18 (`mergeArtikelListenKaeufe`) ist das Leitbeispiel für #75: zwei identisch
strukturierte monotone Fakten, die heute über drei Funktionen verteilt gepflegt werden,
würden in einer generischen Engine durch einen einzigen deklarierten `monoMaxTimestamp`-
Feldtyp ausgedrückt — und genau diese drei Stellen wären das Ziel.
