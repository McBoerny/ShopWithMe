import SwiftUI

/// Eine Zeile der Preishistorie: Datum, Preis und wahlweise Artikel- oder
/// Geschäftsname (je nachdem, aus welcher Detailansicht heraus sie angezeigt wird).
///
/// Über eine Wischgeste lässt sich ``PreispunktZuordnenSheet`` öffnen, um dieser
/// Position einen Alias-Namen zu geben und/oder sie einem übergreifenden ``Artikel``
/// zuzuordnen (inkl. Neuanlage) — siehe ``Preispunkt/anzeigeName`` und
/// `docs/BELEGSCAN.md`.
struct PreisHistorieZeile: View {
    let eintrag: Preispunkt
    /// `true` in der Geschäfts-Detailansicht (zeigt den Artikelnamen), `false` in der
    /// Artikel-Detailansicht (zeigt den Geschäftsnamen).
    let zeigeArtikel: Bool
    /// Optionale Trailing-Wisch-Löschaktion, direkt hier statt über ein
    /// zusätzliches `.onDelete` am umgebenden `ForEach` angeboten (GitHub #33):
    /// zwei unabhängige Swipe-Konfigurationen auf derselben Zeile — hier das
    /// eigene `.swipeActions(edge: .leading)` unten, extern ein zusätzliches
    /// `.onDelete` — brachten UIKits Swipe-Gesten-Erkennung durcheinander und
    /// ließen die App beim Öffnen hängen (blockierender `_UISwipeActionPan...`
    /// laut Debug-Protokoll). `nil` (Standard) zeigt keine Löschaktion.
    var loeschen: (() -> Void)? = nil

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
            // `.euro` allein reicht `Text(_:format:)` wegen dessen mehrerer
            // `FormatStyle`-Overloads (anders als `Decimal.formatted(_:)`)
            // nicht als Kontext — deshalb hier explizit qualifiziert.
            Text(eintrag.preis, format: Decimal.FormatStyle.euro)
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
        .swipeActions(edge: .trailing) {
            if let loeschen {
                Button(role: .destructive, action: loeschen) {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $zeigeZuordnenSheet) {
            PreispunktZuordnenSheet(eintrag: eintrag)
        }
    }

    private var geschaeftName: String {
        let name = eintrag.geschaeftNameSicher
        return name.isEmpty ? "Unbekanntes Geschäft" : name
    }
}
