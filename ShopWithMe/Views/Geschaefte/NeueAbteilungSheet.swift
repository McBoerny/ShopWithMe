import SwiftUI
import SwiftData

/// Sheet zum Anlegen einer neuen ``Abteilung``, z.B. aus der
/// Abteilungen-Verwaltung eines Geschäfts heraus. Die neue Abteilung wird beim
/// Sichern in den Model-Context eingefügt und über ``onErstellt`` an den
/// Aufrufer gemeldet.
struct NeueAbteilungSheet: View {
    let naechsterSortIndex: Int
    let onErstellt: (Abteilung) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbolName = "shippingbox.fill"
    @State private var farbeHex = Color.artikelPalette[0]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: symbolName, farbe: Color(hex: farbeHex), groesse: 56)
                        TextField("Name", text: $name)
                            .font(.title3)
                            .accessibilityIdentifier(A11yID.NeueAbteilungSheet.nameField)
                    }
                    SymbolFarbAuswahlZeile(symbolName: $symbolName, farbeHex: $farbeHex)
                }
            }
            .navigationTitle("Neue Abteilung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let abteilung = Abteilung(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            standardSymbol: symbolName,
                            standardFarbeHex: farbeHex,
                            sortIndex: naechsterSortIndex
                        )
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(abteilung)
                            }
                            onErstellt(abteilung)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(A11yID.NeueAbteilungSheet.sichernButton)
                }
            }
        }
    }
}
