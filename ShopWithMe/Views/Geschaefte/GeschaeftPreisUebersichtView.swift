import SwiftUI
import SwiftData
import Charts

/// Eigener View für die Preisübersicht eines Geschäfts (GitHub #20, vorher als
/// zwei Sektionen direkt in ``GeschaeftDetailView`` eingebettet) — zeigt pro
/// jemals hier gekauftem ``Artikel`` die Preisspanne (niedrigster–höchster
/// erfasster Preis, ``ArtikelPreisSpanne/gruppieren(_:)``). Ein Antippen öffnet
/// ``ArtikelPreisVerlaufView`` mit Preisdiagramm und Einzelpositionen.
/// Belegpositionen ohne Artikel-Zuordnung erscheinen separat darunter — siehe
/// `docs/BELEGSCAN.md`.
struct GeschaeftPreisUebersichtView: View {
    let geschaeft: Geschaeft
    @Query private var kaufHistorie: [KaufEintrag]

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
        let geschaeftID = geschaeft.persistentModelID
        _kaufHistorie = Query(
            filter: #Predicate<KaufEintrag> { $0.geschaeft?.persistentModelID == geschaeftID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    private var artikelPreisSpannen: [ArtikelPreisSpanne] {
        ArtikelPreisSpanne.gruppieren(kaufHistorie)
    }

    private var eintraegeOhneArtikel: [KaufEintrag] {
        kaufHistorie.filter { $0.artikel == nil }
    }

    var body: some View {
        List {
            if !artikelPreisSpannen.isEmpty {
                Section {
                    ForEach(artikelPreisSpannen) { spanne in
                        NavigationLink(value: spanne.artikel) {
                            ArtikelPreisSpanneZeile(spanne: spanne)
                        }
                    }
                } header: {
                    Text("Preisspanne je Artikel")
                } footer: {
                    Text("Zeigt pro Artikel die Preisspanne aller hier gescannten Käufe. Zum Verlauf mit Preisdiagramm antippen.")
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
                    Text("Diese Belegpositionen sind noch keinem Artikel zugeordnet. Nach rechts wischen, um sie über „Zuordnen“ einem (ggf. neuen) Artikel zuzuweisen.")
                }
            }

            if artikelPreisSpannen.isEmpty && eintraegeOhneArtikel.isEmpty {
                ContentUnavailableView(
                    "Noch keine Preise",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Scanne einen Kaufbeleg oder ein Preisschild, um hier Preise zu sehen.")
                )
            }
        }
        .navigationTitle("Preisübersicht")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Artikel.self) { artikel in
            ArtikelPreisVerlaufView(artikel: artikel, geschaeft: geschaeft)
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
///
/// Zeigt den Preisverlauf zusätzlich als Diagramm (``preisDiagramm``, GitHub #21)
/// — nur sichtbar, wenn mindestens eine Position einen erfassten Preis hat.
/// Einzelne Positionen lassen sich per Wischgeste dauerhaft löschen, z.B. wenn
/// eine offensichtlich falsch erfasste Position („fällt aus dem Rahmen“) die
/// Preisspanne verzerrt.
private struct ArtikelPreisVerlaufView: View {
    let artikel: Artikel
    @Environment(\.modelContext) private var modelContext
    /// Alle Belegpositionen dieses Geschäfts — bewusst nur nach **einer** Beziehung
    /// live gefiltert (siehe ``eintraege``), statt eines zusammengesetzten
    /// `#Predicate` über zwei Beziehungen (`artikel` **und** `geschaeft`) — dieses
    /// Zwei-Beziehungen-Muster taucht an anderer Stelle im Code nur in einmaligen
    /// `context.fetch`-Aufrufen auf, nie in einem live `@Query`. Rein defensiv;
    /// die eigentliche Ursache des GitHub-#33-Hängers war, dass dieser View bis vor
    /// Kurzem als Closure-Destination eines wertlosen `NavigationLink` konstruiert
    /// wurde (siehe ``GeschaeftPreisUebersichtView``, jetzt `NavigationLink(value:)`
    /// + `.navigationDestination(for:)`).
    @Query private var eintraegeDesGeschaefts: [KaufEintrag]

    init(artikel: Artikel, geschaeft: Geschaeft) {
        self.artikel = artikel
        let geschaeftID = geschaeft.persistentModelID
        _eintraegeDesGeschaefts = Query(
            filter: #Predicate<KaufEintrag> { $0.geschaeft?.persistentModelID == geschaeftID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    /// ``eintraegeDesGeschaefts``, zusätzlich auf ``artikel`` eingegrenzt — die
    /// zweite Filterbedingung läuft bewusst in Swift statt im `#Predicate` (siehe
    /// Dokumentation an ``eintraegeDesGeschaefts``).
    private var eintraege: [KaufEintrag] {
        eintraegeDesGeschaefts.filter { $0.artikel?.persistentModelID == artikel.persistentModelID }
    }

    /// ``eintraege`` mit vorhandenem Preis, chronologisch aufsteigend — Grundlage
    /// für ``preisDiagramm``. `eintraege` selbst bleibt absteigend (neueste zuerst)
    /// für die Listendarstellung darunter.
    private var preisPunkte: [PreisVerlaufPunkt] {
        eintraege
            .compactMap { eintrag -> PreisVerlaufPunkt? in
                guard let preis = eintrag.preis else { return nil }
                return PreisVerlaufPunkt(id: eintrag.persistentModelID, datum: eintrag.datum, preis: preis)
            }
            .sorted { $0.datum < $1.datum }
    }

    var body: some View {
        List {
            if !preisPunkte.isEmpty {
                Section {
                    preisDiagramm
                        .frame(height: 180)
                        .padding(.vertical, 8)
                }
            }

            Section {
                ForEach(eintraege) { eintrag in
                    PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: true, loeschen: { eintragLoeschen(eintrag) })
                }
            } footer: {
                Text("Nach links wischen, um einen einzelnen Preis dauerhaft zu löschen — z.B. bei einer offensichtlich falsch erfassten Position.")
            }
        }
        .navigationTitle(artikel.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var preisDiagramm: some View {
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
    }

    /// Löscht `eintrag` dauerhaft — bewusst ohne Rückfrage, analog zu anderen
    /// Wisch-Lösch-Aktionen in der App (z.B. Kategorie-Entfernen).
    private func eintragLoeschen(_ eintrag: KaufEintrag) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                // Tombstone verhindert, dass ein Peer, der den Kaufeintrag
                // noch in seinem eigenen Snapshot führt, ihn beim nächsten
                // Sync unwissentlich wiederbelebt (GitHub #52-Nachfolgefund).
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintrag.id, context: modelContext)
                modelContext.delete(eintrag)
            }
        }
    }
}

/// Ein einzelner Datenpunkt im Preisverlauf-Diagramm (``ArtikelPreisVerlaufView``).
private struct PreisVerlaufPunkt: Identifiable {
    let id: PersistentIdentifier
    let datum: Date
    let preis: Decimal

    var preisAlsDouble: Double {
        NSDecimalNumber(decimal: preis).doubleValue
    }
}

#Preview {
    NavigationStack {
        GeschaeftPreisUebersichtView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Artikel.self, KaufEintrag.self], inMemory: true)
}
