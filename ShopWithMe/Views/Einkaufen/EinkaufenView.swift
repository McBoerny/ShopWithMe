import SwiftUI
import SwiftData

/// Einstiegspunkt zum Einkaufen: die globale Einkaufsliste abarbeiten, optional
/// gruppiert nach Regal eines gewählten Geschäfts.
struct EinkaufenView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Query(filter: #Predicate<Einkaufsvorgang> { $0.endZeit == nil })
    private var offeneEinkaufsvorgaenge: [Einkaufsvorgang]
    @Environment(\.modelContext) private var modelContext

    @State private var ausgewaehltesGeschaeft: Geschaeft?

    private var aktuellerEinkauf: Einkaufsvorgang? {
        offeneEinkaufsvorgaenge.first { $0.geschaeft == ausgewaehltesGeschaeft }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let einkauf = aktuellerEinkauf {
                    EinkaufslisteView(geschaeft: ausgewaehltesGeschaeft, einkaufsvorgang: einkauf)
                } else {
                    EinkaufStartenView(geschaeft: ausgewaehltesGeschaeft) {
                        einkaufStarten(fuer: ausgewaehltesGeschaeft)
                    }
                }
            }
            .navigationTitle("Einkaufen")
            .toolbar {
                if !geschaefte.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker("Geschäft", selection: $ausgewaehltesGeschaeft) {
                            Text("Kein Geschäft").tag(Optional<Geschaeft>.none)
                            ForEach(geschaefte) { geschaeft in
                                Text(geschaeft.name).tag(Optional(geschaeft))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }

    private func einkaufStarten(fuer geschaeft: Geschaeft?) {
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        modelContext.insert(vorgang)
    }
}

/// Aufforderung, den Einkauf zu starten — optional für ein bestimmtes Geschäft.
private struct EinkaufStartenView: View {
    let geschaeft: Geschaeft?
    let start: () -> Void

    var body: some View {
        ContentUnavailableView {
            if let geschaeft {
                Label(geschaeft.name, systemImage: geschaeft.typ.symbolName)
            } else {
                Label("Einkaufsliste", systemImage: "cart.fill")
            }
        } description: {
            Text("Starte den Einkauf, um deine Einkaufsliste abzuarbeiten.")
        } actions: {
            Button("Einkauf starten", action: start)
                .buttonStyle(.glass)
        }
    }
}

/// Die global gültige Einkaufsliste für einen laufenden Einkaufsvorgang — bei
/// gewähltem Geschäft nach Regal gruppiert, sonst flach.
private struct EinkaufslisteView: View {
    let geschaeft: Geschaeft?
    let einkaufsvorgang: Einkaufsvorgang

    @Query(filter: #Predicate<Artikel> { $0.istAufEinkaufsliste }, sort: \Artikel.name)
    private var artikelAufListe: [Artikel]
    @Environment(\.modelContext) private var modelContext

    @State private var zeigeBelegScanAngebot = false
    @State private var zeigeBelegScan = false

    private struct Gruppe: Identifiable {
        let regal: Regal
        var artikel: [Artikel]
        var id: PersistentIdentifier { regal.persistentModelID }
    }

    /// Artikel, die sich keinem Regal zuordnen lassen (kein Geschäft gewählt,
    /// keine Kategorie oder Kategorie ohne Regal im gewählten Geschäft) — werden
    /// dennoch angezeigt, nur eben in der Sonstige-Sektion.
    private var sonstigeArtikel: [Artikel] {
        guard let geschaeft else { return artikelAufListe }
        return artikelAufListe.filter { artikel in
            guard let kategorie = artikel.kategorie else { return true }
            return geschaeft.regal(fuer: kategorie) == nil
        }
    }

    private var gruppen: [Gruppe] {
        guard let geschaeft else { return [] }
        var nachRegal: [PersistentIdentifier: Gruppe] = [:]
        for artikel in artikelAufListe {
            guard let kategorie = artikel.kategorie,
                  let regal = geschaeft.regal(fuer: kategorie) else { continue }
            nachRegal[regal.persistentModelID, default: Gruppe(regal: regal, artikel: [])].artikel.append(artikel)
        }
        return nachRegal.values.sorted { $0.regal.sortIndex < $1.regal.sortIndex }
    }

    var body: some View {
        List {
            ForEach(gruppen) { gruppe in
                Section(gruppe.regal.name) {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            istAbgehakt: istAbgehakt(artikel),
                            umschalten: { umschalten(artikel, regal: gruppe.regal) }
                        )
                    }
                }
            }

            if !sonstigeArtikel.isEmpty {
                Section(gruppen.isEmpty ? "Einkaufsliste" : "Sonstige") {
                    ForEach(sonstigeArtikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            istAbgehakt: istAbgehakt(artikel),
                            umschalten: { umschalten(artikel, regal: nil) }
                        )
                    }
                }
            }

            if artikelAufListe.isEmpty {
                ContentUnavailableView(
                    "Einkaufsliste ist leer",
                    systemImage: "checklist",
                    description: Text("Markiere Artikel im Artikel-Tab als „Auf Einkaufsliste“.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Einkauf abschließen") {
                einkaufsvorgang.abschliessen()
                ShelfOrderLearningService.lernenAus(einkaufsvorgang, context: modelContext)
                zeigeBelegScanAngebot = true
            }
            .buttonStyle(.glass)
            .padding()
        }
        .navigationTitle(geschaeft?.name ?? "Einkaufsliste")
        .confirmationDialog(
            "Einkauf abgeschlossen",
            isPresented: $zeigeBelegScanAngebot,
            titleVisibility: .visible
        ) {
            Button("Beleg jetzt scannen") { zeigeBelegScan = true }
            Button("Später", role: .cancel) {}
        } message: {
            Text("Möchtest du den Kassenbon scannen, um die Preise für diesen Einkauf zu erfassen?")
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView(einkaufsvorgang: einkaufsvorgang)
        }
    }

    private func istAbgehakt(_ artikel: Artikel) -> Bool {
        einkaufsvorgang.kaufEintraege.contains { $0.artikel == artikel }
    }

    private func umschalten(_ artikel: Artikel, regal: Regal?) {
        if istAbgehakt(artikel) {
            einkaufsvorgang.artikelAbwaehlen(artikel, context: modelContext)
        } else {
            einkaufsvorgang.artikelAbhaken(artikel, regal: regal, context: modelContext)
        }
    }
}

/// Eine antippbare Zeile zum Abhaken eines Artikels beim Einkaufen.
private struct ArtikelAbhakZeile: View {
    let artikel: Artikel
    let istAbgehakt: Bool
    let umschalten: () -> Void

    var body: some View {
        Button(action: umschalten) {
            HStack {
                GlassSymbolBadge(symbolName: artikel.symbolName, farbe: Color(hex: artikel.farbeHex), groesse: 36)
                Text(artikel.name)
                    .strikethrough(istAbgehakt)
                    .foregroundStyle(istAbgehakt ? .secondary : .primary)
                Spacer()
                Image(systemName: istAbgehakt ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(istAbgehakt ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EinkaufenView()
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self, Artikel.self, Einkaufsvorgang.self], inMemory: true)
}
