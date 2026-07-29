import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``ModelReference`` — sichere Identität über eine `await`-Grenze
/// hinweg statt einer lebendigen Objektreferenz (siehe
/// `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: nebenläufige Löschung während
/// eines Micro-Lease-Erwerbs").
@MainActor
struct ModelReferenceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func loestVorhandenesObjektAufDieGleicheIdentitaetAuf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        try context.save()

        let referenz = ModelReference(artikel)
        let aufgeloest = referenz.resolved(in: context)

        #expect(aufgeloest?.persistentModelID == artikel.persistentModelID)
    }

    @Test
    func loestAufNilAufNachdemDasObjektGeloeschtWurde() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        try context.save()
        let referenz = ModelReference(artikel)

        context.delete(artikel)
        try context.save()

        #expect(referenz.resolved(in: context) == nil)
    }

    @Test
    func optionalerInitialisiererLiefertNilFuerNilEingabe() {
        let referenz = ModelReference<Artikel>(nil)
        #expect(referenz == nil)
    }

    @Test
    func existiertNochImStoreLiefertWahrFuerVorhandenesObjekt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        try context.save()

        #expect(context.existiertNochImStore(artikel))
    }

    @Test
    func existiertNochImStoreLiefertFalschNachdemDasObjektGeloeschtWurde() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        try context.save()

        context.delete(artikel)
        try context.save()

        #expect(!context.existiertNochImStore(artikel))
    }
}
