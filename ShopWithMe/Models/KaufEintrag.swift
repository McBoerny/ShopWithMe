import Foundation
import SwiftData

/// Ein einzelner Kauf eines Artikels — die Grundlage der historischen
/// Preisübersicht.
///
/// `preis` ist bewusst optional: Beim Abhaken auf der Einkaufsliste (siehe
/// ``Einkaufsvorgang/artikelAbhaken(_:regal:context:)``) entsteht der Eintrag zunächst
/// ohne Preis; erst der spätere Belegscan trägt den tatsächlich bezahlten Preis nach.
///
/// `artikelNameSnapshot`/`geschaeftNameSnapshot` speichern den Namen zum Kaufzeitpunkt
/// dauerhaft, damit die Preishistorie auch dann noch lesbar bleibt, wenn der
/// zugehörige ``Artikel`` oder ``Geschaeft`` später umbenannt oder gelöscht wird.
@Model
final class KaufEintrag {
    /// Eindeutige Kennung.
    var id: UUID
    /// Der gekaufte Artikel (kann `nil` werden, wenn der Artikel später gelöscht wird).
    var artikel: Artikel?
    /// Der Einkaufsvorgang, zu dem dieser Kauf gehört.
    var einkaufsvorgang: Einkaufsvorgang?
    /// Das Geschäft, in dem der Kauf stattfand.
    var geschaeft: Geschaeft?
    /// Das Regal, aus dem der Artikel beim Einkaufen entnommen wurde — Grundlage für
    /// ``ShelfOrderLearningService``, unabhängig von einer späteren Änderung der
    /// Regal-Kategorie-Zuordnung.
    var regal: Regal?
    /// Name des Artikels zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var artikelNameSnapshot: String
    /// Name des Geschäfts zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var geschaeftNameSnapshot: String
    /// Datum des Kaufs.
    var datum: Date
    /// Bezahlter Preis — `nil`, solange noch kein Beleg dazu gescannt/erfasst wurde.
    var preis: Decimal?
    /// Gekaufte Menge (Standard: 1).
    var menge: Double
    /// Position in der chronologischen Regal-Besuchsreihenfolge dieses
    /// Einkaufsvorgangs — Grundlage für ``ShelfOrderLearningService``.
    var regalBesuchsIndex: Int?

    init(
        artikel: Artikel?,
        geschaeft: Geschaeft?,
        regal: Regal? = nil,
        preis: Decimal? = nil,
        menge: Double = 1,
        datum: Date = Date(),
        regalBesuchsIndex: Int? = nil
    ) {
        self.id = UUID()
        self.artikel = artikel
        self.geschaeft = geschaeft
        self.regal = regal
        self.artikelNameSnapshot = artikel?.name ?? ""
        self.geschaeftNameSnapshot = geschaeft?.name ?? ""
        self.datum = datum
        self.preis = preis
        self.menge = menge
        self.regalBesuchsIndex = regalBesuchsIndex
    }
}
