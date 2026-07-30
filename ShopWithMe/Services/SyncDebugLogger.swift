import Foundation

/// Fachlicher Wrapper um ``DebugLogWriter`` für die Datensynchronisation
/// (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, GitHub #39, `docs/LOGGING.md`).
/// Protokolliert nur, wenn der Debug-Modus in den Einstellungen aktiv ist —
/// Standard: aus, kein spürbarer Overhead bei Deaktivierung (In-Memory-gecachter
/// Schalter-Zustand, analog ``DatabaseDebugLogger``).
///
/// **Zweck:** Der Plan-Dokument-Abschnitt „Realistische Erwartung ohne
/// Multipeer" schätzt die tatsächliche Sync-Latenz (5–30s iCloud Drive, 1–10s
/// Synology Drive) auf Basis von `docs/DATABASE_CONCURRENCY.md`, nicht auf
/// Basis echter Messungen — und Phase 4 verzichtet bewusst auf Fehler-Backoff,
/// weil die Sync-Funktionen bisher keine auswertbare Erfolgs-/Fehlerrückmeldung
/// liefern. Dieses Protokoll schafft die fehlende Datengrundlage für beides:
/// tatsächlich beobachtete Latenz (wie alt war ein empfangenes Update, als es
/// hier ankam) und tatsächliche Fehlerhäufigkeit, um die Polling-Intervalle aus
/// ``SyncPollingService`` später mit echten Praxisdaten statt Annahmen
/// nachzujustieren.
///
/// Anders als ``DatabaseDebugLogger`` bewusst **nur lokal**, ohne Spiegelung in
/// den Sync-Ordner — die für die Optimierung relevanten Werte (Alter eines
/// empfangenen Updates, Dauer eines Sync-Zyklus) sind bereits aus rein lokaler
/// Sicht aussagekräftig; eine geräteübergreifende Zusammenführung würde
/// zusätzliche Sicherheits-Scope-Handhabung beim Schreiben in den Sync-Ordner
/// erfordern, ohne für den Optimierungszweck nötig zu sein.
enum SyncDebugLogger {
    /// Protokollierte Ereignistypen (siehe `docs/LOGGING.md` → Abschnitt
    /// „Datensynchronisation").
    enum Ereignis: String {
        case zyklusStart = "sync_zyklus_start"
        case zyklusEnde = "sync_zyklus_ende"
        case eventEmpfangen = "sync_event_empfangen"
        case snapshotEmpfangen = "sync_snapshot_empfangen"
        case ordnerZugriffFehlgeschlagen = "sync_ordner_zugriff_fehlgeschlagen"
        case baumelndeReferenzGefunden = "sync_baumelnde_referenz_gefunden"
        case einkaufslistenStand = "sync_einkaufslisten_stand"
        case eventNichtAnwendbar = "sync_event_nicht_anwendbar"
        case peerVerworfenAltersgrenze = "sync_peer_verworfen_altersgrenze"
        case snapshotUnveraendertUebersprungen = "sync_snapshot_unveraendert_uebersprungen"
        case eventAufgegeben = "sync_event_aufgegeben"
        case debugModeEnabled = "debug_mode_enabled"
        case debugModeDisabled = "debug_mode_disabled"
    }

    private static let aktivSchluessel = "datensyncDebugModusAktiv"

    /// In-Memory-gecachter Schalter-Zustand, siehe
    /// ``DatabaseDebugLogger/istAktivCache`` für die identische Begründung.
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

    private static let writer = DebugLogWriter(
        kategorie: "Datensynchronisation",
        dateiURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sync-debug.log")
    )

    static func log(_ ereignis: Ereignis, details: String) {
        guard istAktiv else { return }
        Task.detached(priority: .background) {
            let geraeteName = await DatabaseLeaseService.geraeteName
            await writer.protokolliere(ereignis: ereignis.rawValue, details: details, geraeteName: geraeteName)
        }
    }

    /// Protokolliert das Alter eines empfangenen Updates (Bereich-A-Event oder
    /// Bereich-B/C/D-Snapshot) — die Differenz zwischen jetzt und dem
    /// Erzeugungszeitpunkt auf dem Herkunftsgerät. Grundlage für die
    /// tatsächlich beobachtete Sync-Latenz (siehe Typ-Doku).
    static func protokolliereAlter(_ ereignis: Ereignis, erzeugtAm: Date, zusatz: String = "") {
        guard istAktiv else { return }
        let alterSekunden = Date().timeIntervalSince(erzeugtAm)
        let details = zusatz.isEmpty
            ? "alter_sekunden=\(String(format: "%.1f", alterSekunden))"
            : "alter_sekunden=\(String(format: "%.1f", alterSekunden)) \(zusatz)"
        log(ereignis, details: details)
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
