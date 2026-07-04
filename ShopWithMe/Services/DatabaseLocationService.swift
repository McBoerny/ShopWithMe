import Foundation
import SwiftData

/// Fehler beim Ändern des Datenbank-Speicherorts.
enum DatabaseLocationError: LocalizedError {
    case zugriffVerweigert

    var errorDescription: String? {
        switch self {
        case .zugriffVerweigert:
            return "Zugriff auf den gewählten Ordner wurde verweigert."
        }
    }
}

/// Verwaltet einen optionalen, vom Anwender gewählten Speicherort für die
/// SwiftData-Datenbank außerhalb des App-Containers (z.B. ein lokal gespiegelter
/// Cloud-Ordner wie Dropbox oder OneDrive).
///
/// Es handelt sich bewusst um reine Dateiverlagerung ohne Sync-Logik — kein
/// iCloud/CloudKit. Bei einem Cloud-Sync-Ordner ist der Anwender selbst dafür
/// verantwortlich, dass jeweils nur ein Gerät gleichzeitig schreibend zugreift.
///
/// Eine Änderung des Speicherorts wird erst nach einem Neustart der App wirksam, da
/// der ``ModelContainer`` beim App-Start einmalig aufgebaut wird.
enum DatabaseLocationService {
    private static let bookmarkSchluessel = "datenbankOrdnerBookmark"
    private static let dateiName = "ShopWithMe.store"

    /// Der vom Anwender gewählte Ordner, sofern einer hinterlegt und das
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

    /// Die URL der Store-Datei im übergebenen Ordner.
    static func storeURL(inOrdner ordner: URL) -> URL {
        ordner.appendingPathComponent(dateiName)
    }

    /// Die aktuell aktive Store-URL: der gewählte Ordner, falls gesetzt, sonst der
    /// SwiftData-Standardpfad im App-Container.
    static func aktiveStoreURL(schema: Schema) -> URL {
        if let ordner = gewaehlterOrdner() {
            return storeURL(inOrdner: ordner)
        }
        return ModelConfiguration(schema: schema).url
    }

    /// Legt einen neuen Speicherort fest: kopiert die bestehenden
    /// SwiftData-Store-Dateien vom aktuellen Ort dorthin und merkt sich den Ordner
    /// per Security-Scoped-Bookmark.
    static func ordnerFestlegen(_ ordner: URL, aktuelleStoreURL: URL) throws {
        guard ordner.startAccessingSecurityScopedResource() else {
            throw DatabaseLocationError.zugriffVerweigert
        }
        defer { ordner.stopAccessingSecurityScopedResource() }

        try kopiereStoreDateien(von: aktuelleStoreURL, nachOrdner: ordner)

        let bookmark = try ordner.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: bookmarkSchluessel)
    }

    /// Setzt den Speicherort auf den Standardpfad im App-Container zurück (wirksam
    /// erst nach Neustart). Die zuvor an den Cloud-Ordner kopierten Dateien bleiben
    /// dort unangetastet liegen.
    static func aufStandardZuruecksetzen() {
        UserDefaults.standard.removeObject(forKey: bookmarkSchluessel)
    }

    private static func kopiereStoreDateien(von quelle: URL, nachOrdner ordner: URL) throws {
        let dateiManager = FileManager.default
        let quellOrdner = quelle.deletingLastPathComponent()
        let quellBasisname = quelle.lastPathComponent

        for suffix in ["", "-wal", "-shm"] {
            let quellDatei = quellOrdner.appendingPathComponent(quellBasisname + suffix)
            guard dateiManager.fileExists(atPath: quellDatei.path) else { continue }

            let zielDatei = ordner.appendingPathComponent(dateiName + suffix)
            if dateiManager.fileExists(atPath: zielDatei.path) {
                try dateiManager.removeItem(at: zielDatei)
            }
            try dateiManager.copyItem(at: quellDatei, to: zielDatei)
        }
    }
}
