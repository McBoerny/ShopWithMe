import Foundation

/// Fachlicher Wrapper um ``DebugLogWriter`` für das Micro-/Session-Lease-Verfahren
/// (siehe `docs/DATABASE_CONCURRENCY.md`, `docs/LOGGING.md`). Protokolliert nur, wenn
/// der Debug-Modus in den Einstellungen aktiv ist — Standard: aus, kein spürbarer
/// Overhead bei Deaktivierung (In-Memory-gecachter Schalter-Zustand).
enum DatabaseDebugLogger {
    /// Protokollierte Ereignistypen (Lebenszyklus-Ebene, siehe `docs/LOGGING.md`).
    enum Ereignis: String {
        case storeOpenStart = "store_open_start"
        case storeOpenSuccess = "store_open_success"
        case storeOpenFailure = "store_open_failure"
        case leaseAcquireAttempt = "lease_acquire_attempt"
        case leaseAcquireSuccess = "lease_acquire_success"
        case leaseAcquireDeniedReadonly = "lease_acquire_denied_readonly"
        case leaseStaleTakeover = "lease_stale_takeover"
        case leaseRelease = "lease_release"
        case saveSuccess = "save_success"
        case saveFailure = "save_failure"
        case dedupeConflictDetected = "dedupe_conflict_detected"
        case debugModeEnabled = "debug_mode_enabled"
        case debugModeDisabled = "debug_mode_disabled"
    }

    private static let aktivSchluessel = "datenbankDebugModusAktiv"

    /// In-Memory-gecachter Schalter-Zustand, damit ein deaktivierter Debug-Modus
    /// keinen `UserDefaults`-Zugriff pro Ereignis verursacht. Nur über ``istAktiv``
    /// gelesen/geschrieben (von der Einstellungen-UI auf dem Main-Thread) — daher
    /// bewusst `nonisolated(unsafe)` statt eines Actors, damit ``log(_:details:)``
    /// von jedem Aufrufkontext aus synchron geprüft werden kann.
    nonisolated(unsafe) private static var istAktivCache: Bool = UserDefaults.standard.bool(forKey: aktivSchluessel)

    static var istAktiv: Bool {
        get { istAktivCache }
        set {
            let vorher = istAktivCache
            istAktivCache = newValue
            UserDefaults.standard.set(newValue, forKey: aktivSchluessel)
            guard vorher != newValue else { return }
            log(newValue ? .debugModeEnabled : .debugModeDisabled, details: "")
        }
    }

    private static let lokalerWriter = DebugLogWriter(
        kategorie: "DatabaseConcurrency",
        dateiURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("db-debug.log")
    )

    /// Zusätzlicher Writer im gemeinsamen DB-Ordner, sofern einer konfiguriert ist —
    /// siehe `docs/LOGGING.md` → „Speicherort“. `nil`, solange kein gemeinsamer Ordner
    /// gewählt wurde oder ``konfiguriere(geteilterOrdner:)`` noch nicht aufgerufen
    /// wurde. Wird einmalig beim App-Start gesetzt, danach nur noch lesend
    /// zugegriffen — daher bewusst `nonisolated(unsafe)`, siehe ``istAktivCache``.
    nonisolated(unsafe) private static var geteilterWriter: DebugLogWriter?

    /// Muss beim App-Start aufgerufen werden, sobald der aktive Datenbank-Ordner
    /// bekannt ist, damit Debug-Logs zusätzlich dorthin gespiegelt werden (für die
    /// geräteübergreifende Auswertung nach einem Live-Test).
    static func konfiguriere(geteilterOrdner: URL?) {
        guard let geteilterOrdner else {
            geteilterWriter = nil
            return
        }
        let kurzeGeraeteID = DatabaseLeaseService.geraeteID.prefix(8)
        let dateiname = "\(kurzeGeraeteID)-debug.log"
        geteilterWriter = DebugLogWriter(kategorie: "DatabaseConcurrency", dateiURL: geteilterOrdner.appendingPathComponent(dateiname))
    }

    static func log(_ ereignis: Ereignis, details: String) {
        guard istAktiv else { return }
        Task.detached(priority: .background) {
            let geraeteName = await DatabaseLeaseService.geraeteName
            await lokalerWriter.protokolliere(ereignis: ereignis.rawValue, details: details, geraeteName: geraeteName)
            await geteilterWriter?.protokolliere(ereignis: ereignis.rawValue, details: details, geraeteName: geraeteName)
        }
    }

    /// Aktuelle Gesamtgröße aller Log-Dateien (lokal + geteilt) in Byte.
    static func gesamtGroesse() -> Int {
        lokalerWriter.aktuelleGroesse() + (geteilterWriter?.aktuelleGroesse() ?? 0)
    }

    static func leeren() {
        lokalerWriter.leere()
        geteilterWriter?.leere()
    }

    static var exportURLs: [URL] {
        lokalerWriter.exportURLs + (geteilterWriter?.exportURLs ?? [])
    }
}
