import Foundation
import SwiftData
import UIKit

/// Fehler beim Erwerb eines Datenbank-Lease.
enum DatabaseLeaseError: LocalizedError {
    case belegt(geraet: String, seit: Date)

    var errorDescription: String? {
        switch self {
        case .belegt(let geraet, let seit):
            return "Datenbank wird gerade von \(geraet) bearbeitet (seit \(seit.formatted(date: .omitted, time: .shortened)))."
        }
    }
}

/// Inhalt der Lease-Lock-Datei neben dem Store.
private struct LeaseInfo: Codable, Sendable {
    var geraeteID: String
    var geraeteName: String
    var erworbenAm: Date
}

/// Koordiniert Schreibzugriffe auf die geteilte SwiftData-Datenbank über mehrere
/// Geräte hinweg, wenn der Store in einem per Cloud-Dienst gehosteten Fileshare-Ordner
/// liegt (Box Drive, Synology Drive, iCloud Drive, OneDrive, …) — siehe
/// `docs/DATABASE_CONCURRENCY.md`.
///
/// Zwei Betriebsarten:
/// - **Micro-Lease** (``performMicroLease(context:mutate:)``): für diskrete
///   Einzelaktionen (z.B. Artikel abhaken) — der Lease wird nur für die Dauer der
///   Aktion gehalten.
/// - **Session-Lease** (``SessionLease``): für Bearbeitungs-Bildschirme mit
///   kontinuierlicher Live-Bindung (z.B. Geschäft bearbeiten) — der Lease wird
///   beim Öffnen erworben und beim Verlassen wieder freigegeben.
///
/// Reines Locking über eine JSON-Lock-Datei, koordiniert per ``NSFileCoordinator``,
/// damit File-Provider-Erweiterungen (Box/OneDrive/Synology Drive/iCloud Drive) von
/// der Koordination erfahren. Kein CloudKit, kein eigener Server (Nutzervorgabe).
enum DatabaseLeaseService {
    /// Die aktuell aktive Store-URL, gesetzt einmalig beim App-Start
    /// (``ShopWithMeApp``). `nil` z.B. in Unit-Tests mit In-Memory-Store — in diesem
    /// Fall wird das Lease-Verfahren übersprungen. Nur einmalig beim Start gesetzt,
    /// danach nur noch lesend aus verschiedenen Kontexten zugegriffen — daher bewusst
    /// `nonisolated(unsafe)` statt eines Actors, um `ShopWithMeApp.init()` und die
    /// synchronen Blocking-Dateioperationen unten nicht an den `MainActor` zu binden.
    nonisolated(unsafe) static var storeURL: URL?

    /// Ab welcher Untätigkeit (kein aufgefrischter Lease) ein Lease als verwaist gilt
    /// und automatisch übernommen werden darf.
    static let staleTimeout: TimeInterval = 120

    /// Anzahl Versuche, einen Micro-Lease zu erwerben, bevor aufgegeben wird.
    private static let microLeaseVersuche = 5
    /// Wartezeit zwischen zwei Erwerbsversuchen eines Micro-Lease.
    private static let microLeaseWartezeitNanosekunden: UInt64 = 200_000_000

    /// Eindeutige, über App-Starts stabile Kennung dieses Geräts.
    static let geraeteID: String = {
        let schluessel = "datenbankLeaseGeraeteID"
        if let vorhandene = UserDefaults.standard.string(forKey: schluessel) {
            return vorhandene
        }
        let neue = UUID().uuidString
        UserDefaults.standard.set(neue, forKey: schluessel)
        return neue
    }()

    /// Vom Anwender in den Sync-Einstellungen vergebener Gerätename (GitHub #65) —
    /// überschreibt den sonst identischen `UIDevice.current.name` aller Geräte
    /// (meist schlicht "iPhone"), damit sich Peers beim Sync unterscheiden lassen.
    /// `nil`/leer, solange kein eigener Name gesetzt wurde.
    static var eigenerGeraeteNameOverride: String? {
        get { UserDefaults.standard.string(forKey: "eigenerGeraeteName") }
        set { UserDefaults.standard.set(newValue, forKey: "eigenerGeraeteName") }
    }

    /// Anzeigename dieses Geräts für Lock-Meldungen/Logs/Sync-Snapshots — der
    /// eigene Override, sofern gesetzt, sonst `UIDevice.current.name`.
    @MainActor
    static var geraeteName: String {
        let override = eigenerGeraeteNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (override?.isEmpty == false ? override : nil) ?? UIDevice.current.name
    }

    private static func lockURL(fuerStore storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(storeURL.lastPathComponent + ".lock.json")
    }

    // MARK: - Blockierende Datei-Operationen (laufen abseits des Main-Threads)

    nonisolated private static func leseLeaseBlocking(lockURL: URL) -> LeaseInfo? {
        let coordinator = NSFileCoordinator()
        var ergebnis: LeaseInfo?
        var coordinatorFehler: NSError?
        coordinator.coordinate(readingItemAt: lockURL, options: [], error: &coordinatorFehler) { url in
            guard let daten = try? Data(contentsOf: url) else { return }
            ergebnis = try? JSONDecoder().decode(LeaseInfo.self, from: daten)
        }
        return ergebnis
    }

    nonisolated private static func schreibeLeaseBlocking(_ lease: LeaseInfo, lockURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        var schreibFehler: Error?
        coordinator.coordinate(writingItemAt: lockURL, options: [], error: &coordinatorFehler) { url in
            do {
                let daten = try JSONEncoder().encode(lease)
                try daten.write(to: url, options: .atomic)
            } catch {
                schreibFehler = error
            }
        }
        if let coordinatorFehler { throw coordinatorFehler }
        if let schreibFehler { throw schreibFehler }
    }

    nonisolated private static func loescheLeaseBlocking(lockURL: URL) {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        coordinator.coordinate(writingItemAt: lockURL, options: .forDeleting, error: &coordinatorFehler) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Lease-Erwerb/-Freigabe

    /// Versucht, den Lease zu erwerben: kein Lease vorhanden, eigener Lease (Refresh),
    /// oder ein verwaister fremder Lease (Stale-Timeout überschritten) → eigener Lease
    /// wird geschrieben. Aktiver fremder Lease → ``DatabaseLeaseError/belegt``.
    @MainActor
    private static func leaseErwerben(storeURL: URL) async throws {
        let lockURL = lockURL(fuerStore: storeURL)
        let vorhandene = await Task.detached { leseLeaseBlocking(lockURL: lockURL) }.value

        if let vorhandene, vorhandene.geraeteID != geraeteID {
            let alter = Date().timeIntervalSince(vorhandene.erworbenAm)
            if alter < staleTimeout {
                throw DatabaseLeaseError.belegt(geraet: vorhandene.geraeteName, seit: vorhandene.erworbenAm)
            }
            DatabaseDebugLogger.log(.leaseStaleTakeover, details: vorhandene.geraeteName)
        }

        let eigene = LeaseInfo(geraeteID: geraeteID, geraeteName: geraeteName, erworbenAm: Date())
        try await Task.detached { try schreibeLeaseBlocking(eigene, lockURL: lockURL) }.value
    }

    /// Schreibt den eigenen Lease mit frischem Zeitstempel, ohne den aktuellen Inhalt
    /// zu prüfen (Heartbeat während eines gehaltenen ``SessionLease``).
    @MainActor
    private static func leaseErneuern(storeURL: URL) async {
        let lockURL = lockURL(fuerStore: storeURL)
        let eigene = LeaseInfo(geraeteID: geraeteID, geraeteName: geraeteName, erworbenAm: Date())
        try? await Task.detached { try schreibeLeaseBlocking(eigene, lockURL: lockURL) }.value
    }

    private static func leaseFreigeben(storeURL: URL) async {
        let lockURL = lockURL(fuerStore: storeURL)
        await Task.detached { loescheLeaseBlocking(lockURL: lockURL) }.value
    }

    // MARK: - Micro-Lease

    /// Führt `mutate` und ein anschließendes explizites `context.save()` geschützt
    /// durch einen kurz gehaltenen Micro-Lease aus (siehe
    /// `docs/DATABASE_CONCURRENCY.md` → „Gewähltes Verfahren“). Schlägt der Erwerb
    /// nach mehreren kurzen Versuchen weiterhin fehl (ein anderes Gerät schreibt),
    /// wird `mutate` NICHT ausgeführt.
    @MainActor
    static func performMicroLease(context: ModelContext, mutate: () -> Void) async {
        guard let storeURL else {
            // Kein konfigurierter Speicherort (z.B. Unit-Test mit In-Memory-Store) —
            // Lease-Mechanismus übersprungen, Mutation + Save direkt anwenden.
            mutate()
            try? context.save()
            return
        }

        DatabaseDebugLogger.log(.leaseAcquireAttempt, details: "micro")
        for versuch in 0..<microLeaseVersuche {
            do {
                try await leaseErwerben(storeURL: storeURL)
                DatabaseDebugLogger.log(.leaseAcquireSuccess, details: "micro")

                mutate()

                do {
                    try context.save()
                    DatabaseDebugLogger.log(.saveSuccess, details: "micro")
                } catch {
                    DatabaseDebugLogger.log(.saveFailure, details: "\(error)")
                }

                await leaseFreigeben(storeURL: storeURL)
                DatabaseDebugLogger.log(.leaseRelease, details: "micro")
                return
            } catch {
                if versuch == microLeaseVersuche - 1 {
                    DatabaseDebugLogger.log(.leaseAcquireDeniedReadonly, details: "micro: \(error)")
                } else {
                    try? await Task.sleep(nanoseconds: microLeaseWartezeitNanosekunden)
                }
            }
        }
    }

    // MARK: - Session-Lease

    /// Hält einen Lease für die Dauer eines Bearbeitungs-Bildschirmbesuchs (siehe
    /// `docs/DATABASE_CONCURRENCY.md` → „Zweite Lease-Strategie“). Erwerb über
    /// ``acquire()`` (z.B. in `.task`), Freigabe inkl. explizitem Save über
    /// ``release(context:)`` (z.B. in `.onDisappear`).
    ///
    /// Referenzgezählt über ``aktiveHalterZaehler``, damit verschachtelte
    /// Bearbeitungs-Bildschirme desselben Geräts (z.B. `WarengruppeHinzufuegenSheet`
    /// über einem bereits offenen `GeschaeftDetailView`) sich denselben Lease teilen,
    /// statt dass der innere Bildschirm ihn beim Schließen fälschlich freigibt,
    /// während der äußere noch aktiv ist.
    @MainActor
    final class SessionLease: ObservableObject {
        enum Status: Equatable {
            case erwerbeGerade
            case gehalten
            case belegt(geraet: String, seit: Date)
        }

        @Published private(set) var status: Status = .erwerbeGerade

        /// Ob diese Instanz den prozessweiten Zähler erhöht hat (und ihn beim
        /// Freigeben wieder senken muss).
        private var hatZaehlerErhoeht = false
        /// Ob diese Instanz die tatsächliche Erwerbs-/Heartbeat-Verantwortung trägt
        /// (nur die äußerste, zuerst erwerbende Instanz — verschachtelte Instanzen
        /// zählen nur mit).
        private var istAeusserstePosition = false
        private var heartbeatTask: Task<Void, Never>?

        private static var aktiveHalterZaehler = 0
        private static let heartbeatIntervallNanosekunden: UInt64 = 30_000_000_000

        init() {}

        func acquire() async {
            if Self.aktiveHalterZaehler > 0 {
                Self.aktiveHalterZaehler += 1
                hatZaehlerErhoeht = true
                status = .gehalten
                return
            }

            guard let storeURL = DatabaseLeaseService.storeURL else {
                Self.aktiveHalterZaehler += 1
                hatZaehlerErhoeht = true
                istAeusserstePosition = true
                status = .gehalten
                return
            }

            DatabaseDebugLogger.log(.leaseAcquireAttempt, details: "session")
            do {
                try await DatabaseLeaseService.leaseErwerben(storeURL: storeURL)
                Self.aktiveHalterZaehler += 1
                hatZaehlerErhoeht = true
                istAeusserstePosition = true
                status = .gehalten
                DatabaseDebugLogger.log(.leaseAcquireSuccess, details: "session")
                starteHeartbeat(storeURL: storeURL)
            } catch let DatabaseLeaseError.belegt(geraet, seit) {
                status = .belegt(geraet: geraet, seit: seit)
                DatabaseDebugLogger.log(.leaseAcquireDeniedReadonly, details: "session: \(geraet)")
            } catch {
                status = .belegt(geraet: "unbekannt", seit: Date())
            }
        }

        func release(context: ModelContext) async {
            guard hatZaehlerErhoeht else { return }
            hatZaehlerErhoeht = false
            Self.aktiveHalterZaehler -= 1

            do {
                try context.save()
                DatabaseDebugLogger.log(.saveSuccess, details: "session")
            } catch {
                DatabaseDebugLogger.log(.saveFailure, details: "\(error)")
            }

            guard istAeusserstePosition else { return }
            istAeusserstePosition = false
            heartbeatTask?.cancel()
            heartbeatTask = nil

            guard Self.aktiveHalterZaehler == 0, let storeURL = DatabaseLeaseService.storeURL else { return }
            await DatabaseLeaseService.leaseFreigeben(storeURL: storeURL)
            DatabaseDebugLogger.log(.leaseRelease, details: "session")
        }

        private func starteHeartbeat(storeURL: URL) {
            heartbeatTask?.cancel()
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.heartbeatIntervallNanosekunden)
                    guard !Task.isCancelled else { return }
                    await DatabaseLeaseService.leaseErneuern(storeURL: storeURL)
                }
            }
        }
    }
}
