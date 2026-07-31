import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncSnapshotExportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self, SyncEvent.self,
            SyncPeerZaehlerStand.self, Preispunkt.self, ArtikelAlias.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    @Test
    func erstelleSnapshotEnthaeltAlleBereicheKorrektVerknuepft() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let kategorie = ArtikelKategorie(name: "Obst & Gemüse", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        kategorie.geschaeftsTypen = [typ]
        context.insert(kategorie)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        geschaeft.erkennungsradiusRaw = 150
        geschaeft.kategorien = [kategorie]
        geschaeft.eigeneAnzahlEinkaufsvorgaenge = 3
        context.insert(geschaeft)
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: geschaeft)
        context.insert(ignoriert)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [kategorie])
        context.insert(apfel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let laufenderEinkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(laufenderEinkauf)
        let eintrag = KaufEintrag(artikel: apfel, geschaeft: geschaeft, kategorie: kategorie)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = laufenderEinkauf
        let preispunkt = Preispunkt(artikel: apfel, geschaeft: geschaeft, preis: 1.99)
        context.insert(preispunkt)
        let alias = ArtikelAlias(erkannterName: "APF-BIO", alternativerName: "Bio-Apfel", artikel: apfel)
        context.insert(alias)
        let kategorie2 = ArtikelKategorie(name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF")
        context.insert(kategorie2)
        let distanz = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kategorie, kategorieB: kategorie2, distanz: 0.3)
        context.insert(distanz)
        try context.save()

        let snapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)

        #expect(snapshot.formatVersion == SyncSnapshot.aktuelleFormatVersion)
        #expect(snapshot.geschaeftsTypen.map(\.id) == [typ.id])

        let kategorieSnapshot = try #require(snapshot.artikelKategorien.first { $0.id == kategorie.id })
        #expect(kategorieSnapshot.geschaeftsTypIDs == [typ.id])

        let geschaeftSnapshot = try #require(snapshot.geschaefte.first { $0.id == geschaeft.id })
        #expect(geschaeftSnapshot.typIDs == [typ.id])
        #expect(geschaeftSnapshot.erkennungsradius == 150)
        #expect(geschaeftSnapshot.kategorieIDs == [kategorie.id])
        #expect(geschaeftSnapshot.ignorierteArtikelNamen == ["Pfand"])
        #expect(geschaeftSnapshot.eigeneAnzahlEinkaufsvorgaenge == 3)

        let artikelSnapshot = try #require(snapshot.artikel.first { $0.id == apfel.id })
        #expect(artikelSnapshot.kategorieIDs == [kategorie.id])

        #expect(snapshot.einkaufslisten.map(\.id) == [liste.id])

        let einkaufsvorgangSnapshot = try #require(snapshot.einkaufsvorgaenge.first { $0.id == laufenderEinkauf.id })
        #expect(einkaufsvorgangSnapshot.geschaeftID == geschaeft.id)
        #expect(einkaufsvorgangSnapshot.einkaufslisteID == liste.id)
        #expect(einkaufsvorgangSnapshot.endZeit == nil)

        let kaufEintragSnapshot = try #require(snapshot.kaufEintraege.first { $0.id == eintrag.id })
        #expect(kaufEintragSnapshot.artikelID == apfel.id)
        #expect(kaufEintragSnapshot.einkaufsvorgangID == laufenderEinkauf.id)

        let preispunktSnapshot = try #require(snapshot.preispunkte.first { $0.id == preispunkt.id })
        #expect(preispunktSnapshot.artikelID == apfel.id)
        #expect(preispunktSnapshot.preis == 1.99)

        let aliasSnapshot = try #require(snapshot.artikelAliase.first { $0.id == alias.id })
        #expect(aliasSnapshot.erkannterName == "APF-BIO")
        #expect(aliasSnapshot.alternativerName == "Bio-Apfel")
        #expect(aliasSnapshot.artikelID == apfel.id)

        let distanzSnapshot = try #require(snapshot.warengruppenDistanzen.first { $0.id == distanz.id })
        #expect(distanzSnapshot.kategorieAID == kategorie.id)
        #expect(distanzSnapshot.kategorieBID == kategorie2.id)
    }

    @Test
    func exportiereSnapshotSchreibtExportJsonNachEigenemPeerOrdner() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        try context.save()

        await SyncSnapshotExportService.exportiereSnapshot(context: context)

        let exportURL = SyncSnapshotExportService.eigeneExportURL(in: syncOrdner)
        let daten = try Data(contentsOf: exportURL)
        let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: daten)
        #expect(snapshot.geschaefte.map(\.id) == [geschaeft.id])
        #expect(snapshot.geraeteID == DatabaseLeaseService.geraeteID)
    }

    @Test
    func exportiereSnapshotOhneSyncOrdnerTutNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        SyncOrdnerService.ordnerEntfernen()

        await SyncSnapshotExportService.exportiereSnapshot(context: context)
        // Kein Absturz, keine Datei — nichts weiter zu prüfen ohne einen
        // konfigurierten Ordner, dessen Inhalt man einsehen könnte.
    }

    /// Regressionstest für einen Live-Test-Nachfolgefund (2026-07-31): nicht
    /// nur die äußeren Snapshot-Arrays (ein Eintrag je Entität), auch die
    /// ID-Arrays INNERHALB eines Eintrags (z.B. `GeschaeftSnapshot/typIDs`,
    /// aus einer SwiftData-`@Relationship`-Sammlung abgeleitet) haben keine
    /// garantierte Fetch-Reihenfolge — ohne Sortierung dieser inneren Arrays
    /// erschien praktisch jeder Sync-Zyklus fälschlich als inhaltliche
    /// Änderung. Zwei Snapshots mit identischem Inhalt, aber unterschiedlicher
    /// Reihenfolge sowohl der äußeren Geschäfte-Liste als auch der inneren
    /// `typIDs`/`kategorieIDs`/`alternativeNamen`/`ignorierteArtikelNamen`
    /// müssen denselben Fingerabdruck ergeben.
    @Test
    func fingerabdruckIstUnabhaengigVonReihenfolgeAeussererUndInnererArrays() {
        let geschaeftID = UUID()
        let typA = UUID()
        let typB = UUID()
        let kategorieA = UUID()
        let kategorieB = UUID()

        func snapshot(typIDs: [UUID], kategorieIDs: [UUID], namen: [String]) -> SyncSnapshot {
            SyncSnapshot(
                formatVersion: SyncSnapshot.aktuelleFormatVersion, erzeugtAm: Date(), geraeteID: "geraet", geraeteName: "Gerät",
                geschaeftsTypen: [], artikelKategorien: [],
                geschaefte: [
                    GeschaeftSnapshot(
                        id: geschaeftID, name: "Rewe", typIDs: typIDs, adresse: nil, breitengrad: nil, laengengrad: nil,
                        erkennungsradius: nil, kategorieIDs: kategorieIDs, ausgeschlosseneKategorieIDs: [],
                        alternativeNamen: namen, ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0,
                        umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
                    ),
                ],
                artikel: [], einkaufslisten: [], einkaufslistenEintraege: [], einkaufsvorgaenge: [], kaufEintraege: [],
                preispunkte: [], artikelAliase: [],
                warengruppenDistanzen: [], tombstones: []
            )
        }

        let a = snapshot(typIDs: [typA, typB], kategorieIDs: [kategorieA, kategorieB], namen: ["Rewe Center", "Rewe City"])
        let b = snapshot(typIDs: [typB, typA], kategorieIDs: [kategorieB, kategorieA], namen: ["Rewe City", "Rewe Center"])

        let fingerabdruckA = SyncSnapshotExportService.inhaltsFingerabdruck(of: SyncSnapshotExportService.normalisiertFuerVergleich(a))
        let fingerabdruckB = SyncSnapshotExportService.inhaltsFingerabdruck(of: SyncSnapshotExportService.normalisiertFuerVergleich(b))

        #expect(fingerabdruckA == fingerabdruckB)
    }
}
