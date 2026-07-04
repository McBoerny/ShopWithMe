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

#Preview {
    NavigationStack {
        RegalDetailView(regal: Regal(name: "Kühlregal"))
    }
    .modelContainer(for: [Regal.self, ArtikelKategorie.self], inMemory: true)
}
