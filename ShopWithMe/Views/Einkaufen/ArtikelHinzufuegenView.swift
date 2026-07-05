import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen eines Artikels zu ``einkaufsliste``.
///
/// Bietet eine Suche über alle bereits angelegten Artikel an. Findet die Suche keinen
/// exakten Treffer, kann der gesuchte Artikel direkt hier angelegt und anschließend
/// sofort auf ``einkaufsliste`` gesetzt werden.
struct ArtikelHinzufuegenView: View {
    let einkaufsliste: Einkaufsliste

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
                            ArtikelSucheZeile(artikel: artikel, bereitsAufListe: einkaufsliste.enthaelt(artikel))
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
                einkaufsliste.artikelHinzufuegen(artikel, context: modelContext)
            }
            dismiss()
        }
    }

    private func neuenArtikelAnlegen() {
        neuerArtikelEntwurf = Artikel(
            name: getrimmterSuchtext,
            symbolName: SymbolPalette.alle[0],
            farbeHex: Color.artikelPalette[0]
        )
    }

    /// Wurde der Entwurf tatsächlich gesichert (also in den Model-Context
    /// eingefügt), wird er zusätzlich auf ``einkaufsliste`` gesetzt — dann schließt
    /// sich auch dieses Sheet gleich mit.
    private func nachNeuanlageAufraeumen() {
        guard let entwurf = neuerArtikelEntwurf, entwurf.modelContext != nil else {
            neuerArtikelEntwurf = nil
            return
        }
        neuerArtikelEntwurf = nil
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                einkaufsliste.artikelHinzufuegen(entwurf, context: modelContext)
            }
            dismiss()
        }
    }
}

/// Eine Zeile in der Artikelsuche mit Hinweis, falls der Artikel bereits auf der
/// aktuellen Einkaufsliste steht.
private struct ArtikelSucheZeile: View {
    let artikel: Artikel
    let bereitsAufListe: Bool

    var body: some View {
        HStack {
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
            if bereitsAufListe {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

#Preview {
    ArtikelHinzufuegenView(einkaufsliste: Einkaufsliste(name: "Einkaufsliste"))
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
