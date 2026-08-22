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
            preispunkte: [],
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
            geschaefte: snapshot.geschaefte, artikel: snapshot.artikel, einkaufslisten: snapshot.einkaufslisten
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

    /// Regressionstest für GitHub #80: der lokal bekannte `SyncEvent`-Bestand
    /// muss Teil des Backups sein, inklusive `hochgeladen`-Status — sonst
    /// würde ein Restore ein eigenes, noch nicht exportiertes Event
    /// fälschlich als „bereits geteilt" markieren (siehe
    /// ``SyncErsetzenService/stelleSyncEventsWiederHer(_:context:)``).
    @Test
    func backupRundlaufEnthaeltBekannteSyncEventsMitErhaltenemHochgeladenStatus() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }

        let event = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: UUID(), artikelID: UUID()),
            lamportZaehler: 3, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(event)
        try context.save()
        #expect(event.hochgeladen == false)

        let backupURL = try SyncErsetzenService.erstelleBackup(context: context)
        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: Data(contentsOf: backupURL))

        let gesichertesEvent = try #require(backup.bekannteSyncEvents?.first)
        #expect(gesichertesEvent.event.id == event.id)
        #expect(gesichertesEvent.hochgeladen == false)
    }

    /// Abwärtskompatibilität: ein vor GitHub #80 erstelltes Backup
    /// (Formatversion 1, ohne `bekannteSyncEvents`-Schlüssel) muss weiterhin
    /// decodierbar bleiben, statt den Restore komplett scheitern zu lassen.
    @Test
    func altesBackupFormatOhneBekannteSyncEventsBleibtDecodierbar() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }

        context.insert(Geschaeft(name: "Rewe", typen: []))
        try context.save()
        let backupURL = try SyncErsetzenService.erstelleBackup(context: context)

        var rohesJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
        rohesJSON?.removeValue(forKey: "bekannteSyncEvents")
        let daten = try JSONSerialization.data(withJSONObject: rohesJSON as Any)

        let backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)

        #expect(backup.bekannteSyncEvents == nil)
        #expect(backup.snapshot.geschaefte.map(\.name) == ["Rewe"])
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

    // MARK: - Live ersetzen (``ModelContainerController``, zweiter Anlauf)

    /// Datei-basierter Container in einem isolierten Temp-Verzeichnis — im
    /// Unterschied zu ``machtLeerenContainer()`` (In-Memory) nötig, weil
    /// ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)`` den
    /// Ersatz-Store als Geschwisterdatei im selben Verzeichnis anlegt (siehe
    /// dortige Typ-Doku). Eigenes, pro Aufruf frisches Verzeichnis statt des
    /// echten SwiftData-Standardpfads — berührt dadurch nie echte App-Daten.
    private func machtDateibasiertenContainerController() throws -> (controller: ModelContainerController, ordner: URL) {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let konfiguration = ModelConfiguration(schema: SchemaDefinition.schema, url: ordner.appendingPathComponent("default.store"))
        let container = try ModelContainer(for: SchemaDefinition.schema, configurations: [konfiguration])
        return (ModelContainerController(modelContainer: container), ordner)
    }

    @Test
    func fuehreWiederherstellenAusBackupLiveWirftOhneBackup() async throws {
        SyncErsetzenService.loescheBackup()
        let (controller, _) = try machtDateibasiertenContainerController()
        await #expect(throws: SyncErsetzenFehler.self) {
            try await SyncErsetzenService.fuehreWiederherstellenAusBackupLive(controller: controller)
        }
    }

    /// Regressionstest für die ursprüngliche Neustart-Race (siehe Typ-Doku
    /// ``ModelContainerController``): der ALTE Container/Context bleibt nach
    /// dem Live-Ersetzen unverändert gültig und lesbar (seine Datei wird
    /// NICHT gelöscht) — nur ``ModelContainerController/modelContainer``
    /// zeigt danach auf den neuen, befüllten Store.
    @Test
    func fuehreErsetzenDurchPeerLiveErsetztOhneDenAltenContainerZuBeruehren() async throws {
        // Bewusst KEIN `defer { removeItem(at: ordner) }`: das würde exakt die
        // Race nachstellen, die ``ModelContainerController``s Typ-Doku als
        // Ursache des ursprünglichen Absturzes beschreibt — eine Store-Datei
        // löschen, deren `ModelContainer` derselbe Prozess Sekundenbruchteile
        // zuvor noch selbst offen hatte. `temporaryDirectory` ist ohnehin
        // OS-verwaltetes Scratch-Verzeichnis.
        let (controller, _) = try machtDateibasiertenContainerController()
        defer { SyncErsetzenService.loescheBackup() }
        let alterContext = controller.modelContainer.mainContext
        alterContext.insert(Geschaeft(name: "Rewe", typen: []))
        try alterContext.save()

        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Edeka")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)

        let alteGeneration = controller.generation
        try await SyncErsetzenService.fuehreErsetzenDurchPeerLive(controller: controller)

        #expect(controller.generation != alteGeneration)
        #expect(try controller.modelContainer.mainContext.fetch(FetchDescriptor<Geschaeft>()).map(\.name) == ["Edeka"])
        // Der alte Context/Container bleibt unverändert gültig und lesbar —
        // genau das, was beim ursprünglichen Absturz nicht der Fall war.
        #expect(try alterContext.fetch(FetchDescriptor<Geschaeft>()).map(\.name) == ["Rewe"])
        #expect(SyncErsetzenService.vorhandenesBackup() != nil)
        // Der Live-Pfad berührt ``ausstehendeAktion`` nicht — das bleibt
        // exklusiv dem Boot-Zeit-Mechanismus (GitHub #119) vorbehalten.
        #expect(SyncErsetzenService.ausstehendeAktion == nil)
    }

    /// Analog ``fuehreErsetzenDurchPeerLiveErsetztOhneDenAltenContainerZuBeruehren``,
    /// nur für den Bereinigungs-Pfad (frischer Snapshot des eigenen Bestands
    /// statt eines Peer-Snapshots).
    @Test
    func fuehreBereinigungBaumelnderReferenzenLiveErsetztAusFrischemSnapshot() async throws {
        let (controller, _) = try machtDateibasiertenContainerController()
        defer { SyncErsetzenService.loescheBackup() }
        let alterContext = controller.modelContainer.mainContext
        alterContext.insert(Geschaeft(name: "Rewe", typen: []))
        try alterContext.save()

        let alteGeneration = controller.generation
        try await SyncErsetzenService.fuehreBereinigungBaumelnderReferenzenLive(controller: controller)

        #expect(controller.generation != alteGeneration)
        #expect(try controller.modelContainer.mainContext.fetch(FetchDescriptor<Geschaeft>()).map(\.name) == ["Rewe"])
        #expect(SyncErsetzenService.vorhandenesBackup() != nil)
    }

    /// ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``
    /// direkt: der Ersatz-Store entsteht an einem neuen, noch nie dagewesenen
    /// Dateinamen im selben Verzeichnis, nicht an der ursprünglichen URL —
    /// genau die Eigenschaft, die den ursprünglichen Absturz (Löschen einer
    /// noch offenen Datei) strukturell ausschließt.
    @Test
    func ersetzeLiveMitNeuemStoreLegtNeueDateiAnUndRuftBefuellenAuf() async throws {
        let (controller, _) = try machtDateibasiertenContainerController()
        let urspruenglicheURL = controller.modelContainer.configurations.first?.url

        var befuellt = false
        try await controller.ersetzeLiveMitNeuemStore { context in
            context.insert(Geschaeft(name: "Aldi", typen: []))
            try? context.save()
            befuellt = true
        }

        #expect(befuellt)
        #expect(controller.modelContainer.configurations.first?.url != urspruenglicheURL)
        #expect(controller.modelContainer.configurations.first?.url.lastPathComponent.hasPrefix("ersetzt-") == true)
        #expect(FileManager.default.fileExists(atPath: (urspruenglicheURL?.path ?? "")))
        #expect(try controller.modelContainer.mainContext.fetch(FetchDescriptor<Geschaeft>()).map(\.name) == ["Aldi"])
    }

    /// Live-Test-Nachtrag (analog `2729eab`): zwei ÜBERLAPPENDE Aufrufe von
    /// ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``
    /// (z.B. „Vorherigen Stand wiederherstellen" gefolgt von schnellem
    /// erneuten Ordner-Beitritt mit „Ersetzen", beides live ohne Neustart
    /// dazwischen) dürfen sich nicht gegenseitig überschreiben — ohne die
    /// `wirdErsetzt`-Sperre lesen beide denselben `alteURL`-Ausgangswert und
    /// der zuletzt committende überschreibt den anderen. Erzwingt echte
    /// Überlappung über eine künstliche Verzögerung im ersten `befuellen`.
    @Test
    func ersetzeLiveMitNeuemStoreIgnoriertUeberlappendenZweitenAufruf() async throws {
        let (controller, _) = try machtDateibasiertenContainerController()

        async let ersterAufruf: Void = controller.ersetzeLiveMitNeuemStore { context in
            try? await Task.sleep(for: .milliseconds(100))
            context.insert(Geschaeft(name: "Aldi", typen: []))
            try? context.save()
        }
        async let zweiterAufruf: Void = controller.ersetzeLiveMitNeuemStore { context in
            context.insert(Geschaeft(name: "Edeka", typen: []))
            try? context.save()
        }
        _ = try await (ersterAufruf, zweiterAufruf)

        // Der zweite, überlappende Aufruf wird ohne Wirkung übersprungen
        // (siehe ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``-Doku)
        // — der Endzustand zeigt sauber genau den ersten Datenbestand.
        let geschaefte = try controller.modelContainer.mainContext.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefte.map(\.name) == ["Aldi"])
    }

    @Test
    func raeumeVerwaisteStoreDateienAufLeertDieListe() {
        UserDefaults.standard.set(["ersetzt-\(UUID().uuidString).store"], forKey: "syncErsetzenVerwaisteStoreDateinamen")
        defer { UserDefaults.standard.removeObject(forKey: "syncErsetzenVerwaisteStoreDateinamen") }

        ModelContainerController.raeumeVerwaisteStoreDateienAuf()

        #expect(UserDefaults.standard.stringArray(forKey: "syncErsetzenVerwaisteStoreDateinamen") == nil)
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

    /// Regressionstest (Nutzerbericht 2026-08-06): ein zum Sicherungszeitpunkt
    /// noch offener Einkaufsvorgang im eigenen Backup (z.B. bei einer
    /// Korruptions-Wiederherstellung ohne Sync-Ordner-Austritt,
    /// ``SyncOrdnerSettingsView/backupWiederherstellenGetappt()``) muss nach
    /// der Wiederherstellung geschlossen sein — sonst matcht ihn der nächste
    /// Sync-Zyklus über ``SyncSnapshotImportService``s `offenerTreffer`
    /// blind gegen einen tatsächlich aktiven Vorgang eines Peers und
    /// vermischt dessen eigene, längst veraltete Käufe in die listenweite
    /// "abgehakt"-Ansicht (`docs/DATENSYNCHRONISATION.md` §4.3).
    @Test
    func fuehreAusstehendeAktionAusSchliesstOffenenVorgangAusWiederhergestelltemBackup() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }
        defer { raeumeAusstehendeAktionAuf() }

        let (backupContainer, backupContext) = try machtLeerenContainer()
        _ = backupContainer
        let liste = Einkaufsliste(name: "Einkaufsliste")
        backupContext.insert(liste)
        let offenerVorgang = Einkaufsvorgang(einkaufsliste: liste)
        backupContext.insert(offenerVorgang)
        try backupContext.save()
        try SyncErsetzenService.erstelleBackup(context: backupContext)
        setzeAusstehendeAktion(.wiederherstellenAusBackup)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: context)

        let wiederhergestellterVorgang = try #require(context.fetch(FetchDescriptor<Einkaufsvorgang>()).first)
        #expect(wiederhergestellterVorgang.istAbgeschlossen)
    }

    // MARK: - SyncEvent-Wiederherstellung (GitHub #80)

    @Test
    func fuehreAusstehendeAktionAusStelltBekannteSyncEventsWiederHerFuerWiederherstellenAusBackup() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        defer { SyncErsetzenService.loescheBackup() }
        defer { raeumeAusstehendeAktionAuf() }

        let (backupContainer, backupContext) = try machtLeerenContainer()
        _ = backupContainer
        let event = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: UUID(), artikelID: UUID()),
            lamportZaehler: 7, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        backupContext.insert(event)
        try backupContext.save()
        #expect(event.hochgeladen == false)
        try SyncErsetzenService.erstelleBackup(context: backupContext)
        setzeAusstehendeAktion(.wiederherstellenAusBackup)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: context)

        #expect(SyncEventService.istBereitsBekannt(event.id, context: context))
        // Muss NICHT als bereits hochgeladen markiert sein - sonst würde
        // ``SyncExportService`` es nie an Peers exportieren (siehe Typ-Doku
        // ``SyncErsetzenService/stelleSyncEventsWiederHer(_:context:)``).
        let restauriert = try #require(context.fetch(FetchDescriptor<SyncEvent>()).first)
        #expect(restauriert.hochgeladen == false)
    }

    @Test
    func fuehreAusstehendeAktionAusStelltBekannteSyncEventsWiederHerFuerErsetzenDurchPeer() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        defer { raeumeAusstehendeAktionAuf() }
        defer { SyncErsetzenService.loescheBackup() }
        defer { SyncErsetzenService.zusammenfassungVerwerfen() }

        // Vorher-Backup mit einem eigenen, noch nicht hochgeladenen SyncEvent.
        let event = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: UUID(), artikelID: UUID()),
            lamportZaehler: 9, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(event)
        try context.save()
        try SyncErsetzenService.erstelleBackup(context: context)

        // Neuaufbau auf einem frischen, leeren Context - ein erreichbarer
        // Peer bringt seinen eigenen Datenbestand zurück.
        let (leererContainer, leererContext) = try machtLeerenContainer()
        _ = leererContainer
        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Rewe")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)
        setzeAusstehendeAktion(.ersetzenDurchPeer)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: leererContext)

        #expect(SyncEventService.istBereitsBekannt(event.id, context: leererContext))
        let restauriert = try #require(leererContext.fetch(FetchDescriptor<SyncEvent>()).first)
        #expect(restauriert.hochgeladen == false)
    }

    /// Regressionstest: ``IgnorierterGeschaeftsVorschlag`` ist rein
    /// gerätelokal (nie Teil des Peer-``SyncSnapshot``, siehe Typ-Doku dort)
    /// und muss deshalb auch beim „Ersetzen durch Peer"-Neuaufbau aus dem
    /// Vorher-Backup wiederhergestellt werden — vor dem Fix landete er nur im
    /// `.wiederherstellenAusBackup`-Zweig zurück, beim regulären Sync-Beitritt
    /// bot der ``GeschaeftVorschlagBanner`` bereits ignorierte Vorschläge
    /// danach wieder an.
    @Test
    func fuehreAusstehendeAktionAusStelltIgnorierteGeschaeftsVorschlaegeWiederHerFuerErsetzenDurchPeer() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }
        defer { raeumeAusstehendeAktionAuf() }
        defer { SyncErsetzenService.loescheBackup() }
        defer { SyncErsetzenService.zusammenfassungVerwerfen() }

        context.insert(IgnorierterGeschaeftsVorschlag(name: "Aldi", breitengrad: 1.0, laengengrad: 2.0))
        try context.save()
        try SyncErsetzenService.erstelleBackup(context: context)

        let (leererContainer, leererContext) = try machtLeerenContainer()
        _ = leererContainer
        var snapshot = leererSnapshot(geraeteID: "peer-a")
        snapshot.geschaefte = [leerenGeschaeftSnapshot(name: "Rewe")]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "peer-a", in: syncOrdner)
        setzeAusstehendeAktion(.ersetzenDurchPeer)

        await SyncErsetzenService.fuehreAusstehendeAktionAus(context: leererContext)

        let wiederhergestellt = try #require(leererContext.fetch(FetchDescriptor<IgnorierterGeschaeftsVorschlag>()).first)
        #expect(wiederhergestellt.name == "Aldi")
        #expect(wiederhergestellt.breitengrad == 1.0)
        #expect(wiederhergestellt.laengengrad == 2.0)
    }
}
