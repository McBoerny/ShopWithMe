import SwiftUI
import SwiftData

/// Zeigt alle Artikel als Liste und erlaubt Anlegen, Bearbeiten und Löschen.
struct ArtikelListView: View {
    @Query(sort: \Artikel.name) private var artikel: [Artikel]
    @Environment(\.modelContext) private var modelContext

    @State private var neuerArtikelEntwurf: Artikel?
    @State private var bearbeiteterArtikel: Artikel?

    var body: some View {
        NavigationStack {
            List {
                ForEach(artikel) { eintrag in
                    Button {
                        bearbeiteterArtikel = eintrag
                    } label: {
                        ArtikelZeile(artikel: eintrag)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: artikelLoeschen)
            }
            .overlay {
                if artikel.isEmpty {
                    ContentUnavailableView(
                        "Keine Artikel",
                        systemImage: "carrot.fill",
                        description: Text("Lege deinen ersten Artikel mit dem Plus-Symbol an.")
                    )
                }
            }
            .navigationTitle("Artikel")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        neuerArtikelEntwurf = Artikel(
                            name: "",
                            symbolName: SymbolPalette.alle[0],
                            farbeHex: Color.artikelPalette[0]
                        )
                    } label: {
                        Label("Artikel hinzufügen", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $neuerArtikelEntwurf) { entwurf in
                ArtikelEditView(artikel: entwurf, istNeu: true)
            }
            .sheet(item: $bearbeiteterArtikel) { eintrag in
                ArtikelEditView(artikel: eintrag, istNeu: false)
            }
        }
    }

    private func artikelLoeschen(at offsets: IndexSet) {
        let zuLoeschende = offsets.map { artikel[$0] }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for eintrag in zuLoeschende {
                    modelContext.delete(eintrag)
                }
            }
        }
    }
}

/// Eine Zeile in der Artikel-Liste.
private struct ArtikelZeile: View {
    let artikel: Artikel

    var body: some View {
        HStack(spacing: 12) {
            GlassSymbolBadge(symbolName: artikel.symbolName, farbe: Color(hex: artikel.farbeHex))
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name.isEmpty ? "Unbenannt" : artikel.name)
                    .foregroundStyle(.primary)
                if let kategorie = artikel.kategorie {
                    Text(kategorie.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if artikel.istAufEinkaufsliste {
                Image(systemName: "checklist")
                    .foregroundStyle(.tint)
            }
        }
    }
}

#Preview {
    ArtikelListView()
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self], inMemory: true)
}
