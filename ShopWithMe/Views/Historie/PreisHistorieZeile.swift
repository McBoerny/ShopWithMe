import SwiftUI

/// Eine Zeile der Preishistorie: Datum, Preis und wahlweise Artikel- oder
/// Geschäftsname (je nachdem, aus welcher Detailansicht heraus sie angezeigt wird).
///
/// Über eine Wischgeste lässt sich ``KaufEintragZuordnenSheet`` öffnen, um dieser
/// Position einen Alias-Namen zu geben und/oder sie einem übergreifenden ``Artikel``
/// zuzuordnen (inkl. Neuanlage) — siehe ``KaufEintrag/anzeigeName`` und
/// `docs/BELEGSCAN.md`.
struct PreisHistorieZeile: View {
    let eintrag: KaufEintrag
    /// `true` in der Geschäfts-Detailansicht (zeigt den Artikelnamen), `false` in der
    /// Artikel-Detailansicht (zeigt den Geschäftsnamen).
    let zeigeArtikel: Bool

    @State private var zeigeZuordnenSheet = false

    private static let datumsFormat: Date.FormatStyle = .dateTime.day().month().year()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(zeigeArtikel ? eintrag.anzeigeName : geschaeftName)
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
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            Button {
                zeigeZuordnenSheet = true
            } label: {
                Label("Zuordnen", systemImage: "tag")
            }
            .tint(.blue)
        }
        .sheet(isPresented: $zeigeZuordnenSheet) {
            KaufEintragZuordnenSheet(eintrag: eintrag)
        }
    }

    private var geschaeftName: String {
        let name = eintrag.geschaeft?.name ?? eintrag.geschaeftNameSnapshot
        return name.isEmpty ? "Unbekanntes Geschäft" : name
    }
}
