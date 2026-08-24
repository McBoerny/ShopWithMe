import Foundation
import NaturalLanguage
import os

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

    /// Cache für ``lemma`` nach Eingabe-String, per ``OSAllocatedUnfairLock``
    /// synchronisiert (statt `@MainActor`, damit die weiterhin rein
    /// synchrone, von jedem Kontext aufrufbare API erhalten bleibt — u.a.
    /// direkt von ``StringSingularPluralTests`` außerhalb des Main Actors
    /// genutzt). `NLTagger`-Aufrufe (Allokation + Tagging) sind einzeln teuer;
    /// ohne Cache berechnet ``passtAlsSingularPluralZu(_:)`` z.B. das Lemma
    /// des Suchtexts bei jedem Artikel/Wort-Vergleich neu, obwohl der
    /// Suchtext über einen kompletten Filterdurchlauf (bei >1000 Artikeln in
    /// ``ArtikelHinzufuegenView`` entsprechend oft) unverändert bleibt —
    /// Nutzerbericht 2026-08-24: Suche bei ca. 1200 Artikeln praktisch
    /// unbenutzbar langsam.
    private static let lemmaCache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    /// Wiederverwendetes `Locale` statt einer Neukonstruktion pro
    /// ``diakritikGefaltet``-Aufruf — dieselbe Ursache/derselbe Fund wie bei
    /// ``lemmaCache`` (Nutzerbericht 2026-08-24, Folgefund).
    private static let vergleichsLocale = Locale(identifier: "de_DE")

    /// Cache für ``diakritikGefaltet`` nach Eingabe-String, analog
    /// ``lemmaCache``: `andere` (der Suchtext) bleibt über einen kompletten
    /// Filterdurchlauf unverändert, würde ohne Cache aber pro verglichenem
    /// Artikel/Wort erneut gefaltet.
    private static let stammCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Umlaut-gefaltete, kleingeschriebene Form für den Wortstamm-Vergleich.
    /// Über ``stammCache`` gecacht.
    private var diakritikGefaltet: String {
        if let cached = Self.stammCache.withLock({ $0[self] }) { return cached }
        let ergebnis = folding(options: .diacriticInsensitive, locale: Self.vergleichsLocale).lowercased()
        Self.stammCache.withLock { $0[self] = ergebnis }
        return ergebnis
    }

    /// `NLTagger`-Lemma (Grundform) dieses (einzelnen) Wortes — `nil`, wenn
    /// keins ermittelbar ist. Siehe Typ-Dokumentation: nur als Zusatzsignal
    /// verwenden, nie als alleinige Grundlage. Über ``lemmaCache`` gecacht.
    private var lemma: String? {
        guard !isEmpty else { return nil }
        if let cached = Self.lemmaCache.withLock({ $0[self] }) { return cached }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = self
        let ergebnis = tagger.tag(at: startIndex, unit: .word, scheme: .lemma).0?.rawValue
        Self.lemmaCache.withLock { $0[self] = ergebnis }
        return ergebnis
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
