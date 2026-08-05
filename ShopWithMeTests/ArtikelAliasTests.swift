import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelAliasTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, ArtikelKategorie.self, ArtikelAlias.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func manuellHinzufuegenLegtNeuenAliasAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)

        let alias = try ArtikelAlias.manuellHinzufuegen(name: "Zahncreme", zu: zahnpasta, alle: [], context: context)

        #expect(alias.erkannterName == "Zahncreme")
        #expect(alias.artikel === zahnpasta)
        #expect(alias.alternativerName == nil)
    }

    @Test
    func manuellHinzufuegenIstIdempotentFuerDenselbenArtikel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        let bestehender = ArtikelAlias(erkannterName: "Zahncreme", alternativerName: nil, artikel: zahnpasta)

        let ergebnis = try ArtikelAlias.manuellHinzufuegen(
            name: "zahncreme", zu: zahnpasta, alle: [bestehender], context: context
        )

        #expect(ergebnis === bestehender)
    }

    @Test
    func manuellHinzufuegenBlockiertBeiAnderemArtikel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let mundpflege = Artikel(name: "Mundpflege", symbolName: "sparkles", farbeHex: "#AF52DE")
        context.insert(zahnpasta)
        context.insert(mundpflege)
        let bestehender = ArtikelAlias(erkannterName: "Zahncreme", alternativerName: nil, artikel: zahnpasta)

        #expect(throws: ArtikelAlias.ManuellHinzufuegenFehler.self) {
            try ArtikelAlias.manuellHinzufuegen(
                name: "Zahncreme", zu: mundpflege, alle: [bestehender], context: context
            )
        }
    }
}
