import SwiftUI
import SwiftData

/// Detailansicht eines ``Geschaeft``s: Stammdaten, Kategorien- und Regal-Verwaltung
/// sowie Kaufbeleg- und Preisschild-Scan.
///
/// Der „Kategorien“-Abschnitt zeigt ``Geschaeft/verfuegbareKategorien`` — Kategorien
/// sind dabei auch ohne Regal sofort verfügbar (siehe ``Geschaeft/kategorien``);
/// Regale sind optional und dienen nur der Sortierung beim Einkaufen.
///
/// Die Reihenfolge der Regale in dieser Liste hängt vom gewählten
/// ``RegalSortierModus`` ab: manuell (``Regal/sortIndex``, per Drag-Handle im
/// Bearbeiten-Modus änderbar) oder automatisch anhand der gelernten Einkaufs-
/// Reihenfolge (``ShelfOrderLearningService``). Der Wechsel zwischen beiden Modi
/// überschreibt die jeweils andere Reihenfolge nicht — beide bleiben unabhängig
/// voneinander erhalten.
///
/// „Kaufbeleg scannen“ öffnet ``BelegScanView`` im ``BelegScanKontext/geschaeft(_:)``-
/// Kontext — unabhängig von einem laufenden ``Einkaufsvorgang``, z.B. um Preise für
/// einen älteren oder nachträglich gefundenen Kassenbon zu erfassen.
///
/// „Preisschild scannen“ öffnet ``PreisschildScanView`` — erfasst den Preis eines
/// einzelnen fotografierten Regal-Preisschilds direkt als ``KaufEintrag`` mit
/// heutigem Datum, unabhängig davon, ob der Artikel tatsächlich gekauft wird (z.B.
/// zum Preisvergleich vor der Kaufentscheidung). Siehe `docs/PREISSCHILD_SCAN.md`.
///
/// „Preisübersicht“ zeigt, gruppiert über ``ArtikelPreisSpanne/gruppieren(_:)``, pro
/// jemals hier gekauftem ``Artikel`` die Preisspanne (niedrigster–höchster erfasster
/// Preis). Ein Antippen öffnet ``ArtikelPreisVerlaufView`` mit der historischen Liste
/// aller zugrundeliegenden Belegpositionen. Positionen ohne Artikel-Zuordnung
/// erscheinen separat darunter — siehe `docs/BELEGSCAN.md`.
struct GeschaeftDetailView: View {
    @Bindable var geschaeft: Geschaeft
    @Environment(\.modelContext) private var modelContext
    @State private var zeigeStammdatenEdit = false
    @State private var zeigeBelegScan = false
    @State private var zeigePreisschildScan = false
    @State private var zeigeKategorieHinzufuegen = false
    @Query private var kaufHistorie: [KaufEintrag]

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
        let geschaeftID = geschaeft.persistentModelID
        _kaufHistorie = Query(
            filter: #Predicate<KaufEintrag> { $0.geschaeft?.persistentModelID == geschaeftID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    private var regaleAnzeigen: [Regal] {
        ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: modelContext)
    }

    private var automatischeReihenfolgeVerfuegbar: Bool {
        ShelfOrderLearningService.automatischeReihenfolgeVerfuegbar(fuer: geschaeft, context: modelContext)
    }

    private var verschiebenAktion: ((IndexSet, Int) -> Void)? {
        guard geschaeft.regalSortierModus == .manuell else { return nil }
        return regalVerschieben
    }

    private var artikelPreisSpannen: [ArtikelPreisSpanne] {
        ArtikelPreisSpanne.gruppieren(kaufHistorie)
    }

    private var eintraegeOhneArtikel: [KaufEintrag] {
        kaufHistorie.filter { $0.artikel == nil }
    }

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            if automatischeReihenfolgeVerfuegbar {
                Section {
                    Picker("Reihenfolge", selection: $geschaeft.regalSortierModus) {
                        ForEach(RegalSortierModus.allCases) { modus in
                            Text(modus.anzeigename).tag(modus)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(geschaeft.regalSortierModus == .automatisch
                         ? "ShopWithMe sortiert die Regale automatisch anhand deiner bisherigen Einkäufe. Deine manuelle Reihenfolge bleibt dabei erhalten und lässt sich jederzeit wieder auswählen."
                         : "Du legst die Reihenfolge selbst fest. ShopWithMe hat außerdem genug Einkäufe gelernt, um stattdessen automatisch zu sortieren.")
                }
            }

            Section {
                Button {
                    zeigeStammdatenEdit = true
                } label: {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: geschaeft.typ.symbolName, farbe: .accentColor, groesse: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(geschaeft.name)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(geschaeft.typ.anzeigename)
                                .foregroundStyle(.secondary)
                            if let adresse = geschaeft.adresse, !adresse.isEmpty {
                                Text(adresse)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(regaleAnzeigen) { regal in
                    NavigationLink(value: regal) {
                        RegalZeile(regal: regal)
                    }
                }
                .onDelete(perform: regalLoeschen)
                .onMove(perform: verschiebenAktion)

                Button {
                    regalHinzufuegen()
                } label: {
                    Label("Regal hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Regale")
            } footer: {
                Text(geschaeft.regalSortierModus == .manuell
                     ? "Ziehe die Regale (über „Bearbeiten“) in die Reihenfolge, in der du sie beim Einkaufen ablaufen möchtest."
                     : "Diese Reihenfolge wird automatisch gelernt. Wechsle oben zu „Manuell“, um sie selbst festzulegen.")
            }

            Section {
                ForEach(geschaeft.verfuegbareKategorien) { kategorie in
                    HStack {
                        Label(kategorie.name, systemImage: kategorie.standardSymbol)
                        Spacer()
                        if let regal = geschaeft.regal(fuer: kategorie) {
                            Text(regal.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: kategorieEntfernen)

                Button {
                    zeigeKategorieHinzufuegen = true
                } label: {
                    Label("Kategorie hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Kategorien")
            } footer: {
                Text("Kategorien sind auch ohne Regal sofort verfügbar. Regale sind optional und dienen nur der Sortierung beim Einkaufen. Zum Entfernen nach links wischen.")
            }

            Section {
                Button {
                    zeigeBelegScan = true
                } label: {
                    Label("Kaufbeleg scannen", systemImage: "doc.text.viewfinder")
                }
                Button {
                    zeigePreisschildScan = true
                } label: {
                    Label("Preisschild scannen", systemImage: "text.viewfinder")
                }
            } footer: {
                Text("Erfasse Preise für dieses Geschäft direkt von einem Kassenbon, auch ohne laufenden Einkauf. „Preisschild scannen“ erfasst den Preis eines einzelnen Regal-Preisschilds, auch ohne Kauf — z.B. zum Preisvergleich.")
            }

            if !artikelPreisSpannen.isEmpty {
                Section {
                    ForEach(artikelPreisSpannen) { spanne in
                        NavigationLink {
                            ArtikelPreisVerlaufView(artikel: spanne.artikel, geschaeft: geschaeft)
                        } label: {
                            ArtikelPreisSpanneZeile(spanne: spanne)
                        }
                    }
                } header: {
                    Text("Preisübersicht")
                } footer: {
                    Text("Zeigt pro Artikel die Preisspanne aller hier gescannten Käufe. Zum Verlauf einzelner Käufe antippen.")
                }
            }

            if !eintraegeOhneArtikel.isEmpty {
                Section {
                    ForEach(eintraegeOhneArtikel) { eintrag in
                        PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: true)
                    }
                } header: {
                    Text("Ohne Artikel-Zuordnung")
                } footer: {
                    Text("Diese Belegpositionen sind noch keinem Artikel zugeordnet. Nach links wischen, um sie über „Zuordnen“ einem (ggf. neuen) Artikel zuzuweisen.")
                }
            }
        }
        .navigationTitle(geschaeft.name.isEmpty ? "Geschäft" : geschaeft.name)
        .navigationDestination(for: Regal.self) { regal in
            RegalDetailView(regal: regal)
        }
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $zeigeStammdatenEdit) {
            GeschaeftStammdatenEditView(geschaeft: geschaeft, istNeu: false)
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView(geschaeft: geschaeft)
        }
        .sheet(isPresented: $zeigePreisschildScan) {
            PreisschildScanView(geschaeft: geschaeft)
        }
        .sheet(isPresented: $zeigeKategorieHinzufuegen) {
            KategorieHinzufuegenSheet(geschaeft: geschaeft)
        }
    }

    private func kategorieEntfernen(at offsets: IndexSet) {
        let kategorien = geschaeft.verfuegbareKategorien
        for index in offsets {
            let kategorie = kategorien[index]
            geschaeft.kategorien.removeAll { $0 == kategorie }
            geschaeft.regal(fuer: kategorie)?.kategorien.removeAll { $0 == kategorie }
        }
    }

    private func regalHinzufuegen() {
        let naechsterIndex = (geschaeft.regale.map(\.sortIndex).max() ?? -1) + 1
        let regal = Regal(name: "Neues Regal", sortIndex: naechsterIndex, geschaeft: geschaeft)
        modelContext.insert(regal)
    }

    private func regalLoeschen(at offsets: IndexSet) {
        let sortiert = regaleAnzeigen
        for index in offsets {
            modelContext.delete(sortiert[index])
        }
    }

    private func regalVerschieben(from source: IndexSet, to destination: Int) {
        var sortiert = regaleAnzeigen
        sortiert.move(fromOffsets: source, toOffset: destination)
        for (index, regal) in sortiert.enumerated() {
            regal.sortIndex = index
        }
    }
}

/// Eine Zeile in der Regal-Liste eines Geschäfts.
private struct RegalZeile: View {
    let regal: Regal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(regal.name.isEmpty ? "Unbenannt" : regal.name)
            if regal.kategorien.isEmpty {
                Text("Keine Kategorien zugeordnet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(regal.kategorien.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Eine Zeile der Preisübersicht: Artikelname links, Preisspanne rechts.
private struct ArtikelPreisSpanneZeile: View {
    let spanne: ArtikelPreisSpanne

    var body: some View {
        HStack(spacing: 16) {
            Text(spanne.artikel.name)
                .foregroundStyle(.primary)
            Spacer()
            Text(preisspannenText)
                .foregroundStyle(.secondary)
        }
    }

    private var preisspannenText: String {
        guard let minimum = spanne.minimum else { return "Preis unbekannt" }
        guard let maximum = spanne.maximum, maximum != minimum else {
            return minimum.formatted(.currency(code: "EUR"))
        }
        return "\(minimum.formatted(.currency(code: "EUR"))) – \(maximum.formatted(.currency(code: "EUR")))"
    }
}

/// Historische Liste aller Belegpositionen eines ``Artikel``s in einem bestimmten
/// ``Geschaeft`` — Drill-down aus der Preisübersicht (``ArtikelPreisSpanneZeile``).
private struct ArtikelPreisVerlaufView: View {
    let artikel: Artikel
    @Query private var eintraege: [KaufEintrag]

    init(artikel: Artikel, geschaeft: Geschaeft) {
        self.artikel = artikel
        let artikelID = artikel.persistentModelID
        let geschaeftID = geschaeft.persistentModelID
        _eintraege = Query(
            filter: #Predicate<KaufEintrag> {
                $0.artikel?.persistentModelID == artikelID && $0.geschaeft?.persistentModelID == geschaeftID
            },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    var body: some View {
        List {
            ForEach(eintraege) { eintrag in
                PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: true)
            }
        }
        .navigationTitle(artikel.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        GeschaeftDetailView(geschaeft: Geschaeft(name: "Rewe", typ: .lebensmittel))
    }
    .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
