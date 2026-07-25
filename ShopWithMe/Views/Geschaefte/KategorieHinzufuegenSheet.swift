import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen einer ``ArtikelKategorie`` zu einem ``Geschaeft``, aufrufbar
/// aus dem „Kategorien“-Abschnitt von ``GeschaeftDetailView``.
///
/// Kategorien sind wichtiger als Regale: Eine Kategorie wird beim Antippen direkt
/// diesem Geschäft zugeordnet (``Geschaeft/kategorien``) und damit sofort verfügbar —
/// ganz ohne Regal. Besitzt das Geschäft bereits Regale, kann zusätzlich optional
/// eines gewählt werden, um die Kategorie zugleich für die Einkaufs-Reihenfolge
/// einzusortieren; das bleibt aber jederzeit nachholbar und ist nie Voraussetzung.
struct KategorieHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var ausgewaehltesRegal: Regal?
    @State private var zeigeNeueKategorie = false

    private var regaleSortiert: [Regal] {
        geschaeft.regale.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Kategorien, die in diesem Geschäft noch nicht verfügbar sind.
    private var nichtVerfuegbareKategorien: [ArtikelKategorie] {
        let verfuegbareIDs = Set(geschaeft.verfuegbareKategorien.map(\.persistentModelID))
        return alleKategorien.filter { !verfuegbareIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        SessionLeaseGate { navigationInhalt }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                if !regaleSortiert.isEmpty {
                    Section {
                        Picker("Regal (optional)", selection: $ausgewaehltesRegal) {
                            Text("Kein Regal").tag(Optional<Regal>.none)
                            ForEach(regaleSortiert) { regal in
                                Text(regal.name.isEmpty ? "Unbenannt" : regal.name).tag(Optional(regal))
                            }
                        }
                    } footer: {
                        Text("Nur zur Sortierung beim Einkaufen — die Kategorie ist auch ohne Regal sofort verfügbar.")
                    }
                }

                Section {
                    ForEach(nichtVerfuegbareKategorien) { kategorie in
                        Button {
                            kategorieHinzufuegen(kategorie)
                        } label: {
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .foregroundStyle(.primary)
                        }
                    }

                    Button {
                        zeigeNeueKategorie = true
                    } label: {
                        Label("Neue Kategorie anlegen", systemImage: "plus")
                    }
                } header: {
                    Text("Verfügbare Kategorien")
                } footer: {
                    Text("Bereits in diesem Geschäft verfügbare Kategorien werden hier nicht angeboten.")
                }
            }
            .navigationTitle("Kategorie hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $zeigeNeueKategorie) {
                NeueKategorieSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                    kategorieHinzufuegen(kategorie)
                }
            }
        }
    }

    private func kategorieHinzufuegen(_ kategorie: ArtikelKategorie) {
        geschaeft.kategorien.append(kategorie)
        ausgewaehltesRegal?.kategorien.append(kategorie)
    }
}

#Preview {
    KategorieHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typen: [.lebensmittel]))
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
