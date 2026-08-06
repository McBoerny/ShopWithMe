import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ProduktTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, ArtikelKategorie.self, Produkt.self, Produktname.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func standardProduktLegtNeuesAnFallsNochKeinsExistiert() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)

        let produkt = Produkt.standardProdukt(fuer: zahnpasta, context: context)

        #expect(produkt.name == "Zahnpasta")
        #expect(produkt.artikel === zahnpasta)
        #expect(produkt.istStandard)
    }

    @Test
    func standardProduktIstIdempotent() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)

        let erstes = Produkt.standardProdukt(fuer: zahnpasta, context: context)
        let zweites = Produkt.standardProdukt(fuer: zahnpasta, context: context)

        #expect(erstes === zweites)
        let alle = try context.fetch(FetchDescriptor<Produkt>())
        #expect(alle.count == 1)
    }

    @Test
    func standardProduktUnterscheidetVerschiedeneArtikel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let shampoo = Artikel(name: "Shampoo", symbolName: "drop.fill", farbeHex: "#5AC8FA")
        context.insert(zahnpasta)
        context.insert(shampoo)

        let produktZahnpasta = Produkt.standardProdukt(fuer: zahnpasta, context: context)
        let produktShampoo = Produkt.standardProdukt(fuer: shampoo, context: context)

        #expect(produktZahnpasta !== produktShampoo)
        #expect(produktZahnpasta.artikel === zahnpasta)
        #expect(produktShampoo.artikel === shampoo)
    }

    @Test
    func rekursiveUnterProdukteWerdenMitElternGeloescht() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(paradontol)
        let klein = Produkt(name: "Paradontol 75ml", artikel: zahnpasta, elternProdukt: paradontol)
        context.insert(klein)
        try context.save()

        context.delete(paradontol)
        try context.save()

        let alleProdukte = try context.fetch(FetchDescriptor<Produkt>())
        #expect(!alleProdukte.contains { $0.name == "Paradontol 75ml" })
    }
}
