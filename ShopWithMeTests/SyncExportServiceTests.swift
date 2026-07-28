import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncExportServiceTests {
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

    @Test
    func exportiereNeueEventsSchreibtJeEventEineDateiUndMarkiertHochgeladen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)
        liste.artikelEntfernen(apfel, context: context)

        await SyncExportService.exportiereNeueEvents(context: context)

        let events = try context.fetch(FetchDescriptor<SyncEvent>())
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.hochgeladen })

        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        let geschriebeneDateien = try FileManager.default.contentsOfDirectory(at: eventsOrdner, includingPropertiesForKeys: nil)
        #expect(geschriebeneDateien.count == 2)

        let dekodiert = try geschriebeneDateien.map { url in
            try JSONDecoder().decode(SyncEventExportDarstellung.self, from: Data(contentsOf: url))
        }
        #expect(Set(dekodiert.map(\.id)) == Set(events.map(\.id)))
    }

    @Test
    func exportiereNeueEventsUeberspringtBereitsHochgeladeneEvents() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        await SyncExportService.exportiereNeueEvents(context: context)

        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(birne)
        liste.artikelHinzufuegen(birne, context: context)

        await SyncExportService.exportiereNeueEvents(context: context)

        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        let geschriebeneDateien = try FileManager.default.contentsOfDirectory(at: eventsOrdner, includingPropertiesForKeys: nil)
        #expect(geschriebeneDateien.count == 2)
    }

    @Test
    func exportiereNeueEventsOhneSyncOrdnerTutNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        SyncOrdnerService.ordnerEntfernen()

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        await SyncExportService.exportiereNeueEvents(context: context)

        let events = try context.fetch(FetchDescriptor<SyncEvent>())
        #expect(events.count == 1)
        #expect(events.first?.hochgeladen == false)
    }
}
