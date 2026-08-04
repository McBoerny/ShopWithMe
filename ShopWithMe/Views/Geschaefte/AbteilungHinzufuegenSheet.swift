import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen einer ``ArtikelKategorie`` zu einem ``Geschaeft``, aufrufbar
/// aus ``GeschaeftAbteilungenSektion``.
///
/// Eine Kategorie wird beim Antippen direkt diesem Geschäft zugeordnet
/// (``Geschaeft/kategorien``) und damit sofort verfügbar.
struct AbteilungHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false

    /// Kategorien, die in diesem Geschäft noch nicht verfügbar sind — Kategorien,
    /// die bereits über den Geschäftstyp automatisch verfügbar sind (siehe
    /// ``Geschaeft/verfuegbareKategorien(alleKategorien:)``), werden hier nicht
    /// nochmal zum manuellen Hinzufügen angeboten.
    private var nichtVerfuegbareKategorien: [ArtikelKategorie] {
        let verfuegbareIDs = Set(geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien).map(\.persistentModelID))
        return alleKategorien.filter { !verfuegbareIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        SessionLeaseGate { navigationInhalt }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(nichtVerfuegbareKategorien) { kategorie in
                        Button {
                            kategorieHinzufuegen(kategorie)
                        } label: {
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .foregroundStyle(.primary)
                        }
                    }

                    Button {
                        zeigeNeueKategorie = true
                    } label: {
                        Label("Neue Abteilung anlegen", systemImage: "plus")
                    }
                } header: {
                    Text("Verfügbare Abteilungen")
                } footer: {
                    Text("Bereits in diesem Geschäft verfügbare Abteilungen werden hier nicht angeboten.")
                }
            }
            .navigationTitle("Abteilung hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $zeigeNeueKategorie) {
                NeueAbteilungSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                    kategorieHinzufuegen(kategorie)
                }
            }
        }
    }

    private func kategorieHinzufuegen(_ kategorie: ArtikelKategorie) {
        geschaeft.kategorien.append(kategorie)
        // Falls die Kategorie zuvor als automatisch-über-Geschäftstyp
        // ausgeschlossen war (GitHub #43): Ausschluss aufräumen, da sie jetzt
        // ohnehin direkt zugeordnet ist — sonst bliebe ein wirkungsloser,
        // verwaister Eintrag in `ausgeschlosseneKategorien` stehen.
        geschaeft.ausgeschlosseneKategorien.removeAll { $0 == kategorie }
    }
}

#Preview {
    AbteilungHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, ArtikelKategorie.self], inMemory: true)
}
