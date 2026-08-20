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
        .init(erkannterName: "SEBAMED UR 5%",     artikelName: "Shampoo",
              produktKlarname: "Sebamed Urea 5%",  preisText: "3,49", istZugeordnet: true),
        .init(erkannterName: "VOLLMILCH 3,5%",    artikelName: "Milch",
              produktKlarname: "",                 preisText: "1,09", istZugeordnet: true),
        .init(erkannterName: "XTRA WASCHMITTEL",  artikelName: "XTRA WASCHMITTEL",
              produktKlarname: "",                 preisText: "4,99", istZugeordnet: false),
        .init(erkannterName: "COLG TOTAL PLUS",   artikelName: "Zahnpasta",
              produktKlarname: "Colgate Total Plus", preisText: "2,79", istZugeordnet: true),
    ]
}

// =============================================================================
// MARK: - Variante A: Karten-Zeile
//
// Ansatz: Artikel-Name steht oben als Headline, Bon-Text erscheint am Ende als
// kleine, sekundäre Fußnote. Schnellste Integration — tauscht nur PositionsZeile
// gegen diese View aus; kein Umbau der umgebenden ErgebnisListe nötig.
// =============================================================================

/// Variante A: Jede Belegposition als lesbare Karte mit klarer Hierarchie.
///
/// Unterschied zum aktuellen PositionsZeile:
/// - Artikel-Name hat mehr visuelles Gewicht (Headline statt body)
/// - Produktname ist immer sichtbar, nicht hinter einer Bedingung versteckt
/// - Bon-Text steht unten als Hinweis, nicht als primäre Beschriftung
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
// Ansatz: Eine Position nach der anderen, Wizard-artig mit TabView.
// Gut für sorgfältige Prüfung oder wenn Nutzer mit dem Bon-Scan wenig
// vertraut ist — jeder Schritt ist fokussiert und nicht überwältigend.
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
                .glassCard()

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

                Spacer()
            }
            .padding()
        }
    }
}

/// Variante B: Wizard-Navigation durch alle Positionen, eine nach der anderen.
///
/// Jede Position hat eine eigene Seite mit groß lesbarem Bon-Text oben und
/// klaren Eingabefeldern darunter. Zurück/Weiter-Navigation mit Fortschrittsbalken.
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

            TabView(selection: $seite) {
                ForEach(positionen.indices, id: \.self) { i in
                    FokusSeite(position: $positionen[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 12) {
                if seite > 0 {
                    Button("Zur\u{00FC}ck") { withAnimation { seite -= 1 } }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button(istLetzte ? "Preise \u{00FC}bernehmen" : "Weiter") {
                    if istLetzte { uebernehmen() } else { withAnimation { seite += 1 } }
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
// Ansatz: Die Liste zeigt nur das Nötigste (Status, Name, Preis). Wer eine
// Position bearbeiten will, tippt sie an — dann öffnet sich ein fokussiertes
// Sheet. Für Nutzer, die dem KI-Ergebnis meist vertrauen und nur gelegentlich
// korrigieren.
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

/// Variante C: Minimale Listenzeilen — Bearbeitung ausschließlich im Sheet.
///
/// Jede Zeile zeigt nur Status-Icon, Artikel-Name und Preis. Antippen öffnet
/// ein fokussiertes Bearbeitungs-Sheet mit allen Feldern. Die Liste bleibt dadurch
/// auch bei vielen Positionen \u{00FC}bersichtlich.
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
