import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreisHistorieBereinigungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, Preispunkt.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncTombstone.self,
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
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let alterPunkt = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.99, datum: jetzt.addingTimeInterval(-400 * 86400))
        let neuerPunkt = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 2.49, datum: jetzt.addingTimeInterval(-1 * 86400))
        context.insert(alterPunkt)
        context.insert(neuerPunkt)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30, jetzt: jetzt)

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == neuerPunkt.id)
    }

    @Test
    func bereinigenMitNieLoeschtNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let alterPunkt = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.99, datum: Date.distantPast)
        context.insert(alterPunkt)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .nie)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 1)
    }

    @Test
    func eigeneTageWerdenAlsAufbewahrungsdauerAngewandt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let punktAelterAlsZehnTage = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.0, datum: jetzt.addingTimeInterval(-15 * 86400))
        let punktJuengerAlsZehnTage = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 2.0, datum: jetzt.addingTimeInterval(-5 * 86400))
        context.insert(punktAelterAlsZehnTage)
        context.insert(punktJuengerAlsZehnTage)
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .eigeneTage(10), jetzt: jetzt)

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == punktJuengerAlsZehnTage.id)
    }

    @Test
    func bereinigenSchreibtTombstoneFuerGeloeschtenPreispunkt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let alterPunkt = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.99, datum: Date.distantPast)
        context.insert(alterPunkt)
        let punktID = alterPunkt.id
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30)

        #expect(anzahl == 1)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.preispunkt, id: punktID, context: context))
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
