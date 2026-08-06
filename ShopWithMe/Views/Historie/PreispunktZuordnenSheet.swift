import SwiftUI
import SwiftData

/// Sheet zum Vergeben eines Alias-Namens und/oder Zuordnen eines übergreifenden
/// ``Artikel``s für einen einzelnen ``Preispunkt`` — siehe `docs/BELEGSCAN.md`.
/// Vormals `KaufEintragZuordnenSheet` (GitHub #76 — Preishistorie-Rolle von
/// ``KaufEintrag`` nach ``Preispunkt`` verschoben).
///
/// Existiert der gewünschte Artikel noch nicht, lässt er sich direkt hier über die
/// bestehende ``ArtikelEditView`` anlegen und wird danach automatisch ausgewählt.
///
/// Speichert die Zuordnung zusätzlich als ``ArtikelAlias``, damit künftige
/// Beleg-/Preisschild-Scans desselben erkannten Namens sie automatisch
/// wiederfinden (ersetzt die frühere Suche über die komplette Kaufhistorie,
/// siehe ``ArtikelZuordnungsService``).
struct PreispunktZuordnenSheet: View {
    let eintrag: Preispunkt

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]

    @State private var aliasText: String
    @State private var ausgewaehlterArtikel: Artikel?
    @State private var suchtext = ""
    @State private var neuerArtikelEntwurf: Artikel?

    init(eintrag: Preispunkt) {
        self.eintrag = eintrag
        _aliasText = State(initialValue: eintrag.alternativerName ?? "")
        _ausgewaehlterArtikel = State(initialValue: eintrag.artikel)
    }

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
                Section {
                    TextField("Alias-Name", text: $aliasText)
                } header: {
                    Text("Alias")
                } footer: {
                    Text("Ersetzt ab sofort überall den erkannten Namen „\(eintrag.produktName ?? eintrag.artikelNameSnapshot)“ dieser Position.")
                }

                Section {
                    Button {
                        ausgewaehlterArtikel = nil
                    } label: {
                        HStack {
                            Text("Keine Zuordnung")
                                .foregroundStyle(.primary)
                            Spacer()
                            if ausgewaehlterArtikel == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !getrimmterSuchtext.isEmpty && !existiertGenau {
                        Button {
                            neuenArtikelAnlegen()
                        } label: {
                            Label("„\(getrimmterSuchtext)“ neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }

                    ForEach(gefilterteArtikel) { artikel in
                        Button {
                            ausgewaehlterArtikel = artikel
                        } label: {
                            HStack {
                                Text(artikel.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if ausgewaehlterArtikel?.id == artikel.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Artikel")
                } footer: {
                    Text("Ordnet diese Belegposition dauerhaft einem übergreifenden Artikel zu — Grundlage für die Preisübersicht des Geschäfts und künftige Belegscans desselben Produkts.")
                }
            }
            .searchable(text: $suchtext, prompt: "Artikel suchen oder anlegen")
            .navigationTitle("Position zuordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: speichern)
                }
            }
            .sheet(item: $neuerArtikelEntwurf, onDismiss: nachNeuanlageAufraeumen) { entwurf in
                ArtikelEditView(artikel: entwurf, istNeu: true)
            }
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
    /// eingefügt), wählt ihn dieses Sheet direkt als Zuordnung aus — siehe
    /// ``ArtikelHinzufuegenView`` für dasselbe Muster.
    private func nachNeuanlageAufraeumen() {
        guard let entwurf = neuerArtikelEntwurf, entwurf.modelContext != nil else {
            neuerArtikelEntwurf = nil
            return
        }
        ausgewaehlterArtikel = entwurf
        neuerArtikelEntwurf = nil
    }

    private func speichern() {
        let getrimmterAlias = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        let erkannterName = eintrag.produktName ?? eintrag.artikelNameSnapshot
        // Nur die Identität über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — zwischen dem Erwerb des Micro-Lease und dieser
        // Zuweisung kann ein nebenläufiger Sync-Zyklus genau diesen Artikel
        // (per Tombstone eines Peers) gelöscht haben.
        let eintragReferenz = ModelReference(eintrag)
        let artikelReferenz = ModelReference(ausgewaehlterArtikel)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let eintragFrisch = eintragReferenz.resolved(in: modelContext) else { return }
                let artikel = artikelReferenz?.resolved(in: modelContext)
                let alias = getrimmterAlias.isEmpty ? nil : getrimmterAlias
                eintragFrisch.alternativerName = alias
                eintragFrisch.artikel = artikel
                eintragFrisch.produkt = artikel.map { Produkt.standardProdukt(fuer: $0, context: modelContext) }
                if !erkannterName.isEmpty {
                    ArtikelAlias.lernen(erkannterName: erkannterName, alternativerName: alias, artikel: artikel, context: modelContext)
                }
            }
            dismiss()
        }
    }
}

#Preview {
    let eintrag = Preispunkt(artikel: nil, geschaeft: nil, preis: 2.49)
    eintrag.artikelNameSnapshot = "COL-ZAH"
    eintrag.produktName = "COL-ZAH"
    return PreispunktZuordnenSheet(eintrag: eintrag)
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Preispunkt.self, ArtikelAlias.self, Produkt.self, Produktname.self], inMemory: true)
}
