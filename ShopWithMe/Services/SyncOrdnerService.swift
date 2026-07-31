import Foundation

/// Fehler beim Festlegen des Sync-Ordners.
enum SyncOrdnerError: LocalizedError {
    case zugriffVerweigert

    var errorDescription: String? {
        switch self {
        case .zugriffVerweigert:
            return "Zugriff auf den gewählten Ordner wurde verweigert."
        }
    }
}

/// Verwaltet den vom Anwender gewählten geteilten Ordner für die
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_VERLAUF.md`,
/// GitHub #39). Hier wird nur ein zusätzlicher Ordner referenziert, in den
/// ``SyncExportService`` Peer-Exportdateien schreibt — die lokale Datenbank
/// bleibt immer am Standardpfad (siehe Plan-Dokument Abschnitt 2, GitHub #54).
enum SyncOrdnerService {
    private static let bookmarkSchluessel = "syncOrdnerBookmark"

    /// Der vom Anwender gewählte Sync-Ordner, sofern einer hinterlegt und das
    /// Security-Scoped-Bookmark noch gültig ist.
    static func gewaehlterOrdner() -> URL? {
        guard let daten = UserDefaults.standard.data(forKey: bookmarkSchluessel) else { return nil }
        var veraltet = false
        guard let url = try? URL(
            resolvingBookmarkData: daten,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &veraltet
        ) else { return nil }
        return url
    }

    /// Legt den Sync-Ordner fest und merkt ihn sich per Security-Scoped-Bookmark.
    /// Es wird nichts kopiert oder verschoben — der Ordner dient ausschließlich
    /// als Ziel für Peer-Exportdateien.
    static func ordnerFestlegen(_ ordner: URL) throws {
        guard ordner.startAccessingSecurityScopedResource() else {
            throw SyncOrdnerError.zugriffVerweigert
        }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let bookmark = try ordner.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: bookmarkSchluessel)
    }

    /// Entfernt den hinterlegten Sync-Ordner — Datensynchronisation ist danach
    /// deaktiviert (``SyncExportService`` schreibt nichts mehr), bereits
    /// geschriebene Peer-Dateien im Ordner bleiben unangetastet liegen.
    static func ordnerEntfernen() {
        UserDefaults.standard.removeObject(forKey: bookmarkSchluessel)
    }

    /// Ob `ordner` bereits Peer-Unterordner anderer Geräte enthält (unter
    /// `peers/`, das eigene Gerät ausgenommen) — Grundlage für die
    /// „Zusammenführen"/„Ersetzen"-Abfrage beim erstmaligen Verknüpfen
    /// (``SyncErsetzenService``, GitHub #63). `false` sowohl bei einem völlig
    /// neuen Ordner als auch, falls der Zugriff fehlschlägt.
    static func hatVorhandenePeers(in ordner: URL) -> Bool {
        guard ordner.startAccessingSecurityScopedResource() else { return false }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
        guard let peerVerzeichnisse = try? FileManager.default.contentsOfDirectory(
            at: peersOrdner, includingPropertiesForKeys: nil
        ) else { return false }

        return peerVerzeichnisse.contains { $0.lastPathComponent != DatabaseLeaseService.geraeteID }
    }
}
