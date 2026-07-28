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
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`,
/// GitHub #39) — bewusst getrennt von ``DatabaseLocationService``: Dort wird die
/// aktive Store-Datei selbst an einen neuen Ort verlagert (Einzelnutzer-Fall,
/// keine Sync-Logik). Hier wird nur ein zusätzlicher Ordner referenziert, in den
/// ``SyncExportService`` Peer-Exportdateien schreibt — die lokale Datenbank
/// bleibt für den Mehrbenutzer-Fall immer am Standardpfad (siehe Plan-Dokument
/// Abschnitt 2).
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
    /// Anders als `DatabaseLocationService.ordnerFestlegen` wird hier nichts
    /// kopiert oder verschoben — der Ordner dient ausschließlich als Ziel für
    /// Peer-Exportdateien.
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
}
