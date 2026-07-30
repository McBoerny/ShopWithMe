import SwiftUI
import SwiftData

/// „Kategorien“-Formularabschnitt eines ``Geschaeft``s — zeigt alle verfügbaren
/// Kategorien (``Geschaeft/verfuegbareKategorien(alleKategorien:)``, GitHub #37),
/// manuell zugeordnete und über den Geschäftstyp automatische gemeinsam,
/// alphabetisch, automatische Kategorien speziell markiert und nicht direkt
/// entfernbar.
///
/// Wiederverwendet in ``GeschaeftDetailView`` (bestehendes Geschäft) und in
/// ``GeschaeftStammdatenEditView`` beim erstmaligen Anlegen (GitHub #56) — damit
/// sich Warengruppen bereits beim Akzeptieren eines per Geolocation neu
/// erkannten Geschäfts verfeinern lassen, statt erst nachträglich über die
/// Detailansicht.
struct GeschaeftKategorienSektion: View {
    @Bindable var geschaeft: Geschaeft
    @Query private var alleKategorien: [ArtikelKategorie]
    @State private var zeigeKategorieHinzufuegen = false

    private var kategorienAnzeige: [(kategorie: ArtikelKategorie, automatisch: Bool)] {
        geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien)
            .sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
            .map { ($0, !geschaeft.kategorien.contains($0)) }
    }

    var body: some View {
        Section {
            ForEach(kategorienAnzeige, id: \.kategorie.id) { eintrag in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eintrag.kategorie.name)
                        if eintrag.automatisch {
                            Text("Automatisch über Geschäftstyp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: eintrag.kategorie.standardSymbol)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if eintrag.automatisch {
                        Button(role: .destructive) {
                            kategorieAusschliessen(eintrag.kategorie)
                        } label: {
                            Label("Ausschließen", systemImage: "eye.slash")
                        }
                    } else {
                        Button(role: .destructive) {
                            kategorieEntfernen(eintrag.kategorie)
                        } label: {
                            Label("Entfernen", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                zeigeKategorieHinzufuegen = true
            } label: {
                Label("Kategorie hinzufügen", systemImage: "plus")
            }
        } header: {
            Text("Kategorien")
        } footer: {
            Text("Kategorien sind sofort verfügbar. Die Reihenfolge beim Einkaufen lernt die App automatisch aus deinem bisherigen Abhakverhalten. Automatisch über den Geschäftstyp verfügbare Kategorien lassen sich für dieses eine Geschäft ausschließen, ohne sie generell vom Geschäftstyp zu entfernen — sie tauchen danach wieder unter „Kategorie hinzufügen“ auf. Manuell zugeordnete Kategorien: zum Entfernen nach links wischen.")
        }
        .sheet(isPresented: $zeigeKategorieHinzufuegen) {
            KategorieHinzufuegenSheet(geschaeft: geschaeft)
        }
    }

    private func kategorieEntfernen(_ kategorie: ArtikelKategorie) {
        geschaeft.kategorien.removeAll { $0 == kategorie }
    }

    /// Schließt eine automatisch über den Geschäftstyp verfügbare Kategorie für
    /// dieses eine Geschäft aus (GitHub #43), ohne sie generell vom Geschäftstyp
    /// zu entfernen. Taucht danach wieder in ``KategorieHinzufuegenSheet`` auf.
    private func kategorieAusschliessen(_ kategorie: ArtikelKategorie) {
        guard !geschaeft.ausgeschlosseneKategorien.contains(kategorie) else { return }
        geschaeft.ausgeschlosseneKategorien.append(kategorie)
    }
}

#Preview {
    Form {
        GeschaeftKategorienSektion(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, ArtikelKategorie.self], inMemory: true)
}
