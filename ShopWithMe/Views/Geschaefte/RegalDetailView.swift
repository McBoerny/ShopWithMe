import SwiftUI
import SwiftData

/// Bearbeiten eines ``Regal``s: Name und Zuordnung von ``ArtikelKategorie``n.
///
/// Die hier gewählten Kategorien bestimmen zugleich, welche Kategorien beim
/// Einkaufen in diesem Geschäft überhaupt angezeigt werden (siehe
/// ``Geschaeft/verfuegbareKategorien``).
struct RegalDetailView: View {
    @Bindable var regal: Regal
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Regalname", text: $regal.name)
            }

            Section {
                ForEach(alleKategorien) { kategorie in
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
            } header: {
                Text("Kategorien in diesem Regal")
            } footer: {
                Text("Nur Kategorien, die einem Regal zugeordnet sind, werden beim Einkaufen in diesem Geschäft angezeigt.")
            }
        }
        .navigationTitle(regal.name.isEmpty ? "Regal" : regal.name)
        .navigationBarTitleDisplayMode(.inline)
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
