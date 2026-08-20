import SwiftUI

// MARK: - Gemeinsames Vorschau-Modell

/// Vereinfachtes Positions-Modell für die drei Preview-Varianten.
/// In der echten Implementierung käme BearbeitbarePosition aus BelegScanView.swift.
struct BelegPositionEntwurf: Identifiable {
    let id = UUID()
    /// Unveränderlicher Roh-Bon-Text (z.B. "SEBAMED UR 5%")
    let erkannterName: String
    /// Generischer Artikel-Name, editierbar
    var artikelName: String
    /// Menschenlesbarer Markenname, editierbar, optional
    var produktKlarname: String
    var preisText: String
    var istZugeordnet: Bool

    static let beispiele: [BelegPositionEntwurf] = [
        .init(erkannterName: "SEBAMED UR 5%",    artikelName: "Shampoo",
              produktKlarname: "Sebamed Urea 5%", preisText: "3,49", istZugeordnet: true),
        .init(erkannterName: "VOLLMILCH 3,5%",   artikelName: "Milch",
              produktKlarname: "",                preisText: "1,09", istZugeordnet: true),
        .init(erkannterName: "XTRA WASCHMITTEL", artikelName: "XTRA WASCHMITTEL",
              produktKlarname: "",                preisText: "4,99", istZugeordnet: false),
        .init(erkannterName: "COLG TOTAL PLUS",  artikelName: "Zahnpasta",
              produktKlarname: "Colgate Total Plus", preisText: "2,79", istZugeordnet: true),
    ]
}

// =============================================================================
// MARK: - Variante A: Karten-Zeile
//
// Klare Hierarchie: Artikel als Headline oben, Bon-Text als kleine Fußnote unten.
// Drop-in-Ersatz für PositionsZeile — kein Umbau der ErgebnisListe nötig.
// =============================================================================

struct BelegPositionKartenZeile: View {
    @Binding var position: BelegPositionEntwurf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Artikel", text: $position.artikelName)
                    .font(.headline)
                Spacer()
                TextField("0,00", text: $position.preisText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .font(.subheadline.monospacedDigit())
                Text(" \u{20AC}")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            TextField("Produktname (optional)", text: $position.produktKlarname)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: position.istZugeordnet ? "checkmark.circle.fill" : "sparkles")
                    .font(.caption2)
                    .foregroundStyle(position.istZugeordnet ? Color.green : Color.orange)
                Text(position.erkannterName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview("Variante A \u{2014} Karten-Zeile") {
    @Previewable @State var positionen = BelegPositionEntwurf.beispiele
    NavigationStack {
        List($positionen) { $position in
            BelegPositionKartenZeile(position: $position)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Erkannte Positionen")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Preise \u{00FC}bernehmen") {}
                .buttonStyle(.glass)
                .padding()
        }
    }
}

// =============================================================================
// MARK: - Variante B: Fokus-Assistent
//
// Eine Position nach der anderen — ohne TabView (Absturzgefahr durch
// Subscript-Binding + selection-Binding). Stattdessen direktes if-Rendering
// mit .animation für den Seitenwechsel-Effekt.
// =============================================================================

private struct FokusSeite: View {
    @Binding var position: BelegPositionEntwurf

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bon-Text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(position.erkannterName)
                        .font(.title2.weight(.semibold))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Artikel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField("z.B. Shampoo", text: $position.artikelName)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Text("Generischer Name \u{2014} z.B. \u{201E}Shampoo\u{201D}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Produktname")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField("optional", text: $position.produktKlarname)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Text("Markenname \u{2014} z.B. \u{201E}Sebamed Urea 5%\u{201D}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0,00", text: $position.preisText)
                        .keyboardType(.decimalPad)
                        .font(.title3.monospacedDigit())
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .frame(width: 110)
                    Text("\u{20AC}")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

struct BelegPositionFokusAssistent: View {
    @Binding var positionen: [BelegPositionEntwurf]
    var uebernehmen: () -> Void = {}

    @State private var seite = 0

    private var istLetzte: Bool { seite >= positionen.count - 1 }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                ProgressView(value: Double(seite + 1), total: Double(positionen.count))
                    .padding(.horizontal)
                Text("\(seite + 1) von \(positionen.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Kein TabView+selection — direkte Anzeige mit id()-Trick für Animation.
            if seite < positionen.count {
                FokusSeite(position: $positionen[seite])
                    .id(positionen[seite].id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            HStack(spacing: 12) {
                if seite > 0 {
                    Button("Zur\u{00FC}ck") { withAnimation(.easeInOut) { seite -= 1 } }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button(istLetzte ? "Preise \u{00FC}bernehmen" : "Weiter") {
                    if istLetzte { uebernehmen() } else { withAnimation(.easeInOut) { seite += 1 } }
                }
                .buttonStyle(.glass)
            }
            .padding()
        }
    }
}

#Preview("Variante B \u{2014} Fokus-Assistent") {
    @Previewable @State var positionen = BelegPositionEntwurf.beispiele
    NavigationStack {
        BelegPositionFokusAssistent(positionen: $positionen)
            .navigationTitle("Beleg pr\u{00FC}fen")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// =============================================================================
// MARK: - Variante C: Kompakt-Liste + Bearbeitungs-Sheet
//
// Minimale Listenzeilen (Status, Name, Preis) — Bearbeitung im Sheet.
// Ideal, wenn Nutzer dem KI-Ergebnis meist vertraut und selten eingreift.
// =============================================================================

private struct PositionsBearbeitenSheet: View {
    @Binding var position: BelegPositionEntwurf
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Bon-Text") {
                    Text(position.erkannterName)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Artikel") {
                        TextField("z.B. Shampoo", text: $position.artikelName)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Produktname") {
                        TextField("optional", text: $position.produktKlarname)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("\"Artikel\" ist der generische Name (z.B. Shampoo). \"Produktname\" der Markenname (z.B. Sebamed Urea 5%) \u{2014} optional.")
                }

                Section {
                    LabeledContent("\u{20AC}") {
                        TextField("0,00", text: $position.preisText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle(position.artikelName.isEmpty ? "Position" : position.artikelName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

private struct KompaktZeile: View {
    @Binding var position: BelegPositionEntwurf
    @State private var zeigeSheet = false

    var body: some View {
        Button { zeigeSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: position.istZugeordnet ? "checkmark.circle.fill" : "sparkles")
                    .foregroundStyle(position.istZugeordnet ? Color.green : Color.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.artikelName.isEmpty ? position.erkannterName : position.artikelName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !position.produktKlarname.isEmpty {
                        Text(position.produktKlarname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(position.preisText) \u{20AC}")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $zeigeSheet) {
            PositionsBearbeitenSheet(position: $position)
                .presentationDetents([.medium, .large])
        }
    }
}

struct BelegPositionKompaktListe: View {
    @Binding var positionen: [BelegPositionEntwurf]
    var uebernehmen: () -> Void = {}

    var body: some View {
        List {
            Section("Erkannte Positionen") {
                ForEach($positionen) { $position in
                    KompaktZeile(position: $position)
                }
                .onDelete { positionen.remove(atOffsets: $0) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Preise \u{00FC}bernehmen", action: uebernehmen)
                .buttonStyle(.glass)
                .padding()
        }
    }
}

#Preview("Variante C \u{2014} Kompakt + Sheet") {
    @Previewable @State var positionen = BelegPositionEntwurf.beispiele
    NavigationStack {
        BelegPositionKompaktListe(positionen: $positionen)
            .navigationTitle("Beleg pr\u{00FC}fen")
            .navigationBarTitleDisplayMode(.inline)
    }
}
