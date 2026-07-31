import Foundation
import SwiftData

/// Bereich-A-Export (`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 5.2):
/// schreibt lokale, noch nicht hochgeladene ``SyncEvent``s als einzelne
/// JSON-Dateien in den eigenen Peer-Ordner (`peers/{geraeteID}/events/`). Reines
/// Schreiben — Lesen fremder Peer-Ordner (Import) ist Phase 2/3 des Plans.
enum SyncExportService {
    /// Der Event-Ordner eines beliebigen Geräts (eigenes oder fremdes) innerhalb
    /// des Sync-Ordners — siehe ``SyncImportService`` für das Lesen fremder
    /// Ordner.
    static func eventsOrdner(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraeteID, isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    /// Der Event-Ordner dieses Geräts innerhalb des Sync-Ordners.
    static func eigenerEventsOrdner(in syncOrdner: URL) -> URL {
        eventsOrdner(fuerPeer: DatabaseLeaseService.geraeteID, in: syncOrdner)
    }

    /// Schreibt alle noch nicht hochgeladenen `SyncEvent`s in den eigenen
    /// Peer-Ordner und markiert sie danach als hochgeladen. Ohne hinterlegten
    /// Sync-Ordner (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne
    /// Wirkung — Synchronisation ist optional.
    ///
    /// **Kein Aufräumen alter Event-Dateien** (Revert eines kurzzeitig
    /// eingeführten, zeitbasierten Löschens): „hochgeladen" bedeutet nur, dass
    /// DIESES Gerät die Datei geschrieben hat — nicht, dass ein Peer sie
    /// bereits gelesen hat. Ein age-basiertes Löschen (unabhängig von der
    /// gewählten Frist) kann dadurch einen noch nicht abgeholten Rückstand
    /// löschen, sobald ein Peer länger als die Frist nicht synchronisiert hat
    /// — real beobachtet: löschte zwischen zwei Geräten ausstehende
    /// `artikelAbgehakt`-Events, bevor der zweite Peer sie je gelesen hatte,
    /// wodurch dieser Artikel dort nie als abgehakt ankam. Ein sicheres
    /// Aufräumen bräuchte eine echte Bestätigung, dass alle Peers eine Datei
    /// bereits konsumiert haben (z.B. ein Zuletzt-gelesenes-Cursor pro Peer),
    /// die es aktuell nicht gibt — siehe „Offene Alt-Datei-Frage" oben, jetzt
    /// wieder bewusst offen statt mit einem unsicheren Heuristik-Ersatz
    /// geschlossen.
    /// Rückgabewert meldet ausschließlich, ob der Ordnerzugriff (Berechtigung)
    /// geklappt hat, analog ``SyncSnapshotImportService/importiereSnapshots(context:)``.
    @discardableResult
    @MainActor
    static func exportiereNeueEvents(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }

        var beschreibung = FetchDescriptor<SyncEvent>(
            predicate: #Predicate { $0.hochgeladen == false }
        )
        beschreibung.sortBy = [SortDescriptor(\.lamportZaehler)]
        guard let ausstehende = try? context.fetch(beschreibung), !ausstehende.isEmpty else { return true }

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueEvents")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let eventsOrdner = eigenerEventsOrdner(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(
            at: eventsOrdner, withIntermediateDirectories: true
        )) != nil else { return true }

        for event in ausstehende {
            guard let daten = try? JSONEncoder().encode(event.exportDarstellung) else { continue }
            let zielURL = eventsOrdner.appendingPathComponent(dateiname(fuer: event))
            guard schreibeBlocking(daten, nach: zielURL) else { continue }
            event.hochgeladen = true
        }

        if context.hasChanges { try? context.save() }
        return true
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
