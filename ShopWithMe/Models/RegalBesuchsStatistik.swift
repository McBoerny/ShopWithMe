import Foundation
import SwiftData

/// Gelernte Statistik, an welcher Position ein ``Regal`` in einem ``Geschaeft``
/// typischerweise besucht wird.
///
/// Wird von ``ShelfOrderLearningService`` nach jedem abgeschlossenen
/// ``Einkaufsvorgang`` aktualisiert. Aus ``durchschnittlichePosition`` über alle
/// Regale eines Geschäfts ergibt sich die vorgeschlagene automatische
/// Regal-Reihenfolge.
@Model
final class RegalBesuchsStatistik {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das Geschäft, für das diese Statistik gilt.
    var geschaeft: Geschaeft?
    /// Das Regal, für das diese Statistik gilt.
    var regal: Regal?
    /// Anzahl der Einkaufsvorgänge, die in diese Statistik eingeflossen sind.
    var besucheAnzahl: Int
    /// Summe aller beobachteten Sequenzpositionen (Basis für den Durchschnitt).
    var summeSequenzPosition: Double

    init(geschaeft: Geschaeft?, regal: Regal?) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.regal = regal
        self.besucheAnzahl = 0
        self.summeSequenzPosition = 0
    }

    /// Durchschnittliche Besuchsposition. `.infinity`, solange noch keine Beobachtung
    /// vorliegt, damit unbeobachtete Regale ans Ende einer vorgeschlagenen
    /// Reihenfolge sortiert werden.
    var durchschnittlichePosition: Double {
        besucheAnzahl > 0 ? summeSequenzPosition / Double(besucheAnzahl) : .infinity
    }

    /// Erfasst eine neue Beobachtung dieser Sequenzposition.
    func erfassen(sequenzPosition: Int) {
        besucheAnzahl += 1
        summeSequenzPosition += Double(sequenzPosition)
    }
}
