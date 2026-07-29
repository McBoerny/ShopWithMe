import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``SyncErsetzenService``/``ModelContainerController`` (GitHub #63
/// + Korruptions-Recovery, siehe `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`).
///
/// Anders als die übrigen Tests dieses Projekts braucht
/// ``ModelContainerController/ersetzeDurchLeerenContainer()`` einen
/// dateibasierten statt In-Memory-Container — eine In-Memory-Datenbank hat
/// keine Datei zum Löschen.
@MainActor
struct SyncErsetzenServiceTests {
    private func machtDateiBasiertenContainer() throws -> (url: URL, container: ModelContainer, context: ModelContext) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("syncersetzen-test-\(UUID().uuidString).sqlite")
        let konfiguration = ModelConfiguration(schema: SchemaDefinition.schema, url: url)
        let container = try ModelContainer(for: SchemaDefinition.schema, configurations: [konfiguration])
        return (url, container, container.mainContext)
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
            warengruppenDistanzen: [], tombstones: []
        )
    }

    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let url = SyncSnapshotExportService.exportURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
    }

    private func leerenGeschaeftSnapshot(name: String) -> GeschaeftSnapshot {
        GeschaeftSnapshot(
            id: UUID(), name: name, typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
            erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
            ignorierteArtikelNamen: [], anzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
        )
    }

    /// Fügt genau einen Datensatz jedes der 16 Schema-Modelltypen ein, damit
    /// ``ModelContainerController/ersetzeDurchLeerenContainer()`` gegen einen
    /// vollständig befüllten Store getestet werden kann.
    private func befuelleAllesEinmal(context: ModelContext) throws {
        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        let kategorie = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        let liste = Einkaufsliste(name: "Einkaufsliste")
        let listenEintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: 1)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        let kaufEintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft)
        let distanz = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kategorie, kategorieB: kategorie, distanz: 1)
        let ignArtikel = IgnorierterArtikel(erkannterName: "Test", geschaeft: geschaeft)
        let ignVorschlag = IgnorierterGeschaeftsVorschlag(name: "Test", breitengrad: nil, laengengrad: nil)
        let syncEvent = SyncEvent(
            art: .artikelHinzugefuegt, nutzlast: SyncEventNutzlast(bezugsID: UUID(), artikelID: UUID()),
            lamportZaehler: 1, lamportGeraeteID: "geraet", autorGeraeteID: "geraet"
        )
        let alias = SyncEntitaetsAlias(entitaetsArt: SyncEntitaetsArt.artikel, fremdeID: UUID(), lokaleID: UUID())
        let zaehlerStand = SyncPeerZaehlerStand(peerGeraeteID: "peer", geschaeftID: UUID(), zuletztGesehenerWert: 1)
        let peerInfo = SyncPeerInfo(peerGeraeteID: "peer", geraeteName: "Testgerät")
        let tombstone = SyncTombstone(entitaetsArt: SyncEntitaetsArt.artikel, geloeschteID: UUID())

        context.insert(typ)
        context.insert(geschaeft)
        context.insert(kategorie)
        context.insert(artikel)
        context.insert(liste)
        context.insert(listenEintrag)
        context.insert(vorgang)
        context.insert(kaufEintrag)
        context.insert(distanz)
        context.insert(ignArtikel)
        context.insert(ignVorschlag)
        context.insert(syncEvent)
        context.insert(alias)
        context.insert(zaehlerStand)
        context.insert(peerInfo)
        context.insert(tombstone)
        try context.save()
    }

    @Test
    func ersetzeDurchLeerenContainerLeertAlleModelltypen() throws {
        let (url, container, context) = try machtDateiBasiertenContainer()
        defer { try? FileManager.default.removeItem(at: url) }
        try befuelleAllesEinmal(context: context)

        let controller = ModelContainerController(modelContainer: container)
        let neuerContext = try controller.ersetzeDurchLeerenContainer()

        #expect(try neuerContext.fetchCount(FetchDescriptor<Geschaeft>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<GeschaeftTyp>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<Artikel>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<Einkaufsliste>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<EinkaufslistenEintrag>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<WarengruppenDistanz>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<IgnorierterArtikel>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<IgnorierterGeschaeftsVorschlag>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<SyncEvent>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<SyncEntitaetsAlias>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<SyncPeerZaehlerStand>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<SyncPeerInfo>()) == 0)
        #expect(try neuerContext.fetchCount(FetchDescriptor<SyncTombstone>()) == 0)
        #expect(controller.modelContainer.configurations.first?.url == url)
    }

    @Test
    func backupRundlaufEnthaeltSnapshotUndIgnorierteVorschlaege() throws {
        let (url, container, context) = try machtDateiBasiertenContainer()
        _ = container
        defer { try? FileManager.default.removeItem(at: url) }
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        context.insert(IgnorierterGeschaeftsVorschlag(name: "Aldi", breitengrad: 1.0, laengengrad: 2.0))
        try context.save()

        let backupURL = try SyncErsetzenService.erstelleBackup(context: context)
        let daten = try Data(contentsOf: backupURL)
        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)

        #expect(backup.snapshot.geschaefte.map(\.name) == ["Rewe"])
        #expect(backup.ignorierteGeschaeftsVorschlaege.map(\.name) == ["Aldi"])
        #expect(SyncErsetzenService.vorhandenesBackup() != nil)
    }

    @Test
    func erneutesBackupUeberschreibtDasVorherige() throws {
        let (url, container, context) = try machtDateiBasiertenContainer()
        _ = container
        defer { try? FileManager.default.removeItem(at: url) }
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()
        let ersteBackupURL = try SyncErsetzenService.erstelleBackup(context: context)

        context.insert(Geschaeft(name: "Edeka", typen: []))
        try context.save()
        let zweiteBackupURL = try SyncErsetzenService.erstelleBackup(context: context)

        #expect(ersteBackupURL == zweiteBackupURL)
        let daten = try Data(contentsOf: zweiteBackupURL)
        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
        #expect(Set(backup.snapshot.geschaefte.map(\.name)) == Set(["Rewe", "Edeka"]))
    }

    @Test
    func ersetzenDurchPeerVerwirftLokaleDatenStattZuMergen() async throws {
        let (url, container, context) = try machtDateiBasiertenContainer()
        defer { try? FileManager.default.removeItem(at: url) }
        defer { SyncErsetzenService.loescheBackup() }

        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Lokale, "private" Daten, die NICHT übernommen werden sollen.
        context.insert(Geschaeft(name: "Privater Laden", typen: []))
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Rewe")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)

        let controller = ModelContainerController(modelContainer: container)
        let neuerContext = try await SyncErsetzenService.ersetzenDurchPeer(containerController: controller)

        let geschaefte = try neuerContext.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefte.map(\.name) == ["Rewe"])
    }

    @Test
    func wiederherstellenAusBackupStelltGesichertenStandWiederHer() throws {
        let (url, container, context) = try machtDateiBasiertenContainer()
        defer { try? FileManager.default.removeItem(at: url) }
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()
        try SyncErsetzenService.erstelleBackup(context: context)

        let controller = ModelContainerController(modelContainer: container)
        let neuerContext = try SyncErsetzenService.wiederherstellenAusBackup(containerController: controller)

        let geschaefte = try neuerContext.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefte.map(\.name) == ["Rewe"])
    }
}
