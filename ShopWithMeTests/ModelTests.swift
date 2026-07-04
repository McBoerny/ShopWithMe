import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ModelTests {
    /// `ModelContext` hält den `ModelContainer` nicht stark — daher muss der Aufrufer
    /// den Container selbst am Leben halten, solange der Context benutzt wird.
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
    func seedDatenWerdenNurEinmalAngelegt() throws {
        let (container, context) = try machtLeerenContainer()
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeStandarddatenFallsLeer(context: context)

        let anzahl = try context.fetchCount(FetchDescriptor<ArtikelKategorie>())
        #expect(anzahl == SeedData.standardKategorien.count)
    }

    @Test
    func verfuegbareKategorienLeitenSichAusRegalenAb() throws {
        let (container, context) = try machtLeerenContainer()
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])
    }

    @Test
    func regalBesuchsStatistikBerechnetDurchschnitt() {
        let statistik = RegalBesuchsStatistik(geschaeft: nil, regal: nil)
        #expect(statistik.durchschnittlichePosition == .infinity)

        statistik.erfassen(sequenzPosition: 1)
        statistik.erfassen(sequenzPosition: 3)
        #expect(statistik.durchschnittlichePosition == 2)
    }
}
