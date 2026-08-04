# ShopWithMe — Peer-Lebenszyklus

Status: **In Umsetzung** (Bausteine A und B von 4 fertig). Ausgangspunkt: `SyncTombstone`
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
- **Baustein C0 — Manifest muss „vollständiger Sync" zertifizieren** (offen)
- **Baustein C — Dynamischer Aufbewahrungs-Wasserstand für Events/Tombstones** (offen)

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
