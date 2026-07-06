import SwiftUI
import SwiftData

/// Zeigt alle Geschäfte als Liste und erlaubt Anlegen, Bearbeiten und Löschen —
/// sowohl als Tab-Wurzel (``RootView``) als auch, per `NavigationLink`, aus der
/// Geschäftsverwaltung in ``SettingsView``. Erwartet einen umgebenden
/// `NavigationStack` beim Aufrufer statt selbst einen anzulegen, damit beide
/// Einbindungen ohne verschachtelte `NavigationStack`s funktionieren.
struct GeschaeftListView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Environment(\.modelContext) private var modelContext

    @State private var neuesGeschaeftEntwurf: Geschaeft?

    var body: some View {
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

    private func geschaeftLoeschen(at offsets: IndexSet) {
        let zuLoeschende = offsets.map { geschaefte[$0] }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for eintrag in zuLoeschende {
                    modelContext.delete(eintrag)
                }
            }
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
    NavigationStack {
        GeschaeftListView()
    }
    .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
