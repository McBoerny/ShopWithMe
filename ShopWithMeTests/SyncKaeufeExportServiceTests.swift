import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@Suite(.serialized)
@MainActor
struct SyncKaeufeExportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, Preispunkt.self, ArtikelAlias.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncTombstone.self,
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
    func exportiereNeueKaeufeSchreibtEineDateiProKaufEintrag() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let eintrag = KaufEintrag(artikel: apfel, geschaeft: geschaeft)
        context.insert(eintrag)
        try context.save()

        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)

        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        let dateien = try FileManager.default.contentsOfDirectory(at: ordner, includingPropertiesForKeys: nil)
        #expect(dateien.map(\.lastPathComponent) == ["\(eintrag.id.uuidString).json"])

        let daten = try Data(contentsOf: ordner.appendingPathComponent("\(eintrag.id.uuidString).json"))
        let snapshot = try JSONDecoder().decode(KaufEintragSnapshot.self, from: daten)
        #expect(snapshot.id == eintrag.id)
        #expect(snapshot.artikelID == apfel.id)
    }

    /// Kernaussage von GitHub #82 für die Kaufhistorie: ein bereits
    /// exportierter Eintrag wird bei einem erneuten Aufruf NICHT nochmal
    /// kodiert/geschrieben (Existenz-Check per Datei) — anders als der
    /// bisherige Monolith, der bei jedem Zyklus die komplette Historie neu
    /// kodierte.
    @Test
    func exportiereNeueKaeufeUeberschreibtBereitsVorhandeneDateienNicht() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let eintrag = KaufEintrag(artikel: nil, geschaeft: nil)
        context.insert(eintrag)
        try context.save()

        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)
        let url = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner).appendingPathComponent("\(eintrag.id.uuidString).json")
        let ersteFassung = try Data(contentsOf: url)

        // Manuelle "Manipulation" der Datei, um zu belegen, dass ein
        // erneuter Export sie unangetastet lässt (reiner Existenz-Check,
        // keine Fingerabdruck-/Inhaltsprüfung nötig, da KaufEintrag-Snapshots
        // unveränderlich sind).
        try Data("{}".utf8).write(to: url)
        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)

        let nachDemZweitenExport = try Data(contentsOf: url)
        #expect(nachDemZweitenExport == Data("{}".utf8))
        #expect(ersteFassung != Data("{}".utf8))
    }

    @Test
    func entferneDateienLoeschtVorhandeneKaeufeDateien() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let eintragEins = KaufEintrag(artikel: nil, geschaeft: nil)
        let eintragZwei = KaufEintrag(artikel: nil, geschaeft: nil)
        context.insert(eintragEins)
        context.insert(eintragZwei)
        try context.save()
        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)
        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        let urlEins = ordner.appendingPathComponent("\(eintragEins.id.uuidString).json")
        let urlZwei = ordner.appendingPathComponent("\(eintragZwei.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: urlEins.path))
        #expect(FileManager.default.fileExists(atPath: urlZwei.path))

        // Bewusst EIN gebündelter Aufruf für beide IDs statt zweier
        // Einzelaufrufe — siehe Typ-Doku „Bewusst EIN
        // startAccessingSecurityScopedResource()-Aufruf für die gesamte
        // Liste" (Live-Test-Fund: verschachteltes/wiederholtes Öffnen und
        // Schließen desselben Security-Scoped-Bookmarks destabilisierte den
        // Zugriff auf echten Geräten).
        SyncKaeufeExportService.entferneDateien(fuerKaufEintragIDs: [eintragEins.id, eintragZwei.id])

        #expect(!FileManager.default.fileExists(atPath: urlEins.path))
        #expect(!FileManager.default.fileExists(atPath: urlZwei.path))
    }

    @Test
    func exportiereNeueKaeufeOhneSyncOrdnerTutNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        SyncOrdnerService.ordnerEntfernen()

        await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)
        // Kein Absturz — nichts weiter zu prüfen ohne einen konfigurierten Ordner.
    }
}
