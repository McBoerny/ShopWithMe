import Foundation

/// Locale-bewusste alphabetische Sortierung/Gruppierung (GitHub #34): reines `<`/
/// `sorted()` vergleicht nach Unicode-Codepoint und sortiert umlauthaltige Namen
/// dadurch fälschlich ans Ende der Liste (z.B. „Ä" = U+00C4 liegt hinter „Z" =
/// U+005A). Umlaute sollen stattdessen wie ihr Basisbuchstabe einsortiert werden
/// (Ä bei A, Ö bei O, Ü bei U).
extension String {
    /// Alphabetischer Vergleich zweier Strings, bei dem Umlaute wie ihr
    /// Basisbuchstabe behandelt werden — für die Anzeige-Reihenfolge in Listen.
    func vergleicheAlphabetisch(mit andere: String) -> ComparisonResult {
        compare(andere, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "de_DE"))
    }

    /// Der für Gruppierung/A–Z-Sprungleiste relevante Anfangsbuchstabe: Umlaute
    /// werden auf ihren Basisbuchstaben abgebildet (Ä→A, Ö→O, Ü→U), siehe
    /// ``vergleicheAlphabetisch(mit:)``. Für Namen ohne Anfangsbuchstaben (leer)
    /// oder mit einem Sonderzeichen als erstem Zeichen: `"#"`.
    var alphabetischerAnfangsbuchstabe: String {
        guard let erstesZeichen = first else { return "#" }
        let gefaltet = String(erstesZeichen)
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .uppercased()
        return gefaltet.isEmpty ? "#" : gefaltet
    }
}
