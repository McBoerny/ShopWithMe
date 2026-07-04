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
            Einkaufsvorgang.self, KaufEintrag.self, KategorieBesuchsStatistik.self,
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
    func kategorieEntfernenAusRegalMachtSieWiederNichtVerfuegbar() throws {
        // Spiegelt die Entfernen-Aktion im „Kategorien“-Abschnitt von
        // `GeschaeftDetailView`: die Kategorie wird über ihr zuständiges Regal
        // (`Geschaeft.regal(fuer:)`) entfernt, nicht direkt am Geschäft.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])

        geschaeft.regal(fuer: obst)?.kategorien.removeAll { $0 == obst }

        #expect(geschaeft.verfuegbareKategorien.isEmpty)
    }

    @Test
    func auswaehlbareKategorienSchliessenAnderweitigVerwendeteAus() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let getraenke = ArtikelKategorie(name: "Getränke", standardSymbol: "waterbottle.fill", standardFarbeHex: "#5AC8FA")
        context.insert(obst)
        context.insert(drogerie)
        context.insert(getraenke)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal1 = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal1.kategorien = [obst]
        context.insert(regal1)

        let regal2 = Regal(name: "Regal 2", geschaeft: geschaeft)
        regal2.kategorien = [drogerie]
        context.insert(regal2)

        let alle = [obst, drogerie, getraenke]

        // Regal 1 darf seine eigene Kategorie ("Obst") weiterhin sehen (um sie
        // abwählen zu können), nicht aber die von Regal 2 ("Drogerie") verwendete.
        #expect(Set(regal1.auswaehlbareKategorien(aus: alle).map(\.name)) == ["Obst", "Getränke"])
        #expect(Set(regal2.auswaehlbareKategorien(aus: alle).map(\.name)) == ["Drogerie", "Getränke"])
    }

    @Test
    func sonstigeKategorieWirdBeiBedarfAngelegtUndWiederverwendet() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let angelegt = ArtikelKategorie.sonstige(context: context)
        #expect(angelegt.name == "Sonstiges")
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)

        let wiederverwendet = ArtikelKategorie.sonstige(context: context)
        #expect(wiederverwendet.persistentModelID == angelegt.persistentModelID)
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)
    }

    @Test
    func regalSortierModusFaelltOhneGespeichertenRohwertAufManuellZurueck() throws {
        // Vor v1.4 angelegte Geschäfte kennen die Spalte für `regalSortierModus`
        // nicht — nach der automatischen Migration bleibt ihr Rohwert `nil`. Der
        // Zugriff auf `regalSortierModus` darf dabei nicht abstürzen (siehe
        // v1.4-Crash: Zuordnung von `nil` auf ein nicht-optionales Enum-Attribut),
        // sondern muss auf `.manuell` zurückfallen.
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        #expect(geschaeft.regalSortierModus == .manuell)

        geschaeft.regalSortierModus = .automatisch
        #expect(geschaeft.regalSortierModus == .automatisch)
    }

    @Test
    func kategorieBesuchsStatistikBerechnetDurchschnitt() {
        let statistik = KategorieBesuchsStatistik(geschaeft: nil, kategorie: nil)
        #expect(statistik.durchschnittlichePosition == .infinity)

        statistik.erfassen(sequenzPosition: 1)
        statistik.erfassen(sequenzPosition: 3)
        #expect(statistik.durchschnittlichePosition == 2)
    }
}
