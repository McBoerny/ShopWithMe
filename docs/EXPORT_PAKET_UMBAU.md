# ShopWithMe — Sync-Paket statt `export.json`-Monolith

Status: **Umgesetzt** (GitHub #82). Ersetzt das bisherige Bereich-B/C/D-Format
(eine einzige `export.json`, bei jedem Sync-Zyklus komplett neu aufgebaut und
kodiert) durch mehrere unabhängig fingerabdruck-geprüfte Dateien plus ein
Append-Log für die Kaufhistorie. Siehe `docs/DATENSYNCHRONISATION.md` §4 für
die weiterhin unveränderten Matching-/Merge-Regeln — hier geht es nur um das
Datei-Layout.

## Auslöser

Eine reale `export.json` bestand zu 56% ihrer Größe allein aus `kaufEintraege`
— dem einzigen Bereich, der unbeschränkt wächst (im Gegensatz zu `Preispunkt`,
das durch `PreispunktVerdichtungService` aktiv komprimiert wird, und den
kleinen, selten ändernden Stammdaten). Zwei unabhängige Ineffizienzen:

1. `SyncSnapshotExportService.erstelleSnapshot` fetchte und kodierte bei
   **jedem** Zyklus (alle 5s während aktiv eingekauft wird) die komplette
   Historie neu — der Fingerabdruck-Vergleich (GitHub #70/#71/#78) verhinderte
   nur das finale Datei-Schreiben, nicht diesen Aufbau selbst.
2. `SyncSnapshotImportService.mergeKaufEintraege`/`mergePreispunkte` fetchten
   beim Import ALLE lokalen Einträge und verglichen linear gegen jeden
   Remote-Eintrag — O(n·m) pro Zyklus, wachsend mit der Gesamthistorie statt
   nur mit tatsächlich neuen Einträgen.

## Layout unter `peers/{peer}/`

```
manifest.json    Klein, IMMER geschrieben (auch ohne inhaltliche Änderung) —
                 ersetzt formatVersion/erzeugtAm als Peer-Alters-Gate.
tombstones.json  Löschungen (Geschäft/Artikel/ArtikelKategorie/Einkaufsliste/
                 Einkaufsvorgang/KaufEintrag/Preispunkt) — eigene Datei, nicht
                 mit vorgaenge.json gebündelt (siehe „Warum eine eigene
                 tombstones.json" unten).
stamm.json       GeschaeftTyp, ArtikelKategorie, Geschaeft, Artikel,
                 Einkaufsliste, EinkaufslistenEintrag, ArtikelAlias.
lernen.json      WarengruppenDistanz.
vorgaenge.json   Einkaufsvorgang.
preise.json      Preispunkt — eigene Datei statt Bündelung mit vorgaenge.json,
                 da Einkaufsvorgang.endZeit bei praktisch jedem Kaufabschluss
                 wechselt, Preispunkt aber nur bei echter Preisänderung.
kaeufe/          Ein <uuid>.json pro KaufEintrag — Append-Log analog dem
                 bestehenden Bereich-A-Eventlog events/, siehe unten.
events/          Unverändert (Bereich A).
```

Jede der fünf Dateien (`tombstones.json`/`stamm.json`/`lernen.json`/
`vorgaenge.json`/`preise.json`) hat einen eigenen `UserDefaults`-Fingerabdruck
und wird nur neu geschrieben, wenn sich ihr Inhalt seit dem letzten Schreiben
tatsächlich geändert hat (`SyncSnapshotExportService.schreibeTeilFallsGeaendert`)
— ein Zyklus, in dem nur ein `Einkaufsvorgang.endZeit` sich ändert, schreibt
nur `vorgaenge.json` neu, nicht `stamm.json`/`lernen.json`/`preise.json`.

## Warum eine eigene `tombstones.json`

Ursprünglich war geplant, Tombstones in `vorgaenge.json` zu bündeln. Beim
Umsetzen zeigte eine erneute Durchsicht von `SyncSnapshotImportService.merge`:
`mergeTombstones` muss **vor** jedem Stammdaten-Merge laufen (dokumentierter
Kommentar „läuft bewusst zuerst" seit der „Architektur-Revision Alternative
A"), und Tombstones gelten nicht nur für Bereich C (Einkaufsvorgang/
KaufEintrag/Preispunkt), sondern auch für Stammdaten (Geschäft/Artikel/
ArtikelKategorie/Einkaufsliste). Läge diese Datei in `vorgaenge.json`, würde sie
erst NACH `stamm.json` gelesen — die Stammdaten-Tombstone-Prüfung käme zu
spät. Deshalb eine eigene, immer zuerst gelesene Datei.

## `kaeufe/` — Append-Log statt Voll-Rebuild

Analog zum bestehenden Bereich-A-Eventlog (`SyncExportService`/`events/`,
`docs/DATENSYNCHRONISATION.md` §2), aber ohne Zähler-Präfix im Dateinamen:
anders als `SyncEvent` (Konfliktauflösung braucht Lamport-Reihenfolge) ist
`KaufEintrag`-Merge bereits seit jeher reine Union nach `id`, ohne
Reihenfolgeabhängigkeit — `<uuid>.json` genügt.

**Existenz-Check per Datei statt eines persistierten `bereitsExportiert`-Flags
auf `KaufEintrag`:** bewusste Vereinfachung, um für dieses Issue keine
SwiftData-Modell-Migration einzuführen. `SyncKaeufeExportService.exportiereNeueKaeufe`
prüft für jeden lokalen `KaufEintrag`, ob `kaeufe/{id}.json` schon existiert,
und kodiert/schreibt nur bei fehlender Datei. Bei sehr großen lokalen
Historien (deutlich über den in dieser App typischen wenigen hundert
Einträgen) wäre ein Flag (analog `SyncEvent.hochgeladen`) die schnellere
Lösung — mögliche künftige Verfeinerung, falls der Datei-Existenz-Check
jemals messbar ins Gewicht fällt.

**Pruning bei Löschung:** `KaufEintragBereinigungService.bereinigen` und die
Tombstone-getriebene lokale Löschung (`SyncSnapshotImportService.loescheFallsVorhanden`)
löschen die eigene `kaeufe/{id}.json` zusätzlich zum lokalen `KaufEintrag`
(`SyncKaeufeExportService.entferneDatei(fuerKaufEintragID:)`). Rein
Platzersparnis — der beim Löschen bereits gesetzte `SyncTombstone` schützt
unabhängig davon vor Wiederbelebung durch einen Peer, der die Datei noch
führt.

## Harter Formatschnitt — kein Dual-Read

Entschieden mit dem Nutzer: kein Übergangspfad, der sowohl altes `export.json`
als auch das neue Paket liest. Passt zum bisherigen Vorgehen bei
`SyncSnapshot.formatVersion`-Sprüngen (2→4, jeweils explizit ohne
Rückwärtskompatibilität, da keine feste externe Nutzerbasis) und zur kleinen,
persönlichen Geräteflotte dieser App. Ein noch nicht aktualisiertes Gerät sieht
andere, bereits aktualisierte Geräte vorübergehend nicht (kein `manifest.json`
lesbar — der Peer erscheint wie „noch nie synchronisiert", kein Absturz) —
selbstheilend, sobald auch dieses Gerät aktualisiert. Alte `export.json`-Dateien
werden nicht mehr geschrieben und von `raeumeVerwaisteFremdeExportsAuf` auch
nicht mehr angefasst (das Werkzeug kennt nur noch das neue Format) — sie bleiben
bis zur nächsten manuellen Aufräumung des Sync-Ordners einfach ungenutzt liegen.

## `SyncSnapshot` bleibt bestehen — für das lokale Backup

Der bisherige monolithische `SyncSnapshot`-Typ samt `erstelleSnapshot(context:)`,
`merge(_:peerGeraeteID:context:)` und `importiereEinzelnenSnapshot` wurde
**nicht entfernt** — er dient seit diesem Umbau ausschließlich dem lokalen
Backup-/Wiederherstellungs-/Korruptions-Recovery-Pfad (`SyncErsetzenService`,
GitHub #63). Dort ist ein einzelner, vollständiger In-Memory-Snapshot weiterhin
die richtige Form (ein lokales Backup, kein wiederholtes Über-das-Netz-Problem
wie beim laufenden Peer-Sync-Zyklus). Alle `mergeX`-Funktionen in
`SyncSnapshotImportService` (`mergeGeschaeftsTypen` … `mergeWarengruppenDistanzen`,
`loescheFallsVorhanden`) sind unverändert und werden von BEIDEN Pfaden
gemeinsam genutzt — `mergePaket(...)` (neuer Paket-Zyklus) und `merge(...)`
(Backup-Pfad) unterscheiden sich nur darin, woher die Teil-Arrays kommen.

## Was NICHT geändert wurde

Der O(n·m)-Merge-Scan-Fix (indexierter Existenz-Check statt Voll-Fetch +
linearem Scan für `mergeKaufEintraege`/`mergePreispunkte`, Muster wie
`SyncEventService.istBereitsBekannt`) ist Teil desselben Umbaus, aber
unabhängig vom Datei-Layout — er wäre auch ohne das neue Paket-Format sinnvoll
gewesen. `mergeEinkaufsvorgaenge` bewusst nicht angefasst: `alleLokalen` wird
dort zusätzlich für den `offenerTreffer`-Scan (Geschäft+Liste-Matching über
offene Vorgänge) gebraucht — kein mit der Gesamthistorie wachsendes Problem,
da nur aktuell offene Vorgänge betroffen sind.
