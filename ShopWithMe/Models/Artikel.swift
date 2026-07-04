import Foundation
import SwiftData

/// Ein einkaufbarer Artikel (z.B. "Vollmilch").
///
/// Jeder Artikel gehört zu genau einer ``ArtikelKategorie``. Die Kategorie kann jederzeit
/// über die Bearbeiten-Bildschirme geändert werden.
@Model
final class Artikel {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename des Artikels.
    var name: String
    /// SF-Symbol-Name für die Darstellung des Artikels.
    var symbolName: String
    /// Farbe als Hex-String (z.B. `"#34C759"`).
    var farbeHex: String
    /// Die Kategorie dieses Artikels.
    var kategorie: ArtikelKategorie?
    /// Ob der Artikel aktuell auf der Einkaufsliste steht.
    var istAufEinkaufsliste: Bool
    /// Zeitpunkt der Anlage.
    var erstelltAm: Date
    /// Optionale Notiz, z.B. bevorzugte Marke.
    var notiz: String?

    init(
        name: String,
        symbolName: String,
        farbeHex: String,
        kategorie: ArtikelKategorie? = nil,
        istAufEinkaufsliste: Bool = false,
        notiz: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.symbolName = symbolName
        self.farbeHex = farbeHex
        self.kategorie = kategorie
        self.istAufEinkaufsliste = istAufEinkaufsliste
        self.erstelltAm = Date()
        self.notiz = notiz
    }
}

extension Artikel {
    /// Die für Gruppierung, Regal-Zuordnung und Lernalgorithmus tatsächlich
    /// wirksame Kategorie: ``kategorie``, oder — falls keine gesetzt ist —
    /// automatisch "Sonstiges" (siehe ``ArtikelKategorie/sonstige(context:)``).
    func effektiveKategorie(context: ModelContext) -> ArtikelKategorie {
        kategorie ?? ArtikelKategorie.sonstige(context: context)
    }
}
