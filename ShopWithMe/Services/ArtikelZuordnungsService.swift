import Foundation

/// Ordnet einen auf einem Kassenbon erkannten Artikelnamen automatisch einem
/// bestehenden, generischen ``Artikel`` (und, sofern erkennbar, einem
/// konkreten ``Produkt``) zu — konsistent für alle drei ``BelegScanKontext``e
/// (``BelegScanView``), siehe `docs/BELEGSCAN.md` → „Automatische
/// Artikel-Zuordnung“ und `docs/ARTIKEL_PRODUKT_MODELL.md` (GitHub #47,
/// Schritt 5/5; GitHub #128 — Ablösung von `ArtikelAlias` durch
/// ``Produktname``/``Artikel/alternativeNamen``).
enum ArtikelZuordnungsService {
    /// Welche Zuordnungsstufe einen Treffer geliefert hat — Grundlage für
    /// ``BelegScanView``s Entscheidung, ob bei fehlendem ``Produkt``-Treffer
    /// automatisch ein neues ``Produkt`` angelegt wird (nur wenn noch keins
    /// vorliegt — ``.produktname`` liefert ohnehin schon eins). Siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md`.
    enum Quelle: Equatable {
        case produktname
        case artikelSubstring
        case ki
    }

    /// Textbasierte Zuordnung ohne KI, in zwei Stufen:
    /// 1. Gelernter ``Produktname`` (``Produktname/passend(fuerErkannterName:bevorzugtesGeschaeft:in:)``)
    ///    — sucht zuerst geschäftsspezifisch (`geschaeft`), dann geschäftsunabhängig
    ///    (`geschaeft == nil`, die vormalige `ArtikelAlias`-Rolle). Liefert
    ///    zusätzlich das konkrete ``Produkt``.
    /// 2. Einfacher, beidseitiger Teilstring-Abgleich gegen alle vorhandenen
    ///    ``Artikel`` — sowohl gegen ``Artikel/name`` als auch gegen
    ///    ``Artikel/alternativeNamen`` (generische, vom Nutzer gepflegte
    ///    Synonyme, Nachfolge eines manuell hinzugefügten `ArtikelAlias`-Namens
    ///    ohne Produktbezug).
    ///
    /// `internal` statt `private`, direkt testbar ohne FoundationModels — analog
    /// `GeschaeftErkennungService.passendenVorschlag(...)`.
    static func textBasierteZuordnung(
        erkannterName: String,
        alleArtikel: [Artikel],
        geschaeft: Geschaeft? = nil,
        bekannteProduktnamen: [Produktname] = []
    ) -> (artikel: Artikel?, produkt: Produkt?, quelle: Quelle)? {
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let produktTreffer = Produktname.passend(fuerErkannterName: name, bevorzugtesGeschaeft: geschaeft, in: bekannteProduktnamen),
           let artikel = produktTreffer.produkt?.artikel {
            return (artikel, produktTreffer.produkt, .produktname)
        }
        guard let treffer = alleArtikel.first(where: { artikel in
            artikel.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikel.name)
                || artikel.alternativeNamen.contains(where: {
                    $0.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0)
                })
        }) else { return nil }
        return (treffer, nil, .artikelSubstring)
    }

    /// Volle Zuordnungs-Pipeline: erst
    /// ``textBasierteZuordnung(erkannterName:alleArtikel:geschaeft:bekannteProduktnamen:)``;
    /// bleibt die erfolglos und ist lokale KI verfügbar
    /// (``AISuggestionService/istVerfuegbar``), wird zusätzlich
    /// ``AISuggestionService/artikelMatch(fuerName:bekannteArtikel:)`` befragt und
    /// deren Vorschlag exakt gegen ``alleArtikel`` aufgelöst (liefert dabei nie ein
    /// ``Produkt`` — die KI kennt nur Artikelnamen). Liefert `(nil, nil, nil)`,
    /// wenn keine Stufe einen Treffer findet — die Position gilt dann als „neu
    /// erkannt“ (siehe ``BelegScanView``).
    @MainActor
    static func zuordnen(
        erkannterName: String,
        alleArtikel: [Artikel],
        geschaeft: Geschaeft? = nil,
        bekannteProduktnamen: [Produktname] = []
    ) async -> (artikel: Artikel?, produkt: Produkt?, quelle: Quelle?) {
        if let treffer = textBasierteZuordnung(
            erkannterName: erkannterName, alleArtikel: alleArtikel,
            geschaeft: geschaeft, bekannteProduktnamen: bekannteProduktnamen
        ) {
            return treffer
        }
        guard AISuggestionService.istVerfuegbar,
              let kiVorschlag = try? await AISuggestionService.artikelMatch(
                  fuerName: erkannterName,
                  bekannteArtikel: alleArtikel.map(\.name)
              )
        else {
            return (nil, nil, nil)
        }
        let treffer = alleArtikel.first {
            $0.name.localizedCaseInsensitiveCompare(kiVorschlag.passenderArtikel) == .orderedSame
        }
        return (treffer, nil, treffer != nil ? .ki : nil)
    }
}
