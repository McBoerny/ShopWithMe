import SwiftUI

/// Eine Zeile der Preishistorie: Datum, Preis und wahlweise Artikel- oder
/// Geschäftsname (je nachdem, aus welcher Detailansicht heraus sie angezeigt wird).
///
/// In der Artikel-Spalte (``zeigeArtikel``) lässt sich per Kontextmenü/Wischgeste ein
/// alternativer Anzeigename für genau diese Position vergeben — siehe
/// ``KaufEintrag/anzeigeName`` und `docs/BELEGSCAN.md`.
struct PreisHistorieZeile: View {
    let eintrag: KaufEintrag
    /// `true` in der Geschäfts-Detailansicht (zeigt den Artikelnamen), `false` in der
    /// Artikel-Detailansicht (zeigt den Geschäftsnamen).
    let zeigeArtikel: Bool

    @State private var zeigeUmbenennenDialog = false
    @State private var eingabeName = ""

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
            if zeigeArtikel {
                Button {
                    eingabeName = eintrag.alternativerName ?? ""
                    zeigeUmbenennenDialog = true
                } label: {
                    Label("Umbenennen", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .alert("Alternativer Name", isPresented: $zeigeUmbenennenDialog) {
            TextField("Alternativer Name", text: $eingabeName)
            Button("Speichern") {
                let getrimmt = eingabeName.trimmingCharacters(in: .whitespacesAndNewlines)
                eintrag.alternativerName = getrimmt.isEmpty ? nil : getrimmt
            }
            if eintrag.alternativerName != nil {
                Button("Zurücksetzen", role: .destructive) {
                    eintrag.alternativerName = nil
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Wird dieser Name gesetzt, ersetzt er ab sofort überall den erkannten Kassenbon-/Artikelnamen dieser Position.")
        }
    }

    private var geschaeftName: String {
        let name = eintrag.geschaeft?.name ?? eintrag.geschaeftNameSnapshot
        return name.isEmpty ? "Unbekanntes Geschäft" : name
    }
}
