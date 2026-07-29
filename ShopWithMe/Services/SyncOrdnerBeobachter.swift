import Foundation

/// Beobachtet den `peers/`-Unterordner des Sync-Ordners auf Änderungen über
/// `NSFilePresenter`/`NSFileCoordinator` — löst eine schnellere Erkennung aus,
/// als reines Zeit-Polling (``SyncPollingService``) es könnte.
///
/// Bewusst `NSFilePresenter` statt `NSMetadataQuery`: `NSMetadataQuery`s
/// Ubiquitous-Scopes sind iCloud-Drive-spezifisch — für einen frei über
/// `UIDocumentPickerViewController` gewählten Ordner (dieses Projekt
/// unterstützt zusätzlich Synology Drive, siehe `docs/DATABASE_CONCURRENCY.md`)
/// ist `NSFilePresenter` der providerunabhängige Mechanismus, der auf
/// demselben File-Coordination-Fundament aufbaut, das alle Schreib-/
/// Lesezugriffe dieser App bereits nutzen (``SyncExportService``,
/// ``SyncDateiZugriff``).
///
/// **Ergänzt, ersetzt nicht** das bestehende Zeit-Polling: Die Zustellung von
/// `presentedSubitemDidChange(at:)` ist bei manchen Providern bzw. im
/// Hintergrund nicht garantiert — die Zeit-Intervalle in ``SyncPollingService``
/// bleiben das verlässliche Sicherheitsnetz, dieser Beobachter macht nur den
/// Regelfall (App im Vordergrund) spürbar schneller.
final class SyncOrdnerBeobachter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = .main
    private let aenderungErkannt: () -> Void

    init(peersOrdner: URL, aenderungErkannt: @escaping () -> Void) {
        self.presentedItemURL = peersOrdner
        self.aenderungErkannt = aenderungErkannt
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    /// Muss explizit aufgerufen werden, bevor die letzte Referenz auf dieses
    /// Objekt verschwindet — `NSFileCoordinator.addFilePresenter` hält keine
    /// starke Referenz, ein `deinit`-Aufruf allein reicht aber nicht zuverlässig,
    /// um die Registrierung rechtzeitig zu entfernen.
    func beenden() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedSubitemDidChange(at url: URL) {
        aenderungErkannt()
    }
}
