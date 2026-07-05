import SwiftUI
import SwiftData

/// Einstiegspunkt zum Einkaufen: zeigt sofort beim Öffnen die Einkaufsliste der
/// ausgewählten ``Einkaufsliste`` an — optional gruppiert nach Regal eines
/// gewählten Geschäfts. Ein passender ``Einkaufsvorgang`` (für die Kombination aus
/// gewählter Liste und gewähltem Geschäft) wird dafür automatisch angelegt, sobald
/// keiner läuft; ein manueller "Start" ist nicht nötig, Artikel lassen sich
/// jederzeit abhaken.
struct EinkaufenView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Query(sort: \Einkaufsliste.erstelltAm) private var einkaufslisten: [Einkaufsliste]
    @Query(filter: #Predicate<Einkaufsvorgang> { $0.endZeit == nil })
    private var offeneEinkaufsvorgaenge: [Einkaufsvorgang]
    @Environment(\.modelContext) private var modelContext

    @State private var ausgewaehltesGeschaeft: Geschaeft?
    @State private var ausgewaehlteListe: Einkaufsliste?
    @State private var zeigeNeueListe = false

    private var aktuellerEinkauf: Einkaufsvorgang? {
        guard let ausgewaehlteListe else { return nil }
        return offeneEinkaufsvorgaenge.first {
            $0.geschaeft == ausgewaehltesGeschaeft && $0.einkaufsliste == ausgewaehlteListe
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let ausgewaehlteListe, let einkauf = aktuellerEinkauf {
                    EinkaufslisteView(geschaeft: ausgewaehltesGeschaeft, einkaufsliste: ausgewaehlteListe, einkaufsvorgang: einkauf)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Einkaufen")
            .toolbar {
                if !einkaufslisten.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Einkaufsliste", selection: $ausgewaehlteListe) {
                                ForEach(einkaufslisten) { liste in
                                    Text(liste.name).tag(Optional(liste))
                                }
                            }
                            Button {
                                zeigeNeueListe = true
                            } label: {
                                Label("Neue Liste …", systemImage: "plus")
                            }
                        } label: {
                            Label(ausgewaehlteListe?.name ?? "Liste", systemImage: "checklist")
                        }
                    }
                }
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
        .onAppear {
            Task {
                await listeSicherstellen()
                await einkaufSicherstellen()
            }
        }
        .onChange(of: ausgewaehltesGeschaeft) { _, _ in Task { await einkaufSicherstellen() } }
        .onChange(of: ausgewaehlteListe) { _, _ in Task { await einkaufSicherstellen() } }
        // Reagiert darauf, dass ein Einkaufsvorgang abgeschlossen wurde (verschwindet
        // dadurch aus `offeneEinkaufsvorgaenge`): legt sofort den nächsten an, damit die
        // gerade abgehakten Artikel des beendeten Einkaufs aus der Ansicht verschwinden,
        // statt bis zum nächsten Tab-Wechsel als "ProgressView" hängen zu bleiben.
        .onChange(of: offeneEinkaufsvorgaenge.count) { _, _ in Task { await einkaufSicherstellen() } }
        .sheet(isPresented: $zeigeNeueListe) {
            NeueEinkaufslisteSheet { liste in
                ausgewaehlteListe = liste
            }
        }
    }

    /// Stellt sicher, dass ``ausgewaehlteListe`` gesetzt ist: übernimmt die erste
    /// vorhandene ``Einkaufsliste``, oder legt (falls noch keine existiert) über
    /// ``Einkaufsliste/standard(context:)`` eine erste an.
    private func listeSicherstellen() async {
        guard ausgewaehlteListe == nil else { return }
        if let erste = einkaufslisten.first {
            ausgewaehlteListe = erste
            return
        }
        var neue: Einkaufsliste?
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            neue = Einkaufsliste.standard(context: modelContext)
        }
        ausgewaehlteListe = neue
    }

    /// Legt bei Bedarf einen neuen ``Einkaufsvorgang`` für die aktuell gewählte
    /// Kombination aus Liste und Geschäft an, damit die Einkaufsliste immer sofort
    /// angezeigt wird. Diskrete Einzelaktion → Micro-Lease (siehe
    /// `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
    private func einkaufSicherstellen() async {
        guard let ausgewaehlteListe, aktuellerEinkauf == nil else { return }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            let vorgang = Einkaufsvorgang(geschaeft: ausgewaehltesGeschaeft, einkaufsliste: ausgewaehlteListe)
            modelContext.insert(vorgang)
        }
    }
}

/// Sheet zum Anlegen einer neuen ``Einkaufsliste`` — aufrufbar direkt aus dem
/// Listen-Menü in ``EinkaufenView`` für schnellen Zugriff während des Einkaufens.
private struct NeueEinkaufslisteSheet: View {
    let onErstellt: (Einkaufsliste) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, z.B. \"Wocheneinkauf\"", text: $name)
                    .font(.title3)
            }
            .navigationTitle("Neue Liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let liste = Einkaufsliste(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(liste)
                            }
                            onErstellt(liste)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Wie die Einkaufsliste eines laufenden Einkaufsvorgangs angezeigt wird.
private enum EinkaufsAnzeigeModus: String, CaseIterable, Identifiable {
    /// Nur noch offene, für das gewählte Geschäft verfügbare Artikel (Standard).
    case offene
    /// Zusätzlich die in diesem Einkauf bereits abgehakten Artikel.
    case mitAbgehakten
    /// Lernmodus: zeigt alle auf der Einkaufsliste gespeicherten Artikel,
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

/// Die Einkaufsliste einer ``Einkaufsliste`` für einen laufenden Einkaufsvorgang —
/// bei gewähltem Geschäft nach Regal gruppiert, sonst flach.
private struct EinkaufslisteView: View {
    let geschaeft: Geschaeft?
    let einkaufsliste: Einkaufsliste
    let einkaufsvorgang: Einkaufsvorgang

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

    /// Artikel, die noch auf ``einkaufsliste`` stehen.
    private var offeneArtikel: [Artikel] {
        einkaufsliste.eintraege.compactMap(\.artikel)
    }

    /// Artikel, die in diesem Einkaufsvorgang bereits abgehakt wurden.
    private var abgehakteArtikel: [Artikel] {
        einkaufsvorgang.kaufEintraege.compactMap(\.artikel).filter { abgehakteArtikelIDs.contains($0.persistentModelID) }
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

    /// Die momentan für die Anzeige relevante Menge eines Artikels: solange er noch
    /// auf ``einkaufsliste`` steht, dessen ``EinkaufslistenEintrag/menge``, sonst
    /// (bereits abgehakt) die im ``KaufEintrag`` festgehaltene Menge.
    private func menge(fuer artikel: Artikel) -> Double {
        if let eintrag = einkaufsliste.eintrag(fuer: artikel) { return eintrag.menge }
        return kaufEintrag(fuer: artikel)?.menge ?? artikel.mengenSchritt
    }

    private func kaufEintrag(fuer artikel: Artikel) -> KaufEintrag? {
        einkaufsvorgang.kaufEintraege.first { $0.artikel == artikel }
    }

    var body: some View {
        List {
            ForEach(gruppen) { gruppe in
                Section {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            eintrag: einkaufsliste.eintrag(fuer: artikel),
                            mengeAnzeige: menge(fuer: artikel),
                            istAbgehakt: istAbgehakt(artikel),
                            abhaken: { umschalten(artikel) },
                            mengeErhoehen: { mengeErhoehen(artikel) },
                            mengeVerringern: { mengeVerringern(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
                        )
                    }
                } header: {
                    EinkaufslistenSektionHeader(titel: gruppe.regal.name, kategorie: nil)
                }
            }

            ForEach(sonstigeGruppen) { gruppe in
                Section {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            eintrag: einkaufsliste.eintrag(fuer: artikel),
                            mengeAnzeige: menge(fuer: artikel),
                            istAbgehakt: istAbgehakt(artikel),
                            abhaken: { umschalten(artikel) },
                            mengeErhoehen: { mengeErhoehen(artikel) },
                            mengeVerringern: { mengeVerringern(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
                        )
                    }
                } header: {
                    EinkaufslistenSektionHeader(titel: gruppe.kategorie.name, kategorie: gruppe.kategorie)
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
                        description: Text("Füge oben rechts Artikel zu „\(einkaufsliste.name)“ hinzu.")
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
        .navigationTitle(geschaeft?.name ?? einkaufsliste.name)
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
            ArtikelHinzufuegenView(einkaufsliste: einkaufsliste)
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

    /// Diskrete Einzelaktion wie das Abhaken (``umschalten``) — jeder Tap ist ein
    /// abgeschlossener Schreibvorgang und wird deshalb ebenso per Micro-Lease
    /// abgesichert (siehe `docs/DATABASE_CONCURRENCY.md` → „Vollständiger
    /// Schreibvorgang-Katalog“). Solange der Artikel noch auf ``einkaufsliste``
    /// steht, wirkt sich das auf dessen ``EinkaufslistenEintrag/menge`` aus, danach
    /// (bereits abgehakt) auf die im ``KaufEintrag`` festgehaltene Menge.
    private func mengeErhoehen(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let eintrag = einkaufsliste.eintrag(fuer: artikel) {
                    eintrag.mengeErhoehen()
                } else if let kauf = kaufEintrag(fuer: artikel) {
                    kauf.menge += artikel.mengenSchritt
                }
            }
        }
    }

    private func mengeVerringern(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let eintrag = einkaufsliste.eintrag(fuer: artikel) {
                    eintrag.mengeVerringern()
                } else if let kauf = kaufEintrag(fuer: artikel) {
                    kauf.menge = max(artikel.mengenSchritt, kauf.menge - artikel.mengenSchritt)
                }
            }
        }
    }
}

/// Kopfzeile einer Einkaufslisten-Sektion (Regal oder Kategorie). Bei
/// Kategorie-Sektionen (``kategorie`` gesetzt) wird zusätzlich deren Icon/Farbe
/// (``ArtikelKategorie/standardSymbol``/``standardFarbeHex``) angezeigt — Regal-
/// Sektionen bleiben ohne Icon, da ein Regal mehrere Kategorien bündeln kann.
private struct EinkaufslistenSektionHeader: View {
    let titel: String
    let kategorie: ArtikelKategorie?

    var body: some View {
        HStack(spacing: 6) {
            if let kategorie {
                Image(systemName: kategorie.standardSymbol)
                    .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
            }
            Text(titel)
            Spacer()
        }
    }
}

/// Eine Zeile zum Erhöhen/Verringern der Menge eines Artikels beim Einkaufen — Abhaken
/// geschieht über die eigenständige Checkbox am Zeilenende:
/// - Tap auf die Mengenangabe (nur solange noch offen, ``eintrag`` gesetzt): öffnet
///   ``MengenNotizSheet`` für eine exakte Menge + temporäre Notiz.
/// - Swipe nach links (trailing): erhöht die Menge um ``Artikel/mengenSchritt``.
/// - Swipe nach rechts (leading): verringert die Menge um ``Artikel/mengenSchritt``.
///
/// Ist der Artikel bereits abgehakt, bietet die Trailing-Swipe-Aktion zusätzlich an, ihn
/// dauerhaft aus dieser Ansicht zu entfernen (``dauerhaftEntfernen``, `nil` bei noch
/// offenen Artikeln).
private struct ArtikelAbhakZeile: View {
    let artikel: Artikel
    /// Der offene Einkaufslisten-Eintrag dieses Artikels — `nil`, wenn er bereits
    /// abgehakt wurde (dann gibt es keinen Eintrag mehr, siehe ``mengeAnzeige``).
    let eintrag: EinkaufslistenEintrag?
    let mengeAnzeige: Double
    let istAbgehakt: Bool
    let abhaken: () -> Void
    let mengeErhoehen: () -> Void
    let mengeVerringern: () -> Void
    var dauerhaftEntfernen: (() -> Void)?

    @State private var zeigeMengenSheet = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name)
                    .strikethrough(istAbgehakt)
                    .foregroundStyle(istAbgehakt ? .secondary : .primary)
                if let notiz = eintrag?.notiz, !notiz.isEmpty {
                    Text(notiz)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(mengeAnzeige.formatted()) \(artikel.einheit.kurzform)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { if eintrag != nil { zeigeMengenSheet = true } }
            Button(action: abhaken) {
                Image(systemName: istAbgehakt ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(istAbgehakt ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .leading) {
            Button(action: mengeVerringern) {
                Label("Menge verringern", systemImage: "minus")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let dauerhaftEntfernen {
                Button(role: .destructive, action: dauerhaftEntfernen) {
                    Label("Dauerhaft entfernen", systemImage: "trash")
                }
            }
            Button(action: mengeErhoehen) {
                Label("Menge erhöhen", systemImage: "plus")
            }
            .tint(.blue)
        }
        .sheet(isPresented: $zeigeMengenSheet) {
            if let eintrag {
                MengenNotizSheet(eintrag: eintrag)
            }
        }
    }
}

/// Sheet zum exakten Vorgeben der Menge und einer temporären Notiz für einen
/// ``EinkaufslistenEintrag`` (Tap auf die Mengenangabe in ``ArtikelAbhakZeile``).
/// Arbeitet mit lokalem Entwurfs-Zustand (analog `NeueKategorieSheet`) — die
/// Übernahme ins Modell geschieht erst bei „Sichern“, gekapselt in einem einzelnen
/// Micro-Lease.
private struct MengenNotizSheet: View {
    let eintrag: EinkaufslistenEintrag

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var mengeText: String
    @State private var notizText: String

    init(eintrag: EinkaufslistenEintrag) {
        self.eintrag = eintrag
        _mengeText = State(initialValue: eintrag.menge.formatted())
        _notizText = State(initialValue: eintrag.notiz ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Menge") {
                    HStack {
                        TextField("Menge", text: $mengeText)
                            .keyboardType(.decimalPad)
                        Text(eintrag.artikel?.einheit.kurzform ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Notiz") {
                    TextField(
                        "Temporäre Notiz, z.B. \"diesmal die große Packung\"",
                        text: $notizText,
                        axis: .vertical
                    )
                }
            }
            .navigationTitle(eintrag.artikel?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: sichern)
                }
            }
        }
    }

    private func sichern() {
        let neueMenge = Double(mengeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let getrimmteNotiz = notizText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let neueMenge, neueMenge > 0 {
                    eintrag.menge = neueMenge
                }
                eintrag.notiz = getrimmteNotiz.isEmpty ? nil : getrimmteNotiz
            }
            dismiss()
        }
    }
}

#Preview {
    EinkaufenView()
        .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self, Artikel.self, Einkaufsvorgang.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
