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
    /// Kassenbon-Barcode für dieses Produkt in diesem Geschäft — optional,
    /// da nicht immer bekannt.
    var barcode: String?

    init(name: String, produkt: Produkt?, geschaeft: Geschaeft?, barcode: String? = nil) {
        self.id = UUID()
        self.name = name
        self.produkt = produkt
        self.geschaeft = geschaeft
        self.barcode = barcode
    }
}

extension Produktname {
    /// Sucht in `alle` einen zu `erkannterName` passenden ``Produktname`` —
    /// Nachfolge-Stufe von `ArtikelAlias.passend(fuerErkannterName:in:)`
    /// (GitHub #111/#128), jetzt vereinheitlicht mit dem geschäftsspezifischen
    /// Produktname-Abgleich (vormals Stufe 2 in ``ArtikelZuordnungsService``).
    ///
    /// Reihenfolge, jeweils exakter (case-insensitiver) Treffer vor
    /// beidseitigem Teilstring-Abgleich:
    /// 1. Treffer mit `geschaeft == bevorzugtesGeschaeft` (geschäftsspezifisch,
    ///    präziser — z.B. verschiedene Filialen desselben Namens schreiben
    ///    denselben Artikel unterschiedlich ab).
    /// 2. Treffer mit `geschaeft == nil` — die geschäftsunabhängige Rolle, die
    ///    vormals `ArtikelAlias` abdeckte (z.B. Erfassung ohne bekanntes
    ///    Geschäft, oder ein bewusst geschäftsunabhängig gelernter Rohname).
    ///
    /// `bevorzugtesGeschaeft: nil` (z.B. ``BelegScanKontext/unbekannt`` vor
    /// Geschäfts-Abgleich) übergeht Stufe 1 und sucht nur unter `geschaeft == nil`.
    static func passend(fuerErkannterName erkannterName: String, bevorzugtesGeschaeft: Geschaeft?, in alle: [Produktname]) -> Produktname? {
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        func treffer(unter kandidaten: [Produktname]) -> Produktname? {
            if let exakt = kandidaten.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return exakt
            }
            return kandidaten.first {
                $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
            }
        }

        if let bevorzugtesGeschaeft {
            let geschaeftsspezifisch = alle.filter { $0.geschaeft == bevorzugtesGeschaeft }
            if let treffer = treffer(unter: geschaeftsspezifisch) { return treffer }
        }
        let geschaeftsunabhaengig = alle.filter { $0.geschaeft == nil }
        return treffer(unter: geschaeftsunabhaengig)
    }
}
