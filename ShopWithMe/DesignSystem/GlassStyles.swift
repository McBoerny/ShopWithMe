import SwiftUI

/// Wiederverwendbare Liquid-Glass-Bausteine, damit das neue Material (`.glassEffect()`,
/// `GlassEffectContainer`) app-weit konsistent verwendet wird, statt es an jeder
/// View-Stelle einzeln zu konfigurieren.
extension View {
    /// Legt diese View als abgerundete Liquid-Glass-Karte an.
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .padding()
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Rundes Symbol-Badge in Liquid Glass mit einer Akzentfarbe — die Standarddarstellung
/// eines ``Artikel``-Symbols in Listen und Details.
struct GlassSymbolBadge: View {
    let symbolName: String
    let farbe: Color
    var groesse: CGFloat = 44

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: groesse * 0.45, weight: .semibold))
            .foregroundStyle(farbe)
            .frame(width: groesse, height: groesse)
            .glassEffect(.regular.tint(farbe.opacity(0.18)), in: Circle())
    }
}
