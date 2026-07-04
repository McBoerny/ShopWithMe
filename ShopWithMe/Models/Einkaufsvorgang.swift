import Foundation
import SwiftData

/// Ein einzelner Einkaufsvorgang (Ladenbesuch) in einem bestimmten ``Geschaeft``.
///
/// Während eines Einkaufsvorgangs entstehen ``KaufEintrag``e, aus deren
/// Reihenfolge der ``ShelfOrderLearningService`` lernt, in welcher Reihenfolge der
/// Anwender die Regale typischerweise abläuft.
@Model
final class Einkaufsvorgang {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das Geschäft, in dem dieser Einkauf stattfindet.
    var geschaeft: Geschaeft?
    /// Startzeitpunkt des Einkaufs.
    var startZeit: Date
    /// Endzeitpunkt — `nil`, solange der Einkauf noch läuft.
    var endZeit: Date?
    /// Die einzelnen Käufe dieses Einkaufsvorgangs.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.einkaufsvorgang)
    var kaufEintraege: [KaufEintrag] = []

    init(geschaeft: Geschaeft? = nil, startZeit: Date = Date()) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.startZeit = startZeit
    }

    /// Ob dieser Einkaufsvorgang bereits abgeschlossen wurde.
    var istAbgeschlossen: Bool { endZeit != nil }

    /// Beendet den Einkaufsvorgang zum angegebenen Zeitpunkt (Standard: jetzt).
    func abschliessen(am zeitpunkt: Date = Date()) {
        endZeit = zeitpunkt
    }
}
