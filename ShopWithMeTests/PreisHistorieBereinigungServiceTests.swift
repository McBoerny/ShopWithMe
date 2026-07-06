import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreisHistorieBereinigungServiceTests {
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
    func bereinigenLoeschtNurEintraegeAelterAlsStichtag() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let alterEintrag = KaufEintrag(artikel: nil, geschaeft: nil, preis: 1.99, datum: jetzt.addingTimeInterval(-400 * 86400))
        let neuerEintrag = KaufEintrag(artikel: nil, geschaeft: nil, preis: 2.49, datum: jetzt.addingTimeInterval(-1 * 86400))
        context.insert(alterEintrag)
        context.insert(neuerEintrag)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30, jetzt: jetzt)

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == neuerEintrag.id)
    }

    @Test
    func bereinigenMitNieLoeschtNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let alterEintrag = KaufEintrag(artikel: nil, geschaeft: nil, preis: 1.99, datum: Date.distantPast)
        context.insert(alterEintrag)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .nie)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
    }

    @Test
    func bereinigenLaesstEintraegeEinesLaufendenEinkaufsUnangetastet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let laufenderEinkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(laufenderEinkauf)

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, preis: 1.99, datum: Date.distantPast)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = laufenderEinkauf
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
    }

    @Test
    func bereinigenLoeschtEintraegeEinesAbgeschlossenenEinkaufs() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let abgeschlossenerEinkauf = Einkaufsvorgang(geschaeft: geschaeft)
        abgeschlossenerEinkauf.abschliessen()
        context.insert(abgeschlossenerEinkauf)

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, preis: 1.99, datum: Date.distantPast)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = abgeschlossenerEinkauf
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30)

        #expect(anzahl == 1)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
    }

    @Test
    func eigeneTageWerdenAlsAufbewahrungsdauerAngewandt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let eintragAelterAlsZehnTage = KaufEintrag(artikel: nil, geschaeft: nil, preis: 1.0, datum: jetzt.addingTimeInterval(-15 * 86400))
        let eintragJuengerAlsZehnTage = KaufEintrag(artikel: nil, geschaeft: nil, preis: 2.0, datum: jetzt.addingTimeInterval(-5 * 86400))
        context.insert(eintragAelterAlsZehnTage)
        context.insert(eintragJuengerAlsZehnTage)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .eigeneTage(10), jetzt: jetzt)

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == eintragJuengerAlsZehnTage.id)
    }

    @Test
    func persistenzWertRoundTrip() {
        let werte: [PreisHistorieAufbewahrung] = [.tage30, .monate3, .monate6, .jahr1, .nie, .eigeneTage(45)]
        for wert in werte {
            #expect(PreisHistorieAufbewahrung(persistenzWert: wert.persistenzWert) == wert)
        }
        #expect(PreisHistorieAufbewahrung(persistenzWert: "unbekannt") == nil)
    }
}
