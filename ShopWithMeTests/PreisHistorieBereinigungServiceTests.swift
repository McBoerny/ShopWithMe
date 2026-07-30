import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreisHistorieBereinigungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncTombstone.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

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

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
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

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
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
    func bereinigenLoeschtAlteAbgeschlosseneLeereEinkaufsvorgaengeMitTombstone() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-400 * 86400))
        alterVorgang.abschliessen(am: jetzt.addingTimeInterval(-400 * 86400))
        context.insert(alterVorgang)
        let vorgangID = alterVorgang.id

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, preis: 1.99, datum: jetzt.addingTimeInterval(-400 * 86400))
        context.insert(eintrag)
        eintrag.einkaufsvorgang = alterVorgang
        let eintragID = eintrag.id
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30, jetzt: jetzt)

        #expect(anzahl == 1)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintragID, context: context))
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgangID, context: context))
    }

    @Test
    func bereinigenLaesstEinkaufsvorgangMitVerbleibendenEintraegenBestehen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let jetzt = Date()
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        // Vorgang selbst ist alt genug für die Aufräum-Schwelle, trägt aber
        // noch einen zu jungen KaufEintrag — muss deshalb bestehen bleiben.
        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: jetzt.addingTimeInterval(-400 * 86400))
        alterVorgang.abschliessen(am: jetzt.addingTimeInterval(-400 * 86400))
        context.insert(alterVorgang)
        let vorgangID = alterVorgang.id

        let jungerEintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, preis: 1.99, datum: jetzt.addingTimeInterval(-1 * 86400))
        context.insert(jungerEintrag)
        jungerEintrag.einkaufsvorgang = alterVorgang
        try context.save()

        let anzahl = await PreisHistorieBereinigungService.bereinigen(context: context, aufbewahrung: .tage30, jetzt: jetzt)

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).count == 1)
        let verbleibendeVorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(verbleibendeVorgaenge.count == 1)
        #expect(verbleibendeVorgaenge.first?.id == vorgangID)
        #expect(!SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgangID, context: context))
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
