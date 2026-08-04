import SwiftUI
import SwiftData

/// Wie die Artikelliste in ``ArtikelListView`` sortiert/gruppiert wird.
private enum ArtikelSortierung: String, CaseIterable, Identifiable {
    /// Eine flache, alphabetisch sortierte Liste (Standard).
    case alphabetisch
    /// Nach ``ArtikelKategorie`` gruppiert (Reihenfolge nach
    /// ``ArtikelKategorie/sortIndex``), innerhalb einer Kategorie alphabetisch.
    case abteilung

    var id: String { rawValue }

    var anzeigename: String {
        switch self {
        case .alphabetisch: return "Alphabetisch"
        case .abteilung: return "Nach Abteilung"
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

    /// ``artikel``, alphabetisch sortiert — Umlaute einsortiert bei ihrem
    /// Basisbuchstaben (GitHub #46) statt in der rohen `@Query`-Reihenfolge
    /// (reine Unicode-Codepoint-Sortierung durch SwiftData/SQLite), die
    /// umlauthaltige Namen ans Ende sortiert. Grundlage für beide
    /// ``ArtikelSortierung``-Modi, damit auch innerhalb einer Kategorie-Gruppe
    /// (``kategorieGruppen``) alphabetisch korrekt sortiert ist.
    private var alphabetischSortiert: [Artikel] {
        artikel.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
    }

    /// ``alphabetischSortiert``, gruppiert nach der ersten
    /// ``Artikel/effektiveKategorien(context:)`` und nach
    /// ``ArtikelKategorie/sortIndex`` sortiert — nur relevant im
    /// ``ArtikelSortierung/kategorie``-Modus. Rein geschäftsunabhängige
    /// Verwaltungsansicht, daher (anders als beim Einkaufen) keine „führende
    /// Kategorie pro Geschäft“-Auflösung nötig — einfach die erste zugeordnete
    /// Kategorie.
    private var kategorieGruppen: [KategorieGruppe] {
        var nachKategorie: [PersistentIdentifier: KategorieGruppe] = [:]
        for eintrag in alphabetischSortiert {
            let kategorie = eintrag.effektiveKategorien(context: modelContext)[0]
            nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, artikel: [])].artikel.append(eintrag)
        }
        return nachKategorie.values.sorted {
            $0.kategorie.sortIndex == $1.kategorie.sortIndex
                ? $0.kategorie.name.vergleicheAlphabetisch(mit: $1.kategorie.name) == .orderedAscending
                : $0.kategorie.sortIndex < $1.kategorie.sortIndex
        }
    }

    var body: some View {
        List {
            switch sortierung {
            case .alphabetisch:
                ForEach(alphabetischSortiert) { eintrag in
                    artikelZeile(eintrag)
                }
                .onDelete { offsets in
                    artikelLoeschen(offsets.map { alphabetischSortiert[$0] })
                }
            case .abteilung:
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
        // Nur Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — während des Micro-Lease-Erwerbs kann ein
        // nebenläufiger Sync-Zyklus einen dieser Artikel bereits gelöscht
        // haben (dann einfach überspringen, er ist ja bereits weg).
        let zuLoeschendeReferenzen = zuLoeschende.map { ModelReference($0) }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for referenz in zuLoeschendeReferenzen {
                    guard let eintrag = referenz.resolved(in: modelContext) else { continue }
                    // Tombstone verhindert, dass ein Peer, der den Artikel
                    // noch in seinem eigenen Snapshot führt, ihn beim
                    // nächsten Sync unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
                    SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.artikel, id: eintrag.id, context: modelContext)
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
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
