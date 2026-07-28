import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelVerfuegbarkeitServiceTests {
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

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }
    private func sonstigesTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Sonstiges", symbolName: "shippingbox.fill") }

    @Test
    func geschaeftMitDirektZugeordneterKategorie() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        geschaeft.kategorien = [obst]

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(shampoo)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(apfel, in: geschaeft, context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(shampoo, in: geschaeft, context: context))
    }

    @Test
    func geschaeftLerntAusAbhaken() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typen: [sonstigesTyp()])
        context.insert(kiosk)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", kategorien: [sonstiges])
        context.insert(kaugummi)

        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))

        let einkauf = Einkaufsvorgang(geschaeft: kiosk)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))
    }

    @Test
    func geschaeftIgnoriertKaeufeAusAnderenGeschaeften() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typen: [sonstigesTyp()])
        let anderesGeschaeft = Geschaeft(name: "Anderer Kiosk", typen: [sonstigesTyp()])
        context.insert(kiosk)
        context.insert(anderesGeschaeft)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", kategorien: [sonstiges])
        context.insert(kaugummi)

        let einkauf = Einkaufsvorgang(geschaeft: anderesGeschaeft)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: anderesGeschaeft, context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, context: context))
    }
}
