import Foundation
import Testing
@testable import ShopWithMe

@MainActor
struct SyncOrdnerServiceTests {
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
}
