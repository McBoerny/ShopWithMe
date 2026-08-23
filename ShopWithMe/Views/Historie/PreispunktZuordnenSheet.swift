import SwiftUI
import SwiftData

/// Sheet zum Vergeben eines Anzeigenamens und/oder Umordnen (Korrektur) eines
/// übergreifenden ``Artikel``s für einen einzelnen ``Preispunkt`` — siehe
/// `docs/BELEGSCAN.md`. Seit der Produkt-Pflicht (siehe ``Preispunkt``-Typ-Doku)
/// hat jeder Preispunkt bereits eine Zuordnung; dieses Sheet dient nur noch
/// der nachträglichen Korrektur (z.B. falsch erkannter Artikel).
/// Vormals `KaufEintragZuordnenSheet` (GitHub #76 — Preishistorie-Rolle von
/// ``KaufEintrag`` nach ``Preispunkt`` verschoben).
///
/// Existiert der gewünschte Artikel noch nicht, lässt er sich direkt hier über die
/// bestehende ``ArtikelEditView`` anlegen und wird danach automatisch ausgewählt.
///
/// Löst über ``Produkt/aufgeloestesOderNeuesProdukt(klarname:erkannterName:artikel:geschaeft:context:)``
/// zusätzlich ein konkretes ``Produkt`` auf/legt es an und lernt dabei den
/// erkannten Rohtext als ``Produktname`` — damit künftige Beleg-/Preisschild-
/// Scans desselben erkannten Namens ihn automatisch wiederfinden (GitHub #128,
/// ersetzt das frühere `ArtikelAlias`).
struct PreispunktZuordnenSheet: View {
    let eintrag: Preispunkt

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var aliasText: String
    @State private var ausgewaehlterArtikel: Artikel?
    @State private var zeigeArtikelAuswahl = false

    init(eintrag: Preispunkt) {
        self.eintrag = eintrag
        _aliasText = State(initialValue: eintrag.alternativerName ?? "")
        _ausgewaehlterArtikel = State(initialValue: eintrag.artikel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Anzeigename", text: $aliasText)
                } header: {
                    Text("Anzeigename")
                } footer: {
                    Text("Ersetzt ab sofort überall den erkannten Namen „\(eintrag.produktName ?? eintrag.produktNameSicher)“ dieser Position.")
                }

                Section {
                    Button {
                        zeigeArtikelAuswahl = true
                    } label: {
                        HStack {
                            Text("Artikel")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(ausgewaehlterArtikel?.name ?? "Bitte w\u{00E4}hlen")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Artikel")
                } footer: {
                    Text("Ordnet diese Belegposition dauerhaft einem übergreifenden Artikel zu — Grundlage für die Preisübersicht des Geschäfts und künftige Belegscans desselben Produkts.")
                }
            }
            .navigationTitle("Position zuordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: speichern)
                        .disabled(ausgewaehlterArtikel == nil)
                }
            }
            .sheet(isPresented: $zeigeArtikelAuswahl) {
                ArtikelAuswahlSheet(gewaehlterArtikel: $ausgewaehlterArtikel)
            }
        }
    }

    private func speichern() {
        let getrimmterAlias = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        let erkannterName = eintrag.produktName ?? eintrag.produktNameSicher
        // Nur die Identität über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — zwischen dem Erwerb des Micro-Lease und dieser
        // Zuweisung kann ein nebenläufiger Sync-Zyklus genau diesen Artikel
        // (per Tombstone eines Peers) gelöscht haben.
        let eintragReferenz = ModelReference(eintrag)
        let artikelReferenz = ModelReference(ausgewaehlterArtikel)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                // Produkt-Pflicht: ohne (noch) auflösbaren Artikel lässt sich
                // kein Produkt bestimmen — der Preispunkt bleibt dann bei
                // seiner bisherigen Zuordnung unverändert, statt sie zu
                // verlieren.
                guard let eintragFrisch = eintragReferenz.resolved(in: modelContext),
                      let artikel = artikelReferenz?.resolved(in: modelContext)
                else { return }
                let alias = getrimmterAlias.isEmpty ? nil : getrimmterAlias
                eintragFrisch.alternativerName = alias
                if !erkannterName.isEmpty {
                    let klarname = getrimmterAlias.isEmpty ? erkannterName : getrimmterAlias
                    eintragFrisch.produkt = Produkt.aufgeloestesOderNeuesProdukt(
                        klarname: klarname, erkannterName: erkannterName, artikel: artikel,
                        geschaeft: eintragFrisch.geschaeft, context: modelContext
                    )
                } else {
                    eintragFrisch.produkt = Produkt.standardProdukt(fuer: artikel, context: modelContext)
                }
            }
            dismiss()
        }
    }
}

#Preview {
    let artikel = Artikel(name: "Zahnpasta", symbolName: "circle", farbeHex: "#34C759")
    let geschaeft = Geschaeft(name: "Rewe", typen: [])
    let produkt = Produkt(name: "COL-ZAH", artikel: artikel)
    let eintrag = Preispunkt(produkt: produkt, geschaeft: geschaeft, preis: 2.49)
    eintrag.produktName = "COL-ZAH"
    return PreispunktZuordnenSheet(eintrag: eintrag)
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Preispunkt.self, Produkt.self, Produktname.self], inMemory: true)
}
