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

    /// Erzeugt Duplikate bewusst auf ``ArtikelAlias`` statt auf einem der
    /// ``ModellIDDuplikatService``-typen mit `@Attribute(.unique)`
    /// (`Artikel`, `Geschaeft`, `Einkaufsliste`, `Einkaufsvorgang`,
    /// `KaufEintrag`, GitHub #102) — SwiftData dedupliziert dort bereits beim
    /// `save()` selbst (Upsert-Verhalten der Unique-Constraint, kein
    /// harter Fehler), ein künstlich erzeugtes Duplikat käme also nie bis zur
    /// Prüfung durch. Die Zähllogik selbst ist typ-unabhängig, ein
    /// nicht-eindeutiger Typ genügt zur Verifikation.
    @Test
    func erkenntDoppelteIDInnerhalbEinesTyps() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let gemeinsameID = UUID()
        let eins = ArtikelAlias(erkannterName: "Milch", alternativerName: nil, artikel: nil)
        eins.id = gemeinsameID
        let zwei = ArtikelAlias(erkannterName: "Butter", alternativerName: nil, artikel: nil)
        zwei.id = gemeinsameID
        context.insert(eins)
        context.insert(zwei)
        try context.save()

        let befunde = ModellIDDuplikatService.pruefe(context: context)

        #expect(befunde.count == 1)
        #expect(befunde.first?.typName == "ArtikelAlias")
        #expect(befunde.first?.anzahlBetroffeneIDs == 1)
        #expect(befunde.first?.anzahlUeberzaehligeZeilen == 1)
    }

    @Test
    func zaehltMehrfacheDuplikateUndDreifachDuplikateKorrekt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let idA = UUID()
        for _ in 0..<3 {
            let alias = ArtikelAlias(erkannterName: "Milch", alternativerName: nil, artikel: nil)
            alias.id = idA
            context.insert(alias)
        }
        let idB = UUID()
        for _ in 0..<2 {
            let alias = ArtikelAlias(erkannterName: "Butter", alternativerName: nil, artikel: nil)
            alias.id = idB
            context.insert(alias)
        }
        try context.save()

        let befund = ModellIDDuplikatService.pruefe(context: context).first { $0.typName == "ArtikelAlias" }

        #expect(befund?.anzahlBetroffeneIDs == 2)
        #expect(befund?.anzahlUeberzaehligeZeilen == 3)
    }

    @Test
    func haeltTypenUnabhaengigVoneinander() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geteilteID = UUID()
        let alias = ArtikelAlias(erkannterName: "Milch", alternativerName: nil, artikel: nil)
        alias.id = geteilteID
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        geschaeft.id = geteilteID
        context.insert(alias)
        context.insert(geschaeft)
        try context.save()

        #expect(ModellIDDuplikatService.pruefe(context: context).isEmpty)
    }
}
