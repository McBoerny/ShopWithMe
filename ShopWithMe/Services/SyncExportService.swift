import Foundation
import SwiftData

/// Bereich-A-Export (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` Abschnitt 5.2):
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

    /// Wie lange eine eigene, bereits hochgeladene Event-Datei im Sync-Ordner
    /// verbleibt, bevor ``raeumeAlteEventDateienAuf(eventsOrdner:context:)``
    /// sie löscht (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, Abschnitt
    /// „Offene Alt-Datei-Frage": bislang wurde nie aufgeräumt, der Ordner
    /// wuchs unbegrenzt). Bewusst grosszügig statt weniger Stunden: ein Peer,
    /// der länger offline war, braucht die Datei noch, um Löschungen
    /// (`artikelAbgewaehlt`/`artikelDauerhaftEntfernt`) nachzuvollziehen —
    /// dafür gibt es (anders als für Listen-Mitgliedschaft, siehe
    /// ``SyncSnapshot/einkaufslistenEintraege``) kein Snapshot-Sicherheitsnetz.
    /// `static var` statt Konstante, damit Tests sie verkürzen können.
    @MainActor static var eventDateiAufbewahrung: TimeInterval = 7 * 24 * 60 * 60
    private static let letzteBereinigungSchluessel = "syncEventsLetzteBereinigung"
    /// Mindestabstand zwischen zwei Aufräumdurchläufen — die Bereinigung ist
    /// nicht zeitkritisch und muss nicht bei jedem 5s/60s-Export-Zyklus erneut
    /// den Ordnerinhalt auflisten.
    private static let bereinigungsIntervall: TimeInterval = 60 * 60

    private static var letzteBereinigung: Date? {
        get { UserDefaults.standard.object(forKey: letzteBereinigungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteBereinigungSchluessel) }
    }

    /// Schreibt alle noch nicht hochgeladenen `SyncEvent`s in den eigenen
    /// Peer-Ordner und markiert sie danach als hochgeladen. Ohne hinterlegten
    /// Sync-Ordner (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne
    /// Wirkung — Synchronisation ist optional. Räumt anschließend (höchstens
    /// einmal pro Stunde, siehe ``bereinigungsIntervall``) eigene, alte
    /// Event-Dateien auf — unabhängig davon, ob in diesem Zyklus überhaupt
    /// neue Events zu exportieren waren.
    @MainActor
    static func exportiereNeueEvents(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }

        var beschreibung = FetchDescriptor<SyncEvent>(
            predicate: #Predicate { $0.hochgeladen == false }
        )
        beschreibung.sortBy = [SortDescriptor(\.lamportZaehler)]
        let ausstehende = (try? context.fetch(beschreibung)) ?? []

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueEvents")
            return
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let eventsOrdner = eigenerEventsOrdner(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(
            at: eventsOrdner, withIntermediateDirectories: true
        )) != nil else { return }

        if !ausstehende.isEmpty {
            for event in ausstehende {
                guard let daten = try? JSONEncoder().encode(event.exportDarstellung) else { continue }
                let zielURL = eventsOrdner.appendingPathComponent(dateiname(fuer: event))
                guard schreibeBlocking(daten, nach: zielURL) else { continue }
                event.hochgeladen = true
            }
            if context.hasChanges { try? context.save() }
        }

        raeumeAlteEventDateienAuf(eventsOrdner: eventsOrdner, context: context)
    }

    /// Löscht eigene, bereits hochgeladene Event-Dateien, deren zugehöriges
    /// ``SyncEvent/wallClock`` länger als ``eventDateiAufbewahrung`` zurückliegt.
    /// Löscht bewusst NUR die Dateien im Sync-Ordner, nicht die lokalen
    /// ``SyncEvent``-Datensätze selbst — die bleiben Grundlage der lokalen
    /// Konfliktauflösung (``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``),
    /// deren Löschung ein spät eintreffendes, konkurrierendes Event fälschlich
    /// gewinnen lassen könnte.
    @MainActor
    private static func raeumeAlteEventDateienAuf(eventsOrdner: URL, context: ModelContext) {
        if let letzte = letzteBereinigung, Date().timeIntervalSince(letzte) < bereinigungsIntervall { return }
        letzteBereinigung = Date()

        let stichtag = Date().addingTimeInterval(-eventDateiAufbewahrung)
        let deskriptor = FetchDescriptor<SyncEvent>(
            predicate: #Predicate { $0.hochgeladen == true && $0.wallClock < stichtag }
        )
        guard let alte = try? context.fetch(deskriptor), !alte.isEmpty else { return }

        for event in alte {
            let url = eventsOrdner.appendingPathComponent(dateiname(fuer: event))
            try? FileManager.default.removeItem(at: url)
        }
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
