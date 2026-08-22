import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Testhelfer für Mehrgeräte-Sync-Szenarien: verwaltet N simulierte Geräte mit je
/// eigenem in-Memory-SwiftData-Container und einem gemeinsamen Temp-Sync-Ordner.
///
/// **Vereinfachung gegenüber dem echten Gerätebetrieb**: Da `DatabaseLeaseService.geraeteID`
/// prozessweit global ist, filtert `importiereSnapshots` immer gegen diese ID. Jedes
/// simulierte Gerät bekommt eine eigene UUID als `geraeteID`, die vom realen
/// `DatabaseLeaseService.geraeteID` abweicht — sein eigener Peer-Ordner wird daher
/// nicht herausgefiltert und ebenfalls importiert. Dieser Re-Import ist idempotent
/// (CRDT: Union mit sich selbst = Identity), verursacht also keine Fehler.
@MainActor
final class MehrgeraeteSimulator {

    struct Geraet {
        let id: String        // simulierte geraeteID (UUID-String, ≠ DatabaseLeaseService.geraeteID)
        let name: String
        let container: ModelContainer
        // @MainActor: ModelContainer.mainContext ist MainActor-isoliert.
        @MainActor var context: ModelContext { container.mainContext }
    }

    let syncOrdner: URL
    private(set) var geraete: [Geraet]

    init(anzahlGeraete: Int) throws {
        precondition(anzahlGeraete >= 2)
        syncOrdner = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: syncOrdner, withIntermediateDirectories: true)

        let schema = Schema(SchemaV1.models)
        geraete = try (1...anzahlGeraete).map { index in
            let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [konfiguration])
            return Geraet(id: UUID().uuidString, name: "Gerät \(index)", container: container)
        }
    }

    /// Schreibt den aktuellen Zustand von `geraet` als vollständiges Peer-Paket in den
    /// gemeinsamen Sync-Ordner. Nutzt `SyncSnapshotExportService.erstellePaketTeile`
    /// für Snapshot-Inhalte; das Manifest erhält die simulierte geraeteID.
    func exportiere(_ geraet: Geraet) throws {
        let teile = SyncSnapshotExportService.erstellePaketTeile(context: geraet.context)
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion,
            erzeugtAm: Date(),
            geraeteID: geraet.id,
            geraeteName: geraet.name
        )
        let peerOrdner = syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraet.id, isDirectory: true)
        try FileManager.default.createDirectory(at: peerOrdner, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        try encoder.encode(manifest)
            .write(to: SyncSnapshotExportService.manifestURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.tombstones)
            .write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.stamm)
            .write(to: SyncSnapshotExportService.stammURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.listen)
            .write(to: SyncSnapshotExportService.listenURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.lernen)
            .write(to: SyncSnapshotExportService.lernenURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.vorgaenge)
            .write(to: SyncSnapshotExportService.vorgaengeURL(fuerPeer: geraet.id, in: syncOrdner))
        try encoder.encode(teile.preise)
            .write(to: SyncSnapshotExportService.preiseURL(fuerPeer: geraet.id, in: syncOrdner))
    }

    /// Importiert alle im Sync-Ordner vorhandenen Pakete in `geraet`s Context.
    func importiere(in geraet: Geraet) async {
        try? SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        await SyncSnapshotImportService.importiereSnapshots(context: geraet.context)
    }

    /// Alle Geräte exportieren, dann alle importieren — ein vollständiger
    /// Synchronisationsschritt.
    func synchronisiereAlleGeraete() async throws {
        for geraet in geraete { try exportiere(geraet) }
        for geraet in geraete { await importiere(in: geraet) }
    }

    var a: Geraet { geraete[0] }
    var b: Geraet { geraete[1] }
}
