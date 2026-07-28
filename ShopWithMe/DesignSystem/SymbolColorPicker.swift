import SwiftUI
import UIKit

/// Kuratierte SF-Symbole für die Symbolauswahl bei Artikeln und Kategorien. Der
/// Anwender kann zusätzlich einen eigenen SF-Symbol-Namen eingeben, falls das
/// gewünschte Symbol nicht in der kuratierten Liste enthalten ist.
enum SymbolPalette {
    static let alle: [String] = [
        "carrot.fill", "leaf.fill", "birthday.cake.fill", "basket.fill",
        "refrigerator.fill", "fish.fill", "snowflake", "waterbottle.fill",
        "cup.and.saucer.fill", "wineglass.fill", "takeoutbag.and.cup.and.straw.fill",
        "fork.knife", "sparkles", "bubbles.and.sparkles.fill", "washer.fill",
        "pills.fill", "cross.case.fill", "bandage.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "paintbrush.fill", "bolt.fill",
        "lightbulb.fill", "battery.100", "tshirt.fill", "bag.fill",
        "pawprint.fill", "book.fill", "pencil.and.ruler.fill", "printer.fill",
        "gift.fill", "shippingbox.fill", "cart.fill", "house.fill", "drop.fill",
        "flame.fill", "star.fill", "heart.fill", "faucet.fill", "toilet.fill",
        "shower.fill", "bathtub.fill", "scissors",
    ]
}

/// Zeigt das aktuell gewählte Symbol/Farbe als Zeile an; Antippen öffnet die
/// Auswahl (``SymbolAuswahlSheet``).
struct SymbolFarbAuswahlZeile: View {
    @Binding var symbolName: String
    @Binding var farbeHex: String
    @State private var zeigeAuswahl = false

    var body: some View {
        Button {
            zeigeAuswahl = true
        } label: {
            HStack {
                GlassSymbolBadge(symbolName: symbolName, farbe: Color(hex: farbeHex))
                Text("Symbol & Farbe")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            // Ohne contentShape reagiert nur der sichtbare Inhalt auf Taps, nicht
            // der leere Spacer-Bereich dazwischen (GitHub #38).
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $zeigeAuswahl) {
            SymbolAuswahlSheet(symbolName: $symbolName, farbeHex: $farbeHex)
        }
    }
}

/// Sheet mit Symbol-Raster, Farbpalette und Freitext-Eingabe für ein eigenes
/// SF-Symbol.
private struct SymbolAuswahlSheet: View {
    @Binding var symbolName: String
    @Binding var farbeHex: String
    @Environment(\.dismiss) private var dismiss
    @State private var eigenesSymbol = ""

    private let spalten = Array(repeating: GridItem(.flexible()), count: 5)

    var body: some View {
        NavigationStack {
            Form {
                Section("Farbe") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                        ForEach(Color.artikelPalette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(height: 32)
                                .overlay {
                                    if hex == farbeHex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { farbeHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Symbol") {
                    LazyVGrid(columns: spalten) {
                        ForEach(SymbolPalette.alle, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .foregroundStyle(symbol == symbolName ? Color(hex: farbeHex) : .primary)
                                .glassEffect(
                                    symbol == symbolName ? .regular.tint(Color(hex: farbeHex).opacity(0.2)) : .regular,
                                    in: Circle()
                                )
                                .onTapGesture { symbolName = symbol }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Eigenes SF-Symbol") {
                    HStack {
                        TextField("z.B. \"cup.and.saucer\"", text: $eigenesSymbol)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Übernehmen") {
                            symbolName = eigenesSymbol
                        }
                        .disabled(eigenesSymbol.isEmpty || UIImage(systemName: eigenesSymbol) == nil)
                    }
                    if !eigenesSymbol.isEmpty && UIImage(systemName: eigenesSymbol) == nil {
                        Label("Unbekannter SF-Symbol-Name", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Symbol & Farbe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
