import SwiftUI
import SwiftData

/// Sheet zum Anlegen eines benutzerdefinierten ``GeschaeftTyp`` (GitHub #25) —
/// analog ``NeueKategorieSheet`` für ``ArtikelKategorie``. Aufrufbar sowohl aus der
/// zentralen Typ-Verwaltung (``GeschaeftsTypenVerwaltungView``) als auch direkt aus
/// der Typ-Auswahl beim Anlegen/Bearbeiten eines Geschäfts
/// (``GeschaeftStammdatenEditView``), falls der gewünschte Typ dort noch fehlt.
struct NeuerGeschaeftsTypSheet: View {
    let naechsterSortIndex: Int
    let onErstellt: (GeschaeftTyp) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbolName = "shippingbox.fill"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: symbolName, farbe: .accentColor, groesse: 56)
                        TextField("Name", text: $name)
                            .font(.title3)
                    }
                    TextField("SF-Symbol", text: $symbolName)
                }
            }
            .navigationTitle("Neuer Geschäftstyp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let getrimmtesSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let typ = GeschaeftTyp(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            symbolName: getrimmtesSymbol.isEmpty ? "shippingbox.fill" : getrimmtesSymbol,
                            sortIndex: naechsterSortIndex
                        )
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(typ)
                            }
                            onErstellt(typ)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
