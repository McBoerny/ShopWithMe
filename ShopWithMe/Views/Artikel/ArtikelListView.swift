import SwiftUI
import SwiftData

/// Wie die Artikelliste in ``ArtikelListView`` sortiert/gruppiert wird.
private enum ArtikelSortierung: String, CaseIterable, Identifiable {
    /// Alphabetisch — ab 50 Artikeln automatisch nach Anfangsbuchstaben gruppiert
    /// mit iOS A–Z-Schnellscrollleiste.
    case alphabetisch
    /// Nach ``Abteilung`` gruppiert (Reihenfolge nach
    /// ``Abteilung/sortIndex``), innerhalb einer Abteilung alphabetisch.
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
    @State private var suchtext = ""
    @State private var zeigeDuplikatVorschlaege = false

    private struct AbteilungGruppe: Identifiable {
        let abteilung: Abteilung
        var artikel: [Artikel]
        var id: PersistentIdentifier { abteilung.persistentModelID }
    }

    /// ``artikel``, alphabetisch sortiert und ggf. nach ``suchtext`` gefiltert
    /// — Umlaute einsortiert bei ihrem Basisbuchstaben (GitHub #46).
    private var alphabetischSortiert: [Artikel] {
        let sortiert = artikel.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        guard !getrimmterSuchtext.isEmpty else { return sortiert }
        return sortiert.filter { $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var abteilungGruppen: [AbteilungGruppe] {
        var nachAbteilung: [PersistentIdentifier: AbteilungGruppe] = [:]
        for eintrag in alphabetischSortiert {
            let abteilung = eintrag.effektiveAbteilungen(context: modelContext)[0]
            nachAbteilung[abteilung.persistentModelID, default: AbteilungGruppe(abteilung: abteilung, artikel: [])].artikel.append(eintrag)
        }
        return nachAbteilung.values.sorted {
            $0.abteilung.sortIndex == $1.abteilung.sortIndex
                ? $0.abteilung.name.vergleicheAlphabetisch(mit: $1.abteilung.name) == .orderedAscending
                : $0.abteilung.sortIndex < $1.abteilung.sortIndex
        }
    }

    var body: some View {
        liste
            .navigationTitle("Artikel")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Picker("Sortierung", selection: $sortierung) {
                        ForEach(ArtikelSortierung.allCases) { modus in
                            Text(modus.anzeigename).tag(modus)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if AISuggestionService.istVerfuegbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            zeigeDuplikatVorschlaege = true
                        } label: {
                            Label("Dubletten finden", systemImage: "sparkles")
                        }
                    }
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
            .sheet(isPresented: $zeigeDuplikatVorschlaege) {
                ArtikelDuplikatVorschlaegeView()
            }
    }

    private var liste: some View {
        List {
            switch sortierung {
            case .alphabetisch:
                AlphabetischeListenSektion(
                    alphabetischSortiert,
                    name: \.name,
                    loeschen: { offsets, gruppe in artikelLoeschen(offsets.map { gruppe[$0] }) }
                ) { eintrag in
                    artikelZeile(eintrag)
                }
            case .abteilung:
                ForEach(abteilungGruppen) { gruppe in
                    Section(gruppe.abteilung.name) {
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
        .searchable(text: $suchtext, prompt: "Artikel suchen")
        .overlay {
            if alphabetischSortiert.isEmpty {
                ContentUnavailableView(
                    artikel.isEmpty ? "Keine Artikel" : "Keine Treffer",
                    systemImage: "carrot.fill",
                    description: Text(
                        artikel.isEmpty
                            ? "Lege deinen ersten Artikel mit dem Plus-Symbol an."
                            : "Kein Artikel passt zu \u{201E}\(getrimmterSuchtext)\u{201C}."
                    )
                )
            }
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

/// Eine Zeile in der Artikel-Liste — die gesamte Zeile ist tappbar dank
/// `.contentShape(Rectangle())`, das auch den Spacer-Bereich einschließt.
private struct ArtikelZeile: View {
    let artikel: Artikel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name.isEmpty ? "Unbenannt" : artikel.name)
                    .foregroundStyle(.primary)
                if !artikel.abteilungen.isEmpty {
                    Text(artikel.abteilungen.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        ArtikelListView()
    }
    .modelContainer(for: [Artikel.self, Abteilung.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
