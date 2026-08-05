import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct LamportClockTests {
    /// `UserDefaults.standard` ist prozessweit geteilt — vor jedem Testfall
    /// zurücksetzen, damit sich Tests nicht gegenseitig beeinflussen.
    private func zaehlerZuruecksetzen() {
        UserDefaults.standard.removeObject(forKey: LamportClock.schluessel)
    }

    @Test
    func naechsterZaehlerErhoehtMonotonUmEins() {
        zaehlerZuruecksetzen()
        #expect(LamportClock.naechsterZaehler() == 1)
        #expect(LamportClock.naechsterZaehler() == 2)
        #expect(LamportClock.naechsterZaehler() == 3)
    }

    @Test
    func beiEmpfangSpringtAufFremdenZaehlerPlusEinsFallsGroesser() {
        zaehlerZuruecksetzen()
        LamportClock.naechsterZaehler() // eigener Zähler = 1
        LamportClock.beiEmpfang(fremderZaehler: 10)
        #expect(LamportClock.aktuellerZaehler == 11)
    }

    @Test
    func beiEmpfangFaelltNichtHinterEigenenZaehlerZurueck() {
        zaehlerZuruecksetzen()
        for _ in 0..<5 { LamportClock.naechsterZaehler() } // eigener Zähler = 5
        LamportClock.beiEmpfang(fremderZaehler: 2)
        #expect(LamportClock.aktuellerZaehler == 6)
    }
}

@MainActor
struct SyncEventTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, ArtikelGeschaeftVerfuegbarkeit.self,
            ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    @Test
    func artikelHinzufuegenZeichnetSyncEventAuf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        liste.artikelHinzufuegen(apfel, context: context)

        let events = try context.fetch(FetchDescriptor<SyncEvent>())
        #expect(events.count == 1)
        #expect(events.first?.art == .artikelHinzugefuegt)
        #expect(events.first?.nutzlastDekodiert?.bezugsID == liste.id)
        #expect(events.first?.nutzlastDekodiert?.artikelID == apfel.id)
        #expect(events.first?.autorGeraeteID == DatabaseLeaseService.geraeteID)
    }

    @Test
    func artikelEntfernenZeichnetSyncEventNurBeiTatsaechlicherEntfernungAuf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        // Artikel ist noch gar nicht auf der Liste — kein Event erwartet.
        liste.artikelEntfernen(apfel, context: context)
        #expect(try context.fetchCount(FetchDescriptor<SyncEvent>()) == 0)

        liste.artikelHinzufuegen(apfel, context: context)
        liste.artikelEntfernen(apfel, context: context)

        var beschreibung = FetchDescriptor<SyncEvent>()
        beschreibung.sortBy = [SortDescriptor(\.lamportZaehler)]
        let events = try context.fetch(beschreibung)
        #expect(events.map(\.art) == [.artikelHinzugefuegt, .artikelEntfernt])
    }

    @Test
    func artikelAbhakenZeichnetSyncEventAuf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)

        let abhakEvents = try context.fetch(FetchDescriptor<SyncEvent>()).filter { $0.art == .artikelAbgehakt }
        #expect(abhakEvents.count == 1)
        #expect(abhakEvents.first?.nutzlastDekodiert?.bezugsID == einkauf.id)
        #expect(abhakEvents.first?.nutzlastDekodiert?.artikelID == apfel.id)
    }

    @Test
    func artikelAbhakenBeiDedupeKonfliktZeichnetKeinZweitesEventAuf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()
        einkauf.artikelAbhaken(apfel, context: context) // zweiter Aufruf: Dedupe-Guard greift

        let abhakEvents = try context.fetch(FetchDescriptor<SyncEvent>()).filter { $0.art == .artikelAbgehakt }
        #expect(abhakEvents.count == 1)
    }
}
