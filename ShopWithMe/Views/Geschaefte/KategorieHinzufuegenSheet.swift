import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen einer ``ArtikelKategorie`` zu einem ``Geschaeft``, aufrufbar
/// aus dem „Kategorien“-Abschnitt von ``GeschaeftDetailView``.
///
/// Da die Verfügbarkeit einer Kategorie in einem Geschäft ausschließlich über die
/// Zuordnung zu einem ``Regal`` entsteht (siehe ``Geschaeft/verfuegbareKategorien``),
/// muss beim Hinzufügen ein Ziel-Regal gewählt werden. Existiert noch kein Regal,
/// wird das erklärt statt eine Auswahl anzubieten.
struct KategorieHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var ausgewaehltesRegal: Regal?
    @State private var zeigeNeueKategorie = false

    private var regaleSortiert: [Regal] {
        geschaeft.regale.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Kategorien, die in diesem Geschäft noch keinem Regal zugeordnet sind.
    private var nichtVerfuegbareKategorien: [ArtikelKategorie] {
        let verfuegbareIDs = Set(geschaeft.verfuegbareKategorien.map(\.persistentModelID))
        return alleKategorien.filter { !verfuegbareIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if regaleSortiert.isEmpty {
                    Section {
                        Text("Lege zuerst ein Regal an, um Kategorien zuzuordnen.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Regal") {
                        Picker("Regal", selection: $ausgewaehltesRegal) {
                            ForEach(regaleSortiert) { regal in
                                Text(regal.name.isEmpty ? "Unbenannt" : regal.name).tag(Optional(regal))
                            }
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
                        Text("Kategorien, die bereits einem Regal dieses Geschäfts zugeordnet sind, werden hier nicht angeboten.")
                    }
                }
            }
            .navigationTitle("Kategorie hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear {
                if ausgewaehltesRegal == nil {
                    ausgewaehltesRegal = regaleSortiert.first
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
        guard let regal = ausgewaehltesRegal else { return }
        regal.kategorien.append(kategorie)
    }
}

#Preview {
    KategorieHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typ: .lebensmittel))
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
