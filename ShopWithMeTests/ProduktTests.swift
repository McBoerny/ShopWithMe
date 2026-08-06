import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ProduktTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, ArtikelKategorie.self, Produkt.self, Produktname.self, Preispunkt.self, Geschaeft.self, GeschaeftTyp.self])
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

    // MARK: - Rekursive Preis-Aggregation (GitHub #47, Schritt 3/5)

    @Test
    func minimumMaximumSindNilOhnePreispunkte() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let produkt = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(produkt)

        #expect(produkt.minimum == nil)
        #expect(produkt.maximum == nil)
    }

    @Test
    func minimumMaximumAusEigenenPreispunktenEinesBlattProdukts() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let produkt = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(produkt)
        context.insert(Preispunkt(artikel: zahnpasta, produkt: produkt, geschaeft: nil, preis: 1.99))
        context.insert(Preispunkt(artikel: zahnpasta, produkt: produkt, geschaeft: nil, preis: 2.49))

        #expect(produkt.minimum == 1.99)
        #expect(produkt.maximum == 2.49)
    }

    @Test
    func minimumMaximumKumuliertUeberUnterProdukte() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        context.insert(paradontol)
        let klein = Produkt(name: "Paradontol 75ml", artikel: zahnpasta, elternProdukt: paradontol)
        context.insert(klein)
        let gross = Produkt(name: "Paradontol 125ml", artikel: zahnpasta, elternProdukt: paradontol)
        context.insert(gross)
        context.insert(Preispunkt(artikel: zahnpasta, produkt: klein, geschaeft: nil, preis: 1.99))
        context.insert(Preispunkt(artikel: zahnpasta, produkt: gross, geschaeft: nil, preis: 3.49))

        // Das Eltern-Produkt selbst trägt keinen eigenen Preispunkt — kumuliert
        // trotzdem über beide Unter-Produkte hinweg.
        #expect(paradontol.minimum == 1.99)
        #expect(paradontol.maximum == 3.49)
    }

    @Test
    func minimumMaximumKumuliertMehrstufigRekursiv() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let wurzel = Produkt(name: "Paradontol", artikel: zahnpasta)
        context.insert(wurzel)
        let zahncreme = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta, elternProdukt: wurzel)
        context.insert(zahncreme)
        let klein = Produkt(name: "Paradontol Zahncreme 75ml", artikel: zahnpasta, elternProdukt: zahncreme)
        context.insert(klein)
        context.insert(Preispunkt(artikel: zahnpasta, produkt: klein, geschaeft: nil, preis: 2.29))

        // Zwei Ebenen tief — muss trotzdem beim Großvater-Produkt ankommen.
        #expect(wurzel.minimum == 2.29)
        #expect(wurzel.maximum == 2.29)
        #expect(zahncreme.minimum == 2.29)
    }
}
