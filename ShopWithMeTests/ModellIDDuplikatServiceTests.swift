import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``ModellIDDuplikatService`` (GitHub #102-Diagnose: doppelte
/// `id`-Werte innerhalb eines `@Model`-Typs, Voraussetzung für eine sichere
/// `@Attribute(.unique)`-Einführung).
@MainActor
struct ModellIDDuplikatServiceTests {
    private let schema = Schema([
        Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
        Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
        Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
        SyncEvent.self, ArtikelGeschaeftVerfuegbarkeit.self, GeschaeftBesuch.self, ArtikelListenKauf.self,
        ArtikelAlias.self, SyncAbgleichKandidat.self, SyncEntitaetsAlias.self, SyncPeerInfo.self,
        SyncPeerZaehlerStand.self, SyncTombstone.self, WarengruppenDistanzPeerZaehlerStand.self, Preispunkt.self,
    ])

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func meldetNichtsBeiEindeutigenIDs() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        context.insert(Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000"))
        context.insert(Artikel(name: "Butter", symbolName: "cart", farbeHex: "#000000"))
        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()

        #expect(ModellIDDuplikatService.pruefe(context: context).isEmpty)
    }

    @Test
    func erkenntDoppelteIDInnerhalbEinesTyps() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let gemeinsameID = UUID()
        let milch = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        milch.id = gemeinsameID
        let butter = Artikel(name: "Butter", symbolName: "cart", farbeHex: "#000000")
        butter.id = gemeinsameID
        context.insert(milch)
        context.insert(butter)
        try context.save()

        let befunde = ModellIDDuplikatService.pruefe(context: context)

        #expect(befunde.count == 1)
        #expect(befunde.first?.typName == "Artikel")
        #expect(befunde.first?.anzahlBetroffeneIDs == 1)
        #expect(befunde.first?.anzahlUeberzaehligeZeilen == 1)
    }

    @Test
    func zaehltMehrfacheDuplikateUndDreifachDuplikateKorrekt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let idA = UUID()
        for _ in 0..<3 {
            let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
            artikel.id = idA
            context.insert(artikel)
        }
        let idB = UUID()
        for _ in 0..<2 {
            let artikel = Artikel(name: "Butter", symbolName: "cart", farbeHex: "#000000")
            artikel.id = idB
            context.insert(artikel)
        }
        try context.save()

        let befund = ModellIDDuplikatService.pruefe(context: context).first { $0.typName == "Artikel" }

        #expect(befund?.anzahlBetroffeneIDs == 2)
        #expect(befund?.anzahlUeberzaehligeZeilen == 3)
    }

    @Test
    func haeltTypenUnabhaengigVoneinander() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geteilteID = UUID()
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        artikel.id = geteilteID
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        geschaeft.id = geteilteID
        context.insert(artikel)
        context.insert(geschaeft)
        try context.save()

        #expect(ModellIDDuplikatService.pruefe(context: context).isEmpty)
    }
}
