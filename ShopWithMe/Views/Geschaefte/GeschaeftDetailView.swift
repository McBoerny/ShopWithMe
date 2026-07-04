import SwiftUI
import SwiftData

/// Detailansicht eines ``Geschaeft``s: Stammdaten und Regal-Verwaltung.
///
/// Die Reihenfolge der Regale in dieser Liste hängt vom gewählten
/// ``RegalSortierModus`` ab: manuell (``Regal/sortIndex``, per Drag-Handle im
/// Bearbeiten-Modus änderbar) oder automatisch anhand der gelernten Einkaufs-
/// Reihenfolge (``ShelfOrderLearningService``). Der Wechsel zwischen beiden Modi
/// überschreibt die jeweils andere Reihenfolge nicht — beide bleiben unabhängig
/// voneinander erhalten.
struct GeschaeftDetailView: View {
    @Bindable var geschaeft: Geschaeft
    @Environment(\.modelContext) private var modelContext
    @State private var zeigeStammdatenEdit = false
    @Query private var kaufHistorie: [KaufEintrag]

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
        let geschaeftID = geschaeft.persistentModelID
        _kaufHistorie = Query(
            filter: #Predicate<KaufEintrag> { $0.geschaeft?.persistentModelID == geschaeftID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    private var regaleAnzeigen: [Regal] {
        ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: modelContext)
    }

    private var automatischeReihenfolgeVerfuegbar: Bool {
        ShelfOrderLearningService.automatischeReihenfolgeVerfuegbar(fuer: geschaeft, context: modelContext)
    }

    private var verschiebenAktion: ((IndexSet, Int) -> Void)? {
        guard geschaeft.regalSortierModus == .manuell else { return nil }
        return regalVerschieben
    }

    var body: some View {
        List {
            if automatischeReihenfolgeVerfuegbar {
                Section {
                    Picker("Reihenfolge", selection: $geschaeft.regalSortierModus) {
                        ForEach(RegalSortierModus.allCases) { modus in
                            Text(modus.anzeigename).tag(modus)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(geschaeft.regalSortierModus == .automatisch
                         ? "ShopWithMe sortiert die Regale automatisch anhand deiner bisherigen Einkäufe. Deine manuelle Reihenfolge bleibt dabei erhalten und lässt sich jederzeit wieder auswählen."
                         : "Du legst die Reihenfolge selbst fest. ShopWithMe hat außerdem genug Einkäufe gelernt, um stattdessen automatisch zu sortieren.")
                }
            }

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
                ForEach(regaleAnzeigen) { regal in
                    NavigationLink(value: regal) {
                        RegalZeile(regal: regal)
                    }
                }
                .onDelete(perform: regalLoeschen)
                .onMove(perform: verschiebenAktion)

                Button {
                    regalHinzufuegen()
                } label: {
                    Label("Regal hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Regale")
            } footer: {
                Text(geschaeft.regalSortierModus == .manuell
                     ? "Ziehe die Regale (über „Bearbeiten“) in die Reihenfolge, in der du sie beim Einkaufen ablaufen möchtest."
                     : "Diese Reihenfolge wird automatisch gelernt. Wechsle oben zu „Manuell“, um sie selbst festzulegen.")
            }

            if !kaufHistorie.isEmpty {
                Section("Preishistorie") {
                    ForEach(kaufHistorie) { eintrag in
                        PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: true)
                    }
                }
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
        let sortiert = regaleAnzeigen
        for index in offsets {
            modelContext.delete(sortiert[index])
        }
    }

    private func regalVerschieben(from source: IndexSet, to destination: Int) {
        var sortiert = regaleAnzeigen
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
