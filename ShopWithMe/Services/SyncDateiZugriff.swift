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
/// Kumulative Datei-I/O-Zähler seit dem letzten ``SyncDateiZugriff/statistikZuruecksetzen()``
/// — reine Debug-Anzeige (`DebuggingView`), kein Einfluss auf das Sync-Verhalten.
/// Zählt nur die beiden mit Abstand häufigsten Operationen dieses Chokepoints
/// (``SyncDateiZugriff/leseKoordiniert(_:)``/``SyncDateiZugriff/schreibeKoordiniert(_:nach:)``),
/// nicht Verzeichnis-Listing/-Anlage/Löschen/Verschieben.
struct DateiZugriffStatistik: Sendable {
    var dateienGeoeffnet = 0
    var dateienErstellt = 0
    var bytesGelesen = 0
    var bytesGeschrieben = 0
    var seit = Date.now
}

enum SyncDateiZugriff {
    private static let statistikSperre = NSLock()
    private nonisolated(unsafe) static var _statistik = DateiZugriffStatistik()

    /// Aktueller Stand der Datei-I/O-Zähler seit dem letzten Reset. Thread-sicher
    /// per `NSLock`, da ``leseKoordiniert(_:)``/``schreibeKoordiniert(_:nach:)``
    /// von beliebigen Hintergrund-Tasks (`Task.detached`) aus gleichzeitig
    /// aufgerufen werden können.
    static var statistik: DateiZugriffStatistik {
        statistikSperre.withLock { _statistik }
    }

    /// Setzt alle Zähler auf 0 zurück und den „seit"-Zeitpunkt auf jetzt.
    static func statistikZuruecksetzen() {
        statistikSperre.withLock { _statistik = DateiZugriffStatistik() }
    }

    private static func vermerkeGelesen(bytes: Int) {
        statistikSperre.withLock {
            _statistik.dateienGeoeffnet += 1
            _statistik.bytesGelesen += bytes
        }
    }

    private static func vermerkeGeschrieben(bytes: Int, neuErstellt: Bool) {
        statistikSperre.withLock {
            _statistik.bytesGeschrieben += bytes
            if neuErstellt { _statistik.dateienErstellt += 1 }
        }
    }

    /// Blockierender Aufruf (Netzwerk-Download kann mehrere Sekunden dauern) —
    /// bewusst `nonisolated`, damit Aufrufer ihn per `Task.detached` vom
    /// `MainActor` fernhalten können, statt die UI während des Downloads zu
    /// blockieren.
    ///
    /// **Expliziter `startDownloadingUbiquitousItem`-Aufruf davor** (GitHub
    /// #92-Recherche): eine seit iOS 18.4 dokumentierte Regression lässt eine
    /// bereits einmal heruntergeladene Datei dauerhaft im Status
    /// `NSMetadataUbiquitousItemDownloadingStatusDownloaded` verharren, ohne
    /// automatisch eine neuere Remote-Version nachzuladen (Apple-Forum
    /// #785030, FB17662379, unbeantwortet) — koordiniertes Lesen allein löst
    /// laut Apples Doku zuverlässig nur den ERSTdownload eines noch nie
    /// materialisierten Platzhalters aus, nicht das Nachziehen einer neueren
    /// Version einer bereits lokal vorhandenen Datei. Passt zum beobachteten
    /// Symptom aus #91/#92 ("Sync läuft eine Weile, bleibt dann hängen").
    /// Fire-and-forget ohne Abschluss-Callback (kein API dafür) — Ergebnis
    /// wirkt sich bestenfalls erst im nächsten Zyklus aus, was zum ohnehin
    /// bestehenden Best-Effort-Design ohne Fehler-Backoff passt. `try?`, da
    /// die Methode für Nicht-iCloud-Ordner (Synology Drive u.ä.) einen Fehler
    /// liefert, was hier kein Sonderfall sein muss.
    nonisolated static func leseKoordiniert(_ url: URL) -> Data? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var ergebnis: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &fehler) { koordinierteURL in
            ergebnis = try? Data(contentsOf: koordinierteURL)
        }
        if fehler == nil, let ergebnis {
            vermerkeGelesen(bytes: ergebnis.count)
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
        // Gleicher Grund wie in ``leseKoordiniert(_:)`` — auch ein
        // Verzeichnis kann als bereits "heruntergeladen" hängen bleiben.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

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

    /// Schreibt Dateiinhalt über `NSFileCoordinator`, statt direkt per
    /// `Data.write(to:)` — analog zum bereits bestehenden koordinierten
    /// Schreib-Muster in ``SyncExportService``/``SyncSnapshotExportService``,
    /// hier als wiederverwendbarer Baustein für neue, einzelne Dateien (z.B.
    /// die Multipeer-Gruppen-ID-Markerdatei) statt einer weiteren eigenen
    /// Kopie desselben Coordinator-Musters.
    @discardableResult
    nonisolated static func schreibeKoordiniert(_ daten: Data, nach url: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var fehler: NSError?
        var erfolgreich = false
        var neuErstellt = false
        coordinator.coordinate(writingItemAt: url, options: [], error: &fehler) { zielURL in
            neuErstellt = !FileManager.default.fileExists(atPath: zielURL.path)
            erfolgreich = (try? daten.write(to: zielURL, options: .atomic)) != nil
        }
        if fehler == nil, erfolgreich {
            vermerkeGeschrieben(bytes: daten.count, neuErstellt: neuErstellt)
        }
        return fehler == nil && erfolgreich
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

    /// Zeitlimit für ``mitZeitlimit(sekunden:_:)`` — großzügig oberhalb der in
    /// `SyncPollingService` dokumentierten realistischen Latenz (bis zu 30s für
    /// iCloud Drive), damit ein normaler, nur langsamer Zugriff nicht fälschlich
    /// als Zeitüberschreitung gewertet wird. `static var` statt Konstante, damit
    /// Tests sie auf sehr kurze Werte setzen können.
    nonisolated(unsafe) static var zeitlimitSekunden: Double = 20

    /// Begrenzt einen der oben blockierenden koordinierten Aufrufe auf
    /// ``zeitlimitSekunden`` — bei einem tatsächlich nicht erreichbaren
    /// Remote-Ordner (nicht nur langsam, sondern z.B. mangels Internet dauerhaft
    /// hängend) haben `NSFileCoordinator`-Aufrufe sonst kein Limit, siehe
    /// ``leseKoordiniert(_:)``. Rückgabewert `nil` bedeutet entweder
    /// Zeitüberschreitung ODER dass `operation` selbst schon `nil`/`false`
    /// lieferte — Aufrufer behandeln beide Fälle ohnehin identisch („diesmal
    /// keine verlässliche Antwort, beim nächsten Zyklus erneut versuchen").
    /// Es gibt keine API, eine laufende `NSFileCoordinator`-Koordination
    /// abzubrechen — der unterlegene Zweig läuft im Hintergrund harmlos zu
    /// Ende, sein Ergebnis wird nur nicht mehr abgewartet.
    nonisolated static func mitZeitlimit<T: Sendable>(
        sekunden: Double = zeitlimitSekunden, _ operation: @escaping @Sendable () -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { gruppe in
            gruppe.addTask(priority: .utility) { operation() }
            gruppe.addTask {
                try? await Task.sleep(for: .seconds(sekunden))
                return nil
            }
            let ergebnis = await gruppe.next() ?? nil
            gruppe.cancelAll()
            return ergebnis
        }
    }
}
