import SwiftUI
import SwiftData

/// Zeigt per KI erkannte, potenzielle Artikel-Dubletten/-Varianten an und lässt
/// den Anwender pro Vorschlag entscheiden, ob der verwandte Artikel als Alias
/// (alternativer Name) oder als konkretes ``Produkt`` des primären Artikels
/// aufgelöst wird — GitHub #133, aufgerufen aus ``ArtikelListView``.
///
/// Anfrage läuft **je Abteilung** (nicht über den gesamten Bestand in einer
/// Anfrage) — Dubletten/Varianten liegen praktisch immer in derselben Abteilung,
/// das hält den KI-Kontext klein und die Trefferqualität hoch (siehe
/// ``AISuggestionService/artikelBeziehungsVorschlaege(fuerArtikelNamen:)``).
struct ArtikelDuplikatVorschlaegeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]

    @State private var vorschlaege: [Vorschlag] = []
    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var bereitsGesucht = false
    @State private var geprueftGruppenAnzahl = 0
    @State private var gesamtGruppenAnzahl = 0

    private struct Vorschlag: Identifiable {
        let id = UUID()
        let primaer: Artikel
        let verwandter: Artikel
        var modus: Modus
        let begruendung: String

        enum Modus: String, CaseIterable, Identifiable {
            case alias = "Alias"
            case produkt = "Produkt"
            var id: String { rawValue }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if kiVorschlagLaeuft {
                    VStack(alignment: .leading, spacing: 6) {
                        if gesamtGruppenAnzahl > 0 {
                            ProgressView(value: Double(geprueftGruppenAnzahl), total: Double(gesamtGruppenAnzahl))
                            Text("Apple Intelligence sucht nach Dubletten… (\(geprueftGruppenAnzahl) von \(gesamtGruppenAnzahl) Abteilungen)")
                        } else {
                            HStack {
                                ProgressView()
                                Text("Apple Intelligence sucht nach Dubletten…")
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if let kiFehlermeldung {
                    Text(kiFehlermeldung)
                        .foregroundStyle(.orange)
                }
                if vorschlaege.isEmpty, bereitsGesucht, !kiVorschlagLaeuft {
                    ContentUnavailableView(
                        "Keine Dubletten gefunden",
                        systemImage: "checkmark.circle",
                        description: Text("Apple Intelligence hat keine potenziellen Dubletten oder Varianten erkannt.")
                    )
                }
                ForEach(vorschlaege) { vorschlag in
                    vorschlagsZeile(vorschlag)
                }
            }
            .navigationTitle("Artikel-Dubletten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task {
                guard !bereitsGesucht else { return }
                await kiVorschlagAnfordern()
            }
        }
    }

    @ViewBuilder
    private func vorschlagsZeile(_ vorschlag: Vorschlag) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{201E}\(vorschlag.verwandter.name)\u{201C} → \u{201E}\(vorschlag.primaer.name)\u{201C}")
                        .font(.headline)
                    Text(vorschlag.begruendung)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("Behandeln als", selection: binding(fuer: vorschlag)) {
                ForEach(Vorschlag.Modus.allCases) { modus in
                    Text(modus.rawValue).tag(modus)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(role: .destructive) {
                    verwerfen(vorschlag)
                } label: {
                    Text("Verwerfen")
                }
                Spacer()
                Button {
                    uebernehmen(vorschlag)
                } label: {
                    Text("Übernehmen")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func binding(fuer vorschlag: Vorschlag) -> Binding<Vorschlag.Modus> {
        Binding(
            get: { vorschlaege.first { $0.id == vorschlag.id }?.modus ?? vorschlag.modus },
            set: { neuerModus in
                guard let index = vorschlaege.firstIndex(where: { $0.id == vorschlag.id }) else { return }
                vorschlaege[index].modus = neuerModus
            }
        )
    }

    private func kiVorschlagAnfordern() async {
        kiFehlermeldung = nil
        kiVorschlagLaeuft = true
        bereitsGesucht = true
        geprueftGruppenAnzahl = 0
        gesamtGruppenAnzahl = 0
        defer { kiVorschlagLaeuft = false }

        guard AISuggestionService.istVerfuegbar else {
            kiFehlermeldung = "Apple Intelligence ist auf diesem Gerät nicht verfügbar."
            return
        }

        let gruppen = Dictionary(grouping: alleArtikel) { artikel in
            artikel.effektiveAbteilungen(context: modelContext).first?.persistentModelID
        }
        let zuPruefendeGruppen = gruppen.values.filter { $0.count > 1 }
        gesamtGruppenAnzahl = zuPruefendeGruppen.count

        var gefundene: [Vorschlag] = []
        var trafFehler = false
        for gruppenArtikel in zuPruefendeGruppen {
            defer { geprueftGruppenAnzahl += 1 }
            do {
                let rohVorschlaege = try await AISuggestionService.artikelBeziehungsVorschlaege(
                    fuerArtikelNamen: gruppenArtikel.map(\.name)
                )
                for roh in rohVorschlaege {
                    guard let primaer = gruppenArtikel.first(where: { $0.name.localizedCaseInsensitiveCompare(roh.primaerName) == .orderedSame }),
                          let verwandter = gruppenArtikel.first(where: { $0.name.localizedCaseInsensitiveCompare(roh.verwandterName) == .orderedSame }),
                          primaer.persistentModelID != verwandter.persistentModelID
                    else { continue }
                    gefundene.append(Vorschlag(
                        primaer: primaer,
                        verwandter: verwandter,
                        modus: roh.istDuplikat ? .alias : .produkt,
                        begruendung: roh.begruendung
                    ))
                }
            } catch {
                trafFehler = true
            }
        }
        vorschlaege = gefundene
        if trafFehler && gefundene.isEmpty {
            kiFehlermeldung = "KI-Vorschlag fehlgeschlagen."
        }
    }

    private func uebernehmen(_ vorschlag: Vorschlag) {
        let primaerReferenz = ModelReference(vorschlag.primaer)
        let verwandterReferenz = ModelReference(vorschlag.verwandter)
        let modus = vorschlag.modus
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let primaer = primaerReferenz.resolved(in: modelContext),
                      let verwandter = verwandterReferenz.resolved(in: modelContext)
                else { return }
                switch modus {
                case .alias:
                    ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: modelContext)
                case .produkt:
                    ArtikelZusammenfuehrungsService.alsProduktKonvertieren(verwandter, unter: primaer, context: modelContext)
                }
            }
            vorschlaege.removeAll { $0.id == vorschlag.id }
        }
    }

    private func verwerfen(_ vorschlag: Vorschlag) {
        vorschlaege.removeAll { $0.id == vorschlag.id }
    }
}

#Preview {
    ArtikelDuplikatVorschlaegeView()
        .modelContainer(for: [Artikel.self, Abteilung.self, GeschaeftTyp.self, Produkt.self], inMemory: true)
}
