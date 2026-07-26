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
/// „Preisübersicht“ ist ein eigener View (``GeschaeftPreisUebersichtView``,
/// GitHub #20) mit der Preisspanne pro Artikel sowie Positionen ohne
/// Artikel-Zuordnung — siehe `docs/BELEGSCAN.md`.
///
/// „Besuchsprotokoll“ (``GeschaeftBesuchsProtokollView``, GitHub #32) zeigt
/// Zeitpunkt und Dauer aller abgeschlossenen ``Einkaufsvorgang``e in diesem
/// Geschäft — ohne eigenes Datenmodell, direkt aus dessen `startZeit`/`endZeit`.
struct GeschaeftDetailView: View {
    @Bindable var geschaeft: Geschaeft
    @Environment(\.modelContext) private var modelContext
    @State private var zeigeStammdatenEdit = false
    @State private var zeigeBelegScan = false
    @State private var zeigePreisschildScan = false
    @State private var zeigeKategorieHinzufuegen = false

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
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
                        GlassSymbolBadge(symbolName: geschaeft.fuehrenderTyp?.symbolName ?? "shippingbox.fill", farbe: .accentColor, groesse: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(geschaeft.name)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(geschaeft.typen.map(\.name).joined(separator: ", "))
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

            Section {
                NavigationLink {
                    GeschaeftPreisUebersichtView(geschaeft: geschaeft)
                } label: {
                    Label("Preisübersicht", systemImage: "chart.line.uptrend.xyaxis")
                }
                NavigationLink {
                    GeschaeftBesuchsProtokollView(geschaeft: geschaeft)
                } label: {
                    Label("Besuchsprotokoll", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle(geschaeft.name.isEmpty ? "Geschäft" : geschaeft.name)
        .navigationDestination(for: Regal.self) { regal in
            RegalDetailView(regal: regal)
        }
        .toolbar {
            // Nur anzeigen, wenn er tatsächlich etwas bewirkt: Löschen funktioniert
            // bereits ohne Edit-Modus per Wischgeste, der einzige Mehrwert sind die
            // Zieh-Griffe zum manuellen Umsortieren mehrerer Regale (GitHub #28).
            if geschaeft.regalSortierModus == .manuell && regaleAnzeigen.count > 1 {
                EditButton()
            }
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

#Preview {
    NavigationStack {
        GeschaeftDetailView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
