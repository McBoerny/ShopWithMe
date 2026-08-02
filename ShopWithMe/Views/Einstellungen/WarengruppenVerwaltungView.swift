import SwiftUI
import SwiftData

/// Globale Verwaltung aller ``ArtikelKategorie``n: Umbenennen, Symbol/Farbe ändern,
/// Reihenfolge per Drag-Handle anpassen sowie Anlegen/Löschen — aufrufbar aus
/// ``SettingsView``.
///
/// Anders als ``WarengruppeHinzufuegenSheet`` (ordnet eine bestehende Kategorie einem
/// Geschäft zu) bearbeitet diese Ansicht die Kategorien selbst, unabhängig von
/// einem Geschäft.
struct WarengruppenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            Section {
                ForEach(kategorien) { kategorie in
                    NavigationLink {
                        WarengruppeBearbeitenView(kategorie: kategorie)
                    } label: {
                        Label(kategorie.name, systemImage: kategorie.standardSymbol)
                            .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
                    }
                }
                .onDelete(perform: kategorieLoeschen)
                .onMove(perform: kategorieVerschieben)
            } footer: {
                Text("Zum Ändern von Name, Symbol oder Farbe antippen. Zum Löschen nach links wischen — Artikel dieser Warengruppe landen danach automatisch in „Sonstiges“.")
            }
        }
        .navigationTitle("Warengruppen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeueKategorie = true
                } label: {
                    Label("Warengruppe hinzufügen", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $zeigeNeueKategorie) {
            NeueWarengruppeSheet(naechsterSortIndex: (kategorien.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }

    private func kategorieLoeschen(at offsets: IndexSet) {
        for index in offsets {
            let kategorie = kategorien[index]
            guard kategorie.name != ArtikelKategorie.sonstigesName else { continue }
            // Tombstone verhindert, dass ein Peer, der die Kategorie noch in
            // seinem eigenen Snapshot führt, sie beim nächsten Sync
            // unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
            SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.artikelKategorie, id: kategorie.id, context: modelContext)
            modelContext.delete(kategorie)
        }
    }

    private func kategorieVerschieben(from source: IndexSet, to destination: Int) {
        var sortiert = kategorien
        sortiert.move(fromOffsets: source, toOffset: destination)
        for (index, kategorie) in sortiert.enumerated() {
            kategorie.sortIndex = index
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe einer einzelnen ``ArtikelKategorie`` sowie
/// die ihr zugeordneten Artikel (GitHub #15) — direkt hier hinzufügbar/entfernbar,
/// ohne für jeden Artikel einzeln über ``ArtikelEditView`` zu gehen.
private struct WarengruppeBearbeitenView: View {
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
                    Text("„Sonstiges“ ist die Auffang-Warengruppe für Artikel ohne eigene Warengruppe und kann nicht gelöscht werden.")
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
                Text("Artikel, die dieser Warengruppe zugeordnet sind. Zum Entfernen nach links wischen.")
            }
        }
        .navigationTitle(kategorie.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeArtikelHinzufuegen) {
            ArtikelZuWarengruppeHinzufuegenSheet(kategorie: kategorie)
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
/// ``WarengruppeBearbeitenView``. Tippen auf einen Artikel ordnet ihn sofort zu
/// (kein zusätzlicher Bestätigungsschritt, analog ``WarengruppeHinzufuegenSheet``).
private struct ArtikelZuWarengruppeHinzufuegenSheet: View {
    let kategorie: ArtikelKategorie

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @State private var suchtext = ""

    private var nichtZugeordneteArtikel: [Artikel] {
        let uebrige = alleArtikel.filter { !$0.kategorien.contains(kategorie) }
        guard !suchtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return uebrige }
        return uebrige.filter { $0.name.localizedCaseInsensitiveContains(suchtext) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(nichtZugeordneteArtikel) { artikel in
                    Button {
                        zuordnen(artikel)
                    } label: {
                        Text(artikel.name)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $suchtext, prompt: "Artikel suchen")
            .overlay {
                if nichtZugeordneteArtikel.isEmpty {
                    ContentUnavailableView(
                        "Keine weiteren Artikel",
                        systemImage: "carrot.fill",
                        description: Text("Alle Artikel sind dieser Warengruppe bereits zugeordnet.")
                    )
                }
            }
            .navigationTitle("Artikel hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
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
        WarengruppenVerwaltungView()
    }
    .modelContainer(for: [ArtikelKategorie.self, GeschaeftTyp.self, Artikel.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
