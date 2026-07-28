import Foundation
import SwiftData

/// Zeichnet ``SyncEvent``e für die geplante Datensynchronisation auf
/// (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, GitHub #39, Phase 0) — die
/// einzige Stelle, die einen ``SyncEvent`` erzeugt, damit Lamport-Zähler-Vergabe
/// und Geräte-ID-Zuordnung konsistent an einem Ort passieren.
///
/// Aufgerufen von den bestehenden Bereich-A-Mutationsfunktionen
/// (``Einkaufsliste/artikelHinzufuegen(_:context:)``,
/// ``Einkaufsvorgang/artikelAbhaken(_:context:)``, …) direkt im Anschluss an die
/// eigentliche Modelländerung — diese Funktionen bleiben die einzige Quelle für
/// Änderungen, sowohl bei lokal ausgelösten Aktionen als auch (ab Phase 2 des
/// Plans) beim Anwenden empfangener Remote-Events.
enum SyncEventService {
    @discardableResult
    static func aufzeichnen(
        _ art: SyncEventArt,
        bezugsID: UUID,
        artikelID: UUID,
        context: ModelContext
    ) -> SyncEvent {
        let event = SyncEvent(
            art: art,
            nutzlast: SyncEventNutzlast(bezugsID: bezugsID, artikelID: artikelID),
            lamportZaehler: LamportClock.naechsterZaehler(),
            lamportGeraeteID: DatabaseLeaseService.geraeteID,
            autorGeraeteID: DatabaseLeaseService.geraeteID
        )
        context.insert(event)
        return event
    }

    /// Übernimmt ein von einem Peer empfangenes Event unverändert in die lokale
    /// Datenbank (Phase 2, `SyncImportService`) — im Unterschied zu
    /// ``aufzeichnen(_:bezugsID:artikelID:context:)`` wird KEIN neuer
    /// Lamport-Zähler vergeben und KEINE eigene Autorenschaft gesetzt (siehe
    /// ``SyncEvent/init(empfangen:)``). Gleicht die eigene Uhr über
    /// ``LamportClock/beiEmpfang(fremderZaehler:)`` ab.
    @discardableResult
    static func uebernehmen(_ empfangen: SyncEventExportDarstellung, context: ModelContext) -> SyncEvent {
        LamportClock.beiEmpfang(fremderZaehler: empfangen.lamportZaehler)
        let event = SyncEvent(empfangen: empfangen)
        context.insert(event)
        return event
    }

    /// Ob bereits ein lokales ``SyncEvent`` mit dieser `id` existiert — Grundlage
    /// für die Idempotenz des Imports (``SyncImportService``): ein Event, das
    /// schon einmal übernommen wurde (eigenes oder bereits importiertes fremdes),
    /// darf nicht ein zweites Mal angewendet werden.
    static func istBereitsBekannt(_ id: UUID, context: ModelContext) -> Bool {
        var deskriptor = FetchDescriptor<SyncEvent>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }
}
