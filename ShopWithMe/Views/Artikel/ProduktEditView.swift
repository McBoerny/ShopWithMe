import SwiftUI
import SwiftData
import Charts

/// Anlegen/Bearbeiten eines ``Produkt``s (GitHub #47, Schritt 4/5) — analog
/// ``ArtikelEditView``.
///
/// Bei einem neuen Produkt (`istNeu == true`) wird es erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft es folgenlos). Die bekannten
/// Produktnamen je Geschäft werden als Akkordeon angezeigt; die Preishistorie
/// enthält einen Verlaufsgraphen und einen „Datapunkte“-Button für die
/// Detailliste mit Einzellöschung.
struct ProduktEditView: View {
    @Bindable var produkt: Produkt
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var produktnamen: [Produktname]
    @Query private var preisHistorie: [Preispunkt]

    @State private var zeigeArtikelAuswahl = false
    @State private var zeigeDatenpunkte = false
    @State private var neuerAlternativerKlarname = ""

    init(produkt: Produkt, istNeu: Bool) {
        self.produkt = produkt
        self.istNeu = istNeu
        let produktID = produkt.persistentModelID
        _produktnamen = Query(
            filter: #Predicate<Produktname> { $0.produkt?.persistentModelID == produktID },
            sort: [SortDescriptor(\.name)]
        )
        _preisHistorie = Query(
            filter: #Predicate<Preispunkt> { $0.produkt?.persistentModelID == produktID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
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
                    TextField("Name", text: $produkt.name)
                        .font(.title3)
                    if istNeu {
                        if let artikelName = produkt.artikel?.name {
                            LabeledContent("Artikel", value: artikelName)
                        }
                    } else {
                        Button {
                            zeigeArtikelAuswahl = true
                        } label: {
                            HStack {
                                Text("Artikel")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(produkt.artikel?.name ?? "Bitte w\u{00e4}hlen")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Menschenlesbarer Klarname des Produkts, z.\u{202f}B. \u{201e}Paradontol Zahncreme\u{201c} — unabhängig vom geschäftsspezifischen Bon-Text.")
                }

                if !istNeu {
                    Section {
                        ForEach(produkt.alternativeKlarnamen, id: \.self) { name in
                            Text(name)
                        }
                        .onDelete(perform: alternativerKlarnameEntfernen)

                        HStack {
                            TextField("Alternativer Name, z.B. \"Andechser Vollmilch fett\"", text: $neuerAlternativerKlarname)
                                .onSubmit(alternativenKlarnamenHinzufuegen)
                            Button("Hinzufügen", action: alternativenKlarnamenHinzufuegen)
                                .disabled(neuerAlternativerKlarname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } header: {
                        Text("Alternative Namen")
                    } footer: {
                        Text("Zusätzliche Anzeigenamen für dieses Produkt, geschäftsunabhängig — im Unterschied zu den geschäftsspezifischen Bon-Namen unten.")
                    }
                }

                if !istNeu && !produktnamen.isEmpty {
                    let geschaefteAnzahl = Set(produktnamen.compactMap { $0.geschaeft?.id }).count
                    Section {
                        DisclosureGroup {
                            ForEach(produktnamen) { eintrag in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(eintrag.name)
                                    Text(eintrag.geschaeft?.name ?? "Unbekanntes Gesch\u{00e4}ft")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let barcode = eintrag.barcode, !barcode.isEmpty {
                                        Label(barcode, systemImage: "barcode")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete(perform: produktnameEntfernen)
                        } label: {
                            HStack {
                                Text("Bekannte Namen")
                                Spacer()
                                Text("\(geschaefteAnzahl)\u{00a0}Gesch\u{00e4}ft\(geschaefteAnzahl == 1 ? "" : "e")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Gedruckter Name auf Kassenbons, je Gesch\u{00e4}ft unterschiedlich. Nach links wischen zum Entfernen.")
                    }
                }

                if !istNeu && !preisHistorie.isEmpty {
                    Section("Preishistorie") {
                        if preisPunkte.count >= 2 {
                            Chart(preisPunkte) { punkt in
                                LineMark(
                                    x: .value("Datum", punkt.datum),
                                    y: .value("Preis", punkt.preisAlsDouble)
                                )
                                PointMark(
                                    x: .value("Datum", punkt.datum),
                                    y: .value("Preis", punkt.preisAlsDouble)
                                )
                            }
                            .frame(height: 160)
                            .padding(.vertical, 8)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                        Button {
                            zeigeDatenpunkte = true
                        } label: {
                            Label("Datenpunkte (\(preisHistorie.count))", systemImage: "list.bullet")
                        }
                    }
                }
            }
            .navigationTitle(istNeu ? "Neues Produkt" : produkt.name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: produkt.name) { _, _ in
                guard !istNeu else { return }
                produkt.markiereGeaendert()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`).
                            guard DatabaseLeaseService.gehoertZuAktuellemContext(produkt, context: modelContext) else { return }
                            Task {
                                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                    modelContext.insert(produkt)
                                }
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(produkt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $zeigeArtikelAuswahl) {
                ArtikelAuswahlSheet(gewaehlterArtikel: $produkt.artikel)
            }
            .sheet(isPresented: $zeigeDatenpunkte) {
                ProduktDatenpunkteSheet(produkt: produkt)
            }
        }
    }

    private var preisPunkte: [PreisVerlaufPunkt] {
        preisHistorie
            .map { PreisVerlaufPunkt(id: $0.persistentModelID, datum: $0.datum, preis: $0.preis) }
            .sorted { $0.datum < $1.datum }
    }

    private func produktnameEntfernen(at indexSet: IndexSet) {
        for index in indexSet {
            modelContext.delete(produktnamen[index])
        }
    }

    /// Analog ``ArtikelEditView/alternativenNamenHinzufuegen()`` — reine,
    /// pro Produkt gepflegte Liste ohne globale Eindeutigkeitsprüfung.
    private func alternativenKlarnamenHinzufuegen() {
        let getrimmt = neuerAlternativerKlarname.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { neuerAlternativerKlarname = "" }
        guard !getrimmt.isEmpty,
              !produkt.alternativeKlarnamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        produkt.alternativeKlarnamen.append(getrimmt)
    }

    private func alternativerKlarnameEntfernen(at indexSet: IndexSet) {
        var aktuelle = produkt.alternativeKlarnamen
        for index in indexSet.sorted(by: >) {
            aktuelle.remove(at: index)
        }
        produkt.alternativeKlarnamen = aktuelle
    }
}

/// Zeigt alle gespeicherten ``Preispunkt``e eines ``Produkt``s — einzelne
/// Punkte lassen sich per Wischgeste dauerhaft löschen.
private struct ProduktDatenpunkteSheet: View {
    let produkt: Produkt
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var preisHistorie: [Preispunkt]

    init(produkt: Produkt) {
        self.produkt = produkt
        let produktID = produkt.persistentModelID
        _preisHistorie = Query(
            filter: #Predicate<Preispunkt> { $0.produkt?.persistentModelID == produktID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(preisHistorie) { eintrag in
                    PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: false,
                                       loeschen: { eintragLoeschen(eintrag) })
                }
            }
            .overlay {
                if preisHistorie.isEmpty {
                    ContentUnavailableView("Keine Datenpunkte", systemImage: "chart.line.downtrend.xyaxis")
                }
            }
            .navigationTitle("Datenpunkte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func eintragLoeschen(_ eintrag: Preispunkt) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                SyncTombstoneService.markiereGeloescht(
                    art: SyncEntitaetsArt.preispunkt, id: eintrag.id, context: modelContext
                )
                modelContext.delete(eintrag)
            }
        }
    }
}

private struct PreisVerlaufPunkt: Identifiable {
    let id: PersistentIdentifier
    let datum: Date
    let preis: Decimal
    var preisAlsDouble: Double { NSDecimalNumber(decimal: preis).doubleValue }
}

#Preview {
    ProduktEditView(
        produkt: Produkt(name: "Paradontol Zahncreme", artikel: Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, Produkt.self, Produktname.self, Geschaeft.self, GeschaeftTyp.self, Preispunkt.self], inMemory: true)
}
