import Foundation

/// `SyncConnector`-Implementierung für den gemeinsamen Cloud-Datei-Ordner
/// (iCloud Drive, Synology Drive, usw.) — Fassade über `SyncDateiZugriff`,
/// `SyncOrdnerService`, `SyncExportService`, `SyncSnapshotExportService` und
/// `SyncKaeufeExportService`. Workstream 1a (docs/SYNC_CONNECTOR_ARCHITEKTUR.md).
///
/// **Security-Scope-Invariante**: `beginneZugriff()` öffnet den Bookmark genau
/// einmal und speichert die geöffnete URL in `offenerSyncOrdner`. Alle
/// Methoden außer `binIchNochMitglied()` und `multipeerGruppenID()` setzen
/// einen aktiven Scope voraus. `SyncOrdnerService`-Methoden, die intern
/// `startAccessingSecurityScopedResource()` aufrufen (`binIchNochMitglied(in:)`,
/// `entfernePeer(_:in:context:)`), werden hier NICHT delegiert, um
/// Scope-Verschachtelung auf demselben Bookmark zu vermeiden (GitHub §30-Bug,
/// docs/SYNC_CONNECTOR_ARCHITEKTUR.md §11).
@MainActor
final class FileShareSyncConnector: SyncConnector {

    private var offenerSyncOrdner: URL?

    // MARK: - Lebenszyklus

    func beginneZugriff() async -> Bool {
        guard let ordner = SyncOrdnerService.gewaehlterOrdner() else { return false }
        let erfolgreich = ordner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(
            aufrufstelle: "FileShareSyncConnector.beginneZugriff", erfolgreich: erfolgreich
        )
        guard erfolgreich else { return false }
        offenerSyncOrdner = ordner
        return true
    }

    func beendeZugriff() {
        guard let ordner = offenerSyncOrdner else { return }
        ordner.stopAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "FileShareSyncConnector.beginneZugriff")
        offenerSyncOrdner = nil
    }

    // MARK: - Peer-Verwaltung

    /// Konsolidiert das dreifach duplizierte Peer-Auflistungsmuster aus
    /// `SyncSnapshotImportService` (Z. 88–94), `SyncImportService` (Z. 161)
    /// und `SyncSnapshotImportService.raeumeVerwaisteFremdeExportsAuf` (Z. 1966–1972).
    func bekanntePeers() async -> [String] {
        guard let syncOrdner = offenerSyncOrdner else { return [] }
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }) ?? nil else { return [] }
        return peerVerzeichnisse
            .filter { !PeerOrdnerName.gehoertZu($0.lastPathComponent, geraeteID: eigeneGeraeteID) }
            .map(\.lastPathComponent)
    }

    func binIchNochMitglied() async -> Bool? {
        guard let syncOrdner = offenerSyncOrdner ?? SyncOrdnerService.gewaehlterOrdner() else { return nil }
        if offenerSyncOrdner != nil {
            // Scope bereits offen — direkt prüfen ohne weiteren startAccessingSecurityScopedResource()-Aufruf,
            // der auf demselben Bookmark eine Verschachtelung erzeugen würde (Risiko 1).
            let eigenerName = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
            let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
            guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
                SyncDateiZugriff.listeKoordiniert(peersOrdner)
            }) ?? nil else { return nil }
            return peerVerzeichnisse.contains { $0.lastPathComponent == eigenerName }
        } else {
            // Kein offener Scope — an bestehende Implementierung delegieren, die ihren eigenen öffnet.
            return await SyncOrdnerService.binIchNochMitglied(in: syncOrdner)
        }
    }

    func entfernePeer(_ peerOrdnerName: String) async {
        guard let syncOrdner = offenerSyncOrdner else { return }
        let peerOrdner = syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(peerOrdnerName, isDirectory: true)
        await Task.detached(priority: .utility) {
            SyncDateiZugriff.loescheKoordiniert(peerOrdner)
        }.value
    }

    // MARK: - Bereich A: Event-Sync

    func veroeffentlicheNeueEvents(_ events: [SyncEventExportDarstellung]) async -> Bool {
        guard let syncOrdner = offenerSyncOrdner else { return false }
        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        guard await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.erstelleVerzeichnisKoordiniert(eventsOrdner)
        }) == true else { return false }

        for event in events {
            guard let daten = try? JSONEncoder().encode(event) else { continue }
            let zielURL = eventsOrdner.appendingPathComponent(eventDateiname(fuer: event))
            _ = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.schreibeKoordiniert(daten, nach: zielURL) })
        }
        return true
    }

    func empfangeNeueEvents(von peer: String, bekannteIDs: Set<UUID>) async -> [SyncEventExportDarstellung] {
        guard let syncOrdner = offenerSyncOrdner else { return [] }
        let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: peer, in: syncOrdner)
        guard let dateien = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(eventsOrdner)
        }) ?? nil else { return [] }

        let jsonDateien = dateien
            .filter { $0.pathExtension == "json" }
            .filter { url in
                guard let id = eventID(ausDateiname: url) else { return true }
                return !bekannteIDs.contains(id)
            }

        var ergebnis: [SyncEventExportDarstellung] = []
        for url in jsonDateien {
            guard let daten = await SyncDateiZugriff.mitZeitlimit({
                SyncDateiZugriff.leseKoordiniert(url)
            }) ?? nil else { continue }
            guard let event = try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: daten) else { continue }
            ergebnis.append(event)
        }
        return ergebnis.sorted { $0.lamportZaehler < $1.lamportZaehler }
    }

    // MARK: - Bereich B/C/D: Snapshot-Sync

    func manifest(von peer: String) async -> SyncPeerManifest? {
        guard let syncOrdner = offenerSyncOrdner else { return nil }
        return await ladeTeil(
            SyncPeerManifest.self,
            von: SyncSnapshotExportService.manifestURL(fuerPeer: peer, in: syncOrdner)
        )
    }

    func empfangePaket(von peer: String) async -> SyncPaketTeile? {
        guard let syncOrdner = offenerSyncOrdner else { return nil }
        guard let manifest = await manifest(von: peer) else { return nil }

        let tombstones = await ladeTeil(
            [SyncTombstoneSnapshot].self,
            von: SyncSnapshotExportService.tombstonesURL(fuerPeer: peer, in: syncOrdner)
        ) ?? []
        let stamm = await ladeTeil(
            SyncStammSnapshot.self,
            von: SyncSnapshotExportService.stammURL(fuerPeer: peer, in: syncOrdner)
        ) ?? SyncStammSnapshot(
            geschaeftsTypen: [], abteilungen: [], geschaefte: [], artikel: [],
            einkaufslisten: [], produkte: [], produktnamen: []
        )
        let listen = await ladeTeil(
            SyncListenSnapshot.self,
            von: SyncSnapshotExportService.listenURL(fuerPeer: peer, in: syncOrdner)
        ) ?? SyncListenSnapshot(einkaufslistenEintraege: [])
        let lernen = await ladeTeil(
            SyncLernenSnapshot.self,
            von: SyncSnapshotExportService.lernenURL(fuerPeer: peer, in: syncOrdner)
        ) ?? SyncLernenSnapshot(warengruppenDistanzen: [])
        let vorgaenge = await ladeTeil(
            SyncVorgaengeSnapshot.self,
            von: SyncSnapshotExportService.vorgaengeURL(fuerPeer: peer, in: syncOrdner)
        ) ?? SyncVorgaengeSnapshot(einkaufsvorgaenge: [])
        let preise = await ladeTeil(
            SyncPreisSnapshot.self,
            von: SyncSnapshotExportService.preiseURL(fuerPeer: peer, in: syncOrdner)
        ) ?? SyncPreisSnapshot(preispunkte: [])

        return SyncPaketTeile(
            manifest: manifest, tombstones: tombstones, stamm: stamm,
            listen: listen, lernen: lernen, vorgaenge: vorgaenge, preise: preise
        )
    }

    func veroeffentlichePaket(_ teile: SyncPaketTeile, importErfolgreich: Bool) async -> Bool {
        guard let syncOrdner = offenerSyncOrdner else { return false }
        let eigenerOrdnerName = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
        let eigenerOrdner = syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(eigenerOrdnerName, isDirectory: true)

        guard await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.erstelleVerzeichnisKoordiniert(eigenerOrdner)
        }) == true else { return false }

        let encoder = SyncSnapshotExportService.encoder

        func schreibe<T: Encodable>(_ teil: T, nach url: URL) async {
            guard let daten = try? encoder.encode(teil) else { return }
            _ = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.schreibeKoordiniert(daten, nach: url) })
        }

        // Manifest nur bei erfolgreichem Import-Zyklus aktualisieren (Baustein C0).
        if importErfolgreich {
            await schreibe(
                teile.manifest,
                nach: SyncSnapshotExportService.manifestURL(fuerPeer: eigenerOrdnerName, in: syncOrdner)
            )
        }
        await schreibe(teile.tombstones, nach: SyncSnapshotExportService.tombstonesURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))
        await schreibe(teile.stamm, nach: SyncSnapshotExportService.stammURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))
        await schreibe(teile.listen, nach: SyncSnapshotExportService.listenURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))
        await schreibe(teile.lernen, nach: SyncSnapshotExportService.lernenURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))
        await schreibe(teile.vorgaenge, nach: SyncSnapshotExportService.vorgaengeURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))
        await schreibe(teile.preise, nach: SyncSnapshotExportService.preiseURL(fuerPeer: eigenerOrdnerName, in: syncOrdner))

        return true
    }

    // MARK: - Bereich C: Kauf-Append-Log

    func veroeffentlicheNeueKaufEintraege(_ eintraege: [KaufEintragSnapshot]) async -> Bool {
        guard let syncOrdner = offenerSyncOrdner else { return false }
        let kaeufeOrdner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        guard await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.erstelleVerzeichnisKoordiniert(kaeufeOrdner)
        }) == true else { return false }

        let dateiliste = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(kaeufeOrdner)
        }) ?? nil
        let vorhandeneDateinamen = Set((dateiliste ?? []).map(\.lastPathComponent))

        for eintrag in eintraege {
            let dateiname = "\(eintrag.id.uuidString).json"
            guard !vorhandeneDateinamen.contains(dateiname) else { continue }
            guard let daten = try? JSONEncoder().encode(eintrag) else { continue }
            _ = await SyncDateiZugriff.mitZeitlimit({
                SyncDateiZugriff.schreibeKoordiniert(daten, nach: kaeufeOrdner.appendingPathComponent(dateiname))
            })
        }
        return true
    }

    func empfangeNeueKaufEintraege(von peer: String) async -> [KaufEintragSnapshot] {
        guard let syncOrdner = offenerSyncOrdner else { return [] }
        let kaeufeOrdner = SyncSnapshotExportService.kaeufeOrdner(fuerPeer: peer, in: syncOrdner)
        return await Task.detached(priority: .utility) {
            guard let dateien = SyncDateiZugriff.listeKoordiniert(kaeufeOrdner) else { return [] }
            return dateien.filter { $0.pathExtension == "json" }.compactMap { url -> KaufEintragSnapshot? in
                guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
                return try? JSONDecoder().decode(KaufEintragSnapshot.self, from: daten)
            }
        }.value
    }

    // MARK: - Peer-Metadaten

    func multipeerGruppenID() async -> UUID? {
        // SyncOrdnerService.multipeerGruppenID(in:) öffnet keinen eigenen Scope —
        // mit offenerSyncOrdner direkt nutzbar.
        guard let syncOrdner = offenerSyncOrdner ?? SyncOrdnerService.gewaehlterOrdner() else { return nil }
        return await SyncOrdnerService.multipeerGruppenID(in: syncOrdner)
    }

    // MARK: - Private Hilfsmethoden

    private func ladeTeil<T: Decodable>(_ typ: T.Type, von url: URL) async -> T? {
        guard let daten = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.leseKoordiniert(url)
        }) ?? nil else { return nil }
        return try? JSONDecoder().decode(typ, from: daten)
    }

    /// Zehnstellig nullgepolstert, analog `SyncExportService.dateiname(fuer:)`.
    private func eventDateiname(fuer event: SyncEventExportDarstellung) -> String {
        let zaehlerText = String(event.lamportZaehler)
        let gepolstert = String(repeating: "0", count: max(0, 10 - zaehlerText.count)) + zaehlerText
        return "\(gepolstert)_\(event.id.uuidString).json"
    }

    /// Analog `SyncImportService.eventID(ausDateiname:)`.
    private func eventID(ausDateiname url: URL) -> UUID? {
        let basisname = url.deletingPathExtension().lastPathComponent
        guard let unterstrichIndex = basisname.firstIndex(of: "_") else { return nil }
        return UUID(uuidString: String(basisname[basisname.index(after: unterstrichIndex)...]))
    }
}
