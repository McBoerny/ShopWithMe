import Foundation

/// Immer aktives Protokoll für ``DatenintegritaetsService`` — anders als
/// ``SyncDebugLogger``/``DatabaseDebugLogger`` nicht über einen Debug-Schalter
/// gesteuert: Reparaturen an baumelnden Referenzen sind selten, aber
/// sicherheitsrelevant, und sollen für den Anwender unabhängig davon
/// nachvollziehbar bleiben, ob gerade eine gezielte Debug-Sitzung läuft.
enum DatenintegritaetsLogger {
    private static let writer = DebugLogWriter(
        kategorie: "Datenintegritaet",
        dateiURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("datenintegritaet.log")
    )

    static func log(_ befund: String) {
        Task.detached(priority: .background) {
            let geraeteName = await DatabaseLeaseService.geraeteName
            await writer.protokolliere(ereignis: "reparatur", details: befund, geraeteName: geraeteName)
        }
    }

    static func gesamtGroesse() -> Int {
        writer.aktuelleGroesse()
    }

    static func leeren() {
        writer.leere()
    }

    static var exportURLs: [URL] {
        writer.exportURLs
    }
}
