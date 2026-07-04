import Foundation
import SwiftData

/// Gelernte Statistik, an welcher Position eine ``ArtikelKategorie`` in einem
/// ``Geschaeft`` typischerweise besucht wird.
///
/// Wird von ``ShelfOrderLearningService`` nach jedem abgeschlossenen
/// ``Einkaufsvorgang`` aktualisiert. Aus ``durchschnittlichePosition`` über alle
/// Kategorien eines Geschäfts leitet der Service sowohl eine vorgeschlagene
/// automatische Regal-Reihenfolge (Aggregation über ``Regal/kategorien``) als auch —
/// für Geschäfte ohne Regale — direkt eine Kategorie-Reihenfolge ab.
@Model
final class KategorieBesuchsStatistik {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das Geschäft, für das diese Statistik gilt.
    var geschaeft: Geschaeft?
    /// Die Artikelkategorie, für die diese Statistik gilt.
    var kategorie: ArtikelKategorie?
    /// Anzahl der Einkaufsvorgänge, die in diese Statistik eingeflossen sind.
    var besucheAnzahl: Int
    /// Summe aller beobachteten Sequenzpositionen (Basis für den Durchschnitt).
    var summeSequenzPosition: Double

    init(geschaeft: Geschaeft?, kategorie: ArtikelKategorie?) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.kategorie = kategorie
        self.besucheAnzahl = 0
        self.summeSequenzPosition = 0
    }

    /// Durchschnittliche Besuchsposition. `.infinity`, solange noch keine Beobachtung
    /// vorliegt, damit unbeobachtete Kategorien ans Ende einer vorgeschlagenen
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
