import Foundation

/// Stößt vor jedem Sync-Zyklus aktiv den iCloud-Abgleich für den Sync-Ordner an
/// (GitHub #91). Ein reines `contentsOfDirectory` (siehe die übrigen
/// Sync-Services) liefert nur, was iCloud auf diesem Gerät bereits lokal
/// zwischengespeichert hat — Live-Tests zeigten, dass neue Peer-Änderungen
/// teils deutlich verzögert oder gar nicht auftauchten, bis man den Ordner
/// manuell in der Files-App öffnete. Eine kurz laufende `NSMetadataQuery`,
/// gescoped auf den Sync-Ordner, signalisiert iCloud aktiv „ich beobachte
/// diesen Ordner" und löst dadurch denselben Abgleich aus wie das manuelle
/// Öffnen in der Files-App.
///
/// **Bewusst `NSMetadataQuery`, nicht `NSFilePresenter`:** Ein
/// `NSFilePresenter`-Ansatz (`SyncOrdnerBeobachter`) verursachte in Build 133
/// einen App-Start-Hänger durch einen Deadlock zwischen
/// `presentedItemOperationQueue = .main` und den bestehenden synchronen
/// `NSFileCoordinator`-Schreibzugriffen (ebenfalls auf dem Main-Thread), siehe
/// `SyncPollingService`s Typ-Dokumentation. `NSMetadataQuery.operationQueue`
/// läuft hier deshalb bewusst auf einer eigenen, von `.main` getrennten Queue
/// — unabhängig davon warten wir hier ohnehin nur per `await` (kooperative
/// Unterbrechung), nie synchron/blockierend auf dem Main-Thread.
///
/// **Auf iOS fest an iCloud gebunden:** Auch mit URL-gescopten `searchScopes`
/// (seit iOS 14) bleibt `NSMetadataQuery` auf iCloud beschränkt — bei einem
/// Sync-Ordner eines anderen Anbieters (Synology Drive, lokale/Netzwerk-Ordner)
/// liefert die Query schlicht kein Ergebnis, kein Sonderfall nötig: Das
/// Timeout greift dann einfach wirkungslos.
enum SyncICloudWeckerService {
    /// `static var` statt `let`, damit Tests sie auf einen sehr kurzen Wert
    /// setzen können, ohne auf reale iCloud-Antwortzeiten angewiesen zu sein.
    /// `nonisolated(unsafe)`, analog `SyncOrdnerZugriffsDiagnose` — nur von
    /// Tests (seriell) bzw. hier selbst gelesen, keine parallelen Schreiber.
    nonisolated(unsafe) static var timeout: Duration = .seconds(2)

    /// Wartet höchstens ``timeout`` auf das Ende der iCloud-Metadaten-Abfrage
    /// für `ordner` — kommt sie schneller, kehrt die Funktion sofort zurück.
    /// Kommt sie gar nicht zustande (kein iCloud-Ordner, kein Netz) oder
    /// dauert sie länger als ``timeout``, kehrt die Funktion trotzdem zurück,
    /// ohne den aufrufenden Sync-Zyklus zu blockieren — dieser Schritt ist ein
    /// reiner Anstoß, kein Erfolg, von dem der restliche Zyklus abhängt.
    static func wecke(ordner: URL) async {
        guard ordner.startAccessingSecurityScopedResource() else { return }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let start = ContinuousClock.now
        let rechtzeitigFertig = await warteAufGathering(ordner: ordner)
        let dauer = start.duration(to: .now)
        SyncDebugLogger.log(
            .iCloudWeckerAbgeschlossen,
            details: "rechtzeitig=\(rechtzeitigFertig) dauer=\(dauer)"
        )
    }

    /// Hält `NSMetadataQuery`/Observer/Continuation gebündelt hinter einem
    /// eigenen Lock, damit sie sich gefahrlos in die `@Sendable`-Closures von
    /// `Task {}`/`NotificationCenter` einfangen lassen (`NSMetadataQuery`
    /// selbst ist nicht `Sendable`) — `fortsetzen(rechtzeitig:)` ist dank des
    /// Locks trotz zweier potenzieller Aufrufer (Observer-Callback,
    /// Timeout-Task) idempotent: Nur der erste Aufruf wirkt.
    private final class WeckImpulsKoordinator: @unchecked Sendable {
        private let sperre = NSLock()
        private let query: NSMetadataQuery
        private var beobachter: NSObjectProtocol?
        private var continuation: CheckedContinuation<Bool, Never>?
        private var bereitsFortgesetzt = false

        init(query: NSMetadataQuery) {
            self.query = query
        }

        func einrichten(
            beobachter: NSObjectProtocol,
            continuation: CheckedContinuation<Bool, Never>
        ) {
            sperre.lock()
            self.beobachter = beobachter
            self.continuation = continuation
            sperre.unlock()
        }

        func fortsetzen(rechtzeitig: Bool) {
            sperre.lock()
            let schonErledigt = bereitsFortgesetzt
            bereitsFortgesetzt = true
            let beobachter = beobachter
            let continuation = continuation
            self.continuation = nil
            sperre.unlock()
            guard !schonErledigt else { return }

            query.disableUpdates()
            query.stop()
            if let beobachter { NotificationCenter.default.removeObserver(beobachter) }
            continuation?.resume(returning: rechtzeitig)
        }
    }

    /// Rückgabewert meldet, ob `.NSMetadataQueryDidFinishGathering` innerhalb
    /// von ``timeout`` eintraf (rein diagnostisch, siehe ``wecke(ordner:)``).
    private static func warteAufGathering(ordner: URL) async -> Bool {
        let query = NSMetadataQuery()
        query.searchScopes = [ordner]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        // NSMetadataQuery verlangt zwingend eine serielle Queue — ein
        // unkonfiguriertes `OperationQueue()` hat standardmäßig unbegrenzte
        // Nebenläufigkeit (`maxConcurrentOperationCount == -1`), was zur
        // Laufzeit mit "[CRIT] API MISUSE: running a NSMetadataQuery with
        // maxConcurrentOperationCount != 1 is not supported" abbricht.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        query.operationQueue = queue
        let koordinator = WeckImpulsKoordinator(query: query)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let beobachter = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: query.operationQueue
            ) { _ in
                koordinator.fortsetzen(rechtzeitig: true)
            }
            koordinator.einrichten(beobachter: beobachter, continuation: continuation)

            query.start()

            Task {
                try? await Task.sleep(for: timeout)
                koordinator.fortsetzen(rechtzeitig: false)
            }
        }
    }
}
