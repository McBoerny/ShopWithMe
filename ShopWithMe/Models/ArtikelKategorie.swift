import Foundation
import SwiftData

/// Eine Artikelkategorie fasst gleichartige Artikel zusammen, z.B. „Obst & Gemüse“.
///
/// Kategorien sind global und geschäftsunabhängig. Ob eine Kategorie in einem
/// bestimmten Geschäft überhaupt vorkommt, ergibt sich ausschließlich daraus, ob sie
/// einem ``Regal`` dieses Geschäfts zugeordnet ist — es gibt bewusst kein separates
/// Verfügbarkeits-Modell (siehe `docs/DECISIONS.md`).
@Model
final class ArtikelKategorie {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename der Kategorie, z.B. "Obst & Gemüse".
    var name: String
    /// Standard-SF-Symbol, das neuen ``Artikel``n dieser Kategorie vorgeschlagen wird.
    var standardSymbol: String
    /// Standardfarbe als Hex-String (z.B. `"#34C759"`), die neuen ``Artikel``n dieser
    /// Kategorie vorgeschlagen wird.
    var standardFarbeHex: String
    /// Reihenfolge für die Anzeige in Auswahllisten.
    var sortIndex: Int

    /// Artikel, die dieser Kategorie zugeordnet sind.
    @Relationship(deleteRule: .nullify, inverse: \Artikel.kategorie)
    var artikel: [Artikel] = []

    /// Regale (über alle Geschäfte hinweg), denen diese Kategorie zugeordnet ist.
    var regale: [Regal] = []

    init(name: String, standardSymbol: String, standardFarbeHex: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.standardSymbol = standardSymbol
        self.standardFarbeHex = standardFarbeHex
        self.sortIndex = sortIndex
    }
}
