import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten eines ``Artikel``s.
///
/// Bei einem neuen Artikel (`istNeu == true`) wird er erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft ihn folgenlos). Die Kategorien
/// (Mehrfachauswahl möglich) sind sowohl beim Anlegen als auch danach frei
/// wählbar.
struct ArtikelEditView: View {
    @Bindable var artikel: Artikel
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]
    @Query private var produkte: [Produkt]
    @Query private var alleArtikel: [Artikel]

    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var zeigeKategorieHinzufuegen = false
    @State private var neuerAlternativerName = ""
    @State private var neuesProduktEntwurf: Produkt?
    @State private var bearbeitetesProdukt: Produkt?

    /// Preishistorie über alle ``Produkt``e dieses Artikels (auch das
    /// Platzhalter-Standardprodukt und Unter-Produkte, anders als ``produkte``
    /// unten) — bewusst kein `#Predicate`-``Query`` mehr: ``Preispunkt/artikel``
    /// ist seit der Produkt-Pflicht eine abgeleitete Computed-Property
    /// (`produkt?.artikel`), keine echte gespeicherte Relationship mehr, auf
    /// die ein `#Predicate` zugreifen könnte (SwiftData-Fatal-Error zur
    /// Laufzeit trotz erfolgreichem Build). ``Artikel/preispunkte`` liest
    /// stattdessen live über die Produkt-Relationship.
    private var preisHistorie: [Preispunkt] {
        artikel.preispunkte.sorted { $0.datum > $1.datum }
    }

    init(artikel: Artikel, istNeu: Bool) {
        self.artikel = artikel
        self.istNeu = istNeu
        let artikelID = artikel.persistentModelID
        // Nur oberste Ebene (kein `elternProdukt`) und ohne das automatisch
        // angelegte Platzhalter-Produkt (``Produkt/istStandard``) — Rekursion
        // (Unter-Produkte, z.B. Packungsgrößen) hat bewusst noch keine UI
        // (GitHub #47, Schritt 4/5).
        _produkte = Query(
            filter: #Predicate<Produkt> { $0.artikel?.persistentModelID == artikelID && !$0.istStandard && $0.elternProdukt == nil },
            sort: [SortDescriptor(\.name)]
        )
    }

    var body: some View {
        if istNeu {
            navigationInhalt
        } else {
            SessionLeaseGate { navigationInhalt }
        }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $artikel.name)
                        .font(.title3)
                    if let moeglicheDublette {
                        Label("Es gibt bereits einen Artikel „\(moeglicheDublette.name)“", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(artikel.kategorien) { kategorie in
                        Label(kategorie.name, systemImage: kategorie.standardSymbol)
                    }
                    .onDelete(perform: kategorieEntfernen)

                    Button {
                        zeigeKategorieHinzufuegen = true
                    } label: {
                        Label("Abteilung hinzufügen", systemImage: "plus")
                    }

                    if kiVorschlagLaeuft {
                        HStack {
                            ProgressView()
                            Text("Apple Intelligence schlägt eine Abteilung vor…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let kiFehlermeldung {
                        Text(kiFehlermeldung)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Mehrfachauswahl möglich. Ohne Auswahl landet der Artikel automatisch in „Sonstiges“.")
                }

                Section("Menge & Einheit") {
                    Picker("Einheit", selection: $artikel.einheit) {
                        ForEach(Einheit.allCases) { einheit in
                            Text(einheit.anzeigename).tag(einheit)
                        }
                    }
                    HStack {
                        Text("Standardmenge")
                        Spacer()
                        TextField("Menge", value: $artikel.mengenSchritt, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(artikel.einheit.kurzform)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notiz") {
                    TextField(
                        "Optionale Notiz, z.B. bevorzugte Marke",
                        text: Binding(
                            get: { artikel.notiz ?? "" },
                            set: { artikel.notiz = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                }

                if !istNeu {
                    Section {
                        ForEach(artikel.alternativeNamen, id: \.self) { name in
                            Text(name)
                        }
                        .onDelete(perform: alternativerNameEntfernen)

                        HStack {
                            TextField("Alternativer Name, z.B. \"Zahncreme\"", text: $neuerAlternativerName)
                                .onSubmit(alternativenNamenHinzufuegen)
                            Button("Hinzufügen", action: alternativenNamenHinzufuegen)
                                .disabled(neuerAlternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } header: {
                        Text("Alternative Namen")
                    } footer: {
                        Text("Unter diesen Namen wird derselbe Artikel ebenfalls gefunden, z.B. \"Zahncreme\" oder \"Zahnreiniger\" für \"Zahnpasta\".")
                    }
                }

                if !istNeu {
                    Section {
                        ForEach(produkte) { produkt in
                            Button {
                                bearbeitetesProdukt = produkt
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(produkt.name)
                                            .foregroundStyle(.primary)
                                        if !produkt.produktnamen.isEmpty {
                                            let anzahl = produkt.produktnamen.count
                                            Text("\(anzahl) Bon-Name\(anzahl == 1 ? "" : "n")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: produktLoeschen)

                        Button {
                            neuesProduktAnlegen()
                        } label: {
                            Label("Neues Produkt anlegen", systemImage: "plus")
                        }
                    } header: {
                        Text("Produkte")
                    } footer: {
                        Text("Konkrete Produkte dieses Artikels, z.B. \"Odol\" oder \"Paradontol\" für \"Zahnpasta\" — jedes mit eigenem Preis und eigenen Namen je Geschäft.")
                    }
                }

                if !istNeu && !preisHistorie.isEmpty {
                    Section("Preishistorie") {
                        ForEach(preisHistorie) { eintrag in
                            PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: false,
                                               loeschen: { modelContext.delete(eintrag) })
                        }
                    }
                }
            }
            .navigationTitle(istNeu ? "Neuer Artikel" : artikel.name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: artikel.name) { _, _ in markiereGeaendertFallsBestehend() }
            .onChange(of: artikel.einheit) { _, _ in markiereGeaendertFallsBestehend() }
            .onChange(of: artikel.mengenSchritt) { _, _ in markiereGeaendertFallsBestehend() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`):
                            // bei einem bereits (fälschlich) mehrfach übergebenen
                            // `artikel` (z.B. Sheet über Live-Ersetzen hinweg
                            // offen gelassen) sicherstellen, dass er nicht schon
                            // einem ANDEREN Context zugeordnet ist.
                            guard DatabaseLeaseService.gehoertZuAktuellemContext(artikel, context: modelContext) else { return }
                            Task {
                                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                    modelContext.insert(artikel)
                                }
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(artikel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task(id: artikel.name) {
                await kategorieAutomatischVorschlagen()
            }
            .sheet(isPresented: $zeigeKategorieHinzufuegen) {
                KategorieHinzufuegenSheet(artikel: artikel)
            }
            .sheet(item: $neuesProduktEntwurf) { entwurf in
                ProduktEditView(produkt: entwurf, istNeu: true)
            }
            .sheet(item: $bearbeitetesProdukt) { produkt in
                ProduktEditView(produkt: produkt, istNeu: false)
            }
        }
    }

    /// Siehe ``Artikel/dublette(name:alle:ausgenommen:)`` für die Begründung.
    private var moeglicheDublette: Artikel? {
        Artikel.dublette(name: artikel.name, alle: alleArtikel, ausgenommen: artikel)
    }

    /// Reagiert auf Änderungen an ``Artikel/name``/``Artikel/einheit``/
    /// ``Artikel/mengenSchritt`` — nur bei einem bereits bestehenden Artikel
    /// (siehe ``Artikel/lamportZaehler``); bei Neuanlage (`istNeu == true`)
    /// ist jede Zwischenänderung noch keine echte Bearbeitung eines bereits
    /// synchronisierten Datensatzes.
    private func markiereGeaendertFallsBestehend() {
        guard !istNeu else { return }
        artikel.markiereGeaendert()
    }

    /// Legt einen neuen alternativen Namen für ``artikel`` an (GitHub #111/#128)
    /// — anders als vormals `ArtikelAlias` keine geräteweite Eindeutigkeits-
    /// prüfung nötig: ``Artikel/alternativeNamen`` ist eine reine, pro Artikel
    /// gepflegte Synonymliste ohne globalen Matching-Anspruch (siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md`).
    private func alternativenNamenHinzufuegen() {
        let getrimmt = neuerAlternativerName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { neuerAlternativerName = "" }
        guard !getrimmt.isEmpty,
              !artikel.alternativeNamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        artikel.alternativeNamen.append(getrimmt)
    }

    private func alternativerNameEntfernen(at indexSet: IndexSet) {
        var aktuelle = artikel.alternativeNamen
        for index in indexSet.sorted(by: >) {
            aktuelle.remove(at: index)
        }
        artikel.alternativeNamen = aktuelle
    }

    /// Legt einen neuen Produkt-Entwurf für ``artikel`` an (GitHub #47,
    /// Schritt 4/5) — analog ``ArtikelHinzufuegenView/neuenArtikelAnlegen()``:
    /// erst beim Sichern in ``ProduktEditView`` tatsächlich in den
    /// Model-Context eingefügt, Abbrechen verwirft ihn folgenlos.
    private func neuesProduktAnlegen() {
        neuesProduktEntwurf = Produkt(name: "", artikel: artikel)
    }

    private func produktLoeschen(at indexSet: IndexSet) {
        for index in indexSet {
            modelContext.delete(produkte[index])
        }
    }

    private func kategorieEntfernen(at indexSet: IndexSet) {
        var aktuelle = artikel.kategorien
        for index in indexSet.sorted(by: >) {
            aktuelle.remove(at: index)
        }
        artikel.kategorien = aktuelle
    }

    /// Bestimmt automatisch (ohne manuellen Anstoß) eine Kategorie für einen neuen
    /// Artikel, sobald Apple Intelligence verfügbar ist — entprellt um 600ms, damit
    /// nicht bei jedem Tastenanschlag ein KI-Aufruf losgeschickt wird. SwiftUI
    /// storniert diesen Task automatisch, sobald sich `artikel.name` erneut ändert
    /// (`.task(id:)`). Überschreibt niemals eine bereits (manuell oder von einem
    /// vorherigen Durchlauf) gesetzte Kategorie.
    private func kategorieAutomatischVorschlagen() async {
        guard istNeu, AISuggestionService.istVerfuegbar, artikel.kategorien.isEmpty else { return }
        let name = artikel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, artikel.kategorien.isEmpty else { return }

        kiVorschlagLaeuft = true
        kiFehlermeldung = nil
        defer { kiVorschlagLaeuft = false }

        do {
            let vorschlag = try await AISuggestionService.vorschlag(
                fuerArtikelName: name,
                bekannteKategorien: kategorien.map(\.name)
            )
            guard !Task.isCancelled, artikel.kategorien.isEmpty else { return }

            if let passendeKategorie = kategorien.first(where: {
                $0.name.localizedCaseInsensitiveCompare(vorschlag.kategorieName) == .orderedSame
            }) {
                artikel.kategorien = [passendeKategorie]
            }
        } catch {
            kiFehlermeldung = "KI-Vorschlag nicht verfügbar: \(error.localizedDescription)"
        }
    }
}

/// Sheet zum Zuordnen bestehender ``ArtikelKategorie``n zu ``artikel`` — analog
/// ``ArtikelZuAbteilungHinzufuegenSheet`` (dort umgekehrte Richtung: Artikel zu
/// einer Kategorie zuordnen). Tippen auf eine Abteilung ordnet sie sofort zu
/// (kein zusätzlicher Bestätigungsschritt), das Sheet bleibt offen, um mehrere
/// Abteilungen nacheinander hinzufügen zu können — nutzt die generische
/// ``AuswahlSheet`` (GitHub #130) analog ``AbteilungHinzufuegenSheet``.
private struct KategorieHinzufuegenSheet: View {
    @Bindable var artikel: Artikel

    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    /// Die eigentliche Zuordnung passiert verzögert über ``onChange(of:)``
    /// statt direkt im Binding-Setter — siehe ausführliche Begründung in
    /// ``AbteilungHinzufuegenSheet`` (Live-Fund: Sheet flackerte auf/zu).
    @State private var geradeAusgewaehlt: Set<ArtikelKategorie.ID> = []

    private var nichtZugeordneteKategorien: [ArtikelKategorie] {
        alleKategorien.filter { !artikel.kategorien.contains($0) }
    }

    var body: some View {
        AuswahlSheet(
            titel: "Abteilung hinzufügen",
            items: nichtZugeordneteKategorien,
            name: \.name,
            modus: .mehrfach($geradeAusgewaehlt),
            suchPrompt: "Abteilung suchen",
            symbol: \.standardSymbol,
            neuAnlegenTitel: { _ in "Neue Abteilung anlegen" },
            neuAnlegenNurBeiFehlendemTreffer: false,
            neuAnlegenInhalt: { _, gesichert in
                NeueAbteilungSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                    artikel.kategorien.append(kategorie)
                    gesichert(kategorie)
                }
            }
        )
        .onChange(of: geradeAusgewaehlt) { _, neu in
            guard !neu.isEmpty else { return }
            for id in neu {
                if let kategorie = nichtZugeordneteKategorien.first(where: { $0.id == id }) {
                    artikel.kategorien.append(kategorie)
                }
            }
            geradeAusgewaehlt = []
        }
    }
}

#Preview {
    ArtikelEditView(
        artikel: Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA"),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self, Produkt.self, Produktname.self], inMemory: true)
}
