import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Peer-Lebenszyklus, Baustein C: ``SyncTombstoneService/raeumeAlteTombstonesAufFallsFaellig(context:)``.
@MainActor
struct SyncTombstoneServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([SyncTombstone.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    private func schreibeFremdenPeerManifest(erzeugtAm: Date, in syncOrdner: URL) throws {
        let peerOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent("Fremdes-Geraet_abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: peerOrdner, withIntermediateDirectories: true)
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: erzeugtAm,
            geraeteID: "fremdes-geraet", geraeteName: "Fremdes Gerät"
        )
        try JSONEncoder().encode(manifest).write(to: peerOrdner.appendingPathComponent("manifest.json"))
    }

    @Test
    func raeumtNurAlteTombstonesAuf() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        SyncTombstoneService.letzteBereinigung = nil
        defer { SyncTombstoneService.letzteBereinigung = nil }

        // Anderer Peer mit vollständigem Sync vor 60s -> Wasserstand.
        try schreibeFremdenPeerManifest(erzeugtAm: Date().addingTimeInterval(-60), in: syncOrdner)

        let alterTombstone = SyncTombstone(
            entitaetsArt: SyncEntitaetsArt.artikel, geloeschteID: UUID(), geloeschtAm: Date().addingTimeInterval(-120)
        )
        let neuerTombstone = SyncTombstone(
            entitaetsArt: SyncEntitaetsArt.artikel, geloeschteID: UUID(), geloeschtAm: Date().addingTimeInterval(-30)
        )
        context.insert(alterTombstone)
        context.insert(neuerTombstone)
        try context.save()

        await SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context: context)

        let verbleibend = try context.fetch(FetchDescriptor<SyncTombstone>())
        #expect(verbleibend.map(\.id) == [neuerTombstone.id])
    }

    /// Kein anderer Peer bekannt -> der Wasserstand liefert `nil` -> nichts
    /// wird gelöscht, egal wie alt ein Tombstone ist.
    @Test
    func raeumtNichtsOhneAnderenBekanntenPeer() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        SyncTombstoneService.letzteBereinigung = nil
        defer { SyncTombstoneService.letzteBereinigung = nil }

        let tombstone = SyncTombstone(
            entitaetsArt: SyncEntitaetsArt.artikel, geloeschteID: UUID(), geloeschtAm: Date().addingTimeInterval(-400 * 24 * 60 * 60)
        )
        context.insert(tombstone)
        try context.save()

        await SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context: context)

        #expect(try context.fetch(FetchDescriptor<SyncTombstone>()).count == 1)
    }

    /// Analog dem Event-Vorbild: ein bereits kürzlich gelaufener Aufräumlauf
    /// wird nicht sofort wiederholt.
    @Test
    func bereinigungLaeuftHoechstensEinmalProIntervall() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        SyncTombstoneService.letzteBereinigung = Date()
        defer { SyncTombstoneService.letzteBereinigung = nil }

        try schreibeFremdenPeerManifest(erzeugtAm: Date(), in: syncOrdner)

        let tombstone = SyncTombstone(
            entitaetsArt: SyncEntitaetsArt.artikel, geloeschteID: UUID(), geloeschtAm: Date().addingTimeInterval(-120)
        )
        context.insert(tombstone)
        try context.save()

        await SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context: context)

        #expect(try context.fetch(FetchDescriptor<SyncTombstone>()).count == 1)
    }
}
