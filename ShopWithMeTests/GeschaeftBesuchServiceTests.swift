import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``GeschaeftBesuchService`` (`docs/GESCHAEFTS_AGGREGATE.md`) — die
/// dauerhafte, von ``Einkaufsliste``/``Einkaufsvorgang`` unabhängige Ableitung
/// hinter `GeschaeftBesuchsProtokollView`.
@MainActor
struct GeschaeftBesuchServiceTests {
    private let schema = Schema([
        Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
        Einkaufsvorgang.self, KaufEintrag.self, Einkaufsliste.self, EinkaufslistenEintrag.self,
        SyncEvent.self, ArtikelGeschaeftVerfuegbarkeit.self, GeschaeftBesuch.self, ArtikelListenKauf.self,
    ])

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func erfasstAbgeschlossenenEinkaufMitProduktanzahl() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, startZeit: Date().addingTimeInterval(-300))
        context.insert(vorgang)
        vorgang.artikelAbhaken(artikel, context: context)
        vorgang.abschliessen()

        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)

        let besuche = try context.fetch(FetchDescriptor<GeschaeftBesuch>())
        #expect(besuche.count == 1)
        #expect(besuche.first?.id == vorgang.id)
        #expect(besuche.first?.anzahlProdukte == 1)
        #expect(besuche.first?.geschaeft == geschaeft)
    }

    @Test
    func ignoriertNochOffenenEinkauf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(vorgang)

        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)

        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 0)
    }

    @Test
    func ignoriertEinkaufOhneGeschaeft() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let vorgang = Einkaufsvorgang(geschaeft: nil)
        context.insert(vorgang)
        vorgang.abschliessen()

        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)

        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 0)
    }

    /// Union nach `id` (= `Einkaufsvorgang.id`) — ein zweiter Aufruf für
    /// denselben Vorgang erzeugt keinen weiteren Eintrag (Idempotenz, wichtig
    /// für die Bestandsmigration in ``DatenintegritaetsService``).
    @Test
    func istIdempotentProVorgang() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(vorgang)
        vorgang.abschliessen()

        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)
        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)

        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
    }

    /// Regressionstest für `docs/GESCHAEFTS_AGGREGATE.md`: das Löschen der
    /// ``Einkaufsliste`` (jetzt `.cascade`) darf den bereits erfassten
    /// ``GeschaeftBesuch`` nicht mit wegreißen — er ist bewusst nicht mit
    /// ``Einkaufsliste``/``Einkaufsvorgang`` verknüpft.
    @Test
    func ueberlebtGeloeschteEinkaufsliste() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(vorgang)
        vorgang.abschliessen()
        GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)
        try context.save()

        context.delete(liste)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)
    }
}
