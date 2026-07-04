import Foundation
import SwiftData

/// Stellt Standard-Artikelkategorien bereit, die beim ersten App-Start angelegt
/// werden, damit der Anwender nicht bei null anfangen muss.
enum SeedData {
    /// Name, SF-Symbol und Farbe der Standardkategorien in Anzeige-Reihenfolge.
    static let standardKategorien: [(name: String, symbol: String, farbeHex: String)] = [
        ("Obst & Gemüse", "carrot.fill", "#34C759"),
        ("Brot & Backwaren", "basket.fill", "#FF9500"),
        ("Milchprodukte & Eier", "refrigerator.fill", "#5AC8FA"),
        ("Fleisch & Fisch", "fish.fill", "#FF3B30"),
        ("Getränke", "waterbottle.fill", "#007AFF"),
        ("Tiefkühlkost", "snowflake", "#64D2FF"),
        ("Drogerie & Kosmetik", "sparkles", "#AF52DE"),
        ("Reinigungsmittel", "bubbles.and.sparkles.fill", "#5856D6"),
        ("Medikamente", "pills.fill", "#FF2D55"),
        ("Baumarkt & Werkzeug", "hammer.fill", "#A2845E"),
        ("Elektro & Batterien", "bolt.fill", "#FFCC00"),
        ("Kleidung", "tshirt.fill", "#FF6482"),
        ("Tierbedarf", "pawprint.fill", "#8E8E93"),
        ("Bücher & Schreibwaren", "book.fill", "#32ADE6"),
        ("Sonstiges", "shippingbox.fill", "#8E8E93"),
    ]

    /// Legt die Standardkategorien an, sofern noch keine ``ArtikelKategorie`` im
    /// übergebenen Kontext existiert. Wird idempotent aufgerufen (z.B. bei jedem
    /// App-Start) und ändert nichts, wenn der Anwender bereits eigene Kategorien hat.
    @MainActor
    static func seedeStandarddatenFallsLeer(context: ModelContext) {
        let deskriptor = FetchDescriptor<ArtikelKategorie>()
        let anzahl = (try? context.fetchCount(deskriptor)) ?? 0
        guard anzahl == 0 else { return }

        for (index, eintrag) in standardKategorien.enumerated() {
            let kategorie = ArtikelKategorie(
                name: eintrag.name,
                standardSymbol: eintrag.symbol,
                standardFarbeHex: eintrag.farbeHex,
                sortIndex: index
            )
            context.insert(kategorie)
        }
    }
}
