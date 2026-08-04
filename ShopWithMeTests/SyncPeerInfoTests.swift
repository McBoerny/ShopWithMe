import Foundation
import Testing
@testable import ShopWithMe

@MainActor
struct SyncPeerInfoTests {
    @Test
    func istWahrscheinlichTotIstFalseInnerhalbDerSchwelle() {
        let vorherigeSchwelle = SyncSnapshotImportService.maximalesSnapshotAlter
        defer { SyncSnapshotImportService.maximalesSnapshotAlter = vorherigeSchwelle }
        SyncSnapshotImportService.maximalesSnapshotAlter = 60 * 60

        let peer = SyncPeerInfo(
            peerGeraeteID: "peer-1", geraeteName: "Testgerät", zuletztGesehen: Date().addingTimeInterval(-30 * 60)
        )
        #expect(!peer.istWahrscheinlichTot)
    }

    @Test
    func istWahrscheinlichTotIstTrueJenseitsDerSchwelle() {
        let vorherigeSchwelle = SyncSnapshotImportService.maximalesSnapshotAlter
        defer { SyncSnapshotImportService.maximalesSnapshotAlter = vorherigeSchwelle }
        SyncSnapshotImportService.maximalesSnapshotAlter = 60 * 60

        let peer = SyncPeerInfo(
            peerGeraeteID: "peer-1", geraeteName: "Testgerät", zuletztGesehen: Date().addingTimeInterval(-2 * 60 * 60)
        )
        #expect(peer.istWahrscheinlichTot)
    }
}
