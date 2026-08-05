import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct KaufEintragBereinigungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, Preispunkt.self, ArtikelAlias.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncTombstone.self, ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    @Test
    func bereinigenLaesstEintraegeEinesLaufendenEinkaufsUnangetastet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let laufenderEinkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(laufenderEinkauf)

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = laufenderEinkauf
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
    }

    @Test
    func bereinigenLaesstFrischAbgeschlossenenEinkaufInnerhalbDerKarenzzeitUnangetastet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        vorgang.abschliessen(am: jetzt.addingTimeInterval(-1 * 60 * 60))
        context.insert(vorgang)

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = vorgang
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context, jetzt: jetzt)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
    }

    @Test
    func bereinigenLoeschtEintraegeUndLeerenVorgangNachKarenzzeitMitTombstone() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        vorgang.abschliessen(am: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        context.insert(vorgang)
        let vorgangID = vorgang.id

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = vorgang
        let eintragID = eintrag.id
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context, jetzt: jetzt)

        #expect(anzahl == 1)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintragID, context: context))
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgangID, context: context))
    }

    /// Regressionstest für GitHub #77 (Relationship erst nach `save()` aktuell) —
    /// mehrere Einträge desselben Vorgangs müssen im selben Durchlauf ALLE
    /// gelöscht werden, damit der Vorgang danach korrekt als leer erkannt wird.
    @Test
    func bereinigenErkenntVorgangAlsLeerAuchBeiMehrerenKaufEintraegen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        vorgang.abschliessen(am: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        context.insert(vorgang)
        let vorgangID = vorgang.id

        let eintragEins = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintragEins)
        eintragEins.einkaufsvorgang = vorgang
        let eintragZwei = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintragZwei)
        eintragZwei.einkaufsvorgang = vorgang
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context, jetzt: jetzt)

        #expect(anzahl == 2)
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgangID, context: context))
    }

    @Test
    func bereinigenLaesstEinkaufsvorgangMitVerbleibendenEintraegenBestehen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        // Vorgang selbst ist alt genug für die Karenzzeit, trägt aber noch einen
        // (durch einen frisch nachgereichten Belegscan denkbaren) zu jungen
        // KaufEintrag — muss deshalb bestehen bleiben. Da alle KaufEintraege hier
        // dieselbe Karenzzeit-Bedingung teilen (kein eigenes `datum`-Feld mehr
        // relevant), simuliert dieser Test stattdessen einen zweiten, noch NICHT
        // abgeschlossenen Vorgang, dessen Eintrag unangetastet bleiben muss,
        // während der erste vollständig aufgeräumt wird.
        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        alterVorgang.abschliessen(am: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        context.insert(alterVorgang)

        let laufenderVorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(laufenderVorgang)
        let laufenderEintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(laufenderEintrag)
        laufenderEintrag.einkaufsvorgang = laufenderVorgang
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context, jetzt: jetzt)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
        let verbleibendeVorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(verbleibendeVorgaenge.count == 1)
        #expect(verbleibendeVorgaenge.first?.id == laufenderVorgang.id)
    }

    /// Regressionstest für einen Analyse-Fund (export.json wuchs trotz aktiver
    /// Bereinigung, weil verwaiste `KaufEintrag`e — `einkaufsvorgang == nil`,
    /// entstanden durch einen Bug in `SyncSnapshotImportService.mergeKaufEintraege`
    /// — vom bisherigen Filter (`einkaufsvorgang?.endZeit`) nie erfasst wurden.
    /// Löschung erfolgt sofort, ohne Karenzzeit (`jetzt` == Erstellungszeitpunkt).
    @Test
    func bereinigenLoeschtVerwaisteEintraegeOhneEinkaufsvorgangSofortMitTombstone() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let verwaisterEintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(verwaisterEintrag)
        let eintragID = verwaisterEintrag.id
        try context.save()

        let anzahl = await KaufEintragBereinigungService.bereinigen(context: context)

        #expect(anzahl == 1)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintragID, context: context))
    }

    /// Regressionstest für GitHub #82: löscht `bereinigen` einen `KaufEintrag`,
    /// muss auch dessen eigene `kaeufe/{id}.json`-Datei (falls dieses Gerät
    /// ihn zuvor per ``SyncKaeufeExportService`` exportiert hatte) im eigenen
    /// Peer-Ordner verschwinden — reine Platzersparnis, der bereits gesetzte
    /// Tombstone schützt unabhängig davon vor Wiederbelebung durch einen Peer.
    @Test
    func bereinigenLoeschtAuchDieEigeneKaeufeDateiDesGeloeschtenEintrags() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: syncOrdner, withIntermediateDirectories: true)
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        vorgang.abschliessen(am: jetzt.addingTimeInterval(-3 * 24 * 60 * 60))
        context.insert(vorgang)
        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = vorgang
        try context.save()

        // Simuliert einen vorherigen Sync-Zyklus, der diesen Eintrag bereits
        // als eigene kaeufe/-Datei exportiert hatte.
        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)
        let kaeufeURL = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
            .appendingPathComponent("\(eintrag.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: kaeufeURL.path))

        await KaufEintragBereinigungService.bereinigen(context: context, jetzt: jetzt)

        #expect(!FileManager.default.fileExists(atPath: kaeufeURL.path))
    }
}
