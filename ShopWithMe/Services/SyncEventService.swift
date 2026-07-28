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
}
