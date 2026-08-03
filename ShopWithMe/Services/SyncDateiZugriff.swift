import Foundation

/// Liest eine Datei über `NSFileCoordinator`, statt direkt per `Data(contentsOf:)`
/// (GitHub #52). Ein ungeschütztes `Data(contentsOf:)` schlägt bei einer Datei,
/// die von einer File-Provider-Erweiterung (iCloud Drive, Synology Drive, …)
/// verwaltet wird, aber auf diesem Gerät noch nie heruntergeladen wurde, sofort
/// fehl, statt auf die Materialisierung zu warten — nur ein Cloud-Platzhalter ist
/// bereits lokal vorhanden. Ein `NSFileCoordinator`-Lesezugriff löst dagegen bei
/// Bedarf zuverlässig den Download aus und liefert erst danach.
///
/// Genau das führte dazu, dass ein einem Sync-Ordner **neu beitretendes** Gerät
/// beim allerersten Sync-Zyklus keine der bereits vorhandenen Peer-Dateien lesen
/// konnte: Bestehende Geräte hatten diese Dateien durch frühere Sync-Zyklen
/// längst lokal zwischengespeichert, das neue Gerät sah sie zum ersten Mal.
/// Analog zum bestehenden koordinierten Schreib-Muster in
/// ``SyncExportService``/``SyncSnapshotExportService``, nur für Lesezugriffe.
enum SyncDateiZugriff {
    /// Blockierender Aufruf (Netzwerk-Download kann mehrere Sekunden dauern) —
    /// bewusst `nonisolated`, damit Aufrufer ihn per `Task.detached` vom
    /// `MainActor` fernhalten können, statt die UI während des Downloads zu
    /// blockieren.
    nonisolated static func leseKoordiniert(_ url: URL) -> Data? {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var ergebnis: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &fehler) { koordinierteURL in
            ergebnis = try? Data(contentsOf: koordinierteURL)
        }
        return fehler == nil ? ergebnis : nil
    }

    /// Listet ein Verzeichnis über `NSFileCoordinator`, statt direkt per
    /// `FileManager.contentsOfDirectory` (GitHub #91-Nachfolgefund: Live-Test
    /// zeigte, dass neue Peer-Dateien in einem iCloud-Drive-Sync-Ordner auch
    /// nach mehreren Zyklen nicht auftauchten, obwohl sie auf dem
    /// Herkunftsgerät längst geschrieben waren — erst manuelles Öffnen des
    /// Ordners in der Files-App zeigte sie). Ein ungeschütztes
    /// `contentsOfDirectory` liest offenbar nur einen lokal bereits bekannten
    /// Verzeichnis-Stand; ein koordinierter Lesezugriff gibt der
    /// File-Provider-Erweiterung (iCloud Drive, Synology Drive, …) dieselbe
    /// Gelegenheit, vor der Rückgabe einen frischen Stand zu liefern, wie sie
    /// ``leseKoordiniert(_:)`` bereits für einzelne Dateien nutzt — analog zum
    /// dortigen GitHub #52-Fund, nur eine Ebene höher (Verzeichnis-Listing
    /// statt Dateiinhalt).
    ///
    /// Blockierender Aufruf, aus denselben Gründen wie ``leseKoordiniert(_:)``
    /// bewusst `nonisolated` — Aufrufer aus `@MainActor`-Kontext sollten ihn
    /// per `Task.detached` vom `MainActor` fernhalten.
    nonisolated static func listeKoordiniert(_ url: URL) -> [URL]? {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var ergebnis: [URL]?
        coordinator.coordinate(readingItemAt: url, options: [], error: &fehler) { koordinierteURL in
            ergebnis = try? FileManager.default.contentsOfDirectory(
                at: koordinierteURL, includingPropertiesForKeys: nil
            )
        }
        return fehler == nil ? ergebnis : nil
    }

    /// Legt ein Verzeichnis (inkl. Zwischenverzeichnissen) über
    /// `NSFileCoordinator` an, statt direkt per
    /// `FileManager.createDirectory` (GitHub #91-Nachfolgefund: Apples
    /// iCloud-Dokumentation verlangt Koordination für JEDEN Schreibzugriff
    /// auf einen ubiquitären Ordner, nicht nur für Dateiinhalte). Keine
    /// besondere `WritingOptions` nötig — das Anlegen eines noch nicht
    /// existierenden Verzeichnisses ist ein einfaches „Item aktualisieren",
    /// kein Ersetzen/Löschen/Verschieben.
    @discardableResult
    nonisolated static func erstelleVerzeichnisKoordiniert(_ url: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var erfolgreich = false
        coordinator.coordinate(writingItemAt: url, options: [], error: &fehler) { zielURL in
            erfolgreich = (try? FileManager.default.createDirectory(
                at: zielURL, withIntermediateDirectories: true
            )) != nil
        }
        return fehler == nil && erfolgreich
    }

    /// Löscht über `NSFileCoordinator` mit `.forDeleting`, statt direkt per
    /// `FileManager.removeItem` (GitHub #91-Nachfolgefund). Löscht auch
    /// komplette (Unter-)Ordner rekursiv, kein separates
    /// Verzeichnis-Löschwerkzeug nötig.
    nonisolated static func loescheKoordiniert(_ url: URL) {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &fehler) { zielURL in
            try? FileManager.default.removeItem(at: zielURL)
        }
    }

    /// Verschiebt/benennt um über `NSFileCoordinator`, statt direkt per
    /// `FileManager.moveItem` (GitHub #91-Nachfolgefund). Nutzt exakt das von
    /// Apples `NSFileCoordinator.h`-Header dokumentierte Muster für einen
    /// Move: Quelle mit `.forMoving`, Ziel mit `.forReplacing` — beide in
    /// einem einzigen Koordinationsaufruf, damit kein Beobachter einen
    /// Zwischenzustand sieht.
    @discardableResult
    nonisolated static func verschiebeKoordiniert(von quelle: URL, nach ziel: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var erfolgreich = false
        coordinator.coordinate(
            writingItemAt: quelle, options: .forMoving,
            writingItemAt: ziel, options: .forReplacing,
            error: &fehler
        ) { neueQuelle, neuesZiel in
            erfolgreich = (try? FileManager.default.moveItem(at: neueQuelle, to: neuesZiel)) != nil
        }
        return fehler == nil && erfolgreich
    }
}
