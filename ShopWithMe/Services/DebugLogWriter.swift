import Foundation
import os

/// Generischer, mechanismus-unabhängiger Baustein für optionale Diagnose-Logs (siehe
/// `docs/LOGGING.md`). Kapselt Zwei-Datei-Rotation bei fester Größengrenze,
/// Spiegelung nach `os.Logger` und asynchrones Schreiben auf einem eigenen Actor,
/// damit das Protokollieren selbst die beobachteten Vorgänge nicht messbar
/// verlangsamt oder verfälscht.
///
/// Jeder konkrete Diagnose-Mechanismus (z.B. ``DatabaseDebugLogger``) ist ein dünner,
/// fachlicher Wrapper um eine Instanz dieses Typs.
actor DebugLogWriter {
    private let dateiURL: URL
    private let vorherigeDateiURL: URL
    private let maxGroesse: Int
    private let osLogger: Logger

    init(kategorie: String, dateiURL: URL, maxGroesse: Int = 1_000_000) {
        self.dateiURL = dateiURL
        self.vorherigeDateiURL = dateiURL.deletingPathExtension().appendingPathExtension("previous.log")
        self.maxGroesse = maxGroesse
        self.osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShopWithMe", category: kategorie)
    }

    /// Schreibt ein Ereignis im projektweit einheitlichen Zeilenformat (siehe
    /// `docs/LOGGING.md` → „Gemeinsame Prinzipien“) sowohl in die Log-Datei als auch
    /// (zusätzlich, nicht als Ersatz) nach `os.Logger`.
    func protokolliere(ereignis: String, details: String, geraeteName: String) {
        let zeitstempel = ISO8601DateFormatter().string(from: Date())
        let zeile = "[\(zeitstempel)] [\(geraeteName)] [\(ereignis)] \(details)\n"
        osLogger.log("\(ereignis, privacy: .public): \(details, privacy: .public)")
        schreibeInDatei(zeile)
    }

    private func schreibeInDatei(_ zeile: String) {
        rotiereFallsNoetig()
        guard let daten = zeile.data(using: .utf8) else { return }
        let dateiManager = FileManager.default
        if !dateiManager.fileExists(atPath: dateiURL.path) {
            dateiManager.createFile(atPath: dateiURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: dateiURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: daten)
    }

    private func rotiereFallsNoetig() {
        let dateiManager = FileManager.default
        guard let groesse = (try? dateiManager.attributesOfItem(atPath: dateiURL.path))?[.size] as? Int,
              groesse >= maxGroesse else { return }
        try? dateiManager.removeItem(at: vorherigeDateiURL)
        try? dateiManager.moveItem(at: dateiURL, to: vorherigeDateiURL)
    }

    /// Aktuelle Gesamtgröße (aktuelle + vorherige Datei) in Byte, für die Anzeige in
    /// den Einstellungen. Greift nur auf unveränderliche Konstanten zu, daher sicher
    /// `nonisolated`.
    nonisolated func aktuelleGroesse() -> Int {
        let dateiManager = FileManager.default
        let groesseAktuell = (try? dateiManager.attributesOfItem(atPath: dateiURL.path))?[.size] as? Int ?? 0
        let groesseVorherige = (try? dateiManager.attributesOfItem(atPath: vorherigeDateiURL.path))?[.size] as? Int ?? 0
        return groesseAktuell + groesseVorherige
    }

    nonisolated func leere() {
        let dateiManager = FileManager.default
        try? dateiManager.removeItem(at: dateiURL)
        try? dateiManager.removeItem(at: vorherigeDateiURL)
    }

    nonisolated var exportURLs: [URL] {
        let dateiManager = FileManager.default
        return [dateiURL, vorherigeDateiURL].filter { dateiManager.fileExists(atPath: $0.path) }
    }
}
