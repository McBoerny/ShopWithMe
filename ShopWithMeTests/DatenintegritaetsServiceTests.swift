import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``DatenintegritaetsService`` (Reperaturlauf gegen baumelnde
/// Referenzen, GitHub-Absturzmeldung zu `Geschaeft/p9`).
///
/// **Bewusst kein Test, der eine echte "baumelnde" Referenz nachstellt:** Seit
/// den `@Relationship(inverse:)`-Deklarationen auf allen hier relevanten
/// Beziehungen (Geschaeft/Artikel/ArtikelKategorie/Einkaufsliste) sorgt SwiftData
/// bei jedem `context.delete()` selbst dafür, dass abhängige Referenzen genullt
/// oder kaskadiert werden — das ist ja genau der bereits vorhandene Schutz für
/// künftige Daten. Ein Versuch, den echten Fehlerzustand über zwei unabhängige
/// ``ModelContainer`` auf derselben Datei nachzustellen, erwies sich beim Bau
/// dieses Tests als nicht verlässlich reproduzierbar (abhängig von internem,
/// nicht dokumentiertem Cache-/Merge-Verhalten von SwiftData zwischen Contexts)
/// und wurde deshalb verworfen, statt einen brüchigen Test beizubehalten. Die
/// Reparatur derartiger, bereits auf der Festplatte bestehender Altkorruption
/// lässt sich mit dem aktuellen Modell grundsätzlich nicht mehr über eine normale
/// Programmoperation künstlich erzeugen — sie betrifft ausschließlich Daten von
/// vor Einführung dieser `inverse`-Deklarationen. Verifiziert wird die
/// Nullungs-/Lösch-Logik daher hier nur indirekt (Idempotenz auf sauberen
/// Daten) — die eigentliche Reparaturwirkung am real betroffenen, bereits
/// korrumpierten Datenbestand lässt sich nur auf dem betroffenen Gerät selbst
/// beobachten (kein Absturz mehr, siehe Debug-Menü-Bericht nach dem nächsten
/// Start).
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
    func reparaturAufVollstaendigIntaktenDatenIstNoOp() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let kaufEintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft)
        context.insert(kaufEintrag)
        try context.save()

        let befunde = DatenintegritaetsService.repariereFallsNoetig(context: context)

        #expect(befunde.isEmpty)
        #expect(kaufEintrag.artikel === artikel)
        #expect(kaufEintrag.geschaeft === geschaeft)
        #expect(DatenintegritaetsService.letzterBericht.isEmpty)
    }

    @Test
    func reparaturLoeschtNichtsBeiVollstaendigVerknuepfterWarengruppenDistanz() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "Gemüse", standardSymbol: "leaf.fill", standardFarbeHex: "#34C759")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let distanz = WarengruppenDistanz(geschaeft: nil, kategorieA: kategorieA, kategorieB: kategorieB, distanz: 3)
        context.insert(distanz)
        try context.save()

        let befunde = DatenintegritaetsService.repariereFallsNoetig(context: context)

        #expect(befunde.isEmpty)
        #expect((try? context.fetchCount(FetchDescriptor<WarengruppenDistanz>())) == 1)
    }
}
