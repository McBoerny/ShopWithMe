import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelVerfuegbarkeitServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
            ArtikelGeschaeftVerfuegbarkeit.self, ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }
    private func sonstigesTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Sonstiges", symbolName: "shippingbox.fill") }

    @Test
    func geschaeftMitDirektZugeordneterAbteilung() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = Abteilung(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        geschaeft.abteilungen = [obst]

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", abteilungen: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", abteilungen: [drogerie])
        context.insert(apfel)
        context.insert(shampoo)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(apfel, in: geschaeft, alleAbteilungen: [obst, drogerie], context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(shampoo, in: geschaeft, alleAbteilungen: [obst, drogerie], context: context))
    }

    @Test
    func geschaeftLerntAusAbhaken() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = Abteilung(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typen: [sonstigesTyp()])
        context.insert(kiosk)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", abteilungen: [sonstiges])
        context.insert(kaugummi)

        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, alleAbteilungen: [sonstiges], context: context))

        let einkauf = Einkaufsvorgang(geschaeft: kiosk)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, alleAbteilungen: [sonstiges], context: context))
    }

    @Test
    func geschaeftIgnoriertKaeufeAusAnderenGeschaeften() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = Abteilung(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)

        let kiosk = Geschaeft(name: "Kiosk", typen: [sonstigesTyp()])
        let anderesGeschaeft = Geschaeft(name: "Anderer Kiosk", typen: [sonstigesTyp()])
        context.insert(kiosk)
        context.insert(anderesGeschaeft)

        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", abteilungen: [sonstiges])
        context.insert(kaugummi)

        let einkauf = Einkaufsvorgang(geschaeft: anderesGeschaeft)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: anderesGeschaeft, alleAbteilungen: [sonstiges], context: context))
        #expect(!ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, alleAbteilungen: [sonstiges], context: context))
    }

    /// Regressionstest für `docs/GESCHAEFTS_AGGREGATE.md`: die Verfügbarkeit
    /// ist eine eigene, dauerhafte Tatsache (``ArtikelGeschaeftVerfuegbarkeit``)
    /// — anders als vor der Entkopplung überlebt sie das Löschen der
    /// ``Einkaufsliste``, über die der Artikel ursprünglich gekauft wurde
    /// (löscht seit `.cascade` auch den ``Einkaufsvorgang``/``KaufEintrag``).
    @Test
    func verfuegbarkeitUeberlebtGeloeschteEinkaufsliste() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = Abteilung(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)
        let kiosk = Geschaeft(name: "Kiosk", typen: [sonstigesTyp()])
        context.insert(kiosk)
        let kaugummi = Artikel(name: "Kaugummi", symbolName: "shippingbox.fill", farbeHex: "#8E8E93", abteilungen: [sonstiges])
        context.insert(kaugummi)

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let einkauf = Einkaufsvorgang(geschaeft: kiosk, einkaufsliste: liste)
        context.insert(einkauf)
        einkauf.artikelAbhaken(kaugummi, context: context)
        try context.save()

        context.delete(liste)
        try context.save()

        #expect(ArtikelVerfuegbarkeitService.istVerfuegbar(kaugummi, in: kiosk, alleAbteilungen: [sonstiges], context: context))
        #expect(try context.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)
    }
}
