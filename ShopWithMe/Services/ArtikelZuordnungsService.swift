import Foundation

/// Ordnet einen auf einem Kassenbon erkannten Artikelnamen automatisch einem
/// bestehenden, generischen ``Artikel`` (und, sofern erkennbar, einem
/// konkreten ``Produkt``) zu — konsistent für alle drei ``BelegScanKontext``e
/// (``BelegScanView``), siehe `docs/BELEGSCAN.md` → „Automatische
/// Artikel-Zuordnung“ und `docs/ARTIKEL_PRODUKT_MODELL.md` (GitHub #47,
/// Schritt 5/5).
enum ArtikelZuordnungsService {
    /// Welche Zuordnungsstufe einen Treffer geliefert hat — Grundlage für
    /// ``BelegScanView``s Entscheidung, ob bei fehlendem ``Produkt``-Treffer
    /// automatisch ein neues ``Produkt`` angelegt wird (nur ``.artikelSubstring``/
    /// ``.ki``, nicht ``.alias`` — ein Alias meint dieselbe generische Sache in
    /// anderer Schreibweise, kein eigenständiges Produkt; ``.produktname``
    /// liefert ohnehin schon ein ``Produkt``). Siehe `docs/ARTIKEL_PRODUKT_MODELL.md`.
    enum Quelle: Equatable {
        case alias
        case produktname
        case artikelSubstring
        case ki
    }

    /// Textbasierte Zuordnung ohne KI, in drei Stufen:
    /// 1. Gelernter Alias (``ArtikelAlias/passend(fuerErkannterName:in:)``).
    /// 2. Gelernter ``Produktname`` **innerhalb des übergebenen `geschaeft`s**
    ///    (GitHub #47, Schritt 5/5) — liefert zusätzlich das konkrete
    ///    ``Produkt``, dessen ``Artikel`` sonst nur über Stufe 3 gefunden
    ///    würde. Ohne `geschaeft` (z.B. ``BelegScanKontext/unbekannt``, noch
    ///    kein Treffer) wirkungslos.
    /// 3. Einfacher, beidseitiger Teilstring-Abgleich gegen alle vorhandenen
    ///    ``Artikel`` (ersetzt die frühere, auf `.geschaeft`/`.unbekannt`
    ///    beschränkte private `BelegScanView.passendesArtikel(fuer:)`).
    ///
    /// `internal` statt `private`, direkt testbar ohne FoundationModels — analog
    /// `GeschaeftErkennungService.passendenVorschlag(...)`.
    static func textBasierteZuordnung(
        erkannterName: String,
        bekannteAliase: [ArtikelAlias],
        alleArtikel: [Artikel],
        geschaeft: Geschaeft? = nil,
        bekannteProduktnamen: [Produktname] = []
    ) -> (alias: String?, artikel: Artikel?, produkt: Produkt?, quelle: Quelle)? {
        if let gelernt = ArtikelAlias.passend(fuerErkannterName: erkannterName, in: bekannteAliase) {
            return (gelernt.alias, gelernt.artikel, nil, .alias)
        }
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let geschaeft,
           let produktTreffer = bekannteProduktnamen.first(where: {
               $0.geschaeft == geschaeft
                   && ($0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name))
           }),
           let artikel = produktTreffer.produkt?.artikel {
            return (nil, artikel, produktTreffer.produkt, .produktname)
        }
        guard let treffer = alleArtikel.first(where: {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }) else { return nil }
        return (nil, treffer, nil, .artikelSubstring)
    }

    /// Volle Zuordnungs-Pipeline: erst
    /// ``textBasierteZuordnung(erkannterName:bekannteAliase:alleArtikel:geschaeft:bekannteProduktnamen:)``;
    /// bleibt die erfolglos und ist lokale KI verfügbar
    /// (``AISuggestionService/istVerfuegbar``), wird zusätzlich
    /// ``AISuggestionService/artikelMatch(fuerName:bekannteArtikel:)`` befragt und
    /// deren Vorschlag exakt gegen ``alleArtikel`` aufgelöst (liefert dabei nie ein
    /// ``Produkt`` — die KI kennt nur Artikelnamen). Liefert `(nil, nil, nil, nil)`,
    /// wenn keine Stufe einen Treffer findet — die Position gilt dann als „neu
    /// erkannt“ (siehe ``BelegScanView``).
    @MainActor
    static func zuordnen(
        erkannterName: String,
        bekannteAliase: [ArtikelAlias],
        alleArtikel: [Artikel],
        geschaeft: Geschaeft? = nil,
        bekannteProduktnamen: [Produktname] = []
    ) async -> (alias: String?, artikel: Artikel?, produkt: Produkt?, quelle: Quelle?) {
        if let treffer = textBasierteZuordnung(
            erkannterName: erkannterName, bekannteAliase: bekannteAliase, alleArtikel: alleArtikel,
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
            return (nil, nil, nil, nil)
        }
        let treffer = alleArtikel.first {
            $0.name.localizedCaseInsensitiveCompare(kiVorschlag.passenderArtikel) == .orderedSame
        }
        return (nil, treffer, nil, treffer != nil ? .ki : nil)
    }
}
