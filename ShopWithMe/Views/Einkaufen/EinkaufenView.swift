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
    @State private var zeigeArtikelHinzufuegen = false

    private struct Gruppe: Identifiable {
        let regal: Regal
        var artikel: [Artikel]
        var id: PersistentIdentifier { regal.persistentModelID }
    }

    /// Eine Gruppe von Artikeln derselben Artikelkategorie, die sich keinem Regal
    /// zuordnen lässt — z.B. weil das Geschäft keine Regale besitzt oder die
    /// Kategorie darin keinem Regal zugeordnet ist. Artikel ohne eigene Kategorie
    /// fallen dabei automatisch in die Kategorie "Sonstiges" (siehe
    /// ``Artikel/effektiveKategorie(context:)``).
    private struct KategorieGruppe: Identifiable {
        let kategorie: ArtikelKategorie
        var artikel: [Artikel]
        var id: PersistentIdentifier { kategorie.persistentModelID }
    }

    private func effektiveKategorie(fuer artikel: Artikel) -> ArtikelKategorie {
        artikel.effektiveKategorie(context: modelContext)
    }

    /// Artikel, die sich keinem Regal zuordnen lassen (kein Geschäft gewählt oder
    /// die Kategorie darin keinem Regal zugeordnet) — werden dennoch angezeigt, nur
    /// eben in nach Kategorie gruppierten Sektionen.
    private var sonstigeArtikel: [Artikel] {
        guard let geschaeft else { return artikelAufListe }
        return artikelAufListe.filter { geschaeft.regal(fuer: effektiveKategorie(fuer: $0)) == nil }
    }

    private var gruppen: [Gruppe] {
        guard let geschaeft else { return [] }
        var nachRegal: [PersistentIdentifier: Gruppe] = [:]
        for artikel in artikelAufListe {
            guard let regal = geschaeft.regal(fuer: effektiveKategorie(fuer: artikel)) else { continue }
            nachRegal[regal.persistentModelID, default: Gruppe(regal: regal, artikel: [])].artikel.append(artikel)
        }
        return nachRegal.values.sorted { $0.regal.sortIndex < $1.regal.sortIndex }
    }

    /// ``sonstigeArtikel``, gruppiert nach Artikelkategorie und sortiert nach der für
    /// dieses Geschäft gelernten Kategorie-Reihenfolge (``ShelfOrderLearningService``).
    /// Das ist insbesondere für Geschäfte ohne Regale die alleinige Sortiergrundlage.
    /// Kategorien ohne Beobachtung landen (alphabetisch sortiert) dahinter.
    private var sonstigeGruppen: [KategorieGruppe] {
        var nachKategorie: [PersistentIdentifier: KategorieGruppe] = [:]
        for artikel in sonstigeArtikel {
            let kategorie = effektiveKategorie(fuer: artikel)
            nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, artikel: [])].artikel.append(artikel)
        }
        let positionen = geschaeft.map { ShelfOrderLearningService.kategoriePositionen(fuer: $0, context: modelContext) } ?? [:]
        return nachKategorie.values.sorted { istVor($0, $1, positionen: positionen) }
    }

    private func istVor(_ a: KategorieGruppe, _ b: KategorieGruppe, positionen: [PersistentIdentifier: Double]) -> Bool {
        let posA = positionen[a.kategorie.persistentModelID] ?? .infinity
        let posB = positionen[b.kategorie.persistentModelID] ?? .infinity
        if posA == posB { return a.kategorie.name < b.kategorie.name }
        return posA < posB
    }

    var body: some View {
        List {
            ForEach(gruppen) { gruppe in
                Section(gruppe.regal.name) {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            istAbgehakt: istAbgehakt(artikel),
                            umschalten: { umschalten(artikel) }
                        )
                    }
                }
            }

            ForEach(sonstigeGruppen) { gruppe in
                Section(gruppe.kategorie.name) {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            istAbgehakt: istAbgehakt(artikel),
                            umschalten: { umschalten(artikel) }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeArtikelHinzufuegen = true
                } label: {
                    Label("Artikel hinzufügen", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $zeigeArtikelHinzufuegen) {
            ArtikelHinzufuegenView()
        }
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

    private func umschalten(_ artikel: Artikel) {
        if istAbgehakt(artikel) {
            einkaufsvorgang.artikelAbwaehlen(artikel, context: modelContext)
        } else {
            einkaufsvorgang.artikelAbhaken(artikel, context: modelContext)
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
