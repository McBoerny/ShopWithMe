import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``DatenintegritaetsService`` (Erkennung baumelnder Referenzen,
/// GitHub-Absturzmeldung zu `Geschaeft/p9`).
///
/// **Bewusst rein lesend, keine Reparatur mehr:** Ein früherer Versuch, eine
/// erkannte baumelnde Referenz per Setter zu nullen (`eintrag.artikel = nil`),
/// verursachte selbst einen Absturz (`Artikel/p19`, Crash-Log
/// `ShopWithMe-2026-07-30-000333.ips`) — SwiftDatas Setter für eine Beziehung
/// mit `inverse:`-Deklaration muss beim Nullen die alte Gegenseite auffalten,
/// um sich selbst aus deren inversem Array zu entfernen; ist genau diese alte
/// Gegenseite bereits baumelnd, stürzt exakt dort derselbe Fatal Error, den die
/// Reparatur beheben sollte. Siehe Typ-Dokumentation von
/// ``DatenintegritaetsService`` für die vollständige Erklärung.
///
/// **Bewusst auch kein Test, der eine echte "baumelnde" Referenz nachstellt:**
/// Seit den `@Relationship(inverse:)`-Deklarationen auf allen hier relevanten
/// Beziehungen sorgt SwiftData bei jedem `context.delete()` selbst dafür, dass
/// abhängige Referenzen genullt oder kaskadiert werden — sie lassen sich mit
/// dem aktuellen Modell grundsätzlich nicht mehr über eine normale
/// Programmoperation künstlich erzeugen, sie betreffen ausschließlich Daten von
/// vor Einführung dieser `inverse`-Deklarationen. Verifiziert wird hier daher
/// nur, dass ``DatenintegritaetsService/pruefe(context:)`` auf sauberen Daten
/// nichts fälschlich meldet und nichts verändert.
@MainActor
struct DatenintegritaetsServiceTests {
    private let schema = Schema([
        Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
        Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
        Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
        SyncEvent.self,
    ])

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func pruefungAufVollstaendigIntaktenDatenMeldetNichts() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let kaufEintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft)
        context.insert(kaufEintrag)
        try context.save()

        let befunde = DatenintegritaetsService.pruefe(context: context)

        #expect(befunde.isEmpty)
        #expect(kaufEintrag.artikel === artikel)
        #expect(kaufEintrag.geschaeft === geschaeft)
        #expect(DatenintegritaetsService.letzterBericht.isEmpty)
    }

    @Test
    func pruefungVeraendertVollstaendigVerknuepfteWarengruppenDistanzNicht() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "Gemüse", standardSymbol: "leaf.fill", standardFarbeHex: "#34C759")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let distanz = WarengruppenDistanz(geschaeft: nil, kategorieA: kategorieA, kategorieB: kategorieB, distanz: 3)
        context.insert(distanz)
        try context.save()

        let befunde = DatenintegritaetsService.pruefe(context: context)

        #expect(befunde.isEmpty)
        #expect((try? context.fetchCount(FetchDescriptor<WarengruppenDistanz>())) == 1)
    }
}
