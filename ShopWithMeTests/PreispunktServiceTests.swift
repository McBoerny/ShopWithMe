import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreispunktServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Preispunkt.self, SyncTombstone.self, Produkt.self, Produktname.self,
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

    /// Wie ``artikelUndGeschaeft(_:)``, liefert zusätzlich ein zum Artikel
    /// gehörendes ``Produkt`` — seit der Produkt-Pflicht (GitHub #131) braucht
    /// jeder ``PreispunktService``-Aufruf ein aufgelöstes Produkt.
    private func produktUndGeschaeft(_ context: ModelContext) -> (Produkt, Geschaeft) {
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let produkt = Produkt(name: artikel.name, artikel: artikel)
        context.insert(produkt)
        return (produkt, geschaeft)
    }

    @Test
    func erfassenLegtNeuenPunktNurBeiPreisAenderungAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (produkt, geschaeft) = produktUndGeschaeft(context)
        let jetzt = Date()

        PreispunktService.erfassen(
            preis: 1.19, produkt: produkt, geschaeft: geschaeft, datum: jetzt,
            produktName: nil, alternativerName: nil, context: context
        )
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 1)

        // Gleicher Preis, späterer Zeitpunkt → kein neuer Punkt, nur `datum` aktualisiert.
        let spaeter = jetzt.addingTimeInterval(3600)
        PreispunktService.erfassen(
            preis: 1.19, produkt: produkt, geschaeft: geschaeft, datum: spaeter,
            produktName: nil, alternativerName: nil, context: context
        )
        let nachGleichemPreis = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(nachGleichemPreis.count == 1)
        #expect(nachGleichemPreis.first?.datum == spaeter)

        // Anderer Preis → neuer Punkt.
        PreispunktService.erfassen(
            preis: 1.29, produkt: produkt, geschaeft: geschaeft, datum: spaeter.addingTimeInterval(3600),
            produktName: nil, alternativerName: nil, context: context
        )
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 2)
    }

    @Test
    func vorhandenerPunktHeuteFindetNurTrefferAmSelbenKalendertag() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (produkt, geschaeft) = produktUndGeschaeft(context)
        let jetzt = Date()
        let gestern = jetzt.addingTimeInterval(-1 * 86400)

        PreispunktService.erfassen(
            preis: 1.19, produkt: produkt, geschaeft: geschaeft, datum: gestern,
            produktName: nil, alternativerName: nil, context: context
        )

        #expect(PreispunktService.vorhandenerPunktHeute(produkt: produkt, geschaeft: geschaeft, amDatum: jetzt, context: context) == nil)
        let treffer = PreispunktService.vorhandenerPunktHeute(
            produkt: produkt, geschaeft: geschaeft, amDatum: gestern.addingTimeInterval(3600), context: context
        )
        #expect(treffer?.preis == 1.19)
    }

    // MARK: - Produkt-Scoping (GitHub #47, Schritt 5/5)

    @Test
    func erfassenHaeltZweiProdukteDesselbenArtikelsUnabhaengig() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let odol = Produkt(name: "Odol", artikel: artikel)
        context.insert(odol)
        let paradontol = Produkt(name: "Paradontol", artikel: artikel)
        context.insert(paradontol)
        let jetzt = Date()

        PreispunktService.erfassen(
            preis: 1.99, produkt: odol, geschaeft: geschaeft, datum: jetzt,
            produktName: nil, alternativerName: nil, context: context
        )
        PreispunktService.erfassen(
            preis: 2.49, produkt: paradontol, geschaeft: geschaeft, datum: jetzt,
            produktName: nil, alternativerName: nil, context: context
        )

        let alle = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(alle.count == 2)
        #expect(alle.first { $0.produkt === odol }?.preis == 1.99)
        #expect(alle.first { $0.produkt === paradontol }?.preis == 2.49)

        // Erneutes Erfassen desselben Preises für Odol darf NICHT den
        // Paradontol-Preispunkt finden/überschreiben — weiterhin genau 2
        // Punkte, Odol-Punkt bekommt nur ein neues `datum`.
        let spaeter = jetzt.addingTimeInterval(3600)
        PreispunktService.erfassen(
            preis: 1.99, produkt: odol, geschaeft: geschaeft, datum: spaeter,
            produktName: nil, alternativerName: nil, context: context
        )
        let nachWiederholung = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(nachWiederholung.count == 2)
        #expect(nachWiederholung.first { $0.produkt === odol }?.datum == spaeter)
        #expect(nachWiederholung.first { $0.produkt === paradontol }?.preis == 2.49)
    }

    @Test
    func ersetzeVorhandenenPunktLoeschtMitTombstone() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (_, geschaeft) = artikelUndGeschaeft(context)
        let punkt = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.19)
        context.insert(punkt)
        let punktID = punkt.id

        PreispunktService.ersetzeVorhandenenPunkt(punkt, context: context)

        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).isEmpty)
        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.preispunkt, id: punktID, context: context))
    }
}
