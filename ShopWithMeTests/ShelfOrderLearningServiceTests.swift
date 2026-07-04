import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ShelfOrderLearningServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Regal.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self, RegalBesuchsStatistik.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func lerntReihenfolgeAusWiederholtenEinkaeufen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        // Manuelle Reihenfolge (bewusst "falsch" gewählt): Drogerie vor Obst.
        let drogerieregal = Regal(name: "Drogerieregal", sortIndex: 0, geschaeft: geschaeft)
        drogerieregal.kategorien = [drogerie]
        let obstregal = Regal(name: "Obstregal", sortIndex: 1, geschaeft: geschaeft)
        obstregal.kategorien = [obst]
        context.insert(drogerieregal)
        context.insert(obstregal)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorie: obst)
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorie: drogerie)
        context.insert(apfel)
        context.insert(shampoo)

        // Der Anwender läuft aber tatsächlich immer zuerst durchs Obstregal, dann
        // durchs Drogerieregal.
        for _ in 0..<ShelfOrderLearningService.mindestEinkaeufeFuerVorschlag {
            apfel.istAufEinkaufsliste = true
            shampoo.istAufEinkaufsliste = true
            let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
            context.insert(einkauf)
            einkauf.artikelAbhaken(apfel, regal: obstregal, context: context)
            einkauf.artikelAbhaken(shampoo, regal: drogerieregal, context: context)
            einkauf.abschliessen()
            ShelfOrderLearningService.lernenAus(einkauf, context: context)
        }

        #expect(
            ShelfOrderLearningService.abgeschlosseneEinkaeufe(fuer: geschaeft, context: context)
                == ShelfOrderLearningService.mindestEinkaeufeFuerVorschlag
        )

        let vorschlag = ShelfOrderLearningService.vorgeschlageneReihenfolge(fuer: geschaeft, context: context)
        #expect(vorschlag.map(\.name) == ["Obstregal", "Drogerieregal"])

        ShelfOrderLearningService.vorgeschlageneReihenfolgeUebernehmen(fuer: geschaeft, context: context)
        #expect(obstregal.sortIndex == 0)
        #expect(drogerieregal.sortIndex == 1)
    }
}
