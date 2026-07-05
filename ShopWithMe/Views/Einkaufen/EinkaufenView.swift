import SwiftUI
import SwiftData

/// Einstiegspunkt zum Einkaufen: zeigt sofort beim Öffnen die aktuelle globale
/// Einkaufsliste an — optional gruppiert nach Regal eines gewählten Geschäfts. Ein
/// passender ``Einkaufsvorgang`` (für das gewählte Geschäft, oder ohne Geschäft) wird
/// dafür automatisch angelegt, sobald keiner läuft; ein manueller "Start" ist nicht
/// nötig, Artikel lassen sich jederzeit abhaken.
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
                    ProgressView()
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
        .onAppear { Task { await einkaufSicherstellen() } }
        .onChange(of: ausgewaehltesGeschaeft) { _, _ in Task { await einkaufSicherstellen() } }
    }

    /// Legt bei Bedarf einen neuen ``Einkaufsvorgang`` für das aktuell gewählte
    /// Geschäft (bzw. ohne Geschäft) an, damit die Einkaufsliste immer sofort
    /// angezeigt wird. Diskrete Einzelaktion → Micro-Lease (siehe
    /// `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
    private func einkaufSicherstellen() async {
        guard aktuellerEinkauf == nil else { return }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            let vorgang = Einkaufsvorgang(geschaeft: ausgewaehltesGeschaeft)
            modelContext.insert(vorgang)
        }
    }
}

/// Wie die Einkaufsliste eines laufenden Einkaufsvorgangs angezeigt wird.
private enum EinkaufsAnzeigeModus: String, CaseIterable, Identifiable {
    /// Nur noch offene, für das gewählte Geschäft verfügbare Artikel (Standard).
    case offene
    /// Zusätzlich die in diesem Einkauf bereits abgehakten Artikel.
    case mitAbgehakten
    /// Lernmodus: zeigt alle auf der globalen Einkaufsliste gespeicherten Artikel,
    /// unabhängig vom Verfügbarkeitsfilter des Geschäfts
    /// (``Geschaeft/artikelFilterModus``) — zum Entdecken und Abhaken bislang
    /// unbekannter Artikel, die dadurch für dieses Geschäft als verfügbar gelernt
    /// werden (siehe ``ArtikelVerfuegbarkeitService``).
    case lernmodus

    var id: String { rawValue }

    var anzeigename: String {
        switch self {
        case .offene: return "Nur offene"
        case .mitAbgehakten: return "Auch abgehakte Artikel"
        case .lernmodus: return "Lernmodus (alle Artikel)"
        }
    }
}

/// Die global gültige Einkaufsliste für einen laufenden Einkaufsvorgang — bei
/// gewähltem Geschäft nach Regal gruppiert, sonst flach.
private struct EinkaufslisteView: View {
    let geschaeft: Geschaeft?
    let einkaufsvorgang: Einkaufsvorgang

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Environment(\.modelContext) private var modelContext

    @State private var zeigeBelegScanAngebot = false
    @State private var zeigeBelegScan = false
    @State private var zeigeArtikelHinzufuegen = false
    /// Wie die Einkaufsliste dieses Einkaufsvorgangs gerade angezeigt wird — siehe
    /// ``EinkaufsAnzeigeModus``.
    @State private var anzeigeModus: EinkaufsAnzeigeModus = .offene

    private var abgehakteArtikelIDs: Set<PersistentIdentifier> {
        Set(einkaufsvorgang.kaufEintraege.compactMap { $0.artikel?.persistentModelID })
    }

    /// Artikel, die noch auf der globalen Einkaufsliste stehen.
    private var offeneArtikel: [Artikel] {
        alleArtikel.filter(\.istAufEinkaufsliste)
    }

    /// Artikel, die in diesem Einkaufsvorgang bereits abgehakt wurden.
    private var abgehakteArtikel: [Artikel] {
        alleArtikel.filter { abgehakteArtikelIDs.contains($0.persistentModelID) }
    }

    /// Ist ein Geschäft gewählt und dessen ``Geschaeft/artikelFilterModus`` auf
    /// ``ArtikelFilterModus/nurVerfuegbare`` gestellt (Standard), blendet dies Artikel
    /// aus, die in diesem Geschäft (noch) nicht als verfügbar gelten (siehe
    /// ``ArtikelVerfuegbarkeitService``). Im ``EinkaufsAnzeigeModus/lernmodus`` wird
    /// dieser Filter für diesen Einkauf übergangen.
    private func verfuegbarkeitsgefiltert(_ artikel: [Artikel]) -> [Artikel] {
        guard let geschaeft, geschaeft.artikelFilterModus == .nurVerfuegbare else { return artikel }
        return artikel.filter { ArtikelVerfuegbarkeitService.istVerfuegbar($0, in: geschaeft, context: modelContext) }
    }

    /// Die aktuell darzustellenden Artikel — abhängig von ``anzeigeModus``.
    private var artikelAufListe: [Artikel] {
        switch anzeigeModus {
        case .offene:
            return verfuegbarkeitsgefiltert(offeneArtikel)
        case .mitAbgehakten:
            return verfuegbarkeitsgefiltert(offeneArtikel + abgehakteArtikel)
        case .lernmodus:
            return offeneArtikel
        }
    }

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
        let reihenfolge = ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: modelContext)
        let position = Dictionary(uniqueKeysWithValues: reihenfolge.enumerated().map { ($1.persistentModelID, $0) })
        return nachRegal.values.sorted {
            (position[$0.regal.persistentModelID] ?? .max) < (position[$1.regal.persistentModelID] ?? .max)
        }
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
                            umschalten: { umschalten(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
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
                            umschalten: { umschalten(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
                        )
                    }
                }
            }

            if artikelAufListe.isEmpty {
                if anzeigeModus != .lernmodus, !offeneArtikel.isEmpty {
                    ContentUnavailableView(
                        "Keine verfügbaren Artikel",
                        systemImage: "checklist",
                        description: Text("Wähle oben unter „Anzeige“ den „Lernmodus“, um bislang unbekannte Artikel abzuhaken.")
                    )
                } else if abgehakteArtikel.isEmpty {
                    ContentUnavailableView(
                        "Einkaufsliste ist leer",
                        systemImage: "checklist",
                        description: Text("Markiere Artikel im Artikel-Tab als „Auf Einkaufsliste“.")
                    )
                } else {
                    ContentUnavailableView(
                        "Alles erledigt",
                        systemImage: "checkmark.circle.fill",
                        description: Text("Wähle oben unter „Anzeige“ „Auch abgehakte Artikel“, um sie zu sehen.")
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Einkauf abschließen") {
                Task {
                    // Abschließen + Lernschritt sind fachlich eine Aktion → ein
                    // gemeinsamer Micro-Lease statt zwei getrennter (siehe
                    // `docs/DATABASE_CONCURRENCY.md` → „Gebündelte Aktionen“).
                    await DatabaseLeaseService.performMicroLease(context: modelContext) {
                        einkaufsvorgang.abschliessen()
                        ShelfOrderLearningService.lernenAus(einkaufsvorgang, context: modelContext)
                    }
                    zeigeBelegScanAngebot = true
                }
            }
            .buttonStyle(.glass)
            .padding()
        }
        .navigationTitle(geschaeft?.name ?? "Einkaufsliste")
        .toolbar {
            if !abgehakteArtikel.isEmpty || geschaeft?.artikelFilterModus == .nurVerfuegbare {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Anzeige", selection: $anzeigeModus) {
                        ForEach(EinkaufsAnzeigeModus.allCases) { modus in
                            Text(modus.anzeigename).tag(modus)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
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
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if istAbgehakt(artikel) {
                    einkaufsvorgang.artikelAbwaehlen(artikel, context: modelContext)
                } else {
                    einkaufsvorgang.artikelAbhaken(artikel, context: modelContext)
                }
            }
        }
    }

    private func entferneDauerhaft(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                einkaufsvorgang.artikelDauerhaftEntfernen(artikel, context: modelContext)
            }
        }
    }
}

/// Eine antippbare Zeile zum Abhaken eines Artikels beim Einkaufen. Ist der Artikel
/// bereits abgehakt, bietet eine Swipe-Aktion an, ihn dauerhaft aus dieser Ansicht zu
/// entfernen (``dauerhaftEntfernen``, `nil` bei noch offenen Artikeln).
private struct ArtikelAbhakZeile: View {
    let artikel: Artikel
    let istAbgehakt: Bool
    let umschalten: () -> Void
    var dauerhaftEntfernen: (() -> Void)?

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
        .swipeActions(edge: .trailing) {
            if let dauerhaftEntfernen {
                Button(role: .destructive, action: dauerhaftEntfernen) {
                    Label("Dauerhaft entfernen", systemImage: "trash")
                }
            }
        }
    }
}

#Preview {
    EinkaufenView()
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self, Artikel.self, Einkaufsvorgang.self], inMemory: true)
}
