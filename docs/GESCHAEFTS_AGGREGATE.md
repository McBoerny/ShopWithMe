# ShopWithMe — Geschäfts-Aggregate, entkoppelt von der Einkaufsliste

**Auslöser:** Zwei Geräte liefen nach einer Neuinstallation kurzzeitig auseinander
(siehe `docs/PEER_LEBENSZYKLUS.md` für die Sync-seitige Untersuchung dazu — diese
war letztlich unabhängig davon, ein normaler Aufholvorgang). Bei der Analyse fiel
aber ein echtes, seit langem bestehendes Problem auf: `Einkaufsvorgang.einkaufsliste`
hatte `deleteRule: .nullify` — löschte ein Anwender eine `Einkaufsliste`
(`EinkaufslistenVerwaltungView`), verloren ihre `Einkaufsvorgang`e nur den
Listenbezug, blieben aber (mit echten, angehängten `KaufEintrag`en) als für die
App strukturell unerreichbare Datenleiche zurück — `EinkaufenView` verlangt immer
eine konkrete Liste, ein `Einkaufsvorgang` ohne Liste ist von nirgendwo aus
erreichbar. `DatenintegritaetsService` konnte solche Vorgänge erkennen und
melden, aber (bewusst, um die echte Kaufhistorie nicht per Kaskade zu
vernichten) nicht automatisch bereinigen — sie blieben unbegrenzt liegen (auf
einem Testgerät akkumulierten sich so 22 Vorgänge mit 136 Käufen).

## Kernfrage: was hängt an `Einkaufsvorgang`/`KaufEintrag`, das eine wegwerfbare Liste überleben muss?

Eine `Einkaufsliste` ist ein dynamisches, jederzeit lösch- und neu anlegbares
Planungswerkzeug ("was will ich einkaufen"). Ein `Einkaufsvorgang` ("ein
konkreter Ladenbesuch") hängt an ihr nur, weil während des Einkaufens von ihr
abgehakt wird — fachlich hat er mit der Liste sonst nichts zu tun. Geprüft, wer
`Einkaufsvorgang`/`KaufEintrag` tatsächlich braucht:

| Verbraucher | Frequenz | Bereits ein Aggregat? |
|---|---|---|
| `AbteilungsDistanzService` → `WarengruppenDistanz` | pro Abschluss | ✅ schon vorher, gleitender Mittelwert bei Abschluss geschrieben |
| `Geschaeft.eigeneAnzahlEinkaufsvorgaenge` | pro Abschluss | ✅ schon vorher, reiner Zähler |
| `ArtikelVerfuegbarkeitService.istVerfuegbar` | pro Abhaken | ❌ **Live-Scan über `KaufEintrag`** |
| `GeschaeftBesuchsProtokollView` (Besuchsprotokoll) | — | ❌ **direkt aus `Einkaufsvorgang.startZeit`/`endZeit`** |

Die ersten beiden waren nie das Problem — sie sind längst unabhängig von der
Liste. Die letzten beiden lasen live aus `Einkaufsvorgang`/`KaufEintrag`,
genau der Kette, die an der (wegwerfbaren) Liste hängt.

## Lösung: zwei neue, dauerhafte Aggregate + `.cascade`

- **`ArtikelGeschaeftVerfuegbarkeit`** (`Artikel`, `Geschaeft`) — reine
  Existenz-Tatsache "wurde hier mindestens einmal gekauft", kein Zähler/Zeitstempel
  nötig (anders als `WarengruppenDistanz` gibt es nichts zu mitteln). Geschrieben in
  `Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung` bei jedem tatsächlich neuen
  `KaufEintrag`, gelesen von `ArtikelVerfuegbarkeitService.istVerfuegbar`. Bleibt
  auch nach einem Undo (`artikelAbwaehlen`) bestehen — die Tatsache, dass der
  Artikel dort existiert, ändert sich nicht dadurch, dass ein Kauf rückgängig
  gemacht wird.
- **`GeschaeftBesuch`** (`id` = `id` des ursprünglichen `Einkaufsvorgang`s,
  `geschaeft`, `startZeit`, `endZeit`, `anzahlProdukte`) — geschrieben von
  `GeschaeftBesuchService.erfassen(fuer:context:)`, aufgerufen direkt nach
  `Einkaufsvorgang.abschliessen(...)` an denselben zwei Stellen in `EinkaufenView`
  wie `AbteilungsDistanzService.verarbeiteEinkauf`. Wirkungslos ohne `geschaeft`
  oder ohne gesetztes `endZeit`. Bei Duplikat-Vorgängen desselben physischen
  Besuchs (`zaehleAlsBesuch: false`) bewusst NICHT aufgerufen — sie repräsentieren
  denselben Besuch, ein zweiter Eintrag würde ihn doppelt zählen (analog dem
  bestehenden `Geschaeft.eigeneAnzahlEinkaufsvorgaenge`-Zähler).
  `GeschaeftBesuchsProtokollView` liest seither `GeschaeftBesuch` statt
  `Einkaufsvorgang` und zeigt zusätzlich `anzahlProdukte` an.
- **`Einkaufsliste.einkaufsvorgaenge` jetzt `deleteRule: .cascade`** (vormals
  `.nullify`): mit beiden Aggregaten unabhängig festgeschrieben, ist ein
  `Einkaufsvorgang` ohne Liste kein Zwischenzustand mehr wert, den es zu schützen
  gilt — Löschen der Liste löscht ihn (und seine `KaufEintrag`e) jetzt vollständig,
  genau wie der Anwender es beim Löschen einer Liste erwarten würde ("die Artikel
  darauf verschwinden … bleiben aber im Artikel-Katalog erhalten", analoge Erwartung
  fürs Besuchsprotokoll: der Besuch bleibt, nur der Vorgang selbst nicht).

## Sync

Beide neuen Typen sind Bereich D (Lernen, siehe `docs/DATENSYNCHRONISATION.md`
Abschnitt 4) — mitgeführt in `SyncLernenSnapshot`/`lernen.json` neben
`WarengruppenDistanz` (vergleichbare Änderungsfrequenz, eine weitere unabhängig
fingerabdruck-geprüfte Datei hätte keinen Mehrwert gebracht). Beide werden nie
vom Nutzer direkt gelöscht, brauchen also anders als die meisten Bereich-B/C-Typen
keinen Tombstone-Mechanismus:

- `ArtikelGeschaeftVerfuegbarkeit`: Union nach (`Artikel`, `Geschaeft`)-Paar,
  analog dem Matching-Muster von `WarengruppenDistanz`, aber ohne dessen
  G-Counter/gewichtete Mittelung — eine reine Existenz-Tatsache ist entweder schon
  bekannt oder wird einmalig ergänzt.
- `GeschaeftBesuch`: Union nach `id` (= `id` des ursprünglichen
  `Einkaufsvorgang`s), analog `Preispunkt`/`KaufEintrag` — ein unveränderliches
  historisches Ereignis.

`SyncSnapshot.aktuelleFormatVersion` auf 6 erhöht (siehe Typ-Doku), wie bei allen
vorherigen additiven Erweiterungen keine Rückwärtskompatibilität nötig — ein Peer
mit altem Format liefert für beide neuen Felder einfach leere Arrays, bis auch er
aktualisiert.

## Bestandsmigration

`DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context:)` läuft
beim App-Start (vor `raeumeLeereListenloseVorgaengeAuf`) und sichert für **jeden**
bereits vorhandenen `KaufEintrag`/abgeschlossenen `Einkaufsvorgang` (nicht nur die
bereits listenlosen) beide Aggregate nach, bevor listenlose `Einkaufsvorgang`e
endgültig gelöscht werden — sonst würden Artikel, die nur über eine bereits
gelöschte Liste gekauft wurden, fälschlich wieder als "nie hier gekauft" gelten,
und ihr Besuch verschwände aus dem Protokoll. Idempotent wie
`KaufEintrag.preisverlaufMigrierenFallsNoetig` (kein separates
"schon gelaufen"-Flag): jeder Schritt prüft vor dem Schreiben/Löschen den
aktuellen Bestand.
