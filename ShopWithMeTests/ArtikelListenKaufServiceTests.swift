import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelListenKaufServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
            ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func vermerkeAbgehaktMachtIstJemalsAbgehaktWahr() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        #expect(!ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))
    }

    @Test
    func vermerkeAbgehaktErzeugtKeineDubletteBeiWiederholtemAufruf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)

        #expect(try context.fetchCount(FetchDescriptor<ArtikelListenKauf>()) == 1)
    }

    @Test
    func istJemalsAbgehaktIgnoriertAndereListe() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let urlaub = Einkaufsliste(name: "Urlaub")
        let einkaufsliste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(urlaub)
        context.insert(einkaufsliste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: urlaub, context: context)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: urlaub, context: context))
        #expect(!ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: einkaufsliste, context: context))
    }

    /// Regressionstest fürs zugrundeliegende GitHub-#99-Szenario: das Faktum
    /// bleibt bestehen, auch nachdem der `KaufEintrag`, der es ursprünglich
    /// ausgelöst hat, längst gelöscht wurde (analog
    /// `ArtikelVerfuegbarkeitServiceTests.verfuegbarkeitUeberlebtGeloeschteEinkaufsliste`).
    @Test
    func faktumUeberlebtLoeschungDesUrspruenglichenKaufEintrags() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(vorgang)

        vorgang.artikelAbhaken(artikel, context: context)
        try context.save()
        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))

        // Simuliert KaufEintragBereinigungService: KaufEintrag + Vorgang nach
        // Ablauf der Karenzzeit gelöscht.
        for eintrag in try context.fetch(FetchDescriptor<KaufEintrag>()) {
            context.delete(eintrag)
        }
        context.delete(vorgang)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))
    }

    /// `alleSchluessel` darf bei einer baumelnden Referenz (Artikel gelöscht,
    /// ohne `inverse`-Deklaration bleibt die Relationship bestehen) nicht
    /// abstürzen — siehe `docs/DATABASE_CONCURRENCY.md`.
    @Test
    func alleSchluesselStuerztBeiBaumelnderArtikelReferenzNichtAb() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)
        try context.save()

        context.delete(artikel)
        try context.save()

        let schluessel = ArtikelListenKaufService.alleSchluessel(context: context)
        #expect(schluessel.isEmpty)
    }
}
