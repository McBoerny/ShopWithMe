import Foundation
import NaturalLanguage

/// Singular-/Plural-unabhängiger Wortvergleich für die Artikelsuche (GitHub #44).
///
/// Kombiniert zwei Signale, weil keins allein ausreicht:
/// - Eine deterministische Heuristik (Umlaut-Faltung + Abschneiden gängiger
///   deutscher Pluralendungen), die empirisch gegen 15 typische
///   Einkaufs-Wortpaare (Apfel/Äpfel, Haus/Häuser, Tomate/Tomaten, Ei/Eier,
///   Glas/Gläser, Banane/Bananen, Zitrone/Zitronen, Joghurt/Joghurts, …) alle
///   Fälle korrekt abdeckt.
/// - `NLTagger`s `.lemma`-Schema als zusätzliches Signal — im selben Test aber
///   nur bei rund der Hälfte der Wortpaare überhaupt ein Ergebnis, in einem
///   Fall sogar falsch ("Haus" → "Hau"). Deshalb ausschließlich additiv
///   verwendet (kann zusätzliche Treffer liefern, nie welche verhindern) statt
///   als alleinige Grundlage — sonst würde genau die Lücke entstehen, die
///   diese Funktion vermeiden soll.
extension String {
    private static let gaengigePluralEndungen: Set<String> = ["en", "er", "e", "n", "s"]

    /// Umlaut-gefaltete, kleingeschriebene Form für den Wortstamm-Vergleich.
    private var diakritikGefaltet: String {
        folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE")).lowercased()
    }

    /// `NLTagger`-Lemma (Grundform) dieses (einzelnen) Wortes — `nil`, wenn
    /// keins ermittelbar ist. Siehe Typ-Dokumentation: nur als Zusatzsignal
    /// verwenden, nie als alleinige Grundlage.
    private var lemma: String? {
        guard !isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = self
        return tagger.tag(at: startIndex, unit: .word, scheme: .lemma).0?.rawValue
    }

    /// Ob sich `self` und `andere` nur durch Singular/Plural unterscheiden
    /// könnten (GitHub #44) — Wortstamm-Heuristik ODER übereinstimmendes
    /// `NLTagger`-Lemma.
    ///
    /// Die Heuristik prüft (nach Umlaut-Faltung), ob das kürzere der beiden
    /// Wörter ein Präfix des längeren ist UND der verbleibende Rest exakt einer
    /// gängigen deutschen Pluralendung entspricht — nicht (wie eine frühere,
    /// fehlerhafte Fassung) probeweise eine geratene Endung vom längeren Wort
    /// abzuschneiden und mit dem unveränderten kürzeren zu vergleichen: das
    /// scheiterte z.B. bei "Tomate"/"Tomaten", weil "en" (statt korrekt "n")
    /// als erste passende Endung abgeschnitten wurde und "tomat" dann nicht
    /// mehr zu "tomate" passte.
    func passtAlsSingularPluralZu(_ andere: String) -> Bool {
        let eigenerStamm = diakritikGefaltet
        let andererStamm = andere.diakritikGefaltet
        if eigenerStamm == andererStamm { return true }

        let (kuerzer, laenger) = eigenerStamm.count <= andererStamm.count ? (eigenerStamm, andererStamm) : (andererStamm, eigenerStamm)
        if laenger.hasPrefix(kuerzer) {
            let rest = laenger.dropFirst(kuerzer.count)
            if Self.gaengigePluralEndungen.contains(String(rest)) { return true }
        }

        if let eigenesLemma = lemma?.lowercased(), let anderesLemma = andere.lemma?.lowercased(),
           eigenesLemma == anderesLemma {
            return true
        }
        return false
    }
}
