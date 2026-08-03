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
        /// Diagnose für den Live-Test-Fund „Einkauf abschließen bewirkt
        /// scheinbar nichts" (Session 2026-08-03): protokolliert bei jedem Tap
        /// auf „Einkauf abschließen", wie viele offene Vorgänge für dieselbe
        /// ``Einkaufsliste`` existieren und wie sich die listenweit sichtbaren
        /// abgehakten Einträge auf sie verteilen — Verdacht ist, dass
        /// ``EinkaufenView/EinkaufslisteView/einkaufAbschliessen()`` nur den
        /// EINEN zur aktuellen Geschäftsauswahl gehörenden Vorgang schließt,
        /// während listenweit sichtbare (siehe
        /// ``Einkaufsvorgang/abgehakteKaufEintraege(fuerListe:unter:)``)
        /// abgehakte Artikel an einem ANDEREN, weiterhin offenen Vorgang für
        /// dieselbe Liste hängen können (z.B. nach einem Geschäftswechsel).
        case einkaufAbschlussAusgeloest = "einkauf_abschluss_ausgeloest"
        /// Bestätigung NACH dem Schließen aller Duplikat-Vorgänge (siehe
        /// ``einkaufAbschlussAusgeloest``) — `verbleibendOffenMitEintraegenFuerListe`
        /// sollte im Erfolgsfall `0` sein. Ein Wert `> 0` zeigt direkt im Log,
        /// dass der Fix (noch) eine Lücke hat, statt es aus einem stillen
        /// „hat nicht funktioniert" im nächsten Testlauf erneut erraten zu müssen.
        case einkaufAbschlussDurchgefuehrt = "einkauf_abschluss_durchgefuehrt"
        case debugModeEnabled = "debug_mode_enabled"
        case debugModeDisabled = "debug_mode_disabled"

        /// Mindest-Protokollstufe, ab der dieses Ereignis geschrieben wird
        /// (siehe ``Protokollstufe``-Typ-Doku). Anders als beim
        /// Sync-Protokoll gibt es hier (Stand jetzt) kein
        /// wiederkehrendes-mehrfach-pro-Zyklus-Muster wie
        /// `sync_snapshot_unveraendert_uebersprungen` — das Micro-Lease-
        /// Verfahren ist aktionsgetrieben (ein Lease pro Speichervorgang),
        /// nicht poll-getrieben, siehe `docs/DATABASE_CONCURRENCY.md`.
        /// ``Protokollstufe/ausfuehrlich`` ist daher aktuell nur ein
        /// Platzhalter für künftige, tiefere Diagnose-Ereignisse.
        var mindestStufe: Protokollstufe {
            switch self {
            case .storeOpenFailure, .leaseAcquireDeniedReadonly, .leaseStaleTakeover, .saveFailure,
                 .dedupeConflictDetected, .debugModeEnabled, .debugModeDisabled:
                return .fehler
            case .storeOpenStart, .storeOpenSuccess, .leaseAcquireAttempt, .leaseAcquireSuccess,
                 .leaseRelease, .saveSuccess, .einkaufAbschlussAusgeloest, .einkaufAbschlussDurchgefuehrt:
                return .standard
            }
        }
    }

    /// Nicht `private`, damit ``DatabaseDebugLoggerTests`` isolierte
    /// `UserDefaults`-Instanzen mit denselben Schlüsseln befüllen kann.
    static let stufeSchluessel = "datenbankProtokollstufe"
    /// Alter, vor der Stufen-Einführung genutzter Bool-Key — nur noch für die
    /// einmalige Migration bestehender Installationen gelesen (siehe
    /// ``ermittleMigrierteStartstufe(defaults:)``).
    static let alterAktivSchluessel = "datenbankDebugModusAktiv"

    /// In-Memory-gecachter Zustand, damit ein deaktiviertes Protokoll keinen
    /// `UserDefaults`-Zugriff pro Ereignis verursacht. Nur über ``stufe``/
    /// ``istAktiv`` gelesen/geschrieben (von der Einstellungen-UI auf dem
    /// Main-Thread) — daher bewusst `nonisolated(unsafe)` statt eines
    /// Actors, damit ``log(_:details:)`` von jedem Aufrufkontext aus
    /// synchron geprüft werden kann.
    nonisolated(unsafe) private static var stufeCache: Protokollstufe = ermittleMigrierteStartstufe()

    /// `defaults`-Parameter ausschließlich für ``DatabaseDebugLoggerTests``,
    /// um die Migrationslogik isoliert zu testen — die statische
    /// ``stufeCache`` selbst wird pro Prozess nur einmal lazy initialisiert
    /// und lässt sich danach nicht erneut auslösen.
    static func ermittleMigrierteStartstufe(defaults: UserDefaults = .standard) -> Protokollstufe {
        if let gespeichert = defaults.object(forKey: stufeSchluessel) as? Int, let stufe = Protokollstufe(rawValue: gespeichert) {
            return stufe
        }
        // Migration: vor der Stufen-Einführung gab es nur „an"/„aus" — „an"
        // wird zu `.standard`, dem bisherigen tatsächlichen Verhalten.
        let migriert: Protokollstufe = defaults.bool(forKey: alterAktivSchluessel) ? .standard : .aus
        defaults.set(migriert.rawValue, forKey: stufeSchluessel)
        return migriert
    }

    static var stufe: Protokollstufe {
        get { stufeCache }
        set {
            let vorher = stufeCache
            stufeCache = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: stufeSchluessel)
            guard (vorher == .aus) != (newValue == .aus) else { return }
            log(newValue == .aus ? .debugModeDisabled : .debugModeEnabled, details: "")
        }
    }

    /// Kompatibler Zugriff für Aufrufstellen, die nur „protokolliert
    /// überhaupt etwas" statt der genauen Stufe wissen müssen.
    static var istAktiv: Bool {
        get { stufeCache != .aus }
        set { stufe = newValue ? (stufeCache == .aus ? .standard : stufeCache) : .aus }
    }

    /// Schützt Lesen+ggf.-Neuanlegen von ``zwischengespeicherterWriter`` als eine
    /// atomare Operation, analog dem `NSLock`-Muster von ``WiederholungsFilter``
    /// in `DebugLogWriter.swift`.
    private static let writerSperre = NSLock()
    /// Zwischengespeicherte Writer-Instanz je zuletzt verwendetem Geräte-Präfix
    /// (Live-Test-Fund, Session 2026-08-03: abgeschnittene/vertauschte
    /// Protokollzeilen). ``lokalerWriter`` erzeugte vorher bei JEDEM Aufruf eine
    /// neue ``DebugLogWriter``-Actor-Instanz — ein `actor` serialisiert
    /// Schreibzugriffe aber nur GEGEN SICH SELBST, nicht gegen eine zweite,
    /// zeitgleich frisch erzeugte Instanz auf dieselbe Datei. Zwei nahezu
    /// gleichzeitige ``log(_:details:)``-Aufrufe (seit dem
    /// ``Ereignis/einkaufAbschlussAusgeloest``/``Ereignis/einkaufAbschlussDurchgefuehrt``-Paar
    /// der Regelfall) konnten sich dadurch beim `seekToEnd()`+`write()` in
    /// `DebugLogWriter.schreibeInDatei(_:)` gegenseitig überschreiben. Fix:
    /// dieselbe Instanz wiederverwenden, solange sich der Präfix nicht ändert —
    /// dann serialisiert die Actor-Isolation zuverlässig.
    nonisolated(unsafe) private static var zwischengespeicherterWriter: (praefix: String, writer: DebugLogWriter)?

    /// Dateiname trägt den gesetzten Gerätenamen (GitHub #84), z.B.
    /// „Küche DB Debug.log" — ohne eigenen Override (siehe
    /// ``DatabaseLeaseService/eigenerGeraeteNameOverride``) generisch „Gerät DB
    /// Debug.log". Bewusst nur der Override, nicht ``DatabaseLeaseService/geraeteName``
    /// (der zusätzlich auf `UIDevice.current.name` zurückfällt) — dessen
    /// `@MainActor`-Isolation würde diesen synchron über jeden Aufrufkontext
    /// erreichbaren Dateinamen unnötig verkomplizieren, und „der gesetzte
    /// Gerätename" aus der Anforderung meint ohnehin den Override.
    private static var lokalerWriter: DebugLogWriter {
        let override = DatabaseLeaseService.eigenerGeraeteNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let praefix = (override?.isEmpty == false ? override! : nil) ?? "Gerät"
        writerSperre.lock()
        defer { writerSperre.unlock() }
        if let zwischengespeicherterWriter, zwischengespeicherterWriter.praefix == praefix {
            return zwischengespeicherterWriter.writer
        }
        let writer = DebugLogWriter(
            kategorie: "DatabaseConcurrency",
            dateiURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(praefix) DB Debug.log")
        )
        zwischengespeicherterWriter = (praefix, writer)
        return writer
    }

    private static let wiederholungsFilter = WiederholungsFilter()

    static func log(_ ereignis: Ereignis, details: String) {
        guard stufeCache >= ereignis.mindestStufe else { return }
        guard let effektiveDetails = wiederholungsFilter.pruefe(ereignis: ereignis.rawValue, details: details) else { return }
        Task.detached(priority: .background) {
            let geraeteName = await DatabaseLeaseService.geraeteName
            await lokalerWriter.protokolliere(ereignis: ereignis.rawValue, details: effektiveDetails, geraeteName: geraeteName)
        }
    }

    /// Aktuelle Gesamtgröße aller Log-Dateien in Byte.
    static func gesamtGroesse() -> Int {
        lokalerWriter.aktuelleGroesse()
    }

    static func leeren() {
        lokalerWriter.leere()
    }

    static var exportURLs: [URL] {
        lokalerWriter.exportURLs
    }
}
