import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``SyncAktualitaetsService`` und die dazugehörige Event-
/// Alters-Löschung ``SyncExportService/raeumeAlteEigeneEventDateienAufFallsFaellig()``
/// (GitHub #89).
@MainActor
struct SyncAktualitaetsServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([SyncPeerInfo.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    /// Schreibt einen fremden Peer-Ordner mit `manifest.json` — Grundlage für
    /// den dynamischen Aufräum-Wasserstand (``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``)
    /// in den Bereinigungs-Tests unten: ohne mindestens einen anderen Peer
    /// liefert der Wasserstand `nil` (keine Grundlage, aufzuräumen).
    private func schreibeFremdenPeerManifest(erzeugtAm: Date, in syncOrdner: URL) throws {
        let peerOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent("Fremdes-Geraet_abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: peerOrdner, withIntermediateDirectories: true)
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: erzeugtAm,
            geraeteID: "fremdes-geraet", geraeteName: "Fremdes Gerät"
        )
        try JSONEncoder().encode(manifest).write(to: peerOrdner.appendingPathComponent("manifest.json"))
    }

    @Test
    func ohneSyncOrdnerNieAusDerZeitGefallen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        SyncOrdnerService.ordnerEntfernen()
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = Date().addingTimeInterval(-100 * 24 * 60 * 60)

        #expect(SyncAktualitaetsService.istAusDerZeitGefallen(context: context) == false)
    }

    @Test
    func ohneEtabliertesMitgliedNieAusDerZeitGefallen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Kein SyncPeerInfo angelegt -> noch nie erfolgreich mit einem Peer
        // synchronisiert, also kein etabliertes Mitglied, egal wie alt der
        // Zeitstempel ist.
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = Date().addingTimeInterval(-100 * 24 * 60 * 60)

        #expect(SyncAktualitaetsService.istEtabliertesMitglied(context: context) == false)
        #expect(SyncAktualitaetsService.istAusDerZeitGefallen(context: context) == false)
    }

    /// Migrations-Fall (siehe Typ-Doku): ein bereits etabliertes Gerät, das
    /// diesen Zeitpunkt noch nie aufgezeichnet hat (z.B. weil es schon vor
    /// GitHub #89 etabliert war), darf beim ersten Start nach dem Update
    /// nicht fälschlich als "aus der Zeit gefallen" gelten.
    @Test
    func nilZeitstempelGiltNichtAlsAusDerZeitGefallen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        SyncPeerInfo.aktualisiere(peerGeraeteID: "peer", geraeteName: "Peer", zuletztGesehen: Date(), context: context)
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = nil

        #expect(SyncAktualitaetsService.istAusDerZeitGefallen(context: context) == false)
    }

    @Test
    func etabliertesGeraetInnerhalbDerFristNichtAusDerZeitGefallen() throws {
        let vorherigeSchwelle = SyncAktualitaetsService.veraltungsSchwelle
        SyncAktualitaetsService.veraltungsSchwelle = 60
        defer { SyncAktualitaetsService.veraltungsSchwelle = vorherigeSchwelle }

        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        SyncPeerInfo.aktualisiere(peerGeraeteID: "peer", geraeteName: "Peer", zuletztGesehen: Date(), context: context)
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = Date().addingTimeInterval(-10)

        #expect(SyncAktualitaetsService.istAusDerZeitGefallen(context: context) == false)
    }

    @Test
    func etabliertesGeraetJenseitsDerFristIstAusDerZeitGefallen() throws {
        let vorherigeSchwelle = SyncAktualitaetsService.veraltungsSchwelle
        SyncAktualitaetsService.veraltungsSchwelle = 60
        defer { SyncAktualitaetsService.veraltungsSchwelle = vorherigeSchwelle }

        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        SyncPeerInfo.aktualisiere(peerGeraeteID: "peer", geraeteName: "Peer", zuletztGesehen: Date(), context: context)
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = Date().addingTimeInterval(-120)

        #expect(SyncAktualitaetsService.istAusDerZeitGefallen(context: context) == true)
    }

    @Test
    func vermerkeErfolgreichenZyklusSetztZeitpunkt() {
        SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm = nil
        let zeitpunkt = Date()

        SyncAktualitaetsService.vermerkeErfolgreichenZyklus(am: zeitpunkt)

        #expect(SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm == zeitpunkt)
    }

    // MARK: - Event-Alters-Löschung

    /// Peer-Lebenszyklus, Baustein C: Löschkriterium ist jetzt der dynamische
    /// Aufräum-Wasserstand (Minimum der `erzeugtAm`-Zeitstempel aller
    /// aktuell bekannten Peers) statt einer festen Frist.
    @Test
    func raeumtNurAlteEigeneEventDateienAuf() async throws {
        SyncExportService.letzteEventBereinigung = nil

        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Anderer Peer mit vollständigem Sync vor 60s -> Wasserstand.
        try schreibeFremdenPeerManifest(erzeugtAm: Date().addingTimeInterval(-60), in: syncOrdner)

        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        try FileManager.default.createDirectory(at: eventsOrdner, withIntermediateDirectories: true)
        let alteDatei = eventsOrdner.appendingPathComponent("0000000001_\(UUID().uuidString).json")
        let neueDatei = eventsOrdner.appendingPathComponent("0000000002_\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: alteDatei)
        try Data("{}".utf8).write(to: neueDatei)
        // Älter als der Wasserstand (60s) -> wird gelöscht.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: alteDatei.path
        )
        // Neuer als der Wasserstand -> bleibt.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: neueDatei.path
        )

        await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()

        #expect(!FileManager.default.fileExists(atPath: alteDatei.path))
        #expect(FileManager.default.fileExists(atPath: neueDatei.path))
    }

    /// Kein anderer Peer bekannt -> der Wasserstand liefert `nil` -> nichts
    /// wird gelöscht, egal wie alt eine eigene Event-Datei ist.
    @Test
    func raeumtNichtsOhneAnderenBekanntenPeer() async throws {
        SyncExportService.letzteEventBereinigung = nil

        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        try FileManager.default.createDirectory(at: eventsOrdner, withIntermediateDirectories: true)
        let datei = eventsOrdner.appendingPathComponent("0000000001_\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: datei)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-400 * 24 * 60 * 60)], ofItemAtPath: datei.path
        )

        await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()

        #expect(FileManager.default.fileExists(atPath: datei.path))
    }

    /// Analog `KaufEintragBereinigungService.automatischesIntervall`: ein
    /// bereits kürzlich gelaufener Aufräumlauf wird nicht sofort wiederholt
    /// — verhindert, dass jeder 5s/60s-Sync-Zyklus den eigenen
    /// `events/`-Ordner komplett aufzählt.
    @Test
    func bereinigungLaeuftHoechstensEinmalProIntervall() async throws {
        SyncExportService.letzteEventBereinigung = Date()
        defer { SyncExportService.letzteEventBereinigung = nil }

        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        try schreibeFremdenPeerManifest(erzeugtAm: Date(), in: syncOrdner)

        let eventsOrdner = SyncExportService.eigenerEventsOrdner(in: syncOrdner)
        try FileManager.default.createDirectory(at: eventsOrdner, withIntermediateDirectories: true)
        let datei = eventsOrdner.appendingPathComponent("0000000001_\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: datei)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: datei.path
        )

        await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()

        // Trotz alter Datei nicht gelöscht, weil der letzte Lauf laut
        // `letzteEventBereinigung` gerade erst war (Rate-Limit-Check greift
        // vor jedem Datei-/Wasserstand-Zugriff).
        #expect(FileManager.default.fileExists(atPath: datei.path))
    }
}
