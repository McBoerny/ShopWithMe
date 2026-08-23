import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelZusammenfuehrungsServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, Einkaufsliste.self, EinkaufslistenEintrag.self,
            Preispunkt.self, Produkt.self, Produktname.self,
            ArtikelGeschaeftVerfuegbarkeit.self, ArtikelListenKauf.self,
            SyncEntitaetsAlias.self, SyncTombstone.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func machtArtikel(_ name: String, in context: ModelContext) -> Artikel {
        let artikel = Artikel(name: name, symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        return artikel
    }

    // MARK: - alsAliasAufloesen

    @Test
    func alsAliasAufloesenMergtNamenAlsAlternativeNamen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Cola", in: context)
        let verwandter = machtArtikel("Coca Cola", in: context)
        verwandter.alternativeNamen = ["Cola Light"]

        ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: context)

        #expect(primaer.alternativeNamen.contains { $0.localizedCaseInsensitiveCompare("Coca Cola") == .orderedSame })
        #expect(primaer.alternativeNamen.contains { $0.localizedCaseInsensitiveCompare("Cola Light") == .orderedSame })
        let verbleibende = try context.fetch(FetchDescriptor<Artikel>())
        #expect(!verbleibende.contains { $0.persistentModelID == verwandter.persistentModelID })
    }

    @Test
    func alsAliasAufloesenHaengtKaufUndEinkaufslistenEintraegeUm() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Cola", in: context)
        let verwandter = machtArtikel("Coca Cola", in: context)
        let liste = Einkaufsliste(name: "Standard")
        context.insert(liste)
        let kauf = KaufEintrag(artikel: verwandter, geschaeft: nil)
        context.insert(kauf)
        let listenEintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: verwandter, menge: 1)
        context.insert(listenEintrag)
        liste.eintraege.append(listenEintrag)

        ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: context)

        #expect(kauf.artikel?.persistentModelID == primaer.persistentModelID)
        #expect(listenEintrag.artikel?.persistentModelID == primaer.persistentModelID)
    }

    @Test
    func alsAliasAufloesenVermeidetDoppelteEinkaufslistenEintraege() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Cola", in: context)
        let verwandter = machtArtikel("Coca Cola", in: context)
        let liste = Einkaufsliste(name: "Standard")
        context.insert(liste)
        let primaerEintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: primaer, menge: 1)
        let verwandterEintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: verwandter, menge: 2)
        context.insert(primaerEintrag)
        context.insert(verwandterEintrag)
        liste.eintraege.append(contentsOf: [primaerEintrag, verwandterEintrag])

        ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: context)

        let verbleibendeEintraege = try context.fetch(FetchDescriptor<EinkaufslistenEintrag>())
        #expect(verbleibendeEintraege.count == 1)
        #expect(verbleibendeEintraege.first?.artikel?.persistentModelID == primaer.persistentModelID)
    }

    @Test
    func alsAliasAufloesenLoestStandardProduktKollision() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Cola", in: context)
        let verwandter = machtArtikel("Coca Cola", in: context)
        let primaerStandard = Produkt.standardProdukt(fuer: primaer, context: context)
        let verwandterStandard = Produkt.standardProdukt(fuer: verwandter, context: context)

        ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: context)

        #expect(primaerStandard.istStandard)
        #expect(primaerStandard.artikel?.persistentModelID == primaer.persistentModelID)
        #expect(!verwandterStandard.istStandard)
        #expect(verwandterStandard.artikel?.persistentModelID == primaer.persistentModelID)
    }

    @Test
    func alsAliasAufloesenRegistriertSyncAliasUndTombstone() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Cola", in: context)
        let verwandter = machtArtikel("Coca Cola", in: context)
        let verwandterID = verwandter.id

        ArtikelZusammenfuehrungsService.alsAliasAufloesen(verwandter, in: primaer, context: context)

        let aliase = try context.fetch(FetchDescriptor<SyncEntitaetsAlias>())
        #expect(aliase.contains { $0.entitaetsArt == SyncEntitaetsArt.artikel && $0.fremdeID == verwandterID && $0.lokaleID == primaer.id })
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        #expect(tombstones.contains { $0.entitaetsArt == SyncEntitaetsArt.artikel && $0.geloeschteID == verwandterID })
    }

    // MARK: - alsProduktKonvertieren

    @Test
    func alsProduktKonvertierenWandeltArtikelInProduktUm() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Waschmittel", in: context)
        let verwandter = machtArtikel("Persil", in: context)

        ArtikelZusammenfuehrungsService.alsProduktKonvertieren(verwandter, unter: primaer, context: context)

        #expect(primaer.produkte.contains { $0.name.localizedCaseInsensitiveCompare("Persil") == .orderedSame })
        let verbleibendeArtikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(!verbleibendeArtikel.contains { $0.persistentModelID == verwandter.persistentModelID })
    }

    @Test
    func alsProduktKonvertierenUebernimmtPreishistorieDesStandardProdukts() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Waschmittel", in: context)
        let verwandter = machtArtikel("Persil", in: context)
        let verwandterStandard = Produkt.standardProdukt(fuer: verwandter, context: context)
        let preispunkt = Preispunkt(produkt: verwandterStandard, geschaeft: nil, preis: 4.99)
        context.insert(preispunkt)
        verwandterStandard.preispunkte.append(preispunkt)

        ArtikelZusammenfuehrungsService.alsProduktKonvertieren(verwandter, unter: primaer, context: context)

        #expect(verwandterStandard.artikel?.persistentModelID == primaer.persistentModelID)
        #expect(!verwandterStandard.istStandard)
        #expect(verwandterStandard.preispunkte.contains { $0.persistentModelID == preispunkt.persistentModelID })
    }

    @Test
    func alsProduktKonvertierenHaengtWeitereProdukteAlsGeschwisterUm() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Waschmittel", in: context)
        let verwandter = machtArtikel("Persil", in: context)
        let variante = Produkt(name: "Persil Color", artikel: verwandter)
        context.insert(variante)
        verwandter.produkte.append(variante)

        ArtikelZusammenfuehrungsService.alsProduktKonvertieren(verwandter, unter: primaer, context: context)

        #expect(variante.artikel?.persistentModelID == primaer.persistentModelID)
        #expect(primaer.produkte.contains { $0.persistentModelID == variante.persistentModelID })
    }

    @Test
    func alsProduktKonvertierenFuelltLeeresProduktInEinkaufslistenEintraegen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let primaer = machtArtikel("Waschmittel", in: context)
        let verwandter = machtArtikel("Persil", in: context)
        let liste = Einkaufsliste(name: "Standard")
        context.insert(liste)
        let eintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: verwandter, produkt: nil, menge: 1)
        context.insert(eintrag)
        liste.eintraege.append(eintrag)

        ArtikelZusammenfuehrungsService.alsProduktKonvertieren(verwandter, unter: primaer, context: context)

        #expect(eintrag.artikel?.persistentModelID == primaer.persistentModelID)
        #expect(eintrag.produkt != nil)
        #expect(eintrag.produkt?.artikel?.persistentModelID == primaer.persistentModelID)
    }
}
