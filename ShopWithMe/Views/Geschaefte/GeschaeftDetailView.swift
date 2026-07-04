import SwiftUI
import SwiftData

/// Detailansicht eines ``Geschaeft``s: Stammdaten und Regal-Verwaltung.
///
/// Die Reihenfolge der Regale in dieser Liste ist die manuelle
/// Einkaufs-Reihenfolge (``Regal/sortIndex``), die der Anwender per Drag-Handle
/// (Bearbeiten-Modus) selbst festlegen kann.
struct GeschaeftDetailView: View {
    @Bindable var geschaeft: Geschaeft
    @Environment(\.modelContext) private var modelContext
    @State private var zeigeStammdatenEdit = false

    private var regaleSortiert: [Regal] {
        geschaeft.regale.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        List {
            Section {
                Button {
                    zeigeStammdatenEdit = true
                } label: {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: geschaeft.typ.symbolName, farbe: .accentColor, groesse: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(geschaeft.name)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(geschaeft.typ.anzeigename)
                                .foregroundStyle(.secondary)
                            if let adresse = geschaeft.adresse, !adresse.isEmpty {
                                Text(adresse)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(regaleSortiert) { regal in
                    NavigationLink(value: regal) {
                        RegalZeile(regal: regal)
                    }
                }
                .onDelete(perform: regalLoeschen)
                .onMove(perform: regalVerschieben)

                Button {
                    regalHinzufuegen()
                } label: {
                    Label("Regal hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Regale")
            } footer: {
                Text("Ziehe die Regale (über „Bearbeiten“) in die Reihenfolge, in der du sie beim Einkaufen ablaufen möchtest.")
            }
        }
        .navigationTitle(geschaeft.name.isEmpty ? "Geschäft" : geschaeft.name)
        .navigationDestination(for: Regal.self) { regal in
            RegalDetailView(regal: regal)
        }
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $zeigeStammdatenEdit) {
            GeschaeftStammdatenEditView(geschaeft: geschaeft, istNeu: false)
        }
    }

    private func regalHinzufuegen() {
        let naechsterIndex = (geschaeft.regale.map(\.sortIndex).max() ?? -1) + 1
        let regal = Regal(name: "Neues Regal", sortIndex: naechsterIndex, geschaeft: geschaeft)
        modelContext.insert(regal)
    }

    private func regalLoeschen(at offsets: IndexSet) {
        let sortiert = regaleSortiert
        for index in offsets {
            modelContext.delete(sortiert[index])
        }
    }

    private func regalVerschieben(from source: IndexSet, to destination: Int) {
        var sortiert = regaleSortiert
        sortiert.move(fromOffsets: source, toOffset: destination)
        for (index, regal) in sortiert.enumerated() {
            regal.sortIndex = index
        }
    }
}

/// Eine Zeile in der Regal-Liste eines Geschäfts.
private struct RegalZeile: View {
    let regal: Regal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(regal.name.isEmpty ? "Unbenannt" : regal.name)
            if regal.kategorien.isEmpty {
                Text("Keine Kategorien zugeordnet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(regal.kategorien.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

#Preview {
    NavigationStack {
        GeschaeftDetailView(geschaeft: Geschaeft(name: "Rewe", typ: .lebensmittel))
    }
    .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
