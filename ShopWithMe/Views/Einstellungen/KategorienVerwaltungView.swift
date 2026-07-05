import SwiftUI
import SwiftData

/// Globale Verwaltung aller ``ArtikelKategorie``n: Umbenennen, Symbol/Farbe ändern,
/// Reihenfolge per Drag-Handle anpassen sowie Anlegen/Löschen — aufrufbar aus
/// ``SettingsView``.
///
/// Anders als ``KategorieHinzufuegenSheet`` (ordnet eine bestehende Kategorie einem
/// Geschäft zu) bearbeitet diese Ansicht die Kategorien selbst, unabhängig von
/// einem Geschäft.
struct KategorienVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            Section {
                ForEach(kategorien) { kategorie in
                    NavigationLink {
                        KategorieBearbeitenView(kategorie: kategorie)
                    } label: {
                        Label(kategorie.name, systemImage: kategorie.standardSymbol)
                            .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
                    }
                }
                .onDelete(perform: kategorieLoeschen)
                .onMove(perform: kategorieVerschieben)
            } footer: {
                Text("Zum Ändern von Name, Symbol oder Farbe antippen. Zum Löschen nach links wischen — Artikel dieser Kategorie landen danach automatisch in „Sonstiges“.")
            }
        }
        .navigationTitle("Kategorien")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeueKategorie = true
                } label: {
                    Label("Kategorie hinzufügen", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $zeigeNeueKategorie) {
            NeueKategorieSheet(naechsterSortIndex: (kategorien.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }

    private func kategorieLoeschen(at offsets: IndexSet) {
        for index in offsets {
            let kategorie = kategorien[index]
            guard kategorie.name != ArtikelKategorie.sonstigesName else { continue }
            modelContext.delete(kategorie)
        }
    }

    private func kategorieVerschieben(from source: IndexSet, to destination: Int) {
        var sortiert = kategorien
        sortiert.move(fromOffsets: source, toOffset: destination)
        for (index, kategorie) in sortiert.enumerated() {
            kategorie.sortIndex = index
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe einer einzelnen ``ArtikelKategorie``.
private struct KategorieBearbeitenView: View {
    @Bindable var kategorie: ArtikelKategorie

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $kategorie.name)
                    .font(.title3)
                SymbolFarbAuswahlZeile(symbolName: $kategorie.standardSymbol, farbeHex: $kategorie.standardFarbeHex)
            } footer: {
                if kategorie.name == ArtikelKategorie.sonstigesName {
                    Text("„Sonstiges“ ist die Auffangkategorie für Artikel ohne eigene Kategorie und kann nicht gelöscht werden.")
                }
            }
        }
        .navigationTitle(kategorie.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        KategorienVerwaltungView()
    }
    .modelContainer(for: [ArtikelKategorie.self, Artikel.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
