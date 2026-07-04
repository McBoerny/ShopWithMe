import Foundation
import SwiftData

/// Typische Geschäftskategorien, die die Standardauswahl beim Anlegen eines
/// ``Geschaeft``s vorschlägt.
enum GeschaeftTyp: String, Codable, CaseIterable, Identifiable {
    case lebensmittel
    case drogerie
    case baumarkt
    case apotheke
    case elektronik
    case bekleidung
    case getraenkemarkt
    case tierbedarf
    case buchUndSchreibwaren
    case sonstiges

    var id: String { rawValue }

    /// Anzeigename in der Benutzeroberfläche.
    var anzeigename: String {
        switch self {
        case .lebensmittel: return "Lebensmittel"
        case .drogerie: return "Drogerie"
        case .baumarkt: return "Baumarkt"
        case .apotheke: return "Apotheke"
        case .elektronik: return "Elektronik"
        case .bekleidung: return "Bekleidung"
        case .getraenkemarkt: return "Getränkemarkt"
        case .tierbedarf: return "Tierbedarf"
        case .buchUndSchreibwaren: return "Bücher & Schreibwaren"
        case .sonstiges: return "Sonstiges"
        }
    }

    /// Standard-SF-Symbol für diesen Geschäftstyp.
    var symbolName: String {
        switch self {
        case .lebensmittel: return "cart.fill"
        case .drogerie: return "sparkles"
        case .baumarkt: return "hammer.fill"
        case .apotheke: return "cross.case.fill"
        case .elektronik: return "bolt.fill"
        case .bekleidung: return "tshirt.fill"
        case .getraenkemarkt: return "waterbottle.fill"
        case .tierbedarf: return "pawprint.fill"
        case .buchUndSchreibwaren: return "book.fill"
        case .sonstiges: return "shippingbox.fill"
        }
    }
}

/// Ein Geschäft, das der Anwender zum Einkaufen aufsucht.
///
/// Ein Geschäft besitzt eigene ``Regal``e; die Menge der in diesem Geschäft
/// verfügbaren ``ArtikelKategorie``n ergibt sich automatisch aus den Kategorien, die
/// diesen Regalen zugeordnet sind (siehe ``verfuegbareKategorien``).
@Model
final class Geschaeft {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename des Geschäfts, z.B. "Rewe am Markt".
    var name: String
    /// Geschäftstyp (Lebensmittel, Drogerie, …).
    var typ: GeschaeftTyp
    /// Optionale Adresse.
    var adresse: String?
    /// Breitengrad — für die zukünftige, standortbasierte Ladenerkennung vorbereitet,
    /// aktuell ungenutzt.
    var breitengrad: Double?
    /// Längengrad — für die zukünftige, standortbasierte Ladenerkennung vorbereitet,
    /// aktuell ungenutzt.
    var laengengrad: Double?
    /// Regale dieses Geschäfts. Wird ein Geschäft gelöscht, werden auch seine Regale
    /// gelöscht.
    @Relationship(deleteRule: .cascade, inverse: \Regal.geschaeft)
    var regale: [Regal] = []

    init(name: String, typ: GeschaeftTyp, adresse: String? = nil) {
        self.id = UUID()
        self.name = name
        self.typ = typ
        self.adresse = adresse
    }

    /// Alle Artikelkategorien, die in diesem Geschäft verfügbar sind.
    ///
    /// Leitet sich aus der Vereinigung der Kategorien ab, die den Regalen dieses
    /// Geschäfts zugeordnet sind (dedupliziert, sortiert nach
    /// ``ArtikelKategorie/sortIndex``). Beim Einkaufen werden für dieses Geschäft nur
    /// diese Kategorien angezeigt.
    var verfuegbareKategorien: [ArtikelKategorie] {
        var gesehen = Set<PersistentIdentifier>()
        return regale
            .flatMap(\.kategorien)
            .filter { gesehen.insert($0.persistentModelID).inserted }
            .sorted { $0.sortIndex < $1.sortIndex }
    }
}
