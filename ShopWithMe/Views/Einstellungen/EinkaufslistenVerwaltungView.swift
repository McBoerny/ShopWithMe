import SwiftUI
import SwiftData

/// Verwaltung aller ``Einkaufsliste``n: Umbenennen sowie Anlegen/Löschen —
/// aufrufbar aus ``SettingsView``. Die schnelle Anlage einer neuen Liste direkt
/// beim Einkaufen (``EinkaufenView``) bleibt davon unabhängig möglich.
///
/// Der Name lässt sich direkt in der Zeile per `TextField` bearbeiten — kein
/// separater Bearbeiten-Subview nötig (GitHub #27). Löschen funktioniert bereits
/// per Wischgeste, ein zusätzlicher `EditButton()` wäre daher ohne Mehrwert.
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
                    EinkaufslisteZeile(liste: liste)
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
            let liste = listen[index]
            // Tombstone verhindert, dass ein Peer, der die Liste noch in
            // seinem eigenen Snapshot führt, sie beim nächsten Sync
            // unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
            SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.einkaufsliste, id: liste.id, context: modelContext)
            modelContext.delete(liste)
        }
    }
}

/// Eine Zeile in der Einkaufslisten-Verwaltung: der Name ist direkt per
/// `TextField` editierbar, ganz ohne eigenen Bearbeiten-Bildschirm (GitHub #27).
private struct EinkaufslisteZeile: View {
    @Bindable var liste: Einkaufsliste

    var body: some View {
        Label {
            TextField("Name", text: $liste.name)
        } icon: {
            Image(systemName: "checklist")
        }
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
    .modelContainer(for: [Einkaufsliste.self, EinkaufslistenEintrag.self, Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self], inMemory: true)
}
