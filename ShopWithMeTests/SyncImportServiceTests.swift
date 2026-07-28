import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Simuliert zwei Geräte, die sich über einen echten (temporären) gemeinsamen
/// Sync-Ordner austauschen — jedes Gerät bekommt seinen eigenen In-Memory-
/// `ModelContainer`, beide teilen sich dieselbe `SyncOrdnerService`/
/// `DatabaseLeaseService`-Konfiguration (prozessweite Singletons), daher werden
/// diese vor/nach jedem Testfall explizit zurückgesetzt bzw. isoliert
/// (`geraeteID` wird für „das andere Gerät" nicht über den echten
/// `DatabaseLeaseService.geraeteID` simuliert, sondern per direktem
/// Dateisystem-Layout, siehe ``schreibeFremdesEvent``).
@MainActor
struct SyncImportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
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

    /// Schreibt ein Event so, als käme es von einem fremden Gerät `fremdeGeraeteID`
    /// (nutzt direkt `SyncExportService.eventsOrdner`, um nicht auf den echten,
    /// prozessweiten ``DatabaseLeaseService/geraeteID`` angewiesen zu sein).
    private func schreibeFremdesEvent(
        _ event: SyncEventExportDarstellung, fremdeGeraeteID: String, in syncOrdner: URL
    ) throws {
        let ordner = SyncExportService.eventsOrdner(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let dateiname = "\(String(format: "%010d", event.lamportZaehler))_\(event.id.uuidString).json"
        try JSONEncoder().encode(event).write(to: ordner.appendingPathComponent(dateiname))
    }

    @Test
    func importiertArtikelHinzugefuegtVonFremdemGeraet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(liste.enthaelt(apfel))
        let uebernommeneEvents = try context.fetch(FetchDescriptor<SyncEvent>())
        let uebernommen = try #require(uebernommeneEvents.first { $0.id == fremdesEvent.id })
        #expect(uebernommen.autorGeraeteID == "fremdes-geraet")
        #expect(uebernommen.hochgeladen == true)
    }

    @Test
    func importVonBereitsBekanntemEventWirdNichtErneutAngewendet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)
        liste.artikelEntfernenOhneEventAufzeichnung(apfel, context: context)
        try context.save()
        await SyncImportService.importiereNeueEvents(context: context)

        // Das (identische) Event darf beim zweiten Lauf nicht erneut angewendet
        // werden — sonst wäre der Artikel wieder auf der Liste.
        #expect(!liste.enthaelt(apfel))
    }

    @Test
    func abwaehlenGewinntGegenAbhakenUnabhaengigVonReihenfolge() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegenOhneEventAufzeichnung(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        // Lokal (dieses Gerät) abgehakt, mit niedrigerem Lamport-Zähler.
        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        let lokalesEvent = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id),
            lamportZaehler: 5, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(lokalesEvent)
        try context.save()

        // Fremdes Gerät hat (kausal unabhängig, höherer Lamport-Zähler) denselben
        // Artikel wieder abgewählt.
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 10, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(einkauf.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(apfel))
    }

    @Test
    func schwaechesAbwaehlenGewinntNichtGegenBekanntesDauerhaftEntfernen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        // Lokal bereits dauerhaft entfernt, mit HÖHEREM Lamport-Zähler als das
        // gleich ankommende, fremde "abgewählt".
        let lokalesEvent = SyncEvent(
            art: .artikelDauerhaftEntfernt,
            nutzlast: SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id),
            lamportZaehler: 20, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(lokalesEvent)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 3, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        // "Dauerhaft entfernt" schlägt alles — der Artikel darf NICHT wieder auf
        // die Liste zurückgesetzt worden sein.
        #expect(!liste.enthaelt(apfel))
    }

    @Test
    func referenzierterEinkaufsvorgangNochNichtLokalBekanntWirdNichtAlsBekanntMarkiert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        // bezugsID verweist auf einen Einkaufsvorgang, den dieses Gerät (noch)
        // nicht kennt (Bereich-B/C-Import ist erst Phase 3).
        let unbekannteVorgangsID = UUID()
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: unbekannteVorgangsID, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        // Nicht als bekannt markiert -> beim nächsten Zyklus wird ein erneuter
        // Versuch unternommen (kein permanenter Datenverlust).
        #expect(SyncEventService.istBereitsBekannt(fremdesEvent.id, context: context) == false)
    }
}
