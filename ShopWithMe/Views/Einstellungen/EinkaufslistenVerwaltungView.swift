import SwiftUI
import SwiftData

/// Verwaltung aller ``Einkaufsliste``n: Umbenennen sowie Anlegen/Löschen —
/// aufrufbar aus ``SettingsView``. Die schnelle Anlage einer neuen Liste direkt
/// beim Einkaufen (``EinkaufenView``) bleibt davon unabhängig möglich.
struct EinkaufslistenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Einkaufsliste.erstelltAm) private var listen: [Einkaufsliste]
    @State private var zeigeNeueListe = false
    @State private var zeigeMilkForUsImport = false

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            Section {
                ForEach(listen) { liste in
                    NavigationLink {
                        ListeBearbeitenView(liste: liste)
                    } label: {
                        Label(liste.name, systemImage: "checklist")
                    }
                }
                .onDelete(perform: listeLoeschen)
            } footer: {
                Text("Zum Umbenennen antippen. Zum Löschen nach links wischen — die Artikel darauf verschwinden von dieser Liste, bleiben aber im Artikel-Katalog erhalten.")
            }
        }
        .navigationTitle("Einkaufslisten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeueListe = true
                } label: {
                    Label("Liste hinzufügen", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    zeigeMilkForUsImport = true
                } label: {
                    Label("MilkForUs importieren", systemImage: "square.and.arrow.down.on.square")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $zeigeNeueListe) {
            NeueEinkaufslisteVerwaltungSheet()
        }
        .sheet(isPresented: $zeigeMilkForUsImport) {
            MilkForUsImportView()
        }
    }

    private func listeLoeschen(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(listen[index])
        }
    }
}

/// Bearbeitet den Namen einer einzelnen ``Einkaufsliste``.
private struct ListeBearbeitenView: View {
    @Bindable var liste: Einkaufsliste

    var body: some View {
        Form {
            TextField("Name", text: $liste.name)
                .font(.title3)
        }
        .navigationTitle(liste.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Sheet zum Anlegen einer neuen ``Einkaufsliste`` aus der Verwaltung heraus (siehe
/// `NeueEinkaufslisteSheet` in `EinkaufenView` für das Pendant beim Einkaufen selbst).
private struct NeueEinkaufslisteVerwaltungSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, z.B. \"Wocheneinkauf\"", text: $name)
                    .font(.title3)
            }
            .navigationTitle("Neue Liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let liste = Einkaufsliste(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(liste)
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        EinkaufslistenVerwaltungView()
    }
    .modelContainer(for: [Einkaufsliste.self, EinkaufslistenEintrag.self, Artikel.self, ArtikelKategorie.self], inMemory: true)
}
