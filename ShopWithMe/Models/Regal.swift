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

    /// Kategorien aus `alle`, die diesem Regal zugeordnet werden können.
    ///
    /// Das sind die bereits diesem Regal zugeordneten Kategorien sowie alle
    /// Kategorien, die noch keinem anderen Regal desselben Geschäfts zugeordnet
    /// sind — jede Kategorie soll innerhalb eines Geschäfts genau einem Regal
    /// angehören.
    func auswaehlbareKategorien(aus alle: [ArtikelKategorie]) -> [ArtikelKategorie] {
        let anderweitigVerwendet = Set(
            (geschaeft?.regale ?? [])
                .filter { $0.persistentModelID != persistentModelID }
                .flatMap(\.kategorien)
                .map(\.persistentModelID)
        )
        return alle.filter {
            kategorien.contains($0) || !anderweitigVerwendet.contains($0.persistentModelID)
        }
    }
}
