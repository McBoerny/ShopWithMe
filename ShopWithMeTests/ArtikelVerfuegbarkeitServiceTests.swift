import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelVerfuegbarkeitServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Regal.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self, KategorieBesuchsStatistik.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func geschaeftMitRegalenNutztRegalZuordnung() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Rewe", typ: .lebensmittel)
        context.insert(geschaeft)
        let obstregal = Regal(name: "Obstregal", sortIndex: 0, geschaeft: geschaeft)
        obstregal.kategorien = [obst]
        context.insert(obstregal)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst)
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorie: drogerie)
        context.insert(apfel)
        context.insert(shampoo)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(apfel, in: geschaeft, context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(shampoo, in: geschaeft, context: context))
    }

    @Test
    func geschaeftOhneRegaleLerntAusAbhaken() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typ: .sonstiges)
        context.insert(kiosk)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", kategorie: sonstiges, istAufEinkaufsliste: true)
        context.insert(kaugummi)

        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))

        let einkauf = Einkaufsvorgang(geschaeft: kiosk)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))
    }

    @Test
    func geschaeftOhneRegaleIgnoriertKaeufeAusAnderenGeschaeften() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typ: .sonstiges)
        let anderesGeschaeft = Geschaeft(name: "Anderer Kiosk", typ: .sonstiges)
        context.insert(kiosk)
        context.insert(anderesGeschaeft)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", kategorie: sonstiges, istAufEinkaufsliste: true)
        context.insert(kaugummi)

        let einkauf = Einkaufsvorgang(geschaeft: anderesGeschaeft)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: anderesGeschaeft, context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))
    }
}
