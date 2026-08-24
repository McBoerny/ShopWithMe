import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``DatabaseLeaseService`` gegen das lokale Dateisystem (siehe
/// `docs/DATABASE_CONCURRENCY.md` → „Nächste Schritte“: ein echter Cloud-Provider
/// lässt sich in Unit-Tests nicht sinnvoll nachbilden, `NSFileCoordinator` selbst
/// funktioniert aber auch für lokale Dateien und ist damit hier real testbar).
@MainActor
struct DatabaseLeaseServiceTests {
    /// Spiegelt das private `LeaseInfo`-Format aus `DatabaseLeaseService.swift`, um
    /// in Tests einen "fremden" Lock vorzubereiten, ohne auf den internen Typ
    /// zugreifen zu können.
    private struct FremdeLeaseInfo: Codable {
        var geraeteID: String
        var geraeteName: String
        var erworbenAm: Date
    }

    private func macheTempStoreURL() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner.appendingPathComponent("Test.store")
    }

    private func lockURL(fuer storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(storeURL.lastPathComponent + ".lock.json")
    }

    private func schreibeFremdenLock(storeURL: URL, alter: TimeInterval) throws {
        let fremd = FremdeLeaseInfo(
            geraeteID: "test-anderes-geraet",
            geraeteName: "Anderes iPhone",
            erworbenAm: Date().addingTimeInterval(-alter)
        )
        try JSONEncoder().encode(fremd).write(to: lockURL(fuer: storeURL))
    }

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Artikel.self, Abteilung.self, Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func microLeaseErfolgreichOhneKonfliktUndGibtLeaseWiederFrei() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let storeURL = macheTempStoreURL()
        DatabaseLeaseService.storeURL = storeURL
        defer { DatabaseLeaseService.storeURL = nil }

        var mutateAufgerufen = false
        await DatabaseLeaseService.performMicroLease(context: context) {
            mutateAufgerufen = true
        }

        #expect(mutateAufgerufen)
        #expect(!FileManager.default.fileExists(atPath: lockURL(fuer: storeURL).path))
    }

    @Test
    func microLeaseWirdBeiAktivemFremdenLockZurueckgestellt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let storeURL = macheTempStoreURL()
        DatabaseLeaseService.storeURL = storeURL
        defer { DatabaseLeaseService.storeURL = nil }

        try schreibeFremdenLock(storeURL: storeURL, alter: 5) // frisch, nicht verwaist

        var mutateAufgerufen = false
        await DatabaseLeaseService.performMicroLease(context: context) {
            mutateAufgerufen = true
        }

        #expect(mutateAufgerufen == false)
    }

    @Test
    func microLeaseUebernimmtVerwaistenFremdenLockNachStaleTimeout() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let storeURL = macheTempStoreURL()
        DatabaseLeaseService.storeURL = storeURL
        defer { DatabaseLeaseService.storeURL = nil }

        try schreibeFremdenLock(storeURL: storeURL, alter: DatabaseLeaseService.staleTimeout + 5)

        var mutateAufgerufen = false
        await DatabaseLeaseService.performMicroLease(context: context) {
            mutateAufgerufen = true
        }

        #expect(mutateAufgerufen)
    }

    @Test
    func performMicroLeaseOhneKonfigurierteStoreURLFuehrtMutationDirektAus() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        DatabaseLeaseService.storeURL = nil

        var mutateAufgerufen = false
        await DatabaseLeaseService.performMicroLease(context: context) {
            mutateAufgerufen = true
        }

        #expect(mutateAufgerufen)
    }

    /// Verschachtelte Session-Leases (z.B. `AbteilungHinzufuegenSheet` über einem
    /// bereits offenen `GeschaeftDetailView`) teilen sich denselben Lease — die
    /// Lock-Datei darf erst verschwinden, wenn auch der äußere Lease freigegeben ist.
    @Test
    func sessionLeaseVerschachtelungTeiltSichDenselbenLease() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let storeURL = macheTempStoreURL()
        DatabaseLeaseService.storeURL = storeURL
        defer { DatabaseLeaseService.storeURL = nil }

        let aeussererLease = DatabaseLeaseService.SessionLease()
        await aeussererLease.acquire()
        #expect(aeussererLease.status == .gehalten)

        let innererLease = DatabaseLeaseService.SessionLease()
        await innererLease.acquire()
        #expect(innererLease.status == .gehalten)

        await innererLease.release(context: context)
        #expect(FileManager.default.fileExists(atPath: lockURL(fuer: storeURL).path))

        await aeussererLease.release(context: context)
        #expect(!FileManager.default.fileExists(atPath: lockURL(fuer: storeURL).path))
    }
}
