import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Testet die Sync-Integration von ``Produkt``/``Produktname`` (GitHub #47,
/// Schritt 2/5) — eigene Datei statt Erweiterung von
/// `SyncSnapshotImportServiceTests.swift`, da diese bereits sehr groß ist.
/// Helfer bewusst dupliziert statt geteilt (die Originale dort sind
/// `private`), Umfang hier reduziert auf das für Produkt/Produktname
/// tatsächlich Nötige.
@Suite(.serialized)
@MainActor
struct ProduktSyncTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, Einkaufsliste.self, EinkaufslistenEintrag.self,
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerInfo.self, SyncTombstone.self,
            Preispunkt.self, SyncAbgleichKandidat.self, Produkt.self, Produktname.self,
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

    private func leererSnapshot(geraeteID: String, geraeteName: String = "Fremdes iPhone") -> SyncSnapshot {
        SyncSnapshot(
            formatVersion: SyncSnapshot.aktuelleFormatVersion, erzeugtAm: Date(), geraeteID: geraeteID, geraeteName: geraeteName,
            geschaeftsTypen: [], artikelKategorien: [], geschaefte: [], artikel: [],
            einkaufslisten: [], einkaufslistenEintraege: [], einkaufsvorgaenge: [], kaufEintraege: [],
            preispunkte: [],
            warengruppenDistanzen: [], tombstones: []
        )
    }

    /// Analog `SyncSnapshotImportServiceTests.schreibeFremdenSnapshot` —
    /// hier zusätzlich `produkte`/`produktnamen` ins `stamm.json` mit
    /// aufgenommen (dort noch nicht nötig gewesen).
    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: snapshot.erzeugtAm,
            geraeteID: snapshot.geraeteID, geraeteName: snapshot.geraeteName
        )
        let stamm = SyncStammSnapshot(
            geschaeftsTypen: snapshot.geschaeftsTypen, artikelKategorien: snapshot.artikelKategorien,
            geschaefte: snapshot.geschaefte, artikel: snapshot.artikel, einkaufslisten: snapshot.einkaufslisten,
            produkte: snapshot.produkte, produktnamen: snapshot.produktnamen
        )
        let listen = SyncListenSnapshot(einkaufslistenEintraege: snapshot.einkaufslistenEintraege)
        let lernen = SyncLernenSnapshot(warengruppenDistanzen: snapshot.warengruppenDistanzen)
        let vorgaenge = SyncVorgaengeSnapshot(einkaufsvorgaenge: snapshot.einkaufsvorgaenge)
        let preise = SyncPreisSnapshot(preispunkte: snapshot.preispunkte)

        let manifestURL = SyncSnapshotExportService.manifestURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(snapshot.tombstones)
            .write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(stamm).write(to: SyncSnapshotExportService.stammURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(listen).write(to: SyncSnapshotExportService.listenURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(lernen).write(to: SyncSnapshotExportService.lernenURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(vorgaenge).write(to: SyncSnapshotExportService.vorgaengeURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(preise).write(to: SyncSnapshotExportService.preiseURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
    }

    @Test
    func produktWirdPerNameInnerhalbArtikelGematchtStattDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let lokalesProdukt = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(lokalesProdukt)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let fremdeProduktID = UUID()
        snapshot.produkte = [
            ProduktSnapshot(id: fremdeProduktID, name: "Paradontol Zahncreme", artikelID: zahnpasta.id, elternProduktID: nil, istStandard: false),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let alleProdukte = try context.fetch(FetchDescriptor<Produkt>())
        #expect(alleProdukte.count == 1)
        #expect(alleProdukte.first?.id == lokalesProdukt.id)
    }

    @Test
    func produktMitGleichemNamenUnterAnderemArtikelWirdNichtGematcht() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let shampoo = Artikel(name: "Shampoo", symbolName: "drop.fill", farbeHex: "#5AC8FA")
        context.insert(zahnpasta)
        context.insert(shampoo)
        let lokalesProdukt = Produkt(name: "Sensitiv", artikel: zahnpasta)
        context.insert(lokalesProdukt)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
            ArtikelSnapshot(
                id: shampoo.id, name: "Shampoo", symbolName: "drop.fill", farbeHex: "#5AC8FA",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.produkte = [
            ProduktSnapshot(id: UUID(), name: "Sensitiv", artikelID: shampoo.id, elternProduktID: nil, istStandard: false),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleProdukte = try context.fetch(FetchDescriptor<Produkt>())
        #expect(alleProdukte.count == 2)
        #expect(alleProdukte.filter { $0.name == "Sensitiv" }.count == 2)
    }

    @Test
    func rekursivesElternProduktWirdAufgeloestAuchVorEigenemEintragInDerListe() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let elternID = UUID()
        let kindID = UUID()
        // Kind bewusst VOR dem Elternteil in der Liste — Reihenfolge ist beim
        // Sync nicht garantiert.
        snapshot.produkte = [
            ProduktSnapshot(id: kindID, name: "Paradontol 75ml", artikelID: zahnpasta.id, elternProduktID: elternID, istStandard: false),
            ProduktSnapshot(id: elternID, name: "Paradontol Zahncreme", artikelID: zahnpasta.id, elternProduktID: nil, istStandard: false),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let kind = try #require(try context.fetch(FetchDescriptor<Produkt>(predicate: #Predicate { $0.id == kindID })).first)
        let eltern = try #require(try context.fetch(FetchDescriptor<Produkt>(predicate: #Predicate { $0.id == elternID })).first)
        #expect(kind.elternProdukt?.id == eltern.id)
    }

    @Test
    func produktnameWirdAdditivGemergtOhneDuplikatBeiWiederholtemSync() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let produkt = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(produkt)
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: geschaeft.id, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        snapshot.produkte = [
            ProduktSnapshot(id: produkt.id, name: "Paradontol Zahncreme", artikelID: zahnpasta.id, elternProduktID: nil, istStandard: false),
        ]
        snapshot.produktnamen = [
            ProduktnameSnapshot(id: UUID(), name: "Parad Zahncr", produktID: produkt.id, geschaeftID: geschaeft.id),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let alleNamen = try context.fetch(FetchDescriptor<Produktname>())
        #expect(alleNamen.count == 1)
        #expect(alleNamen.first?.name == "Parad Zahncr")
        #expect(alleNamen.first?.produkt?.id == produkt.id)
        #expect(alleNamen.first?.geschaeft?.id == geschaeft.id)
    }

    @Test
    func preispunktLoestEchteProduktZuordnungAufStattNurStandardProdukt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let fremdeProduktID = UUID()
        snapshot.produkte = [
            ProduktSnapshot(id: fremdeProduktID, name: "Paradontol Zahncreme", artikelID: zahnpasta.id, elternProduktID: nil, istStandard: false),
        ]
        snapshot.preispunkte = [
            PreispunktSnapshot(
                id: UUID(), geschaeftID: nil, preis: 2.49, datum: Date(),
                produktName: nil, alternativerName: nil, geschaeftNameSnapshot: "",
                produktID: fremdeProduktID
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let punkt = try #require(try context.fetch(FetchDescriptor<Preispunkt>()).first)
        #expect(punkt.produkt?.name == "Paradontol Zahncreme")
        #expect(punkt.produkt?.istStandard == false)
    }

    /// Seit der Produkt-Pflicht (GitHub #131) gibt es keinen Fallback auf ein
    /// Standardprodukt mehr — ``SyncSnapshotImportService`` überspringt einen
    /// empfangenen ``Preispunkt`` ohne auflösbare `produktID` defensiv, statt
    /// selbst ein Produkt zu erzeugen (siehe Doku-Kommentar an
    /// `SyncSnapshotImportService.mergePreispunkte`): ein sendender Peer auf
    /// aktuellem Code hätte diesen Fall bereits vor dem Export selbst nicht
    /// mehr anlegen dürfen.
    @Test
    func preispunktOhneProduktIDWirdBeimImportUebersprungen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: zahnpasta.id, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.preispunkte = [
            PreispunktSnapshot(
                id: UUID(), geschaeftID: nil, preis: 2.49, datum: Date(),
                produktName: nil, alternativerName: nil, geschaeftNameSnapshot: "",
                produktID: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).isEmpty)
    }
}
