import SwiftUI

/// Inline-Hinweis bei einer Tages-Kollision zwischen einem soeben gescannten Preis
/// und einem bereits am selben Kalendertag erfassten ``Preispunkt`` (GitHub
/// #76-Folgearbeit) — gemeinsam genutzt von `BelegScanView`/`PreisschildScanView`.
/// Vorbelegung „wird ersetzt" (``behalteBestehenden`` startet `false`), der Anwender
/// kann per Tippen stattdessen den bestehenden Preis behalten.
struct TagesKollisionZeile: View {
    let bestehenderPreis: Decimal
    @Binding var behalteBestehenden: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(
                "Heute bereits \(bestehenderPreis.formatted(.currency(code: "EUR"))) erfasst",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Spacer()
            Button(behalteBestehenden ? "Bisherigen behalten" : "Wird ersetzt") {
                behalteBestehenden.toggle()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .tint(behalteBestehenden ? .secondary : .orange)
        }
    }
}

#Preview {
    @Previewable @State var behalteBestehenden = false
    return List {
        TagesKollisionZeile(bestehenderPreis: 1.99, behalteBestehenden: $behalteBestehenden)
    }
}
