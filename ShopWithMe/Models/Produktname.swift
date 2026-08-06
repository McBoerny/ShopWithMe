import Foundation
import SwiftData

/// Ein geschäftsabhängiger Name eines ``Produkt``s, z.B. "Parad Zahncr" für
/// "Paradontol Zahncreme" bei Geschäft A (GitHub #47) — im Unterschied zum
/// geschäftsunabhängigen ``ArtikelAlias`` (GitHub #111). Siehe
/// `docs/ARTIKEL_PRODUKT_MODELL.md`.
@Model
final class Produktname {
    /// Eindeutige Kennung.
    @Attribute(.unique) var id: UUID
    /// Der in diesem Geschäft verwendete Name.
    var name: String
    /// Das Produkt, dem dieser Name zugeordnet ist.
    var produkt: Produkt?
    /// Das Geschäft, in dem dieser Name gilt.
    var geschaeft: Geschaeft?

    init(name: String, produkt: Produkt?, geschaeft: Geschaeft?) {
        self.id = UUID()
        self.name = name
        self.produkt = produkt
        self.geschaeft = geschaeft
    }
}
