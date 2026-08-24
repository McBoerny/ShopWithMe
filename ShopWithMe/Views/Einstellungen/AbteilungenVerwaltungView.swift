import SwiftUI
import SwiftData

/// Globale Verwaltung aller ``Abteilung``en: Umbenennen, Symbol/Farbe ändern
/// sowie Anlegen/Löschen — aufrufbar aus ``SettingsView``.
///
/// Anders als ``AbteilungHinzufuegenSheet`` (ordnet eine bestehende Abteilung einem
/// Geschäft zu) bearbeitet diese Ansicht die Abteilungen selbst, unabhängig von
/// einem Geschäft.
struct AbteilungenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var abteilungen: [Abteilung]
    @State private var zeigeNeueAbteilung = false

    private var sortierteAbteilungen: [Abteilung] {
        abteilungen.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
    }

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            AlphabetischeListenSektion(
                sortierteAbteilungen,
                name: \.name,
                loeschen: { offsets, gruppe in abteilungLoeschen(at: offsets, aus: gruppe) },
                fusszeile: "Zum Ändern von Name, Symbol oder Farbe antippen. Zum Löschen nach links wischen — Artikel dieser Abteilung landen danach automatisch in \u{201E}Sonstiges\u{201C}."
            ) { abteilung in
                NavigationLink {
                    AbteilungBearbeitenView(abteilung: abteilung)
                } label: {
                    Label {
                        Text(abteilung.name)
                    } icon: {
                        Image(systemName: abteilung.standardSymbol)
                            .foregroundStyle(Color(hex: abteilung.standardFarbeHex))
                    }
                }
                .accessibilityIdentifier(A11yID.AbteilungenVerwaltung.abteilungRow(abteilung.id))
            }
        }
        .accessibilityIdentifier(A11yID.AbteilungenVerwaltung.list)
        .navigationTitle("Abteilungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeueAbteilung = true
                } label: {
                    Label("Abteilung hinzufügen", systemImage: "plus")
                }
                .accessibilityIdentifier(A11yID.AbteilungenVerwaltung.hinzufuegenButton)
            }
        }
        .sheet(isPresented: $zeigeNeueAbteilung) {
            NeueAbteilungSheet(naechsterSortIndex: (abteilungen.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }

    private func abteilungLoeschen(at offsets: IndexSet, aus sortiert: [Abteilung]) {
        for index in offsets {
            let abteilung = sortiert[index]
            guard abteilung.name != Abteilung.sonstigesName else { continue }
            // Tombstone verhindert, dass ein Peer, der die Abteilung noch in
            // seinem eigenen Snapshot führt, sie beim nächsten Sync
            // unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
            SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.abteilung, id: abteilung.id, context: modelContext)
            modelContext.delete(abteilung)
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe einer einzelnen ``Abteilung`` sowie
/// die ihr zugeordneten Artikel (GitHub #15) — direkt hier hinzufügbar/entfernbar,
/// ohne für jeden Artikel einzeln über ``ArtikelEditView`` zu gehen.
private struct AbteilungBearbeitenView: View {
    @Bindable var abteilung: Abteilung
    @State private var zeigeArtikelHinzufuegen = false

    /// Artikel, die dieser Abteilung zugeordnet sind, alphabetisch — Vereinigung aus
    /// ``Abteilung/zugeordneteArtikel`` (maßgebliche Quelle für
    /// Mehrfachzuordnung) und ``Abteilung/artikel`` (Migrations-Fallback für
    /// Artikel, die noch nie über die Mehrfachauswahl neu gespeichert wurden, siehe
    /// ``Artikel/effektiveAbteilungen(context:)``) — sonst fehlen genau diese
    /// Alt-Artikel hier, obwohl sie überall sonst in der App korrekt zu dieser
    /// Abteilung gehören.
    private var zugeordneteArtikel: [Artikel] {
        let mehrfachzuordnung = Set(abteilung.zugeordneteArtikel.map(\.persistentModelID))
        let legacy = abteilung.artikel.filter { !mehrfachzuordnung.contains($0.persistentModelID) }
        return (abteilung.zugeordneteArtikel + legacy)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $abteilung.name)
                    .font(.title3)
                SymbolFarbAuswahlZeile(symbolName: $abteilung.standardSymbol, farbeHex: $abteilung.standardFarbeHex)
            } footer: {
                if abteilung.name == Abteilung.sonstigesName {
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
                .accessibilityIdentifier(A11yID.AbteilungBearbeiten.artikelHinzufuegenButton)
            } header: {
                Text("Artikel")
            } footer: {
                Text("Artikel, die dieser Abteilung zugeordnet sind. Zum Entfernen nach links wischen.")
            }
        }
        .navigationTitle(abteilung.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: abteilung.name) { _, _ in abteilung.markiereGeaendert() }
        .onChange(of: abteilung.standardSymbol) { _, _ in abteilung.markiereGeaendert() }
        .onChange(of: abteilung.standardFarbeHex) { _, _ in abteilung.markiereGeaendert() }
        .sheet(isPresented: $zeigeArtikelHinzufuegen) {
            ArtikelZuAbteilungHinzufuegenSheet(abteilung: abteilung)
        }
    }

    private func artikelEntfernen(at offsets: IndexSet) {
        for index in offsets {
            let artikel = zugeordneteArtikel[index]
            var aktuelle = artikel.abteilungen
            aktuelle.removeAll { $0 == abteilung }
            artikel.abteilungen = aktuelle
        }
    }
}

/// Sheet zum Zuordnen bestehender ``Artikel`` zu ``abteilung`` — aufrufbar aus
/// ``AbteilungBearbeitenView``. Tippen auf einen Artikel ordnet ihn sofort zu
/// (kein zusätzlicher Bestätigungsschritt, analog ``AbteilungHinzufuegenSheet``).
/// Nutzt die generische ``AuswahlSheet`` (GitHub #130) analog
/// ``AbteilungHinzufuegenSheet``/``AbteilungHinzufuegenSheet`` — hier ohne
/// Neuanlage-Option, da jeder Artikel bereits vorher über die
/// Artikel-Verwaltung angelegt werden muss.
private struct ArtikelZuAbteilungHinzufuegenSheet: View {
    let abteilung: Abteilung

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    /// Die eigentliche Zuordnung passiert verzögert über ``onChange(of:)``
    /// statt direkt im Binding-Setter — siehe ausführliche Begründung in
    /// ``AbteilungHinzufuegenSheet`` (Live-Fund: Sheet flackerte auf/zu).
    @State private var geradeAusgewaehlt: Set<Artikel.ID> = []

    private var nichtZugeordneteArtikel: [Artikel] {
        alleArtikel.filter { !$0.abteilungen.contains(abteilung) }
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
        var aktuelle = artikel.abteilungen
        guard !aktuelle.contains(abteilung) else { return }
        aktuelle.append(abteilung)
        artikel.abteilungen = aktuelle
    }
}

#Preview {
    NavigationStack {
        AbteilungenVerwaltungView()
    }
    .modelContainer(for: [Abteilung.self, GeschaeftTyp.self, Artikel.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
