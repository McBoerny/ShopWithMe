import SwiftUI
import SwiftData

/// Globale Verwaltung aller ``ArtikelKategorie``n: Umbenennen, Symbol/Farbe ändern
/// sowie Anlegen/Löschen — aufrufbar aus ``SettingsView``.
///
/// Anders als ``AbteilungHinzufuegenSheet`` (ordnet eine bestehende Kategorie einem
/// Geschäft zu) bearbeitet diese Ansicht die Kategorien selbst, unabhängig von
/// einem Geschäft.
struct AbteilungenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var kategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false

    private var sortierteKategorien: [ArtikelKategorie] {
        kategorien.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
    }

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            AlphabetischeListenSektion(
                sortierteKategorien,
                name: \.name,
                loeschen: { offsets, gruppe in kategorieLoeschen(at: offsets, aus: gruppe) },
                fusszeile: "Zum Ändern von Name, Symbol oder Farbe antippen. Zum Löschen nach links wischen — Artikel dieser Abteilung landen danach automatisch in \u{201E}Sonstiges\u{201C}."
            ) { kategorie in
                NavigationLink {
                    AbteilungBearbeitenView(kategorie: kategorie)
                } label: {
                    Label {
                        Text(kategorie.name)
                    } icon: {
                        Image(systemName: kategorie.standardSymbol)
                            .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
                    }
                }
            }
        }
        .navigationTitle("Abteilungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeueKategorie = true
                } label: {
                    Label("Abteilung hinzufügen", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $zeigeNeueKategorie) {
            NeueAbteilungSheet(naechsterSortIndex: (kategorien.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }

    private func kategorieLoeschen(at offsets: IndexSet, aus sortiert: [ArtikelKategorie]) {
        for index in offsets {
            let kategorie = sortiert[index]
            guard kategorie.name != ArtikelKategorie.sonstigesName else { continue }
            // Tombstone verhindert, dass ein Peer, der die Kategorie noch in
            // seinem eigenen Snapshot führt, sie beim nächsten Sync
            // unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
            SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.artikelKategorie, id: kategorie.id, context: modelContext)
            modelContext.delete(kategorie)
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe einer einzelnen ``ArtikelKategorie`` sowie
/// die ihr zugeordneten Artikel (GitHub #15) — direkt hier hinzufügbar/entfernbar,
/// ohne für jeden Artikel einzeln über ``ArtikelEditView`` zu gehen.
private struct AbteilungBearbeitenView: View {
    @Bindable var kategorie: ArtikelKategorie
    @State private var zeigeArtikelHinzufuegen = false

    /// Artikel, die dieser Kategorie zugeordnet sind, alphabetisch — Vereinigung aus
    /// ``ArtikelKategorie/zugeordneteArtikel`` (maßgebliche Quelle für
    /// Mehrfachzuordnung) und ``ArtikelKategorie/artikel`` (Migrations-Fallback für
    /// Artikel, die noch nie über die Mehrfachauswahl neu gespeichert wurden, siehe
    /// ``Artikel/effektiveKategorien(context:)``) — sonst fehlen genau diese
    /// Alt-Artikel hier, obwohl sie überall sonst in der App korrekt zu dieser
    /// Kategorie gehören.
    private var zugeordneteArtikel: [Artikel] {
        let mehrfachzuordnung = Set(kategorie.zugeordneteArtikel.map(\.persistentModelID))
        let legacy = kategorie.artikel.filter { !mehrfachzuordnung.contains($0.persistentModelID) }
        return (kategorie.zugeordneteArtikel + legacy)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $kategorie.name)
                    .font(.title3)
                SymbolFarbAuswahlZeile(symbolName: $kategorie.standardSymbol, farbeHex: $kategorie.standardFarbeHex)
            } footer: {
                if kategorie.name == ArtikelKategorie.sonstigesName {
                    Text("\u{201E}Sonstiges\u{201C} ist die Auffang-Abteilung für Artikel ohne eigene Abteilung und kann nicht gelöscht werden.")
                }
            }

            Section {
                ForEach(zugeordneteArtikel) { artikel in
                    Text(artikel.name)
                }
                .onDelete(perform: artikelEntfernen)

                Button {
                    zeigeArtikelHinzufuegen = true
                } label: {
                    Label("Artikel hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Artikel")
            } footer: {
                Text("Artikel, die dieser Abteilung zugeordnet sind. Zum Entfernen nach links wischen.")
            }
        }
        .navigationTitle(kategorie.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kategorie.name) { _, _ in kategorie.markiereGeaendert() }
        .onChange(of: kategorie.standardSymbol) { _, _ in kategorie.markiereGeaendert() }
        .onChange(of: kategorie.standardFarbeHex) { _, _ in kategorie.markiereGeaendert() }
        .sheet(isPresented: $zeigeArtikelHinzufuegen) {
            ArtikelZuAbteilungHinzufuegenSheet(kategorie: kategorie)
        }
    }

    private func artikelEntfernen(at offsets: IndexSet) {
        for index in offsets {
            let artikel = zugeordneteArtikel[index]
            var aktuelle = artikel.kategorien
            aktuelle.removeAll { $0 == kategorie }
            artikel.kategorien = aktuelle
        }
    }
}

/// Sheet zum Zuordnen bestehender ``Artikel`` zu ``kategorie`` — aufrufbar aus
/// ``AbteilungBearbeitenView``. Tippen auf einen Artikel ordnet ihn sofort zu
/// (kein zusätzlicher Bestätigungsschritt, analog ``AbteilungHinzufuegenSheet``).
/// Nutzt die generische ``AuswahlSheet`` (GitHub #130) analog
/// ``AbteilungHinzufuegenSheet``/``KategorieHinzufuegenSheet`` — hier ohne
/// Neuanlage-Option, da jeder Artikel bereits vorher über die
/// Artikel-Verwaltung angelegt werden muss.
private struct ArtikelZuAbteilungHinzufuegenSheet: View {
    let kategorie: ArtikelKategorie

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    /// Die eigentliche Zuordnung passiert verzögert über ``onChange(of:)``
    /// statt direkt im Binding-Setter — siehe ausführliche Begründung in
    /// ``AbteilungHinzufuegenSheet`` (Live-Fund: Sheet flackerte auf/zu).
    @State private var geradeAusgewaehlt: Set<Artikel.ID> = []

    private var nichtZugeordneteArtikel: [Artikel] {
        alleArtikel.filter { !$0.kategorien.contains(kategorie) }
    }

    var body: some View {
        AuswahlSheet(
            titel: "Artikel hinzufügen",
            items: nichtZugeordneteArtikel,
            name: \.name,
            modus: .mehrfach($geradeAusgewaehlt),
            suchPrompt: "Artikel suchen",
            neuAnlegenInhalt: { (_: String, _: @escaping (Artikel) -> Void) in EmptyView() },
            leerTitel: "Keine weiteren Artikel",
            leerBeschreibung: Text("Alle Artikel sind dieser Abteilung bereits zugeordnet."),
            leerSymbolName: "carrot.fill"
        )
        .onChange(of: geradeAusgewaehlt) { _, neu in
            guard !neu.isEmpty else { return }
            for id in neu {
                if let artikel = nichtZugeordneteArtikel.first(where: { $0.id == id }) {
                    zuordnen(artikel)
                }
            }
            geradeAusgewaehlt = []
        }
    }

    private func zuordnen(_ artikel: Artikel) {
        var aktuelle = artikel.kategorien
        guard !aktuelle.contains(kategorie) else { return }
        aktuelle.append(kategorie)
        artikel.kategorien = aktuelle
    }
}

#Preview {
    NavigationStack {
        AbteilungenVerwaltungView()
    }
    .modelContainer(for: [ArtikelKategorie.self, GeschaeftTyp.self, Artikel.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
