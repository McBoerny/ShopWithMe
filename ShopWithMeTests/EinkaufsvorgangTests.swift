import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct EinkaufsvorgangTests {
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
    func abhakenErstelltKaufEintragUndEntferntVonEinkaufsliste() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let regal = Regal(name: "Obstregal", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst, istAufEinkaufsliste: true)
        context.insert(apfel)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)

        #expect(apfel.istAufEinkaufsliste == false)
        #expect(einkauf.kaufEintraege.count == 1)
        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
        #expect(einkauf.kaufEintraege.first?.kategorieBesuchsIndex == 0)
        #expect(einkauf.kaufEintraege.first?.preis == nil)
    }

    @Test
    func gleicheKategorieTeiltSichDenBesuchsIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let obstregal = Regal(name: "Obstregal", sortIndex: 0, geschaeft: geschaeft)
        obstregal.kategorien = [obst]
        context.insert(obstregal)
        let drogerieregal = Regal(name: "Drogerieregal", sortIndex: 1, geschaeft: geschaeft)
        drogerieregal.kategorien = [drogerie]
        context.insert(drogerieregal)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst, istAufEinkaufsliste: true)
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst, istAufEinkaufsliste: true)
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorie: drogerie, istAufEinkaufsliste: true)
        context.insert(apfel)
        context.insert(birne)
        context.insert(shampoo)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbhaken(birne, context: context)
        einkauf.artikelAbhaken(shampoo, context: context)

        let apfelEintrag = einkauf.kaufEintraege.first { $0.artikel == apfel }
        let birneEintrag = einkauf.kaufEintraege.first { $0.artikel == birne }
        let shampooEintrag = einkauf.kaufEintraege.first { $0.artikel == shampoo }

        #expect(apfelEintrag?.kategorieBesuchsIndex == 0)
        #expect(birneEintrag?.kategorieBesuchsIndex == 0)
        #expect(shampooEintrag?.kategorieBesuchsIndex == 1)
    }

    @Test
    func abwaehlenMachtAbhakenRueckgaengig() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let regal = Regal(name: "Obstregal", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst, istAufEinkaufsliste: true)
        context.insert(apfel)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbwaehlen(apfel, context: context)

        #expect(apfel.istAufEinkaufsliste == true)
        #expect(einkauf.kaufEintraege.isEmpty)
    }
}
