import SwiftUI
import SwiftData

/// Zeigt alle Geschäfte als Liste und erlaubt Anlegen, Bearbeiten und Löschen.
struct GeschaeftListView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Environment(\.modelContext) private var modelContext

    @State private var neuesGeschaeftEntwurf: Geschaeft?

    var body: some View {
        NavigationStack {
            List {
                ForEach(geschaefte) { geschaeft in
                    NavigationLink(value: geschaeft) {
                        GeschaeftZeile(geschaeft: geschaeft)
                    }
                }
                .onDelete(perform: geschaeftLoeschen)
            }
            .overlay {
                if geschaefte.isEmpty {
                    ContentUnavailableView(
                        "Keine Geschäfte",
                        systemImage: "cart.fill",
                        description: Text("Lege dein erstes Geschäft mit dem Plus-Symbol an.")
                    )
                }
            }
            .navigationDestination(for: Geschaeft.self) { geschaeft in
                GeschaeftDetailView(geschaeft: geschaeft)
            }
            .navigationTitle("Geschäfte")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        neuesGeschaeftEntwurf = Geschaeft(name: "", typ: .lebensmittel)
                    } label: {
                        Label("Geschäft hinzufügen", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $neuesGeschaeftEntwurf) { entwurf in
                GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true)
            }
        }
    }

    private func geschaeftLoeschen(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(geschaefte[index])
        }
    }
}

/// Eine Zeile in der Geschäfte-Liste.
private struct GeschaeftZeile: View {
    let geschaeft: Geschaeft

    var body: some View {
        HStack(spacing: 12) {
            GlassSymbolBadge(symbolName: geschaeft.typ.symbolName, farbe: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(geschaeft.name.isEmpty ? "Unbenannt" : geschaeft.name)
                Text("\(geschaeft.typ.anzeigename) · \(geschaeft.regale.count) Regal(e)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    GeschaeftListView()
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
