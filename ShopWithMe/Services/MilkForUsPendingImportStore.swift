import Foundation

/// Übergibt den Text einer per Teilen-Funktion geteilten MilkForUs-Datei von der
/// ``ShopWithMeShareExtension`` an die Haupt-App, über eine gemeinsame
/// App-Group-Containerdatei — die Extension selbst hat keinen Zugriff auf den
/// SwiftData-Store (siehe `docs/MILKFORUS_IMPORT.md`). Diese Datei ist bewusst
/// Quelle für beide Targets (App + Extension, siehe `project.yml`), statt den
/// Inhalt zu duplizieren.
enum MilkForUsPendingImportStore {
    private static let appGroupID = "group.com.made4me.ShopWithMe"
    private static let dateiName = "MilkForUsPendingImport.txt"

    private static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(dateiName)
    }

    /// Von der Share Extension aufgerufen, um den geteilten Text für die Haupt-App
    /// bereitzulegen, bevor diese über `shopwithme://milkforus-import` geöffnet wird.
    static func speichern(_ text: String) {
        guard let containerURL else { return }
        try? text.write(to: containerURL, atomically: true, encoding: .utf8)
    }

    /// Von der Haupt-App beim Öffnen über `shopwithme://milkforus-import` aufgerufen:
    /// liest den bereitgelegten Text (falls vorhanden) und entfernt ihn danach, damit
    /// er nicht bei einem erneuten App-Start nochmal aufgegriffen wird.
    static func abholen() -> String? {
        guard let containerURL,
              let text = try? String(contentsOf: containerURL, encoding: .utf8)
        else { return nil }
        try? FileManager.default.removeItem(at: containerURL)
        return text
    }
}
