import Foundation
import SwiftData

/// Bereich-A-Export (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` Abschnitt 5.2):
/// schreibt lokale, noch nicht hochgeladene ``SyncEvent``s als einzelne
/// JSON-Dateien in den eigenen Peer-Ordner (`peers/{geraeteID}/events/`). Reines
/// Schreiben — Lesen fremder Peer-Ordner (Import) ist Phase 2/3 des Plans.
enum SyncExportService {
    /// Der Event-Ordner dieses Geräts innerhalb des Sync-Ordners.
    static func eigenerEventsOrdner(in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(DatabaseLeaseService.geraeteID, isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    /// Schreibt alle noch nicht hochgeladenen `SyncEvent`s in den eigenen
    /// Peer-Ordner und markiert sie danach als hochgeladen. Ohne hinterlegten
    /// Sync-Ordner (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne
    /// Wirkung — Synchronisation ist optional.
    @MainActor
    static func exportiereNeueEvents(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }

        var beschreibung = FetchDescriptor<SyncEvent>(
            predicate: #Predicate { $0.hochgeladen == false }
        )
        beschreibung.sortBy = [SortDescriptor(\.lamportZaehler)]
        guard let ausstehende = try? context.fetch(beschreibung), !ausstehende.isEmpty else { return }

        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let eventsOrdner = eigenerEventsOrdner(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(
            at: eventsOrdner, withIntermediateDirectories: true
        )) != nil else { return }

        for event in ausstehende {
            guard let daten = try? JSONEncoder().encode(event.exportDarstellung) else { continue }
            let zielURL = eventsOrdner.appendingPathComponent(dateiname(fuer: event))
            guard schreibeBlocking(daten, nach: zielURL) else { continue }
            event.hochgeladen = true
        }

        try? context.save()
    }

    /// Zehnstellig nullgepolsterter Lamport-Zähler sorgt für lexikografisch
    /// korrekte, aufsteigende Sortierung der Dateinamen unabhängig davon, wie das
    /// Dateisystem/der Cloud-Anbieter Verzeichnisse auflistet.
    private static func dateiname(fuer event: SyncEvent) -> String {
        let zaehlerText = String(event.lamportZaehler)
        let gepolstert = String(repeating: "0", count: max(0, 10 - zaehlerText.count)) + zaehlerText
        return "\(gepolstert)_\(event.id.uuidString).json"
    }

    /// Schreibt über `NSFileCoordinator`, damit File-Provider-Erweiterungen
    /// (iCloud Drive/Synology Drive/…) von der Änderung erfahren — analog zum
    /// bestehenden Muster in ``DatabaseLeaseService``.
    nonisolated private static func schreibeBlocking(_ daten: Data, nach url: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        var erfolgreich = false
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorFehler) { zielURL in
            do {
                try daten.write(to: zielURL, options: .atomic)
                erfolgreich = true
            } catch {
                erfolgreich = false
            }
        }
        return coordinatorFehler == nil && erfolgreich
    }
}
