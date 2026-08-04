import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncOrdnerServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([SyncPeerInfo.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    /// `UserDefaults.standard` ist prozessweit geteilt — vor/nach jedem
    /// Testfall zurücksetzen, damit sich Tests nicht gegenseitig beeinflussen
    /// (analog ``LamportClockTests``).
    private func cacheZuruecksetzen() {
        UserDefaults.standard.removeObject(forKey: SyncOrdnerService.eigenerPeerOrdnerNameCacheSchluessel)
    }

    @Test
    func eigenerPeerOrdnerNameEnthaeltGeraeteNamenUndBleibtBeiWiederholtemAufrufGleich() {
        cacheZuruecksetzen()
        defer { cacheZuruecksetzen() }
        let vorherigerOverride = DatabaseLeaseService.eigenerGeraeteNameOverride
        defer { DatabaseLeaseService.eigenerGeraeteNameOverride = vorherigerOverride }
        DatabaseLeaseService.eigenerGeraeteNameOverride = "Annas iPhone"

        let syncOrdner = macheTempSyncOrdner()
        let ersterAufruf = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
        let zweiterAufruf = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)

        #expect(ersterAufruf.hasPrefix("Annas-iPhone_"))
        #expect(ersterAufruf == zweiterAufruf)
    }

    @Test
    func eigenerPeerOrdnerNameBenenntBestehendenOrdnerBeiGeaendertemGeraeteNamenUmOhneDatenzuverlieren() throws {
        cacheZuruecksetzen()
        defer { cacheZuruecksetzen() }
        let vorherigerOverride = DatabaseLeaseService.eigenerGeraeteNameOverride
        defer { DatabaseLeaseService.eigenerGeraeteNameOverride = vorherigerOverride }

        let syncOrdner = macheTempSyncOrdner()
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)

        DatabaseLeaseService.eigenerGeraeteNameOverride = "Erster Name"
        let ersterName = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
        let ersterOrdner = peersOrdner.appendingPathComponent(ersterName, isDirectory: true)
        try FileManager.default.createDirectory(at: ersterOrdner, withIntermediateDirectories: true)
        let markerURL = ersterOrdner.appendingPathComponent("marker.txt")
        try Data("test".utf8).write(to: markerURL)

        DatabaseLeaseService.eigenerGeraeteNameOverride = "Zweiter Name"
        let zweiterName = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
        let zweiterOrdner = peersOrdner.appendingPathComponent(zweiterName, isDirectory: true)

        #expect(ersterName != zweiterName)
        #expect(!FileManager.default.fileExists(atPath: ersterOrdner.path))
        #expect(FileManager.default.fileExists(atPath: zweiterOrdner.appendingPathComponent("marker.txt").path))
    }

    @Test
    func hatVorhandenePeersIgnoriertEigenenNeuUndAltBenanntenOrdner() throws {
        let syncOrdner = macheTempSyncOrdner()
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        try FileManager.default.createDirectory(at: peersOrdner, withIntermediateDirectories: true)

        let eigenerNeuerOrdner = PeerOrdnerName.name(geraeteID: DatabaseLeaseService.geraeteID, geraeteName: "Dieses Gerät")
        try FileManager.default.createDirectory(
            at: peersOrdner.appendingPathComponent(eigenerNeuerOrdner, isDirectory: true), withIntermediateDirectories: true
        )
        #expect(!SyncOrdnerService.hatVorhandenePeers(in: syncOrdner))

        try FileManager.default.createDirectory(
            at: peersOrdner.appendingPathComponent("Fremdes-Geraet_abcdef", isDirectory: true), withIntermediateDirectories: true
        )
        #expect(SyncOrdnerService.hatVorhandenePeers(in: syncOrdner))
    }

    /// Rückkehrer-Erkennung (Peer-Lebenszyklus): der eigene Peer-Ordner ist
    /// noch da → weiterhin Mitglied.
    @Test
    func binIchNochMitgliedLiefertTrueWennEigenerOrdnerExistiert() async throws {
        cacheZuruecksetzen()
        defer { cacheZuruecksetzen() }
        let vorherigerOverride = DatabaseLeaseService.eigenerGeraeteNameOverride
        defer { DatabaseLeaseService.eigenerGeraeteNameOverride = vorherigerOverride }
        DatabaseLeaseService.eigenerGeraeteNameOverride = "Testgerät"

        let syncOrdner = macheTempSyncOrdner()
        let eigenerName = SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner)
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: peersOrdner.appendingPathComponent(eigenerName, isDirectory: true), withIntermediateDirectories: true
        )

        let ergebnis = await SyncOrdnerService.binIchNochMitglied(in: syncOrdner)
        #expect(ergebnis == true)
    }

    /// Rückkehrer-Erkennung: `peers/` existiert, der eigene Unterordner aber
    /// nicht (mehr) — die Gruppe hat dieses Gerät entfernt.
    @Test
    func binIchNochMitgliedLiefertFalseWennEigenerOrdnerFehlt() async throws {
        cacheZuruecksetzen()
        defer { cacheZuruecksetzen() }
        let vorherigerOverride = DatabaseLeaseService.eigenerGeraeteNameOverride
        defer { DatabaseLeaseService.eigenerGeraeteNameOverride = vorherigerOverride }
        DatabaseLeaseService.eigenerGeraeteNameOverride = "Testgerät"

        let syncOrdner = macheTempSyncOrdner()
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: peersOrdner.appendingPathComponent("Anderes-Geraet_abcdef", isDirectory: true), withIntermediateDirectories: true
        )

        let ergebnis = await SyncOrdnerService.binIchNochMitglied(in: syncOrdner)
        #expect(ergebnis == false)
    }

    /// Rückkehrer-Erkennung: ein nicht erreichbarer Ordner darf NICHT als
    /// „ausgeschlossen" gewertet werden (sonst würde ein rein transientes
    /// Problem fälschlich einen Voll-Neuaufbau auslösen) — `nil` statt `false`.
    @Test
    func binIchNochMitgliedLiefertNilBeiNichtErreichbaremOrdner() async {
        let nichtErreichbar = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("unterordner", isDirectory: true)
        let ergebnis = await SyncOrdnerService.binIchNochMitglied(in: nichtErreichbar)
        #expect(ergebnis == nil)
    }

    /// Peer-Lebenszyklus, bestätigte Entfernung: löscht sowohl den
    /// kompletten Peer-Ordner im geteilten Ordner als auch den lokalen
    /// ``SyncPeerInfo``-Merkposten.
    @Test
    func entfernePeerLoeschtOrdnerUndSyncPeerInfo() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let peerOrdnerName = "Anderes-Geraet_abcdef"
        let peerOrdner = peersOrdner.appendingPathComponent(peerOrdnerName, isDirectory: true)
        try FileManager.default.createDirectory(at: peerOrdner, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: peerOrdner.appendingPathComponent("manifest.json"))

        let peer = SyncPeerInfo(peerGeraeteID: "abcdef", geraeteName: "Anderes Gerät")
        context.insert(peer)
        try context.save()

        await SyncOrdnerService.entfernePeer(peer, in: syncOrdner, context: context)

        #expect(!FileManager.default.fileExists(atPath: peerOrdner.path))
        #expect(try context.fetch(FetchDescriptor<SyncPeerInfo>()).isEmpty)
    }
}
