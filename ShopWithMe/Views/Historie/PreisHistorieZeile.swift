import SwiftUI

/// Eine Zeile der Preishistorie: Datum, Preis und wahlweise Artikel- oder
/// Geschäftsname (je nachdem, aus welcher Detailansicht heraus sie angezeigt wird).
struct PreisHistorieZeile: View {
    let eintrag: KaufEintrag
    /// `true` in der Geschäfts-Detailansicht (zeigt den Artikelnamen), `false` in der
    /// Artikel-Detailansicht (zeigt den Geschäftsnamen).
    let zeigeArtikel: Bool

    private static let datumsFormat: Date.FormatStyle = .dateTime.day().month().year()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(zeigeArtikel ? artikelName : geschaeftName)
                Text(eintrag.datum, format: Self.datumsFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let preis = eintrag.preis {
                Text(preis, format: .currency(code: "EUR"))
            } else {
                Text("Preis unbekannt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Zeigt den genauen Produktnamen (z.B. „Colgate Total“), falls beim Belegscan
    /// erfasst — sonst den (ggf. generischen) Artikelnamen. So bleiben unterschiedliche
    /// Marken desselben generischen ``Artikel``s (z.B. „Zahnpasta“) in der
    /// Preishistorie unterscheidbar, siehe ``KaufEintrag/produktName``.
    private var artikelName: String {
        let name = eintrag.produktName ?? eintrag.artikel?.name ?? eintrag.artikelNameSnapshot
        return name.isEmpty ? "Unbekannter Artikel" : name
    }

    private var geschaeftName: String {
        let name = eintrag.geschaeft?.name ?? eintrag.geschaeftNameSnapshot
        return name.isEmpty ? "Unbekanntes Geschäft" : name
    }
}
