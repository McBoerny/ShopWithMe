import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@Suite(.serialized)
@MainActor
struct SyncPollingServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerZaehlerStand.self, SyncPeerInfo.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    @Test
    func syncZyklusOhneKontextTutNichtsUndStuerztNichtAb() async throws {
        let service = SyncPollingService()
        await service.syncZyklus() // kein starten() zuvor -> context ist nil
    }

    @Test
    func startenFuehrtSofortEinenSyncZyklusAus() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer {
            SyncOrdnerService.ordnerEntfernen()
        }

        // Sehr kurzes Ruhe-Intervall, damit der Test nicht auf die reale
        // 60-Sekunden-Wartezeit angewiesen ist.
        let vorherigesIntervall = SyncPollingService.intervallRuhend
        SyncPollingService.intervallRuhend = .milliseconds(20)
        defer { SyncPollingService.intervallRuhend = vorherigesIntervall }

        let service = SyncPollingService()
        service.starten(context: context)
        defer { service.stoppen() }

        // Der erste Sync-Zyklus läuft synchron-ähnlich sofort beim Start (vor
        // dem ersten Intervall) — kurz warten, bis das eigene manifest.json
        // geschrieben wurde (wird jeden Zyklus unbedingt geschrieben, siehe
        // ``SyncPeerManifest``).
        let manifestURL = SyncSnapshotExportService.eigenerManifestURL(in: syncOrdner)
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: manifestURL.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test
    func stoppenBeendetDenLoopEndgueltig() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let vorherigesIntervall = SyncPollingService.intervallRuhend
        SyncPollingService.intervallRuhend = .milliseconds(10)
        defer { SyncPollingService.intervallRuhend = vorherigesIntervall }

        let service = SyncPollingService()
        service.starten(context: context)
        try await Task.sleep(for: .milliseconds(30))
        service.stoppen()

        // Erneutes Starten nach dem Stoppen muss wieder möglich sein (kein
        // dauerhaft blockierter Zustand).
        service.starten(context: context)
        service.stoppen()
    }

    /// Rückkehrer-Erkennung (Peer-Lebenszyklus): `peers/` existiert, der
    /// eigene Unterordner aber nicht — die Gruppe hat dieses Gerät entfernt.
    /// Erwartet: Sync-Ordner wird sofort entfernt, `wurdeAusGruppeEntfernt`
    /// wird gesetzt, und es läuft KEIN `syncZyklus()` mehr in dieser Session
    /// (kein `manifest.json` geschrieben) — genau die Garantie, die den
    /// Export veralteten Bestands verhindern soll.
    @Test
    func startenErkenntAusschlussAusGruppeUndEntferntSyncOrdnerOhneWeiterenSyncZyklus() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer {
            SyncOrdnerService.ordnerEntfernen()
            SyncErsetzenService.loescheBackup()
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: peersOrdner.appendingPathComponent("Anderes-Geraet_abcdef", isDirectory: true), withIntermediateDirectories: true
        )

        let service = SyncPollingService()
        service.starten(context: context)
        defer { service.stoppen() }

        for _ in 0..<50 {
            if service.wurdeAusGruppeEntfernt { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(service.wurdeAusGruppeEntfernt)
        #expect(SyncOrdnerService.gewaehlterOrdner() == nil)
        let manifestURL = SyncSnapshotExportService.eigenerManifestURL(in: syncOrdner)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    }
}
