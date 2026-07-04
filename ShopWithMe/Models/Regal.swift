import Foundation
import SwiftData

/// Ein Regal innerhalb genau eines ``Geschaeft``s.
///
/// Jedem Regal sind eine oder mehrere ``ArtikelKategorie``n zugeordnet. Diese
/// Zuordnung bestimmt zugleich, welche Kategorien in diesem Geschäft überhaupt
/// verfügbar sind (siehe ``Geschaeft/verfuegbareKategorien``).
@Model
final class Regal {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename des Regals, z.B. "Kühlregal".
    var name: String
    /// Manuelle Reihenfolge, in der der Anwender die Regale dieses Geschäfts
    /// ablaufen möchte. Wird durch ``ShelfOrderLearningService`` nicht automatisch
    /// verändert — eine gelernte Reihenfolge muss vom Anwender explizit übernommen
    /// werden.
    var sortIndex: Int
    /// Das Geschäft, zu dem dieses Regal gehört.
    var geschaeft: Geschaeft?
    /// Artikelkategorien, die in diesem Regal zu finden sind.
    @Relationship(inverse: \ArtikelKategorie.regale)
    var kategorien: [ArtikelKategorie] = []

    init(name: String, sortIndex: Int = 0, geschaeft: Geschaeft? = nil) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.geschaeft = geschaeft
    }
}
