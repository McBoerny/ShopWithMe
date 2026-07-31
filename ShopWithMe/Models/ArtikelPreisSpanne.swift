import Foundation

/// Aggregiert alle ``Preispunkt``e eines ``Artikel``s (z.B. innerhalb eines
/// ``Geschaeft``s) zu einer Preisspanne — Grundlage für die Preisübersicht eines
/// Geschäfts (siehe `docs/BELEGSCAN.md`).
struct ArtikelPreisSpanne: Identifiable {
    let artikel: Artikel
    let eintraege: [Preispunkt]

    var id: UUID { artikel.id }

    /// Niedrigster erfasster Preis, `nil` falls keiner der Einträge einen Preis hat.
    var minimum: Decimal? { eintraege.map(\.preis).min() }
    /// Höchster erfasster Preis, `nil` falls keiner der Einträge einen Preis hat.
    var maximum: Decimal? { eintraege.map(\.preis).max() }
}

extension ArtikelPreisSpanne {
    /// Gruppiert `eintraege` nach ihrem verknüpften ``Preispunkt/artikel``. Einträge
    /// ohne Artikel-Verknüpfung werden ausgelassen — die zeigt die Preisübersicht
    /// separat unter „Ohne Artikel-Zuordnung“ an (siehe `docs/BELEGSCAN.md`).
    /// Ergebnis alphabetisch nach Artikelname sortiert.
    static func gruppieren(_ eintraege: [Preispunkt]) -> [ArtikelPreisSpanne] {
        var eintraegeProArtikelID: [UUID: [Preispunkt]] = [:]
        var artikelProID: [UUID: Artikel] = [:]
        for eintrag in eintraege {
            guard let artikel = eintrag.artikel else { continue }
            eintraegeProArtikelID[artikel.id, default: []].append(eintrag)
            artikelProID[artikel.id] = artikel
        }
        return eintraegeProArtikelID.compactMap { artikelID, gruppenEintraege in
            guard let artikel = artikelProID[artikelID] else { return nil }
            return ArtikelPreisSpanne(artikel: artikel, eintraege: gruppenEintraege)
        }
        .sorted { $0.artikel.name.vergleicheAlphabetisch(mit: $1.artikel.name) == .orderedAscending }
    }
}
