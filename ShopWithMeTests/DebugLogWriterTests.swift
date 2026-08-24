import Foundation
import Testing
@testable import ShopWithMe

/// Tests für ``DebugLogWriter`` (siehe `docs/LOGGING.md`): Zeilenformat, Rotation,
/// Leeren.
struct DebugLogWriterTests {
    private func macheTempDateiURL() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner.appendingPathComponent("test-debug.log")
    }

    @Test
    func protokolliertEreignisImEinheitlichenZeilenformat() async throws {
        let dateiURL = macheTempDateiURL()
        let writer = DebugLogWriter(abteilung: "Test", dateiURL: dateiURL)

        await writer.protokolliere(ereignis: "lease_acquire_success", details: "micro", geraeteName: "Test-iPhone")

        let inhalt = try String(contentsOf: dateiURL, encoding: .utf8)
        #expect(inhalt.contains("[Test-iPhone]"))
        #expect(inhalt.contains("[lease_acquire_success]"))
        #expect(inhalt.contains("micro"))
        #expect(inhalt.hasSuffix("\n"))
    }

    @Test
    func rotiertBeiUeberschreitenDerGroessengrenze() async throws {
        let dateiURL = macheTempDateiURL()
        // Sehr kleine Grenze, damit schon wenige Zeilen die Rotation auslösen.
        let writer = DebugLogWriter(abteilung: "Test", dateiURL: dateiURL, maxGroesse: 50)

        for index in 0..<20 {
            await writer.protokolliere(ereignis: "save_success", details: "Eintrag \(index)", geraeteName: "Test-iPhone")
        }

        let vorherigeDateiURL = dateiURL.deletingPathExtension().appendingPathExtension("previous.log")
        #expect(FileManager.default.fileExists(atPath: vorherigeDateiURL.path))
        // Aktuelle Datei bleibt klein (nur die Zeilen seit der letzten Rotation).
        #expect(writer.aktuelleGroesse() > 0)
    }

    @Test
    func leerenEntferntBeideDateien() async throws {
        let dateiURL = macheTempDateiURL()
        let writer = DebugLogWriter(abteilung: "Test", dateiURL: dateiURL, maxGroesse: 50)

        for index in 0..<20 {
            await writer.protokolliere(ereignis: "save_success", details: "Eintrag \(index)", geraeteName: "Test-iPhone")
        }
        #expect(writer.aktuelleGroesse() > 0)

        writer.leere()

        #expect(writer.aktuelleGroesse() == 0)
        #expect(writer.exportURLs.isEmpty)
    }
}
