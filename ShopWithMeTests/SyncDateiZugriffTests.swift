import Foundation
import Testing
@testable import ShopWithMe

/// Deckt nur die lokale Korrektheit von ``SyncDateiZugriff/listeKoordiniert(_:)``
/// ab (GitHub #91, Abschnitt 40) — ob der koordinierte Zugriff das eigentlich
/// beobachtete Problem (verzögerte/ausbleibende Sichtbarkeit neuer
/// Peer-Dateien über iCloud Drive) tatsächlich behebt, lässt sich hiermit
/// NICHT verifizieren: Ein lokales Temp-Verzeichnis läuft nie über eine
/// File-Provider-Erweiterung, zeigt also nie die Cache-/Staleness-Effekte, um
/// die es im Live-Test ging. Diese Tests sichern nur ab, dass der
/// `NSFileCoordinator`-Wrapper selbst korrekt bleibt (kein Regressions-Risiko
/// durch den Umbau von rohem `contentsOfDirectory`).
struct SyncDateiZugriffTests {
    private func macheTempOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    @Test
    func listeKoordiniertLiefertAlleDateienUndUnterordnerEinesVorhandenenVerzeichnisses() throws {
        let ordner = macheTempOrdner()
        try Data("a".utf8).write(to: ordner.appendingPathComponent("a.json"))
        try Data("b".utf8).write(to: ordner.appendingPathComponent("b.json"))
        try FileManager.default.createDirectory(
            at: ordner.appendingPathComponent("unterordner", isDirectory: true), withIntermediateDirectories: true
        )

        let ergebnis = try #require(SyncDateiZugriff.listeKoordiniert(ordner))

        #expect(Set(ergebnis.map(\.lastPathComponent)) == ["a.json", "b.json", "unterordner"])
    }

    @Test
    func listeKoordiniertLiefertLeeresArrayFuerLeeresVerzeichnis() throws {
        let ordner = macheTempOrdner()

        let ergebnis = try #require(SyncDateiZugriff.listeKoordiniert(ordner))

        #expect(ergebnis.isEmpty)
    }

    @Test
    func listeKoordiniertLiefertNilFuerNichtVorhandenesVerzeichnis() {
        let nichtVorhandenerOrdner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(SyncDateiZugriff.listeKoordiniert(nichtVorhandenerOrdner) == nil)
    }
}
