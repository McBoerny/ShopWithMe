import Foundation
import Testing
@testable import ShopWithMe

struct SyncOrdnerBeobachterTests {
    @Test
    func erkenntNeueDateiImBeobachtetenOrdner() async throws {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

        let erkannt = Erkennung()
        let beobachter = SyncOrdnerBeobachter(peersOrdner: ordner) {
            Task { await erkannt.setzen() }
        }
        defer { beobachter.beenden() }

        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        let zielURL = ordner.appendingPathComponent("neuer-peer.json")
        coordinator.coordinate(writingItemAt: zielURL, options: [], error: &fehler) { koordinierteURL in
            try? Data("{}".utf8).write(to: koordinierteURL)
        }
        #expect(fehler == nil)

        for _ in 0..<50 {
            if await erkannt.wert { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await erkannt.wert)
    }
}

private actor Erkennung {
    private(set) var wert = false
    func setzen() { wert = true }
}
