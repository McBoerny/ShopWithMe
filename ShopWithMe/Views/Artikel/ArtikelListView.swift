import SwiftUI
import SwiftData

/// Wie die Artikelliste in ``ArtikelListView`` sortiert/gruppiert wird.
private enum ArtikelSortierung: String, CaseIterable, Identifiable {
    /// Eine flache, alphabetisch sortierte Liste (Standard).
    case alphabetisch
    /// Nach ``ArtikelKategorie`` gruppiert (Reihenfolge nach
    /// ``ArtikelKategorie/sortIndex``), innerhalb einer Kategorie alphabetisch.
    case kategorie

    var id: String { rawValue }

    var anzeigename: String {
        switch self {
        case .alphabetisch: return "Alphabetisch"
        case .kategorie: return "Nach Kategorie"
        }
    }
}

/// Zeigt alle Artikel als Liste und erlaubt Anlegen, Bearbeiten und Löschen —
/// erreichbar über die Artikel-Verwaltung in ``SettingsView``. Erwartet einen
/// umgebenden `NavigationStack` beim Aufrufer statt selbst einen anzulegen (analog
/// ``GeschaeftListView``), seit sie keine eigene Tab-Wurzel mehr ist (GitHub #1).
struct ArtikelListView: View {
    @Query(sort: \Artikel.name) private var artikel: [Artikel]
    @Environment(\.modelContext) private var modelContext

    @State private var neuerArtikelEntwurf: Artikel?
    @State private var bearbeiteterArtikel: Artikel?
    @State private var sortierung: ArtikelSortierung = .alphabetisch

    private struct KategorieGruppe: Identifiable {
        let kategorie: ArtikelKategorie
        var artikel: [Artikel]
        var id: PersistentIdentifier { kategorie.persistentModelID }
    }

    /// ``artikel``, gruppiert nach der ersten ``Artikel/effektiveKategorien(context:)``
    /// und nach ``ArtikelKategorie/sortIndex`` sortiert — nur relevant im
    /// ``ArtikelSortierung/kategorie``-Modus. Rein geschäftsunabhängige
    /// Verwaltungsansicht, daher (anders als beim Einkaufen) keine „führende
    /// Kategorie pro Geschäft“-Auflösung nötig — einfach die erste zugeordnete
    /// Kategorie.
    private var kategorieGruppen: [KategorieGruppe] {
        var nachKategorie: [PersistentIdentifier: KategorieGruppe] = [:]
        for eintrag in artikel {
            let kategorie = eintrag.effektiveKategorien(context: modelContext)[0]
            nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, artikel: [])].artikel.append(eintrag)
        }
        return nachKategorie.values.sorted {
            $0.kategorie.sortIndex == $1.kategorie.sortIndex
                ? $0.kategorie.name < $1.kategorie.name
                : $0.kategorie.sortIndex < $1.kategorie.sortIndex
        }
    }

    var body: some View {
        List {
            switch sortierung {
            case .alphabetisch:
                ForEach(artikel) { eintrag in
                    artikelZeile(eintrag)
                }
                .onDelete { offsets in
                    artikelLoeschen(offsets.map { artikel[$0] })
                }
            case .kategorie:
                ForEach(kategorieGruppen) { gruppe in
                    Section(gruppe.kategorie.name) {
                        ForEach(gruppe.artikel) { eintrag in
                            artikelZeile(eintrag)
                        }
                        .onDelete { offsets in
                            artikelLoeschen(offsets.map { gruppe.artikel[$0] })
                        }
                    }
                }
            }
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
            ToolbarItem(placement: .topBarLeading) {
                Picker("Sortierung", selection: $sortierung) {
                    ForEach(ArtikelSortierung.allCases) { modus in
                        Text(modus.anzeigename).tag(modus)
                    }
                }
                .pickerStyle(.menu)
            }
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

    @ViewBuilder
    private func artikelZeile(_ eintrag: Artikel) -> some View {
        Button {
            bearbeiteterArtikel = eintrag
        } label: {
            ArtikelZeile(artikel: eintrag)
        }
        .buttonStyle(.plain)
    }

    private func artikelLoeschen(_ zuLoeschende: [Artikel]) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name.isEmpty ? "Unbenannt" : artikel.name)
                    .foregroundStyle(.primary)
                if !artikel.kategorien.isEmpty {
                    Text(artikel.kategorien.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !artikel.einkaufslistenEintraege.isEmpty {
                Image(systemName: "checklist")
                    .foregroundStyle(.tint)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ArtikelListView()
    }
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
