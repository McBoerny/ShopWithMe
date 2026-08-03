# Datensynchronisation — Architektur (aktueller Stand)

**Zweck dieses Dokuments:** beschreibt, wie die Mehrgeräte-Synchronisation
*heute* tatsächlich funktioniert — als Nachschlagewerk, nicht als
chronologischer Verlauf. Die Entstehungsgeschichte (welche Entscheidung wann
warum getroffen wurde, jeder Live-Test-Fund, jeder Bugfix) steht separat in
`docs/DATENSYNCHRONISATION_VERLAUF.md` — dort nachlesen, wenn die Frage lautet
„warum ist das so", nicht „wie funktioniert das".

**Bezug:** [Issue #39](https://github.com/McBoerny/ShopWithMe/issues/39) (Grundarchitektur),
#48 (Überkauf-Hinweis), #50 (Gruppen-Beitritt), #52/#60/#70/#71 (Live-Test-Robustheit),
#63 (Ersetzen/Backup), #81 (lesbare Peer-Ordnernamen).

## 1. Grundprinzip

Kein CloudKit, kein eigener Server (bewusste Nutzervorgabe) — stattdessen ein
vom Nutzer gewählter, geteilter Ordner (iCloud Drive, Synology Drive, o.ä.).
Jedes Gerät führt seine **eigene, lokale, live genutzte** SwiftData-Datenbank
am Standardpfad; es gibt zu keinem Zeitpunkt eine gemeinsam beschriebene
Store-Datei. Stattdessen schreibt jedes Gerät ausschließlich in seinen
eigenen Unterordner und liest alle anderen:

```
{geteilter Ordner}/
  peers/
    {Gerätename-A}_{kurzeID-A}/
      export.json           ← vollständiger Bereich-B/C/D-Stand
      events/
        0001_{uuid}.json     ← einzelne Bereich-A-Events seit letztem Export
        0002_{uuid}.json
    {Gerätename-B}_{kurzeID-B}/
      ...
```

Der Ordnername (`PeerOrdnerName`, GitHub #81) trägt den vom Anwender vergebenen
Gerätenamen plus ein sechsstelliges, aus der Geräte-ID abgeleitetes Suffix — das
Suffix ist **immer** Teil des Namens, nicht nur bei Namensgleichheit zweier
Geräte, wodurch jede Kollisionsprüfung entfällt. Rein kosmetisch: der Ordnername
selbst ist niemals die interne Peer-Identität (siehe Abschnitt 2). Ändert der
Anwender später seinen Gerätenamen, wird der bestehende eigene Ordner beim
nächsten Export-Zyklus umbenannt (`SyncOrdnerService.eigenerPeerOrdnerName(in:)`),
nicht neu angelegt — damit dort bereits liegende, von Peers noch nicht
abgeholte Event-Dateien nicht verwaisen. Alte, noch nicht umbenannte Ordner aus
der Zeit vor #81 (Ordnername == rohe Geräte-ID) werden von lesendem Code
weiterhin erkannt (`PeerOrdnerName.gehoertZu(_:geraeteID:)`).

Jedes Gerät liest **alle** Peer-Ordner (auch den eigenen, zur Kontrolle),
schreibt aber **ausschließlich** in seinen eigenen — dadurch entsteht
strukturell nie ein Schreibkonflikt zwischen zwei Geräten für diesen Kanal
(anders als beim rein lokalen Schreibzugriff auf die eigene Store-Datei, dafür
siehe `docs/DATABASE_CONCURRENCY.md`).

Zwei Kanäle mit unterschiedlicher Frequenz/Konfliktsemantik:

| Bereich | Inhalt | Kanal | Konfliktregel |
|---|---|---|---|
| **A — zeitkritisch** | Einkaufslisten-Mitgliedschaft, Abhaken/Abwählen | `SyncEvent`, jeder Sync-Zyklus | Lamport-Uhr + `SyncKonfliktAufloesung` (Abschnitt 3) |
| **B — Stammdaten** | `GeschaeftTyp`, `ArtikelKategorie`, `Geschaeft`, `Artikel`, `Einkaufsliste`, `ArtikelAlias` | `SyncSnapshot`, jeder Sync-Zyklus | additiv/nie destruktiv (Abschnitt 4) |
| **C — Historie** | `Einkaufsvorgang`, `KaufEintrag`, `Preispunkt` | `SyncSnapshot` | Union nach `id` |
| **D — Lernen** | `WarengruppenDistanz` | `SyncSnapshot` | gewichteter Mittelwert |

Bewusst **kein** MultipeerConnectivity-Kanal (WiFi/Bluetooth-Echtzeitaustausch
im Laden, Issue #49) — nur der FileProvider-Kanal. Realistische Latenz daher
durch die Sync-Geschwindigkeit des Cloud-Anbieters begrenzt (grob 5–30s
iCloud Drive, 1–10s Synology Drive laut `docs/DATABASE_CONCURRENCY.md`), nicht
Sekundenbruchteile. Multipeer bliebe eine spätere, rein beschleunigende
Ergänzung (derselbe `SyncEvent`-Typ würde nur zusätzlich sofort an verbundene
Peers gespiegelt), keine Ablösung dieser Architektur.

## 2. Geräte-Identität und Lamport-Uhr

- **Geräte-ID:** `DatabaseLeaseService.geraeteID` (stabile UUID pro
  Installation) — die alleinige interne Peer-Identität
  (`SyncEvent.autorGeraeteID`, `SyncPeerInfo.peerGeraeteID`,
  `SyncPeerZaehlerStand.peerGeraeteID`). Der Peer-**Ordnername** (Abschnitt 1,
  GitHub #81) ist davon bewusst entkoppelt und rein kosmetisch — er darf
  nirgends anstelle der echten `geraeteID` als Identität verwendet werden.
- **`LamportClock`** (`UserDefaults`-basiert): `naechsterZaehler()` beim
  Erzeugen eines eigenen Events, `beiEmpfang(fremderZaehler:)` beim Empfang
  eines fremden — sorgt für eine geräteübergreifend vergleichbare, monoton
  wachsende Ordnung ohne synchronisierte Uhren.
- **`wallClock`/`erzeugtAm`** (auf `SyncEvent`/`SyncSnapshot`) sind bewusst
  **nur informativ** (Latenzmessung, Altersgrenzen) — nie für die
  Konfliktordnung zwischen Geräten verwendet, dafür ausschließlich der
  Lamport-Zähler.

## 3. Bereich A — Events

`SyncEvent` (`art`, `nutzlast: Data`, `lamportZaehler`, `autorGeraeteID`,
`wallClock`, `hochgeladen`) — additives Modell neben den bestehenden
SwiftData-Typen, keine Ablösung. `nutzlast` referenziert Entitäten immer über
ihre app-eigene `UUID`, nie über `persistentModelID` (die ist vor dem
Speichern nicht eindeutig).

**Erzeugt an genau der Stelle, die auch heute schon die einzige
Mutationsquelle ist** — jede der fünf Bereich-A-Mutationsfunktionen
(`artikelHinzufuegen`/`-entfernen`, `artikelAbhaken`/`-abwaehlen`/
`-dauerhaftEntfernen`) ist in eine reine `…OhneEventAufzeichnung`-Zustands-
mutation und einen aufzeichnenden Wrapper aufgeteilt — Import (Empfang eines
fremden Events) ruft direkt die reine Variante auf, sonst würde jedes
angewendete fremde Event zusätzlich ein neues, selbst-authored Event erzeugen
und beim nächsten Export dupliziert zurückgespiegelt.

**Konfliktregel** (`SyncKonfliktAufloesung`): „Löschen schlägt alles",
„Abwählen schlägt Abhaken" (lieber ein Artikel versehentlich wieder offen als
ein übersehener Doppelkauf), sonst höherer Lamport-Zähler gewinnt.

**Empfang** (`SyncImportService.importiereNeueEvents`): pro fremdem Peer-Ordner
alle Event-Dateien seit dem letzten Zyklus laden (über
`SyncDateiZugriff.leseKoordiniert(_:)`, damit ein File-Provider-Platzhalter
zuverlässig materialisiert wird, statt fehlzuschlagen), nach Lamport-Zähler
sortiert anwenden.

**Referenz noch nicht auflösbar (Retry-Semantik):** Referenziert ein
empfangenes Event eine `Einkaufsliste`/einen `Einkaufsvorgang`/einen `Artikel`,
den dieses Gerät noch nicht kennt, wird es **nicht** als bekannt markiert,
sondern bei jedem weiteren Zyklus erneut versucht — bis entweder die Referenz
auflösbar wird (typischerweise durch den nächsten Bereich-B/C-Import) oder
eine der beiden Ausnahmen greift:

1. **Tombstone** (`SyncTombstoneService`): die Referenz ist absichtlich
   gelöscht und wird nie entstehen — sofort als bekannt markiert, kein Retry.
2. **Altersgrenze** (`SyncImportService.maximalesEventAlterFuerRetry`,
   Standard 48h): eine Referenz kann auch **ohne** Tombstone dauerhaft
   unauflösbar bleiben (z.B. wenn sie durch eine Nachfolger-Umleitung ersetzt
   wurde, bevor ihre ID je Teil eines Snapshots wurde) — nach Ablauf der Frist
   wird das Event aufgegeben statt endlos weiterversucht.

## 4. Bereich B/C/D — Sync-Paket

**Seit GitHub #82 mehrere Dateien statt einer `export.json`** — Layout,
Fingerabdruck-pro-Teil und Begründung (Append-Log für die Kaufhistorie statt
Voll-Rebuild, harter Formatschnitt) stehen vollständig in
`docs/EXPORT_PAKET_UMBAU.md`. Der bisherige `SyncSnapshot`-Monolith-Typ bleibt
nur noch für den lokalen Backup-Pfad (`SyncErsetzenService`, GitHub #63)
bestehen. Die folgenden Unterabschnitte (Matching-Regeln, „nie destruktiv",
G-Counter, baumelnde Referenzen, Fingerabdruck-Prinzip) gelten unverändert für
beide Pfade — sie sind unabhängig vom Datei-Layout.

### 4.1 Grundprinzip: nie destruktiv

Ein bestehender lokaler Wert wird **nie** durch einen abweichenden
Remote-Wert überschrieben — es gibt keine Feld-Zeitstempel/Lamport-Uhr für
Bereich B, die entscheiden könnte, welcher Wert „neuer" ist (anders als
Bereich A). Merge ergänzt nur fehlende Werte (`nil` → Remote-Wert) und
vereinigt Mengen (Kategorien, Typen, ignorierte Artikel, alternative Namen),
statt sie zu ersetzen. Diese additive Regel ist absichtlich beibehalten
worden, auch nachdem Beobachtbarkeits-Werkzeuge (Abschnitt 7) einen Großteil
ihres ursprünglichen Korruptions-Absicherungszwecks übernommen haben — sie
ist in erster Linie die laufende Korrektheits-Grundlage für gleichzeitiges
Bearbeiten auf mehreren Geräten, keine bloße Vorsichtsmaßnahme (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 21 für die vollständige
Abwägung).

**Ausnahmen von „additiv":**
- **Tombstones** (`SyncTombstone`, Bereich B: `Geschaeft`/`Artikel`/
  `ArtikelKategorie`/`Einkaufsliste`/`KaufEintrag`) — merken eine absichtliche
  Löschung vor, werden zuerst gemergt (`mergeTombstones`) und verhindern,
  dass ein Peer mit veraltetem Snapshot das gelöschte Objekt zurückbringt.
  Jede UI-Löschstelle ruft `SyncTombstoneService.markiereGeloescht(...)` vor
  dem eigentlichen `context.delete(...)` auf.
- **Additive Zähler** (`Geschaeft.anzahlEinkaufsvorgaenge`) — kein simples
  Überschreiben, sondern ein echtes G-Counter-CRDT-Muster (Abschnitt 4.4).
- **`Einkaufsvorgang`/`KaufEintrag`** — Historie, Union nach `id`, siehe 4.3.

### 4.2 Entitäts-Matching und Alias-Auflösung

Zwei unabhängig gestartete Geräte kennen dieselbe reale Entität (z.B. „Rewe")
unter zwei unterschiedlichen `UUID`s, solange sie noch nie synchronisiert
haben. Matching-Strategie je Typ:

| Modell | Matching | Bemerkung |
|---|---|---|
| `GeschaeftTyp` | Name (`GeschaeftTyp.mitNamen(_:symbolName:context:)`, fetch-or-create) | kein Alias-Register — Name ist bereits das eindeutige Merkmal |
| `ArtikelKategorie` | case-insensitiver Name | Alias bei abweichender ID |
| `Geschaeft` | Name UND Koordinaten (`GeschaeftErkennungService.istGleicherOrtFuerSyncMerge`, GitHub #86 — strenger als die interaktiven Aufrufer von `istGleicherOrt`) | Alias bei abweichender ID |
| `Artikel` | case-insensitiver Name | Alias bei abweichender ID |
| `Einkaufsliste` | case-insensitiver Name | Alias bei abweichender ID — **nicht** ID-basiert (siehe Grund unten) |
| `Einkaufsvorgang` | ID **plus** „lokal noch offener Vorgang für dasselbe (Geschäft, Liste)-Paar gilt als derselbe" | Alias bei Zusammenführung; s. 4.3 |
| `KaufEintrag` | ID (unveränderliche Historie, nie gemergt, nur ergänzt) | — |
| `Preispunkt` (seit v4, GitHub #76) | ID (unveränderliche Historie, nie gemergt, nur ergänzt) | Absender hat SCD-Kompression bereits vorgenommen (`PreispunktService`) |
| `ArtikelAlias` (seit v4, GitHub #76) | case-insensitiver `erkannterName` | nie destruktiv — ein bereits lokal bekannter Alias wird nie überschrieben |
| `WarengruppenDistanz` | (Geschäft, KategorieA, KategorieB) | gewichteter Mittelwert bei Treffer |

**`Einkaufsliste` bewusst namensbasiert statt ID-basiert:** Jedes Gerät legt
beim allerersten Start automatisch eine eigene Standardliste namens
„Einkaufsliste" an, bereits bevor je synchronisiert wurde — bei
ID-basiertem Matching entstand dadurch bei jedem Beitritt zu einem
bestehenden Sync-Ordner eine zweite, für den Nutzer unsichtbare Dublette, auf
der die tatsächlich synchronisierten Artikel landeten, während die UI
weiterhin die eigene (fast leere) Liste zeigte.

**`SyncEntitaetsAlias`** (additive Tabelle „fremde ID X entspricht lokaler ID
Y") macht das Ergebnis eines Namens-/Koordinaten-Matches für spätere
Bereich-A-Events auflösbar, die weiterhin die ursprüngliche Peer-ID
referenzieren — ohne diesen Fallback liefen künftige Events des betroffenen
Peers für die zusammengeführte Entität dauerhaft ins Leere.

**Bewusste Grenze:** unterschiedliche Namen für real dieselbe Entität (z.B.
„Milch" vs. „Vollmilch") erkennt das Namens-Matching nicht — es entstehen
zwei separate Objekte. Manuelles Zusammenführen über die vorhandene
Kategorien-/Artikel-Verwaltung bleibt der Weg, kein automatischer
Ähnlichkeits-Abgleich (Fehleranfälligkeit höher als der Nutzen).

**Abhängigkeitsreihenfolge beim Merge** (spätere Schritte brauchen die
Zuordnungstabellen früherer): `GeschaeftTyp` → `ArtikelKategorie` →
`Geschaeft` → `Artikel` → `Einkaufsliste` → `EinkaufslistenEintrag` →
`Einkaufsvorgang` → `KaufEintrag` → `Preispunkt` → `ArtikelAlias` →
`WarengruppenDistanz`.

### 4.3 Einkaufsvorgang — Erkennung „ist das derselbe reale Einkauf"

Zusätzlich zum ID-/Alias-Abgleich gilt ein lokal noch **offener**
Einkaufsvorgang für dasselbe (`Geschaeft`, `Einkaufsliste`)-Paar als derselbe
realweltliche Einkauf wie ein zeitgleich von einem Peer begonnener — jedes
Gerät legt beim gemeinsamen Einkaufen sonst unabhängig einen eigenen,
zufällig-IDten Vorgang an (`EinkaufenView.einkaufSicherstellen()`), noch bevor
ein Sync stattfinden konnte.

Ist der per ID/Alias gefundene Vorgang bereits lokal abgeschlossen (dieses
Gerät hat zwischenzeitlich „Einkauf abschließen" getippt), wird ein
referenzierender `KaufEintrag`/ein nachträgliches Bereich-A-Event stattdessen
auf den aktuell **offenen Nachfolger** für dieselbe Liste umgeleitet
(`Einkaufsvorgang.offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)`,
gemeinsam genutzt von `SyncImportService` und `SyncSnapshotImportService`) —
bevorzugt mit gleichem Geschäft, sonst irgendein offener Vorgang für die
Liste (kein Geschäft-Zwang: „Einkauf abschließen" setzt die Geschäftsauswahl
zurück, der direkt danach neu angelegte Nachfolger hat also fast immer
`geschaeft == nil`). **Nur für `.artikelAbgehakt`** (materialisiert einen
NEUEN Eintrag) — `.artikelAbgewaehlt`/`.artikelDauerhaftEntfernt` müssen einen
bereits BESTEHENDEN Eintrag auf dem ursprünglichen Vorgang finden und dürfen
nicht umgeleitet werden, sonst liefe die Umleitung dort still ins Leere,
während das Event trotzdem als erledigt gälte.

Ein so oder per Snapshot-Merge fremd materialisierter `KaufEintrag` bekommt
bewusst **keinen** `kategorieBesuchsIndex` — er beschreibt die Laufreihenfolge
des SENDENDEN Geräts durchs Geschäft, nicht die dieses Geräts, und würde
`WarengruppenDistanzService` sonst mit einer erfundenen Position füttern.
`Einkaufsvorgang.naechsterKategorieBesuchsIndex` ignoriert indexlose Einträge
bei der Suche nach einem bereits vergebenen Index für dieselbe Kategorie.

**Geschäft kommt aus der Nutzlast, nicht aus dem Container-Vorgang (GitHub
#66):** `SyncEventNutzlast.geschaeftID` (additiv-optional) trägt das beim
SENDENDEN Gerät zum Zeitpunkt des Abhakens aktive Geschäft mit. Ohne dieses
Feld hätte der beim Umleiten neu materialisierte `KaufEintrag` das Geschäft
des NACHFOLGE-Vorgangs geerbt (`self.geschaeft` in
`Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`) statt des Geschäfts,
an dem der Kauf tatsächlich stattfand — z.B. wenn „Einkauf abschließen" die
Geschäftsauswahl zurücksetzt (GitHub #51) oder der Nachfolger an einem
anderen Geschäft läuft. `geschaeft geschaeftUeberschreibung: Geschaeft??`
(bewusst doppelt optional, analog dem bereits bestehenden
`kategorie`-Override) unterscheidet „kein Override, `self.geschaeft` gilt"
(Standardfall beim lokalen Abhaken) von „Override auf explizit KEIN
Geschäft" (Sender hatte keins ausgewählt) — beides muss unterscheidbar
bleiben.

**Auswirkung auf #69:** Da der Kaufeintrag jetzt unabhängig vom
Container-Vorgang immer das korrekte Geschäft trägt, kann der store-lose
Umleitungs-Fallback (kein offener Vorgang mit passendem Geschäft, siehe
GitHub #69) keine zwei Einkäufe an unterschiedlichen Geschäften mehr
inhaltlich vermischen — er könnte höchstens noch einen Kaufeintrag am
„falschen" Container-Vorgang gruppieren, was für Distanzlernen (immer
indexlos bei Fremdherkunft), Listenzustand (listenbasiert, nicht
vorgangsbasiert) und Preishistorie (seit GitHub #76 komplett von
`KaufEintrag` entkoppelt) folgenlos bleibt.

**Deterministische Kanon-Wahl bei mehreren passenden Kandidaten (GitHub
#67-Erweiterung):** Legen zwei Geräte kurz nacheinander (vor dem ersten
Sync-Zyklus) unabhängig je einen eigenen offenen Vorgang für dieselbe
(Geschäft, Liste)-Kombination an, existieren lokal kurzzeitig zwei
gleichwertige Kandidaten. `Einkaufsvorgang.kanonischer(unter:)` (gemeinsam
genutzt von `offenerNachfolger`, `EinkaufenView.aktuellerEinkauf` und
`SyncSnapshotImportService.mergeEinkaufsvorgaenge`s `offenerTreffer`-Zweig)
entscheidet dabei immer nach demselben Kriterium: ältester `startZeit`
gewinnt, bei exaktem Gleichstand die lexikographisch kleinere `id` als
stabiler Tiebreaker (analog `LamportTimestamp`). Da `startZeit` beim Sync
unverändert übernommen wird, kommen alle Geräte nach der Synchronisation
zuverlässig auf denselben Vorgang — vorher konnte ein beliebiger, per
Fetch-Reihenfolge nicht garantierter Treffer dazu führen, dass ein Gerät
dauerhaft auf seinem eigenen, vom Merge bereits „verlorenen" Vorgang
hängen blieb und vom anderen Gerät abgehakte Artikel nie als abgehakt sah.

**Neu anzulegender Vorgang braucht eine auflösbare Liste:** Referenziert ein
empfangener Snapshot-Eintrag weder ein bekanntes Geschäft noch eine bekannte
Liste (weil beide Referenzen bereits auf dem sendenden Gerät baumelten und
beim Export weggelassen wurden, siehe `sichereID` in 4.5), wird **kein**
neuer lokaler Vorgang angelegt — ein Vorgang ohne Liste ist für die gesamte
App strukturell unerreichbar (`EinkaufenView.aktuellerEinkauf` verlangt immer
eine konkrete Liste). Ein fehlendes Geschäft bleibt dagegen legitim (Einkauf
ohne gewählten Laden ist der Normalfall).

### 4.4 Additive Zähler: G-Counter statt Delta-Merge

`Geschaeft.anzahlEinkaufsvorgaenge` ist in zwei Teile aufgeteilt:
- `eigeneAnzahlEinkaufsvorgaenge` — rein lokaler, direkt inkrementierter Anteil.
- `anzahlEinkaufsvorgaenge` (computed) — Summe aus dem eigenen Anteil plus
  allen über `SyncPeerZaehlerStand` gespeicherten, **zuletzt bekannten**
  Beiträgen jedes Peers (klassisches CRDT-G-Counter-Muster: jeder Schreiber
  führt seinen eigenen Zähler, der Gesamtwert ist die Summe der neuesten
  bekannten Werte).

`SyncPeerZaehlerStand.merkeEigenenZuwachsDesPeers(...)` überschreibt beim
Merge nur den unter der **lokal aufgelösten** `Geschaeft.id` gespeicherten
Beitrag eines Peers — reine Zustandsspeicherung, keine Addition. Eine frühere
Delta-Merge-Regel („Zuwachs seit dem zuletzt bekannten Stand") führte zu
unbegrenztem Doppelzählen bei jedem Sync-Zyklus zwischen zwei Geräten (siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 17). `umbauVerdacht` wird
per ODER-Verknüpfung gemergt; `unauffaelligeEinkaeufeInFolge` bewusst **nie**
gemergt (ein Serien-Zähler, dessen Addition eine so nie stattgefundene
Serie vortäuschen würde).

### 4.5 Sichere Referenzen und baumelnde Verweise

`sichereID`/`sichereIDs` (`SyncSnapshotExportService`) liefern die `id` eines
Objekts nur, falls dessen `persistentModelID` tatsächlich noch unter den
gültigen IDs des aktuellen Bestands ist — sonst `nil`, plus
`sync_baumelnde_referenz_gefunden`-Protokolleintrag. `persistentModelID`
bleibt auch auf einer bereits ungültigen (baumelnden) Referenz sicher lesbar,
jede andere Eigenschaft würde abstürzen (siehe
`docs/DATABASE_CONCURRENCY.md` → „Behobener Absturz"). Ein Export ist dadurch
strukturell **niemals** Träger einer baumelnden Referenz — der Export-Pfad
„heilt" eine solche Referenz sogar beiläufig, siehe Abschnitt 8.

### 4.6 Fingerabdruck-basiertes Überspringen

`exportiereSnapshot(context:)` schreibt `export.json` nur, wenn sich der
Inhalt gegenüber dem zuletzt tatsächlich geschriebenen Stand geändert hat
(SHA256-Fingerabdruck, ohne die reinen Metafelder `erzeugtAm`/`geraeteID`/
`geraeteName`). `normalisiertFuerVergleich(_:)` sortiert dafür **sowohl** die
äußeren Snapshot-Arrays (ein Eintrag je Entität) **als auch** alle inneren
ID-/Namens-Arrays innerhalb eines einzelnen Eintrags (z.B.
`GeschaeftSnapshot/typIDs`) — SwiftData garantiert für keine der beiden
Ebenen eine stabile Fetch-Reihenfolge, ohne Sortierung erschien praktisch
jeder Zyklus fälschlich als inhaltliche Änderung. Ohne diese Prüfung erzwang
jeder Sync-Zyklus (5s/60s) einen echten `context.save()` auf jedem
empfangenden Peer, selbst ohne inhaltliche Änderung.

## 5. Sync-Zyklus und adaptives Polling

`SyncPollingService` führt einen vollständigen Zyklus (Import Bereich A →
Import Bereich B/C/D → Export Bereich A → Export Bereich B/C/D) aus, solange
die App im Vordergrund ist: sofort bei App-Start/Rückkehr aus dem
Hintergrund, danach alle 5s während `EinkaufenView` aktiv sichtbar ist (aktiv
gemeinsam eingekauft wird), sonst alle 60s. Kein separates
Hintergrund-Intervall (ein reiner In-App-`Task`-Loop pausiert ohnehin, sobald
iOS die App suspendiert) und kein Fehler-Backoff (alle Sync-Funktionen sind
heute best-effort mit stillem Fehlschlagen, `try?`, ohne auswertbares
Erfolgs-/Fehlersignal).

`SyncOrdnerSettingsView` nutzt denselben `SyncPollingService.syncZyklus()`
für „Jetzt synchronisieren" wie das automatische Polling — Protokollierung
passiert dadurch an einer einzigen Stelle für beide Auslöser.

## 6. Gruppen-Beitritt (Bootstrap)

1. Person A wählt/erstellt einen geteilten Ordner.
2. Person B verknüpft in ihren Einstellungen denselben Ordner
   (`SyncOrdnerSettingsView.ordnerFestlegen(_:)`).
3. Enthält der Ordner bereits fremde Peer-Daten
   (`SyncOrdnerService.hatVorhandenePeers(in:)`), fragt die App
   „Zusammenführen" vs. „Ersetzen" (verwirft den eigenen Bestand zugunsten des
   Peer-Stands, siehe Abschnitt 8) vs. „Abbrechen".
4. **„Zusammenführen" (GitHub #86, Teil 2):** Anders als früher läuft danach
   nicht sofort derselbe additive Merge wie im laufenden Betrieb — zuerst
   scannt `SyncSnapshotImportService.mehrdeutigeGeschaeftsKandidatenBeimBeitritt(context:)`
   die Bereich-B-Stammdaten aller Peers (reines Lesen, keine
   Zustandsänderung) gegen den lokalen Geschäfts-Bestand und sammelt jeden
   Kandidaten, der nach der großzügigen, aber nicht nach der strengen
   automatischen Merge-Regel übereinstimmt (siehe
   `docs/GESCHAEFTSERKENNUNG.md` → „Strengere Regel für den automatischen
   Sync-Merge"). Gibt es welche, entscheidet die Person aktiv pro Kandidat
   (`GeschaeftsBeitrittsAbgleichSheet`): „gleicher Laden" (mit Wahl, welcher
   Name bleibt — registriert vorab einen `SyncEntitaetsAlias`, damit der
   nachfolgende Merge die `remoteID` bereits über den ID-Fast-Path erkennt)
   oder „unterschiedliche Läden" (keine Aktion, Standardverhalten). Erst
   danach läuft der eigentliche `SyncPollingService.syncZyklus()`. Ohne
   gefundene Kandidaten entfällt dieser Zwischenschritt, der normale Merge
   läuft direkt.
5. Diese aktive Rückfrage bleibt bewusst auf den einmaligen Beitritts-Moment
   beschränkt — im laufenden Betrieb danach entscheidet ausschließlich die
   strenge, deterministische Regel automatisch (kein wiederkehrender
   Hintergrund-Dialog), siehe `docs/GESCHAEFTSERKENNUNG.md`.
6. Kein separates Vertrauens-/Freigabemodell in der App — Zugriff auf den
   Ordner selbst (vom Betriebssystem/Cloud-Anbieter verwaltet) ist das
   Vertrauensmerkmal.

## 7. Diagnose und manuelle Statuskonsolidierung

- **`SyncDebugLogger`** (opt-in, Einstellungen → Debugging → Sync-Debug-Modus):
  Zyklusdauer, Alter empfangener Updates, welcher Bereich `export.json`
  tatsächlich neu schreibt — siehe `docs/LOGGING.md` für alle protokollierten
  Ereignistypen.
- **`DatenintegritaetsService`** (immer aktiv, läuft bei jedem App-Start):
  löscht zuerst automatisch `Einkaufsvorgang`e ohne `Einkaufsliste` UND ohne
  angehängte `KaufEintrag`e (`raeumeLeereListenloseVorgaengeAuf(context:)`
  — beweisbar verlustfrei, da ein `nil`-Bezug kein Absturzrisiko ist und
  nichts referenziert wird, das dabei verloren ginge), dann meldet `pruefe(context:)`
  baumelnde Referenzen (Absturzrisiko, `persistentModelID` zeigt auf
  Gelöschtes) UND — separat, da eine andere Fehlerklasse — verbleibende
  `Einkaufsvorgang`e ohne `Einkaufsliste`, die trotzdem angehängte Käufe
  haben (nicht automatisch gelöscht, `deleteRule: .cascade` würde die Käufe
  mitlöschen), als eine aggregierte Zeile inkl. Anzahl. Ein Zuwachs über
  `DatenintegritaetsService.warnschwelleSchnellesWachstum` (Standard 10) seit
  der letzten Prüfung wird zusätzlich als Warnung markiert — eine reine
  Bestandszahl verrät für sich genommen nicht, ob sie über Wochen langsam
  getröpfelt ist oder gerade akut wächst.
- **Manuelle Statuskonsolidierung** (Einstellungen → Debugging): „Events
  aufräumen" gibt aktuell nicht anwendbare empfangene Events sofort auf
  (statt die 48h-Frist aus Abschnitt 3 abzuwarten); „Sync-Paket aufräumen"
  erzwingt ein frisches eigenes Paket (`docs/EXPORT_PAKET_UMBAU.md`) und löscht
  verwaiste Paket-Dateien von Peers jenseits der 30-Tage-Altersgrenze (Abschnitt
  8); „KaufEintraege jetzt bereinigen" ruft
  `KaufEintragBereinigungService.bereinigen(context:)` direkt auf (statt über
  die 24h-Sperre von `automatischBereinigenFallsFaellig`) — z.B. um einen Fix
  an dieser Bereinigung sofort zu verifizieren, ohne bis zum nächsten
  automatischen Zeitpunkt zu warten (`docs/DATENSYNCHRONISATION_VERLAUF.md`
  Abschnitt 27/28). Alle drei rühren bewusst nicht an eigenen, noch nicht
  abgeholten ausgehenden Event-Dateien.

## 8. Korruptions-Recovery (`SyncErsetzenService`)

Der einzige bewusst **destruktive** Pfad in dieser Architektur (alles andere
ist additiv, Abschnitt 4.1) — nötig, weil ein bereits korrumpierter lokaler
Datensatz (baumelnde Referenz) sich über die normale SwiftData-API nicht
reparieren lässt: jede schreibende Operation muss die Inverse-Gegenseite
einer `@Relationship(inverse:)`-Beziehung auffalten, was crasht, falls genau
diese Gegenseite bereits baumelnd ist.

**Ablauf, zweigeteilt in „planen" (aktuelle Sitzung) und „ausführen" (nächster
App-Start):** ein Laufzeit-Austausch der Store-Datei führte auf einem echten
Gerät zu einem SQLite-I/O-Fehler und Absturz (Details:
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 13) — die eigentliche
Ersetzung passiert deshalb erst ganz am Anfang eines neuen Prozesses
(`ShopWithMeApp.init()`), bevor überhaupt ein `ModelContainer` existiert.

- `erstelleBackup(context:)` — lokales, nicht geteiltes Backup, wiederverwendet
  `SyncSnapshotExportService.erstelleSnapshot(context:)`. Genau ein Backup,
  wird bei jedem Ersetzen/Beitritt überschrieben.
- `planeErsetzenDurchPeer(context:)` — sichert, merkt die Aktion für den
  nächsten Start vor. Beim Start: Store-Datei physisch löschen (vor dem
  Öffnen des `ModelContainer`s), dann aus allen erreichbaren Peer-Snapshots
  neu aufbauen.
- `planeWiederherstellenAusBackup()` — stellt stattdessen das eigene, zuvor
  erstellte Backup wieder her (z.B. beim Austritt aus der Synchronisierung).

**Vorher-/Nachher-Zusammenfassung:** Ein Neuaufbau, der zum Zeitpunkt der
Ausführung weniger zurückbekommt als vorher vorhanden war (z.B. weil kein
erreichbarer Peer den vollständigen Stand hatte), blieb bisher unbemerkt —
`fuehreAusstehendeAktionAus(context:)` berechnet direkt nach einem
`.ersetzenDurchPeer`-Neuaufbau einen Vergleich zwischen dem (ohnehin
vorhandenen) Vorher-Backup und einem frischen Nachher-Snapshot je Bereich und
zeigt ihn in `DebuggingView` an, Rückgänge rot markiert — das bestehende
„Backup wiederherstellen" bleibt direkt daneben als Rückgängig-Option
sichtbar.

**Automatischer Rollback bei eindeutigem Fehlschlag (Härtung, 2026-08-03):**
Die reine Anzeige oben deckt nur den TEILWEISEN Rückgang ab (kann legitim
sein, z.B. bereits verarbeitete Peer-Löschungen) — ein EINDEUTIGER
Totalverlust wurde bisher trotzdem nur angezeigt, nicht verhindert: scheitert
der Ordnerzugriff komplett, oder bringt kein einziger erreichbarer Peer
irgendetwas zurück (vorher nicht leerer Bestand, nachher Summe aller Bereiche
exakt 0), importiert `fuehreAusstehendeAktionAus(context:)` jetzt automatisch
das ohnehin vorhandene Vorher-Backup zurück in den Context, statt den leeren
Neuaufbau stehen zu lassen. `DebuggingView` zeigt dafür zusätzlich zur
Vorher-/Nachher-Zusammenfassung einen roten Hinweis
(`SyncErsetzenService.letzterNeuaufbauAutomatischZurueckgerollt`). Ein
teilweiser Rückgang bleibt bewusst nur informativ, ohne automatischen
Rollback — die Unterscheidung "legitim vs. Bug" ist dort nicht zuverlässig
automatisierbar.

**Verwaiste Peer-Exports:** Sync-Pakete (`docs/EXPORT_PAKET_UMBAU.md`) von
Peers, deren `manifest.erzeugtAm` über `SyncSnapshotImportService.maximalesSnapshotAlter`
(30 Tage) hinaus ist, werden beim Import ignoriert (verwaister Peer-Ordner aus
einer früheren Testinstallation, jede Neuinstallation erzeugt eine neue
Geräte-ID) und lassen sich über „Sync-Paket aufräumen" (Abschnitt 7)
zusätzlich sichtbar aus dem geteilten Ordner entfernen — inklusive des
kompletten `kaeufe/`-Ordners, aber ohne `events/` anzutasten.

## 9. Bekannte Grenzen

- **Kein echter Live-Test-Ersatz:** alle Merge-Regeln sind unit-getestet mit
  zwei simulierten Geräten (zwei In-Memory-`ModelContainer`), aber jede
  Aussage über tatsächliche Cloud-Sync-Latenz/-Zuverlässigkeit stammt aus
  echten Zwei-Geräte-Tests, nicht aus den Unit-Tests selbst.
- **Unerreichbare Vorgeschichte:** Einkaufslisten-Einträge, die entstanden,
  bevor Bereich-A-Events bzw. der volle Snapshot-Inhalt existierten, wurden
  nie als Event aufgezeichnet und stecken in keinem historischen Snapshot —
  sie lassen sich nicht rückwirkend zwischen Geräten abgleichen.
- **Event-Dateien werden seit GitHub #89 wieder gelöscht** (siehe
  `docs/SYNC_EVENT_BEREINIGUNG.md`) — ein früherer Versuch, sie nach einem
  Sicherheitsfenster zu löschen, löschte dabei noch nicht von allen Peers
  abgeholte Events (siehe `docs/DATENSYNCHRONISATION_VERLAUF.md`
  Abschnitt 15) und wurde revertiert. Diesmal abgesichert durch
  `SyncAktualitaetsService`: ein Gerät, das selbst länger als die
  Aufbewahrungsfrist (30 Tage) nicht erfolgreich synchronisiert hat, erkennt
  das lokal und löst statt eines additiven Merges einen erzwungenen
  Voll-Abgleich aus (`SyncErsetzenService`) — ein Peer verliert dadurch nie
  mehr unbemerkt eine Löschung. Das wiederholte LESEN längst entschiedener
  Dateien bei jedem Zyklus bleibt zusätzlich seit dem Performance-Fund
  „ID-Vorfilter aus Dateinamen" (`SyncImportService.importiereNeueEvents`)
  kein wachsendes Problem — bereits bekannte Event-IDs werden anhand des
  Dateinamens erkannt und ihre Dateien gar nicht erst gelesen/dekodiert,
  ohne die Retry-Semantik für noch nicht auflösbare Events zu berühren.
- **Kein echtes Hintergrund-Sync:** ein In-App-`Task`-Loop läuft nur im
  Vordergrund — Sync bei gesperrtem Gerät oder vor dem Öffnen der App bräuchte
  das `BackgroundTasks`-Framework, nicht umgesetzt.
- **Kein Fehler-Backoff:** alle Sync-Funktionen sind best-effort
  (`try?`) ohne auswertbares Erfolgs-/Fehlersignal.
