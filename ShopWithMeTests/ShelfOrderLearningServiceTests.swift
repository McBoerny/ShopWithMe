import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ShelfOrderLearningServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Regal.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self, KategorieBesuchsStatistik.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func lerntRegalReihenfolgeAusWiederholtenEinkaeufen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [.lebensmittel])
        context.insert(geschaeft)

        // Manuelle Reihenfolge (bewusst "falsch" gewählt): Drogerie vor Obst.
        let drogerieregal = Regal(name: "Drogerieregal", sortIndex: 0, geschaeft: geschaeft)
        drogerieregal.kategorien = [drogerie]
        let obstregal = Regal(name: "Obstregal", sortIndex: 1, geschaeft: geschaeft)
        obstregal.kategorien = [obst]
        context.insert(drogerieregal)
        context.insert(obstregal)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(shampoo)

        // Der Anwender läuft aber tatsächlich immer zuerst durchs Obstregal, dann
        // durchs Drogerieregal.
        for _ in 0..<ShelfOrderLearningService.mindestEinkaeufeFuerVorschlag {
            let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
            context.insert(einkauf)
            einkauf.artikelAbhaken(apfel, context: context)
            einkauf.artikelAbhaken(shampoo, context: context)
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

    @Test
    func automatischerModusUeberschreibtManuelleReihenfolgeNicht() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [.lebensmittel])
        context.insert(geschaeft)

        // Manuelle Reihenfolge (bewusst "falsch" gewählt): Drogerie vor Obst.
        let drogerieregal = Regal(name: "Drogerieregal", sortIndex: 0, geschaeft: geschaeft)
        drogerieregal.kategorien = [drogerie]
        let obstregal = Regal(name: "Obstregal", sortIndex: 1, geschaeft: geschaeft)
        obstregal.kategorien = [obst]
        context.insert(drogerieregal)
        context.insert(obstregal)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(shampoo)

        for _ in 0..<ShelfOrderLearningService.mindestEinkaeufeFuerVorschlag {
            let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
            context.insert(einkauf)
            einkauf.artikelAbhaken(apfel, context: context)
            einkauf.artikelAbhaken(shampoo, context: context)
            einkauf.abschliessen()
            ShelfOrderLearningService.lernenAus(einkauf, context: context)
        }

        #expect(ShelfOrderLearningService.automatischeReihenfolgeVerfuegbar(fuer: geschaeft, context: context))

        // Standardmäßig (manuell) bleibt die manuelle Reihenfolge maßgeblich, obwohl
        // eine automatische Reihenfolge verfügbar wäre.
        #expect(geschaeft.regalSortierModus == .manuell)
        #expect(
            ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: context).map(\.name)
                == ["Drogerieregal", "Obstregal"]
        )

        // Umschalten auf automatisch liefert die gelernte Reihenfolge, ohne
        // sortIndex zu verändern.
        geschaeft.regalSortierModus = .automatisch
        #expect(
            ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: context).map(\.name)
                == ["Obstregal", "Drogerieregal"]
        )
        #expect(drogerieregal.sortIndex == 0)
        #expect(obstregal.sortIndex == 1)

        // Zurück zu manuell stellt wieder exakt die ursprüngliche manuelle
        // Reihenfolge her.
        geschaeft.regalSortierModus = .manuell
        #expect(
            ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: context).map(\.name)
                == ["Drogerieregal", "Obstregal"]
        )
    }

    @Test
    func liefertKategorieReihenfolgeFuerLadenOhneRegal() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        // Dieses Geschäft hat bewusst keine Regale.
        let geschaeft = Geschaeft(name: "Kiosk", typen: [.sonstiges])
        context.insert(geschaeft)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(shampoo)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)
        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbhaken(shampoo, context: context)
        einkauf.abschliessen()
        ShelfOrderLearningService.lernenAus(einkauf, context: context)

        let positionen = ShelfOrderLearningService.kategoriePositionen(fuer: geschaeft, context: context)
        #expect(positionen[obst.persistentModelID] == 0)
        #expect(positionen[drogerie.persistentModelID] == 1)
        #expect(ShelfOrderLearningService.vorgeschlageneReihenfolge(fuer: geschaeft, context: context).isEmpty)
    }
}
