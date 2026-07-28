import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct GeschaeftHaeufigkeitServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Geschaeft.self, GeschaeftTyp.self, Einkaufsvorgang.self, SyncEvent.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    private func vorgang(fuer geschaeft: Geschaeft, vorTagen tage: Int, jetzt: Date, context: ModelContext) {
        let start = Calendar.current.date(byAdding: .day, value: -tage, to: jetzt)!
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: start)
        vorgang.endZeit = start.addingTimeInterval(600)
        context.insert(vorgang)
    }

    @Test
    func favoritenZaehltNurAbgeschlosseneVorgaengeInnerhalbDesZeitfensters() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let jetzt = Date()
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        context.insert(rewe)
        context.insert(edeka)

        // Rewe: 3 Besuche innerhalb der letzten 30 Tage.
        vorgang(fuer: rewe, vorTagen: 1, jetzt: jetzt, context: context)
        vorgang(fuer: rewe, vorTagen: 5, jetzt: jetzt, context: context)
        vorgang(fuer: rewe, vorTagen: 10, jetzt: jetzt, context: context)
        // Edeka: 1 Besuch innerhalb, 1 Besuch außerhalb des Zeitfensters.
        vorgang(fuer: edeka, vorTagen: 2, jetzt: jetzt, context: context)
        vorgang(fuer: edeka, vorTagen: 40, jetzt: jetzt, context: context)
        // Ein noch laufender Einkaufsvorgang (kein endZeit) zählt nicht mit.
        let laufend = Einkaufsvorgang(geschaeft: edeka, startZeit: jetzt)
        context.insert(laufend)

        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        let favoriten = GeschaeftHaeufigkeitService.favoriten(
            aus: vorgaenge, anzahl: 5, zeitfensterTage: 30, jetzt: jetzt
        )

        #expect(favoriten.map(\.name) == ["Rewe", "Edeka"])
    }

    @Test
    func favoritenBegrenztAufAnzahlUndSortiertBeiGleichstandAlphabetisch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let jetzt = Date()
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        let aldi = Geschaeft(name: "Aldi", typen: [lebensmittelTyp()])
        context.insert(rewe)
        context.insert(edeka)
        context.insert(aldi)

        // Alle drei mit je einem Besuch — Gleichstand, alphabetisch sortiert.
        vorgang(fuer: rewe, vorTagen: 1, jetzt: jetzt, context: context)
        vorgang(fuer: edeka, vorTagen: 1, jetzt: jetzt, context: context)
        vorgang(fuer: aldi, vorTagen: 1, jetzt: jetzt, context: context)

        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        let favoriten = GeschaeftHaeufigkeitService.favoriten(
            aus: vorgaenge, anzahl: 2, zeitfensterTage: 30, jetzt: jetzt
        )

        #expect(favoriten.map(\.name) == ["Aldi", "Edeka"])
    }

    @Test
    func favoritenIstLeerOhneVorgaenge() {
        let favoriten = GeschaeftHaeufigkeitService.favoriten(aus: [], anzahl: 5, zeitfensterTage: 30)
        #expect(favoriten.isEmpty)
    }
}
