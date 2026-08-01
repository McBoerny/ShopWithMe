import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreispunktServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Preispunkt.self, ArtikelAlias.self, SyncTombstone.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func artikelUndGeschaeft(_ context: ModelContext) -> (Artikel, Geschaeft) {
        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(artikel)
        return (artikel, geschaeft)
    }

    @Test
    func erfassenLegtNeuenPunktNurBeiPreisAenderungAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()

        PreispunktService.erfassen(
            preis: 1.19, artikel: artikel, geschaeft: geschaeft, datum: jetzt,
            produktName: nil, alternativerName: nil, context: context
        )
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 1)

        // Gleicher Preis, späterer Zeitpunkt → kein neuer Punkt, nur `datum` aktualisiert.
        let spaeter = jetzt.addingTimeInterval(3600)
        PreispunktService.erfassen(
            preis: 1.19, artikel: artikel, geschaeft: geschaeft, datum: spaeter,
            produktName: nil, alternativerName: nil, context: context
        )
        let nachGleichemPreis = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(nachGleichemPreis.count == 1)
        #expect(nachGleichemPreis.first?.datum == spaeter)

        // Anderer Preis → neuer Punkt.
        PreispunktService.erfassen(
            preis: 1.29, artikel: artikel, geschaeft: geschaeft, datum: spaeter.addingTimeInterval(3600),
            produktName: nil, alternativerName: nil, context: context
        )
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 2)
    }

    @Test
    func vorhandenerPunktHeuteFindetNurTrefferAmSelbenKalendertag() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        let gestern = jetzt.addingTimeInterval(-1 * 86400)

        PreispunktService.erfassen(
            preis: 1.19, artikel: artikel, geschaeft: geschaeft, datum: gestern,
            produktName: nil, alternativerName: nil, context: context
        )

        #expect(PreispunktService.vorhandenerPunktHeute(artikel: artikel, geschaeft: geschaeft, amDatum: jetzt, context: context) == nil)
        let treffer = PreispunktService.vorhandenerPunktHeute(
            artikel: artikel, geschaeft: geschaeft, amDatum: gestern.addingTimeInterval(3600), context: context
        )
        #expect(treffer?.preis == 1.19)
    }

    @Test
    func vorhandenerPunktHeuteLiefertNilOhneArtikel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (_, geschaeft) = artikelUndGeschaeft(context)
        #expect(PreispunktService.vorhandenerPunktHeute(artikel: nil, geschaeft: geschaeft, amDatum: Date(), context: context) == nil)
    }

    @Test
    func ersetzeVorhandenenPunktLoeschtMitTombstone() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let punkt = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19)
        context.insert(punkt)
        let punktID = punkt.id

        PreispunktService.ersetzeVorhandenenPunkt(punkt, context: context)

        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.preispunkt, id: punktID, context: context))
    }
}
