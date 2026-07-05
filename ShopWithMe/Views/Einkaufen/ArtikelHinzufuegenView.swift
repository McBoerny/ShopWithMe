import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen eines Artikels zur Einkaufsliste.
///
/// Bietet eine Suche über alle bereits angelegten Artikel an. Findet die Suche keinen
/// exakten Treffer, kann der gesuchte Artikel direkt hier angelegt und anschließend
/// sofort auf die Einkaufsliste gesetzt werden.
struct ArtikelHinzufuegenView: View {
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var suchtext = ""
    @State private var neuerArtikelEntwurf: Artikel?

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gefilterteArtikel: [Artikel] {
        guard !getrimmterSuchtext.isEmpty else { return alleArtikel }
        return alleArtikel.filter { $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var existiertGenau: Bool {
        alleArtikel.contains {
            $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !getrimmterSuchtext.isEmpty && !existiertGenau {
                    Section {
                        Button {
                            neuenArtikelAnlegen()
                        } label: {
                            Label("„\(getrimmterSuchtext)“ neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }
                }

                Section {
                    ForEach(gefilterteArtikel) { artikel in
                        Button {
                            hinzufuegen(artikel)
                        } label: {
                            ArtikelSucheZeile(artikel: artikel)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if gefilterteArtikel.isEmpty && getrimmterSuchtext.isEmpty {
                    ContentUnavailableView(
                        "Keine Artikel",
                        systemImage: "carrot.fill",
                        description: Text("Lege deinen ersten Artikel über die Suche an.")
                    )
                }
            }
            .searchable(text: $suchtext, prompt: "Artikel suchen oder anlegen")
            .navigationTitle("Artikel hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $neuerArtikelEntwurf, onDismiss: nachNeuanlageAufraeumen) { entwurf in
                ArtikelEditView(artikel: entwurf, istNeu: true)
            }
        }
    }

    private func hinzufuegen(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                artikel.istAufEinkaufsliste = true
            }
            dismiss()
        }
    }

    private func neuenArtikelAnlegen() {
        neuerArtikelEntwurf = Artikel(
            name: getrimmterSuchtext,
            symbolName: SymbolPalette.alle[0],
            farbeHex: Color.artikelPalette[0],
            istAufEinkaufsliste: true
        )
    }

    /// Wurde der Entwurf tatsächlich gesichert (also in den Model-Context eingefügt),
    /// war der neue Artikel damit direkt auf der Einkaufsliste — dann schließt sich
    /// auch dieses Sheet gleich mit.
    private func nachNeuanlageAufraeumen() {
        let wurdeGesichert = neuerArtikelEntwurf?.modelContext != nil
        neuerArtikelEntwurf = nil
        if wurdeGesichert {
            dismiss()
        }
    }
}

/// Eine Zeile in der Artikelsuche mit Hinweis, falls der Artikel bereits auf der
/// Einkaufsliste steht.
private struct ArtikelSucheZeile: View {
    let artikel: Artikel

    var body: some View {
        HStack {
            GlassSymbolBadge(symbolName: artikel.symbolName, farbe: Color(hex: artikel.farbeHex), groesse: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name)
                    .foregroundStyle(.primary)
                if let kategorie = artikel.kategorie {
                    Text(kategorie.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if artikel.istAufEinkaufsliste {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

#Preview {
    ArtikelHinzufuegenView()
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self], inMemory: true)
}
