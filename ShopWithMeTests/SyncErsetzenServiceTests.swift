import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``SyncErsetzenService`` (GitHub #63 + Korruptions-Recovery, siehe
/// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`).
///
/// **Bewusst kein Test, der den vollen Ablauf „Store-Datei löschen, dann neu
/// öffnen" innerhalb eines einzigen Testlaufs nachstellt:** ein erster
/// Versuch dazu ließ den Testprozess selbst mit genau demselben
/// `BUG IN CLIENT OF libsqlite3.dylib`-Muster abstürzen, das auf einem echten
/// Gerät beim ursprünglichen (verworfenen) Laufzeit-Austausch auftrat — selbst
/// nachdem der erste `ModelContainer` sauber aus dem Scope gegangen war.
/// SwiftData/CoreData scheint intern noch etwas asynchron gegen die Datei
/// laufen zu haben, das durch simples ARC-Deallozieren nicht sofort beendet
/// wird. Der reale Mechanismus verlässt sich stattdessen darauf, dass die
/// Löschung in einem komplett NEUEN Prozess passiert (App-Neustart) — dort
/// kann es diese Art von Restaktivität aus dem alten Prozess gar nicht geben.
/// Ein Unit-Test innerhalb eines einzigen Prozesses kann diese
/// Prozessgrenze nicht nachstellen; das ist daher Gegenstand der manuellen
/// Verifikation auf einem echten Gerät, nicht dieser Tests.
///
/// Getestet wird deshalb an den tatsächlichen Nahtstellen getrennt:
/// - Das reine Löschen einer Store-Datei (``SyncErsetzenService/loescheStoreDateiFallsAusstehend(url:)``)
///   gegen einfache, per `Data.write` erzeugte Dateien — ganz ohne
///   `ModelContainer`, um jede Lebenszyklus-Unschärfe zu vermeiden.
/// - Das Befüllen eines (bereits leeren) Contexts gemäß ausstehender Aktion
///   (``SyncErsetzenService/fuehreAusstehendeAktionAus(context:)``) — der
///   Context ist hier einfach ein zweiter, unabhängiger In-Memory-Container,
///   nicht derselbe, aus dem zuvor "gelöscht" wurde.
@MainActor
struct SyncErsetzenServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: SchemaDefinition.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SchemaDefinition.schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    private func leererSnapshot(geraeteID: String, geraeteName: String = "Fremdes iPhone") -> SyncSnapshot {
        SyncSnapshot(
            formatVersion: SyncSnapshot.aktuelleFormatVersion, erzeugtAm: Date(), geraeteID: geraeteID, geraeteName: geraeteName,
            geschaeftsTypen: [], artikelKategorien: [], geschaefte: [], artikel: [],
            einkaufslisten: [], einkaufslistenEintraege: [], einkaufsvorgaenge: [], kaufEintraege: [],
            warengruppenDistanzen: [], tombstones: []
        )
    }

    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let url = SyncSnapshotExportService.exportURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
    }

    private func leerenGeschaeftSnapshot(name: String) -> GeschaeftSnapshot {
        GeschaeftSnapshot(
            id: UUID(), name: name, typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
            erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
            ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
        )
    }

    /// Testisolation: ``SyncErsetzenService/ausstehendeAktion`` liegt in
    /// `UserDefaults` und übersteht damit einzelne Testläufe.
    private func raeumeAusstehendeAktionAuf() {
        UserDefaults.standard.removeObject(forKey: "syncErsetzenAusstehendeAktion")
    }

    private func setzeAusstehendeAktion(_ aktion: SyncErsetzenService.AusstehendeAktion) {
        UserDefaults.standard.set(aktion.rawValue, forKey: "syncErsetzenAusstehendeAktion")
    }

    // MARK: - Backup

    @Test
    func backupRundlaufEnthaeltSnapshotUndIgnorierteVorschlaege() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        context.insert(IgnorierterGeschaeftsVorschlag(name: "Aldi", breitengrad: 1.0, laengengrad: 2.0))
        try context.save()

        let backupURL = try SyncErsetzenService.erstelleBackup(context: context)
        let daten = try Data(contentsOf: backupURL)
        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)

        #expect(backup.snapshot.geschaefte.map(\.name) == ["Rewe"])
        #expect(backup.ignorierteGeschaeftsVorschlaege.map(\.name) == ["Aldi"])
        #expect(SyncErsetzenService.vorhandenesBackup() != nil)
    }

    @Test
    func erneutesBackupUeberschreibtDasVorherige() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()
        let ersteBackupURL = try SyncErsetzenService.erstelleBackup(context: context)

        context.insert(Geschaeft(name: "Edeka", typen: []))
        try context.save()
        let zweiteBackupURL = try SyncErsetzenService.erstelleBackup(context: context)

        #expect(ersteBackupURL == zweiteBackupURL)
        let daten = try Data(contentsOf: zweiteBackupURL)
        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
        #expect(Set(backup.snapshot.geschaefte.map(\.name)) == Set(["Rewe", "Edeka"]))
    }

    // MARK: - Planen

    @Test
    func planeWiederherstellenAusBackupWirftOhneBackup() {
        SyncErsetzenService.loescheBackup()
        #expect(throws: SyncErsetzenFehler.self) {
            try SyncErsetzenService.planeWiederherstellenAusBackup()
        }
    }

    @Test
    func planeErsetzenDurchPeerSetztAktionUndErstelltBackupOhneDenStoreZuVeraendern() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }
        defer { raeumeAusstehendeAktionAuf() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()

        try SyncErsetzenService.planeErsetzenDurchPeer(context: context)

        #expect(SyncErsetzenService.ausstehendeAktion == .ersetzenDurchPeer)
        #expect(SyncErsetzenService.vorhandenesBackup() != nil)
        // Noch nichts am aktuellen Datenbestand verändert - das passiert erst
        // beim nächsten Start.
        #expect(try context.fetchCount(FetchDescriptor<Geschaeft>()) == 1)
    }

    // MARK: - Store-Datei löschen (ohne ModelContainer, siehe Typ-Doku)

    @Test
    func loescheStoreDateiFallsAusstehendTutNichtsOhneAusstehendeAktion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).sqlite")
        try Data("test".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        SyncErsetzenService.loescheStoreDateiFallsAusstehend(url: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func loescheStoreDateiFallsAusstehendLoeschtDateiUndNebendateienBeiAusstehenderAktion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).sqlite")
        try Data("test".utf8).write(to: url)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        setzeAusstehendeAktion(.ersetzenDurchPeer)
        defer { raeumeAusstehendeAktionAuf() }

        SyncErsetzenService.loescheStoreDateiFallsAusstehend(url: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    // MARK: - Ausstehende Aktion ausführen (auf bereits leerem Context)

    @Test
    func fuehreAusstehendeAktionAusImportiertVonPeer() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        defer { raeumeAusstehendeAktionAuf() }

        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Rewe")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)
        setzeAusstehendeAktion(.ersetzenDurchPeer)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: context)

        let geschaefte = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefte.map(\.name) == ["Rewe"])
        #expect(SyncErsetzenService.ausstehendeAktion == nil)
    }

    @Test
    func fuehreAusstehendeAktionAusStelltGesichertenStandWiederHer() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }
        defer { raeumeAusstehendeAktionAuf() }

        // Backup mit einem eigenen, unabhängigen Datenbestand erzeugen.
        let (backupContainer, backupContext) = try machtLeerenContainer()
        _ = backupContainer
        backupContext.insert(Geschaeft(name: "Rewe", typen: []))
        try backupContext.save()
        try SyncErsetzenService.erstelleBackup(context: backupContext)
        setzeAusstehendeAktion(.wiederherstellenAusBackup)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: context)

        let geschaefte = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefte.map(\.name) == ["Rewe"])
        #expect(SyncErsetzenService.ausstehendeAktion == nil)
    }
}
