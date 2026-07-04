import SwiftUI
import SwiftData

/// Bearbeiten eines ``Regal``s: Name und Zuordnung von ``ArtikelKategorie``n.
///
/// Die hier gewählten Kategorien bestimmen zugleich, welche Kategorien beim
/// Einkaufen in diesem Geschäft überhaupt angezeigt werden (siehe
/// ``Geschaeft/verfuegbareKategorien``).
///
/// Zur Auswahl stehen nur Kategorien, die nicht bereits einem anderen Regal
/// desselben Geschäfts zugeordnet sind — jede Kategorie soll innerhalb eines
/// Geschäfts genau einem Regal angehören. Existiert die gewünschte Kategorie
/// noch nicht, kann sie direkt hier neu angelegt werden.
struct RegalDetailView: View {
    @Bindable var regal: Regal
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Regalname", text: $regal.name)
            }

            Section {
                ForEach(regal.auswaehlbareKategorien(aus: alleKategorien)) { kategorie in
                    Button {
                        kategorieUmschalten(kategorie)
                    } label: {
                        HStack {
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            if regal.kategorien.contains(kategorie) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }

                Button {
                    zeigeNeueKategorie = true
                } label: {
                    Label("Neue Kategorie anlegen", systemImage: "plus")
                }
            } header: {
                Text("Kategorien in diesem Regal")
            } footer: {
                Text("Nur Kategorien, die einem Regal zugeordnet sind, werden beim Einkaufen in diesem Geschäft angezeigt. Bereits einem anderen Regal dieses Geschäfts zugeordnete Kategorien werden hier nicht angeboten.")
            }
        }
        .navigationTitle(regal.name.isEmpty ? "Regal" : regal.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeNeueKategorie) {
            NeueKategorieSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                regal.kategorien.append(kategorie)
            }
        }
    }

    private func kategorieUmschalten(_ kategorie: ArtikelKategorie) {
        if let index = regal.kategorien.firstIndex(of: kategorie) {
            regal.kategorien.remove(at: index)
        } else {
            regal.kategorien.append(kategorie)
        }
    }
}

/// Sheet zum Anlegen einer neuen ``ArtikelKategorie`` direkt aus der
/// Regal-Bearbeitung heraus. Die neue Kategorie wird beim Sichern in den
/// Model-Context eingefügt und über ``onErstellt`` an den Aufrufer gemeldet,
/// der sie üblicherweise sofort dem aktuellen Regal zuordnet.
private struct NeueKategorieSheet: View {
    let naechsterSortIndex: Int
    let onErstellt: (ArtikelKategorie) -> Void

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
                    }
                    SymbolFarbAuswahlZeile(symbolName: $symbolName, farbeHex: $farbeHex)
                }
            }
            .navigationTitle("Neue Kategorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let kategorie = ArtikelKategorie(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            standardSymbol: symbolName,
                            standardFarbeHex: farbeHex,
                            sortIndex: naechsterSortIndex
                        )
                        modelContext.insert(kategorie)
                        onErstellt(kategorie)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RegalDetailView(regal: Regal(name: "Kühlregal"))
    }
    .modelContainer(for: [Regal.self, ArtikelKategorie.self], inMemory: true)
}
