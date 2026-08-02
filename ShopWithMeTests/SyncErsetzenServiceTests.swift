import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``SyncErsetzenService`` (GitHub #63 + Korruptions-Recovery, siehe
/// `docs/DATENSYNCHRONISATION_VERLAUF.md`).
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
            preispunkte: [], artikelAliase: [],
            warengruppenDistanzen: [], tombstones: []
        )
    }

    /// Schreibt `snapshot` als Peer-**Paket** (GitHub #82) statt als
    /// Monolith-`export.json` — `SyncSnapshotImportService.importiereSnapshots`
    /// (von ``SyncErsetzenService/fuehreAusstehendeAktionAus(context:)`` im
    /// `.ersetzenDurchPeer`-Fall aufgerufen) liest seither ausschließlich das
    /// neue Paket-Format. `SyncSnapshot` bleibt als bequemer Test-Baustein
    /// (Felder statt sechs Einzel-Parametern) — wird hier nur beim Schreiben
    /// in die Paket-Teile zerlegt.
    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: snapshot.erzeugtAm,
            geraeteID: snapshot.geraeteID, geraeteName: snapshot.geraeteName
        )
        let stamm = SyncStammSnapshot(
            geschaeftsTypen: snapshot.geschaeftsTypen, artikelKategorien: snapshot.artikelKategorien,
            geschaefte: snapshot.geschaefte, artikel: snapshot.artikel, einkaufslisten: snapshot.einkaufslisten,
            artikelAliase: snapshot.artikelAliase
        )
        let listen = SyncListenSnapshot(einkaufslistenEintraege: snapshot.einkaufslistenEintraege)
        let lernen = SyncLernenSnapshot(warengruppenDistanzen: snapshot.warengruppenDistanzen)
        let vorgaenge = SyncVorgaengeSnapshot(einkaufsvorgaenge: snapshot.einkaufsvorgaenge)
        let preise = SyncPreisSnapshot(preispunkte: snapshot.preispunkte)

        let manifestURL = SyncSnapshotExportService.manifestURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(snapshot.tombstones)
            .write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(stamm).write(to: SyncSnapshotExportService.stammURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(listen).write(to: SyncSnapshotExportService.listenURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(lernen).write(to: SyncSnapshotExportService.lernenURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(vorgaenge).write(to: SyncSnapshotExportService.vorgaengeURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(preise).write(to: SyncSnapshotExportService.preiseURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        guard !snapshot.kaufEintraege.isEmpty else { return }
        let kaeufeOrdner = SyncSnapshotExportService.kaeufeOrdner(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: kaeufeOrdner, withIntermediateDirectories: true)
        for eintrag in snapshot.kaufEintraege {
            try JSONEncoder().encode(eintrag).write(to: kaeufeOrdner.appendingPathComponent("\(eintrag.id.uuidString).json"))
        }
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

    /// Regressionstest für die Reparaturstrategie ohne SQLite-Direktzugriff
    /// (Abschnitt 24): erstellt einen frischen Snapshot des AKTUELLEN Bestands
    /// (der ein bereits bestehendes Backup überschreibt) und merkt „Wiederherstellen
    /// aus Backup" vor — identischer Mechanismus wie `planeWiederherstellenAusBackup()`,
    /// nur mit einem eben erst erstellten statt einem irgendwann früher
    /// erstellten Snapshot. Der volle Rundlauf gegen eine echte baumelnde
    /// Referenz ist mangels künstlich erzeugbarer Testreferenz nicht
    /// automatisiert verifizierbar (siehe Typ-Doku) — hier wird nur der
    /// Mechanismus selbst geprüft.
    @Test
    func planeBereinigungBaumelnderReferenzenSetztWiederherstellenAktionUndErstelltFrischesBackup() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }
        defer { raeumeAusstehendeAktionAuf() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()

        try SyncErsetzenService.planeBereinigungBaumelnderReferenzen(context: context)

        #expect(SyncErsetzenService.ausstehendeAktion == .wiederherstellenAusBackup)
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

    /// Regressionstest für einen Live-Test-Nachfolgefund (Abschnitt 21): ein
    /// Neuaufbau, der weniger zurückbekommt als vorher vorhanden war (hier:
    /// nur 1 von 2 vorherigen Geschäften, weil der erreichbare Peer nicht den
    /// vollständigen Stand hatte), muss das jetzt sichtbar als
    /// ``SyncErsetzenService/letzteNeuaufbauZusammenfassung`` festhalten,
    /// statt unbemerkt zu bleiben.
    @Test
    func fuehreAusstehendeAktionAusErstelltNeuaufbauZusammenfassungMitVorherNachherVergleich() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        defer { raeumeAusstehendeAktionAuf() }
        defer { SyncErsetzenService.loescheBackup() }
        defer { SyncErsetzenService.zusammenfassungVerwerfen() }

        // Vorher-Backup: 2 Geschäfte.
        context.insert(Geschaeft(name: "Rewe", typen: []))
        context.insert(Geschaeft(name: "Edeka", typen: []))
        try context.save()
        try SyncErsetzenService.erstelleBackup(context: context)

        // Neuaufbau läuft (wie im echten Ablauf) auf einem frischen, leeren
        // Context — der erreichbare Peer bringt nur 1 der 2 vorherigen
        // Geschäfte zurück.
        let (leererContainer, leererContext) = try machtLeerenContainer()
        _ = leererContainer
        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Rewe")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)
        setzeAusstehendeAktion(.ersetzenDurchPeer)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: leererContext)

        let zusammenfassung = try #require(SyncErsetzenService.letzteNeuaufbauZusammenfassung)
        #expect(zusammenfassung.vorher.geschaefte == 2)
        #expect(zusammenfassung.nachher.geschaefte == 1)
    }

    /// Härtung (Kategorie-3-Review, GitHub-Diskussion 2026-08-03): ein
    /// Neuaufbau, der eindeutig fehlschlägt (hier: kein einziger erreichbarer
    /// Peer, `peers`-Ordner bleibt leer), darf NICHT als leerer Datenbestand
    /// stehen bleiben, sondern muss automatisch auf den Vorher-Stand aus dem
    /// Backup zurückgerollt werden — anders als der Live-Test-Nachfolgefund
    /// oben (Abschnitt 21, teilweiser Rückgang), der bewusst nur informativ
    /// bleibt.
    @Test
    func fuehreAusstehendeAktionAusRolltBeiKomplettLeeremNeuaufbauAutomatischZurueck() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        defer { raeumeAusstehendeAktionAuf() }
        defer { SyncErsetzenService.loescheBackup() }
        defer { SyncErsetzenService.zusammenfassungVerwerfen() }

        // Vorher-Backup: 2 Geschäfte.
        context.insert(Geschaeft(name: "Rewe", typen: []))
        context.insert(Geschaeft(name: "Edeka", typen: []))
        try context.save()
        try SyncErsetzenService.erstelleBackup(context: context)

        // Neuaufbau auf einem frischen, leeren Context — bewusst KEIN Peer im
        // Sync-Ordner (kein `schreibeFremdenSnapshot`-Aufruf), simuliert den
        // Fall "kein erreichbares Sync-Gerät zum Zeitpunkt des Neuaufbaus".
        let (leererContainer, leererContext) = try machtLeerenContainer()
        _ = leererContainer
        setzeAusstehendeAktion(.ersetzenDurchPeer)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: leererContext)

        #expect(SyncErsetzenService.letzterNeuaufbauAutomatischZurueckgerollt)
        let geschaefte = try leererContext.fetch(FetchDescriptor<Geschaeft>())
        #expect(Set(geschaefte.map(\.name)) == Set(["Rewe", "Edeka"]))
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
