import Foundation
import SwiftData

/// Stellt Standard-Abteilungen bereit, die beim ersten App-Start angelegt
/// werden, damit der Anwender nicht bei null anfangen muss.
enum SeedData {
    /// Name, SF-Symbol und Farbe der Standardabteilungen in Anzeige-Reihenfolge.
    static let standardAbteilungen: [(name: String, symbol: String, farbeHex: String)] = [
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

    /// Name und SF-Symbol der Standard-Geschäftstypen (GitHub #25) in
    /// Anzeige-Reihenfolge — entspricht den bisherigen `GeschaeftTyp`-enum-Fällen.
    static let standardGeschaeftsTypen: [(name: String, symbol: String)] = [
        ("Lebensmittel", "cart.fill"),
        ("Drogerie", "sparkles"),
        ("Baumarkt", "hammer.fill"),
        ("Apotheke", "cross.case.fill"),
        ("Elektronik", "bolt.fill"),
        ("Bekleidung", "tshirt.fill"),
        ("Getränkemarkt", "waterbottle.fill"),
        ("Tierbedarf", "pawprint.fill"),
        ("Bücher & Schreibwaren", "book.fill"),
        (GeschaeftTyp.sonstigesName, "shippingbox.fill"),
    ]

    /// Legt die Standardabteilungen an, sofern noch keine ``Abteilung`` im
    /// übergebenen Kontext existiert. Wird idempotent aufgerufen (z.B. bei jedem
    /// App-Start) und ändert nichts, wenn der Anwender bereits eigene Abteilungen hat.
    @MainActor
    static func seedeStandarddatenFallsLeer(context: ModelContext) {
        let deskriptor = FetchDescriptor<Abteilung>()
        let anzahl = (try? context.fetchCount(deskriptor)) ?? 0
        guard anzahl == 0 else { return }

        for (index, eintrag) in standardAbteilungen.enumerated() {
            let abteilung = Abteilung(
                name: eintrag.name,
                standardSymbol: eintrag.symbol,
                standardFarbeHex: eintrag.farbeHex,
                sortIndex: index
            )
            context.insert(abteilung)
        }
        // Expliziter Save nötig, seit Autosave global deaktiviert ist (siehe
        // `docs/DATABASE_CONCURRENCY.md` → „Voraussetzung: explizite Speicherpunkte“).
        // Bewusst ohne Lease-Schutz (Nutzervorgabe) — das seltene Race bei
        // zeitgleichem Erst-Start zweier Geräte gegen einen leeren Store führt
        // höchstens zu kosmetischen doppelten Abteilungen, siehe „Vollständiger
        // Schreibvorgang-Katalog“.
        try? context.save()
    }

    /// Legt die Standard-Geschäftstypen an, sofern noch kein ``GeschaeftTyp`` im
    /// übergebenen Kontext existiert (GitHub #25) — analog
    /// ``seedeStandarddatenFallsLeer(context:)``.
    @MainActor
    static func seedeGeschaeftsTypenFallsLeer(context: ModelContext) {
        let deskriptor = FetchDescriptor<GeschaeftTyp>()
        let anzahl = (try? context.fetchCount(deskriptor)) ?? 0
        guard anzahl == 0 else { return }

        for (index, eintrag) in standardGeschaeftsTypen.enumerated() {
            let typ = GeschaeftTyp(name: eintrag.name, symbolName: eintrag.symbol, sortIndex: index)
            context.insert(typ)
        }
        try? context.save()
    }
}
