import Foundation

/// Ordnet einen auf einem Kassenbon erkannten Artikelnamen automatisch einem
/// bestehenden, generischen ``Artikel`` zu — konsistent für alle drei
/// ``BelegScanKontext``e (``BelegScanView``), siehe `docs/BELEGSCAN.md` →
/// „Automatische Artikel-Zuordnung“.
enum ArtikelZuordnungsService {
    /// Textbasierte Zuordnung ohne KI, in zwei Stufen:
    /// 1. Gelernter Alias (``ArtikelAlias/passend(fuerErkannterName:in:)``).
    /// 2. Einfacher, beidseitiger Teilstring-Abgleich gegen alle vorhandenen
    ///    ``Artikel`` (ersetzt die frühere, auf `.geschaeft`/`.unbekannt`
    ///    beschränkte private `BelegScanView.passendesArtikel(fuer:)`).
    ///
    /// `internal` statt `private`, direkt testbar ohne FoundationModels — analog
    /// `GeschaeftErkennungService.passendenVorschlag(...)`.
    static func textBasierteZuordnung(
        erkannterName: String,
        bekannteAliase: [ArtikelAlias],
        alleArtikel: [Artikel]
    ) -> (alias: String?, artikel: Artikel?)? {
        if let gelernt = ArtikelAlias.passend(fuerErkannterName: erkannterName, in: bekannteAliase) {
            return gelernt
        }
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let treffer = alleArtikel.first(where: {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }) else { return nil }
        return (nil, treffer)
    }

    /// Volle Zuordnungs-Pipeline: erst ``textBasierteZuordnung(erkannterName:bekannteAliase:alleArtikel:)``;
    /// bleibt die erfolglos und ist lokale KI verfügbar
    /// (``AISuggestionService/istVerfuegbar``), wird zusätzlich
    /// ``AISuggestionService/artikelMatch(fuerName:bekannteArtikel:)`` befragt und
    /// deren Vorschlag exakt gegen ``alleArtikel`` aufgelöst. Liefert `(nil, nil)`,
    /// wenn keine Stufe einen Treffer findet — die Position gilt dann als „neu
    /// erkannt“ (siehe ``BelegScanView``).
    @MainActor
    static func zuordnen(
        erkannterName: String,
        bekannteAliase: [ArtikelAlias],
        alleArtikel: [Artikel]
    ) async -> (alias: String?, artikel: Artikel?) {
        if let treffer = textBasierteZuordnung(erkannterName: erkannterName, bekannteAliase: bekannteAliase, alleArtikel: alleArtikel) {
            return treffer
        }
        guard AISuggestionService.istVerfuegbar,
              let kiVorschlag = try? await AISuggestionService.artikelMatch(
                  fuerName: erkannterName,
                  bekannteArtikel: alleArtikel.map(\.name)
              )
        else {
            return (nil, nil)
        }
        let treffer = alleArtikel.first {
            $0.name.localizedCaseInsensitiveCompare(kiVorschlag.passenderArtikel) == .orderedSame
        }
        return (nil, treffer)
    }
}
