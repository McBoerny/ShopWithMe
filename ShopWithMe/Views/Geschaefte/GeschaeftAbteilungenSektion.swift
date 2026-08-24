import SwiftUI
import SwiftData

/// „Abteilungen“-Formularabschnitt eines ``Geschaeft``s — zeigt alle verfügbaren
/// Abteilungen (``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``, GitHub #37),
/// manuell zugeordnete und über den Geschäftstyp automatische gemeinsam,
/// alphabetisch, automatische Abteilungen speziell markiert und nicht direkt
/// entfernbar.
///
/// Wiederverwendet in ``GeschaeftDetailView`` (bestehendes Geschäft) und in
/// ``GeschaeftStammdatenEditView`` beim erstmaligen Anlegen (GitHub #56) — damit
/// sich Abteilungen bereits beim Akzeptieren eines per Geolocation neu
/// erkannten Geschäfts verfeinern lassen, statt erst nachträglich über die
/// Detailansicht.
struct GeschaeftAbteilungenSektion: View {
    @Bindable var geschaeft: Geschaeft
    @Query private var alleAbteilungen: [Abteilung]
    @State private var zeigeAbteilungHinzufuegen = false

    private var abteilungenAnzeige: [(abteilung: Abteilung, automatisch: Bool)] {
        geschaeft.verfuegbareAbteilungen(alleAbteilungen: alleAbteilungen)
            .sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
            .map { ($0, !geschaeft.abteilungen.contains($0)) }
    }

    var body: some View {
        Section {
            ForEach(abteilungenAnzeige, id: \.abteilung.id) { eintrag in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eintrag.abteilung.name)
                        if eintrag.automatisch {
                            Text("Automatisch über Geschäftstyp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: eintrag.abteilung.standardSymbol)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if eintrag.automatisch {
                        Button(role: .destructive) {
                            abteilungAusschliessen(eintrag.abteilung)
                        } label: {
                            Label("Ausschließen", systemImage: "eye.slash")
                        }
                    } else {
                        Button(role: .destructive) {
                            abteilungEntfernen(eintrag.abteilung)
                        } label: {
                            Label("Entfernen", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                zeigeAbteilungHinzufuegen = true
            } label: {
                Label("Abteilung hinzufügen", systemImage: "plus")
            }
            .accessibilityIdentifier(A11yID.GeschaeftAbteilungenSektion.hinzufuegenButton)
        } header: {
            Text("Abteilungen")
        } footer: {
            Text("Abteilungen sind sofort verfügbar. Die Reihenfolge beim Einkaufen lernt die App automatisch aus deinem bisherigen Abhakverhalten. Automatisch über den Geschäftstyp verfügbare Abteilungen lassen sich für dieses eine Geschäft ausschließen, ohne sie generell vom Geschäftstyp zu entfernen — sie tauchen danach wieder unter „Abteilung hinzufügen“ auf. Manuell zugeordnete Abteilungen: zum Entfernen nach links wischen.")
        }
        .sheet(isPresented: $zeigeAbteilungHinzufuegen) {
            AbteilungHinzufuegenSheet(geschaeft: geschaeft)
        }
    }

    private func abteilungEntfernen(_ abteilung: Abteilung) {
        geschaeft.abteilungen.removeAll { $0 == abteilung }
    }

    /// Schließt eine automatisch über den Geschäftstyp verfügbare Abteilung für
    /// dieses eine Geschäft aus (GitHub #43), ohne sie generell vom Geschäftstyp
    /// zu entfernen. Taucht danach wieder in ``AbteilungHinzufuegenSheet`` auf.
    private func abteilungAusschliessen(_ abteilung: Abteilung) {
        guard !geschaeft.ausgeschlosseneAbteilungen.contains(abteilung) else { return }
        geschaeft.ausgeschlosseneAbteilungen.append(abteilung)
    }
}

#Preview {
    Form {
        GeschaeftAbteilungenSektion(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Abteilung.self], inMemory: true)
}
