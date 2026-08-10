import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, ArtikelKategorie.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func dubletteFindetArtikelMitGleichemNamenCaseInsensitiv() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let bestehender = Artikel(name: "Berner Würstl", symbolName: "cart", farbeHex: "#000000")
        context.insert(bestehender)

        let treffer = Artikel.dublette(name: "berner würstl", alle: [bestehender], ausgenommen: nil)

        #expect(treffer === bestehender)
    }

    @Test
    func dubletteIgnoriertFuehrendeUndAbschliessendeLeerzeichen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let bestehender = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(bestehender)

        let treffer = Artikel.dublette(name: "  Milch  ", alle: [bestehender], ausgenommen: nil)

        #expect(treffer === bestehender)
    }

    @Test
    func dubletteSchliesstSichSelbstAus() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)

        let treffer = Artikel.dublette(name: "Milch", alle: [artikel], ausgenommen: artikel)

        #expect(treffer == nil)
    }

    @Test
    func dubletteLiefertNilBeiUnterschiedlichenNamen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let milch = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(milch)

        let treffer = Artikel.dublette(name: "Vollmilch", alle: [milch], ausgenommen: nil)

        #expect(treffer == nil)
    }

    @Test
    func dubletteLiefertNilBeiLeeremNamen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let milch = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(milch)

        let treffer = Artikel.dublette(name: "   ", alle: [milch], ausgenommen: nil)

        #expect(treffer == nil)
    }
}
