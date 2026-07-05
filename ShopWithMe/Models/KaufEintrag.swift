import Foundation
import SwiftData

/// Ein einzelner Kauf eines Artikels — die Grundlage der historischen
/// Preisübersicht.
///
/// `preis` ist bewusst optional: Beim Abhaken auf der Einkaufsliste (siehe
/// ``Einkaufsvorgang/artikelAbhaken(_:context:)``) entsteht der Eintrag zunächst
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
    /// Die Kategorie des Artikels zum Kaufzeitpunkt — Grundlage für
    /// ``ShelfOrderLearningService``, unabhängig von einer späteren Änderung der
    /// Artikel-Kategorie-Zuordnung.
    var kategorie: ArtikelKategorie?
    /// Name des Artikels zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var artikelNameSnapshot: String
    /// Name des Geschäfts zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var geschaeftNameSnapshot: String
    /// Genauer Produkt-/Markenname vom Kassenbon, falls er sich vom (ggf.
    /// generischen) ``artikel`` unterscheidet — z.B. „Colgate Total“ bei einem auf
    /// „Zahnpasta“ verlinkten ``Artikel``. Wird beim Belegscan gesetzt, damit
    /// unterschiedliche Marken desselben generischen Artikels in der Preishistorie
    /// unterscheidbar bleiben (siehe ``BelegScanView``), statt beim Umbenennen zwecks
    /// Zuordnung verlorenzugehen. `nil` für normale Einkaufslisten-Käufe ohne
    /// Belegscan.
    var produktName: String?
    /// Vom Nutzer vergebener alternativer Anzeigename für diese Position, z.B. um
    /// einen unhandlich abgekürzten Kassenbon-Namen durch einen sprechenden Namen zu
    /// ersetzen. `nil`/leer, solange kein alternativer Name gesetzt wurde. Hat, sobald
    /// gesetzt, Vorrang vor ``produktName``/``artikel``/``artikelNameSnapshot`` — siehe
    /// ``anzeigeName`` und `docs/BELEGSCAN.md`.
    var alternativerName: String?
    /// Datum des Kaufs.
    var datum: Date
    /// Bezahlter Preis — `nil`, solange noch kein Beleg dazu gescannt/erfasst wurde.
    var preis: Decimal?
    /// Gekaufte Menge (Standard: 1).
    var menge: Double
    /// Position in der chronologischen Kategorie-Besuchsreihenfolge dieses
    /// Einkaufsvorgangs — Grundlage für ``ShelfOrderLearningService``.
    var kategorieBesuchsIndex: Int?

    init(
        artikel: Artikel?,
        geschaeft: Geschaeft?,
        kategorie: ArtikelKategorie? = nil,
        preis: Decimal? = nil,
        menge: Double = 1,
        datum: Date = Date(),
        kategorieBesuchsIndex: Int? = nil
    ) {
        self.id = UUID()
        self.artikel = artikel
        self.geschaeft = geschaeft
        self.kategorie = kategorie
        self.artikelNameSnapshot = artikel?.name ?? ""
        self.geschaeftNameSnapshot = geschaeft?.name ?? ""
        self.datum = datum
        self.preis = preis
        self.menge = menge
        self.kategorieBesuchsIndex = kategorieBesuchsIndex
    }
}

extension KaufEintrag {
    /// Der für Anzeigen (z.B. ``PreisHistorieZeile``) tatsächlich zu verwendende
    /// Artikelname, mit ``alternativerName`` an oberster Priorität, sonst wie bisher
    /// ``produktName`` (Original vom Kassenbon), dann ``artikel``, dann
    /// ``artikelNameSnapshot``. Siehe `docs/BELEGSCAN.md`.
    var anzeigeName: String {
        if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alternativerName
        }
        let name = produktName ?? artikel?.name ?? artikelNameSnapshot
        return name.isEmpty ? "Unbekannter Artikel" : name
    }
}
