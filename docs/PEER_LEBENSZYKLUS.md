# ShopWithMe — Peer-Lebenszyklus

Status: **Umgesetzt** (alle 4 Bausteine fertig). Ausgangspunkt: `SyncTombstone`
wächst aktuell für immer (siehe `docs/DATENSYNCHRONISATION.md` — dominiert durch einen
Tombstone pro `KaufEintrag`, automatisch 48h nach jedem Einkauf erzeugt). Statt einer
fest „gepflegten" Zeit-Frist soll ein dynamischer, sich selbst nachführender
Aufbewahrungs-Wasserstand treten: „ist ein Ereignis/Tombstone älter als der Zeitpunkt,
zu dem JEDER aktuell bekannte Peer nachweislich schon einen vollständigen Sync hatte,
hat es für die Gruppe keinen Mehrwert mehr und kann weg." Damit das sicher ist, darf ein
dauerhaft nicht mehr erreichbares Gerät diesen Wasserstand nicht für immer blockieren —
dafür braucht es einen Peer-Lebenszyklus: sichtbare Warnung bei langer Abwesenheit,
bestätigte Entfernung, und vor allem eine sichere Rückkehrer-Erkennung, damit ein
wieder auftauchendes, zwischenzeitlich entferntes Gerät nicht seinen veralteten Bestand
zurück in die Gruppe exportiert.

Vier Bausteine, jeder ein eigener Checkpoint:

- **Baustein B — Rückkehrer-Erkennung** (✅)
- **Baustein A — Peer-Sterblichkeit sichtbar machen + bestätigte Entfernung** (✅)
- **Baustein C0 — Manifest muss „vollständiger Sync" zertifizieren** (✅)
- **Baustein C — Dynamischer Aufbewahrungs-Wasserstand für Events/Tombstones** (✅)

Reihenfolge bewusst so: B zuerst, weil es die Sicherheits-Garantie liefert, von der alle
anderen Bausteine abhängen.

## Baustein B: Rückkehrer-Erkennung

**Problem:** Ein Gerät, dessen eigener Peer-Ordner von der Gruppe entfernt wurde
(Baustein A), darf beim nächsten Start unter keinen Umständen mehr seinen — inzwischen
möglicherweise veralteten — lokalen Bestand exportieren, bevor der Nutzer überhaupt vom
Ausschluss erfährt. Ein Check, der nur zufällig VOR dem ersten Sync-Zyklus greift, reicht
nicht: `SyncPollingService.starten(context:)` wird von zwei unabhängigen, nicht in
garantierter Reihenfolge feuernden Auslösern aufgerufen (`RootView().task` und
`.onChange(of: scenePhase)` in `ShopWithMeApp.swift`). Ein Hook in `ShopWithMeApp.init()`
scheidet aus, weil die Prüfung asynchronen, koordinierten Datei-I/O braucht, `init()`
aber synchron läuft.

**Lösung:** `SyncOrdnerService.binIchNochMitglied(in:)` prüft, ob der eigene
Peer-Unterordner (`eigenerPeerOrdnerName(in:)`) noch unter `peers/` existiert — `nil` bei
nicht erreichbarem Ordner (bewusst nicht als „ausgeschlossen" gewertet, sonst würde ein
rein transientes Problem einen Voll-Neuaufbau auslösen). Der Check läuft als allererster
Schritt innerhalb des `Task(priority: .utility) { while ... }`-Blocks, den
`SyncPollingService.starten(context:)` beim ersten Aufruf erzeugt (geschützt durch
`guard schleife == nil`) — der einzige Punkt, der garantiert vor jedem möglichen
`syncZyklus()` dieser Session erreicht wird, unabhängig davon, welcher der beiden
Auslöser zuerst feuert.

Bei `false` (definitiv ausgeschlossen):
1. `SyncErsetzenService.erstelleBackup(context:)` — bestehende Funktion, unverändert
   wiederverwendet (lokales, nicht geteiltes Backup).
2. `SyncOrdnerService.ordnerEntfernen()` — aktiviert sofort das überall im Sync-Code
   bereits bestehende Gate (`guard SyncOrdnerService.gewaehlterOrdner() != nil`). Kein
   neuer, separat zu verwaltender „pausiert"-Zustand nötig: sobald kein Zielordner mehr
   konfiguriert ist, kann strukturell kein weiterer Sync-Zyklus mehr laufen, unabhängig
   davon, wie lange der Nutzer braucht, um auf die folgende Meldung zu reagieren.
3. Loop wird NICHT gestartet — kein `syncZyklus()` mehr in dieser Session.
4. `SyncPollingService.wurdeAusGruppeEntfernt` (`@Published`) wird gesetzt.

`RootView` beobachtet dieses Signal und zeigt einen eigenen, vom bestehenden
30-Tage-„Sync-Abgleich nötig"-Dialog bewusst abweichend formulierten Dialog („Deine
Gruppe hat dieses Gerät entfernt …"), rein informativ — Backup und Trennung sind zu dem
Zeitpunkt bereits erfolgt. Zwei Optionen: „Alleine weitermachen" (nichts weiter zu tun)
oder „Wieder beitreten" (öffnet `SyncOrdnerSettingsView` als Sheet, dort der normale,
bestehende Ordner-Auswahl-/Ersetzen-Fluss).

**Bewusst außerhalb dieses Bausteins:** Der bestehende, selbst-erkannte 30-Tage-Pfad
(`RootView.vollAbgleichAusloesen()`) führt weiterhin erst einen normalen `syncZyklus()`
aus (exportiert dabei möglicherweise noch veralteten Bestand), bevor der Neuaufbau
greift — dieselbe Lücke bleibt dort bestehen (anderes Szenario: Gerät erkennt sich selbst
als zurückgefallen, wurde aber nicht von der Gruppe ausgeschlossen). Ein Angleichen wäre
eine separate, spätere Entscheidung.

**Tests:** `SyncOrdnerServiceTests.binIchNochMitgliedLiefertTrueWennEigenerOrdnerExistiert`/
`binIchNochMitgliedLiefertFalseWennEigenerOrdnerFehlt`/
`binIchNochMitgliedLiefertNilBeiNichtErreichbaremOrdner`;
`SyncPollingServiceTests.startenErkenntAusschlussAusGruppeUndEntferntSyncOrdnerOhneWeiterenSyncZyklus`.

## Baustein A: Peer-Sterblichkeit sichtbar machen + bestätigte Entfernung

**Wiederverwendung statt Neubau:** `SyncPeerInfo` trackt bereits `geraeteName` +
`zuletztGesehen` (abgeleitet aus des Peers eigenem `manifest.erzeugtAm`, nicht lokaler
Importzeit). `DebuggingView.BekannteSyncPeersSection` hatte bereits eine
`@Query`-Liste mit Swipe-to-delete — vor diesem Baustein aber mit rohem `FileManager`
statt koordiniertem Zugriff, und ohne Alters-Hervorhebung, nur im Debug-Menü versteckt.

**Neu:**
1. `SyncOrdnerService.entfernePeer(_:in:context:) async` — die Lösch-Logik aus
   `DebuggingView` extrahiert, jetzt über `SyncDateiZugriff.listeKoordiniert`/
   `loescheKoordiniert` statt rohem `FileManager` (Konsistenz mit dem Rest der
   Sync-Schicht). `DebuggingView.peerEntfernen` ruft seither dieselbe Funktion auf
   (Single Source of Truth) — gleichzeitig die Grundlage für die Rückkehrer-Erkennung
   in Baustein B: kehrt ein entfernter Peer zurück, erkennt `binIchNochMitglied(in:)`,
   dass sein Ordner fehlt.
2. `SyncPeerInfo.istWahrscheinlichTot: Bool` — Vergleich `zuletztGesehen` gegen
   `SyncSnapshotImportService.maximalesSnapshotAlter` (30 Tage) — dieselbe Schwelle wie
   der bereits bestehende Ignorier-Mechanismus beim Import, kein neuer Wert.
3. Neuer proaktiver Dialog in `RootView.swift`, strukturell analog zu
   `pruefeAusDerZeitGefallen()`/`zeigeAusDerZeitGefallenDialog`: `pruefeToteGruppenPeers()`,
   gleiche Auslöser (`.task`, `scenePhase == .active`), zeigt bei mindestens einem
   `istWahrscheinlichTot`-Peer einen eigenen Dialog ("Gerät seit langem nicht gesehen")
   mit „Entfernen“ (ruft `entfernePeer` auf) / „Später erinnern“ (kein „für immer
   abbrechen“, wie beim bestehenden Vorbild) — pro Aufruf höchstens ein Peer, weitere
   folgen bei erneutem Auslösen.

**Tests:** `SyncPeerInfoTests.istWahrscheinlichTotIstFalseInnerhalbDerSchwelle`/
`istWahrscheinlichTotIstTrueJenseitsDerSchwelle`;
`SyncOrdnerServiceTests.entfernePeerLoeschtOrdnerUndSyncPeerInfo`. Der proaktive Dialog
selbst nur manuell im Simulator verifizierbar (nach expliziter Freigabe).

## Baustein C0: Manifest muss „vollständiger Sync" zertifizieren

**Lücke:** `SyncSnapshotExportService.exportierePaket` schrieb `manifest.json` (mit
frischem `erzeugtAm`) bisher **bedingungslos** bei jedem Export-Versuch — unabhängig
davon, ob der Import-Teil desselben Zyklus (`importiereSnapshots`/`importiereNeueEvents`
in `SyncPollingService.syncZyklus()`) erfolgreich war. Der Zeitstempel bedeutete damit
nur „ein Export wurde versucht", nicht „ich habe erfolgreich alles importiert, was es
gab" — für den in Baustein C geplanten dynamischen Aufbewahrungs-Wasserstand muss er
aber genau das zertifizieren, sonst könnte ein Gerät mit dauerhaft fehlschlagendem
Import trotzdem „frisch" wirken und andere Geräte dazu bringen, zu früh aufzuräumen.

**Fix:** `exportierePaket(context:importErfolgreich:)` — neuer Parameter (Default
`true`, deckt bestehende Aufrufstellen wie das Debug-Werkzeug „Sync-Paket aufräumen"
unverändert ab), von `syncZyklus()` mit `snapshotImportErfolgreich && eventImportErfolgreich`
durchgereicht. Der Manifest-Schreibvorgang läuft nur noch bei `importErfolgreich == true`
— bei `false` bleibt die alte Datei (mit ihrem alten, weiterhin korrekten Zeitstempel)
unverändert stehen. Restlicher Paket-Export (`tombstones.json`/`stamm.json`/etc.,
fingerabdruck-geprüft) bleibt unverändert.

**Tests:** `SyncSnapshotExportServiceTests.exportierePaketSchreibtManifestBeiFehlgeschlagenemImportNichtNeu`/
`exportierePaketSchreibtManifestBeiErfolgreichemImportNeu`.

## Baustein C: Dynamischer Aufbewahrungs-Wasserstand, ersetzt beide festen Fristen

**Neue Funktion:** `SyncSnapshotImportService.aktuellerAufraeumWasserstand(in:)` — listet
`peers/` (`SyncDateiZugriff.listeKoordiniert`), überspringt den eigenen Ordner, liest je
verbleibendem Peer-Ordner `manifest.json` und bildet das Minimum aller `erzeugtAm`-
Zeitstempel. **Kein separat gepflegter Cache** — `SyncPeerInfo` dient einem anderen
Zweck (Namensauflösung für Meldungen wie „Bereits von {Gerät} abgehakt") und wird hier
bewusst nicht gelesen; jeder Aufräum-Lauf liest live.

`nil`, wenn (a) der Ordnerzugriff fehlschlägt, (b) aktuell kein anderer Peer bekannt ist
(frisch verbundenes Gerät ohne Partner), oder (c) sich auch nur EIN aktuell vorhandener
Peer-Ordner nicht lesen lässt — bewusst nicht übersprungen, sonst könnte der Wasserstand
an genau dem Peer vorbei fortschreiten, der ihn eigentlich noch zurückhalten müsste.
`nil` bedeutet für Aufrufer: in diesem Lauf nichts löschen.

**Ersetzt zwei bestehende Mechanismen:**
- `SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()` — Löschkriterium
  vorher „Datei-Änderungsdatum älter als die feste `eventAufbewahrungsfrist` (30 Tage)",
  jetzt „... älter als der aktuelle Wasserstand". Die Wasserstand-Berechnung läuft dabei
  bewusst VOR dem Öffnen des eigenen Security-Scoped-Zugriffs dieser Funktion (nicht von
  innen heraus aufgerufen) — verschachtelter/überlappender Zugriff auf denselben
  Bookmark destabilisiert ihn auf echten Geräten nachweisbar (siehe
  `SyncOrdnerZugriffsDiagnose`-Typ-Doku).
- **Neu:** `SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context:)` — löscht
  `SyncTombstone`-Zeilen mit `geloeschtAm` älter als der Wasserstand, gleiches
  Rate-Limit-Muster (`automatischesBereinigungsintervall`) wie das Event-Vorbild.
- Beide aufgerufen von denselben Stellen wie die übrigen `automatisch…FallsFaellig`-
  Dienste in `RootView.swift`.

**`SyncAktualitaetsService.istAusDerZeitGefallen` bewusst unverändert** — reiner,
lokaler Selbst-Check ohne Gruppenbezug, in einer anderen Kategorie als die beiden
Aufräum-Mechanismen oben. Bekommt einen eigenen, unabhängigen Wert
(`SyncAktualitaetsService.veraltungsSchwelle`, weiterhin 30 Tage) statt weiter
`SyncExportService.eventAufbewahrungsfrist` mitzunutzen, die mit dieser Umstellung
komplett entfällt.

**Kein Cleanup für `SyncEntitaetsAlias`** — wächst nach demselben „nie bereinigt"-Muster,
aber deutlich langsamer (nur bei Bereich-B-Namens-/Koordinaten-Treffern, nicht pro Kauf)
und hat aktuell kein Zeitstempel-Feld überhaupt. Bewusst als eigenständiger, späterer
Schritt zurückgestellt.

**Tests:** `SyncSnapshotImportServiceTests.aktuellerAufraeumWasserstandBildetMinimumMehrererPeers`/
`aktuellerAufraeumWasserstandLiefertNilOhneAnderenPeer`/
`aktuellerAufraeumWasserstandLiefertNilBeiUnlesbaremPeerManifest`;
`SyncAktualitaetsServiceTests.raeumtNurAlteEigeneEventDateienAuf`/
`raeumtNichtsOhneAnderenBekanntenPeer`/`bereinigungLaeuftHoechstensEinmalProIntervall`
(umgeschrieben); `SyncTombstoneServiceTests` (neu, 3 Tests, analoges Muster).

## Zusammenfassung

Mit allen vier Bausteinen: ein Gerät, das die Gruppe lange nicht gesehen hat, wird
sichtbar markiert und nach Bestätigung entfernt (A); ein zurückkehrendes, entferntes
Gerät kann strukturell keinen veralteten Bestand mehr exportieren, bevor der Nutzer
überhaupt informiert wurde (B); der Zeitstempel jedes Peers zertifiziert einen
tatsächlich vollständigen Sync (C0); und Sync-Events/Tombstones werden gelöscht, sobald
jeder aktuell bekannte Peer sie nachweislich gesehen hat — kein fest „gepflegter"
Zeitwert mehr nötig, der Mechanismus passt sich dem tatsächlichen Gruppenzustand an (C).
