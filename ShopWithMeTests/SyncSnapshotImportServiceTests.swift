import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncSnapshotImportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerZaehlerStand.self, SyncPeerInfo.self,
            SyncTombstone.self, Preispunkt.self, ArtikelAlias.self,
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
    /// liest seither ausschließlich das neue Paket-Format. `SyncSnapshot`
    /// bleibt als bequemer Test-Baustein (ein Feld je Bereich statt sechs
    /// Einzel-Parametern für alle unten stehenden Tests) — wird hier nur beim
    /// Schreiben in die Paket-Teile zerlegt, analog
    /// ``SyncSnapshotExportService/erstellePaketTeile(context:)``.
    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: snapshot.erzeugtAm,
            geraeteID: snapshot.geraeteID, geraeteName: snapshot.geraeteName
        )
        let stamm = SyncStammSnapshot(
            geschaeftsTypen: snapshot.geschaeftsTypen, artikelKategorien: snapshot.artikelKategorien,
            geschaefte: snapshot.geschaefte, artikel: snapshot.artikel, einkaufslisten: snapshot.einkaufslisten,
            einkaufslistenEintraege: snapshot.einkaufslistenEintraege, artikelAliase: snapshot.artikelAliase
        )
        let lernen = SyncLernenSnapshot(warengruppenDistanzen: snapshot.warengruppenDistanzen)
        let vorgaenge = SyncVorgaengeSnapshot(einkaufsvorgaenge: snapshot.einkaufsvorgaenge)
        let preise = SyncPreisSnapshot(preispunkte: snapshot.preispunkte)

        let manifestURL = SyncSnapshotExportService.manifestURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(snapshot.tombstones)
            .write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
        try JSONEncoder().encode(stamm).write(to: SyncSnapshotExportService.stammURL(fuerPeer: fremdeGeraeteID, in: syncOrdner))
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

    @Test
    func geschaeftstypWirdPerNamenGematchtStattDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let lokalerTyp = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(lokalerTyp)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaeftsTypen = [
            GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart", farbeHex: "#FF0000", sortIndex: 0),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alle = try context.fetch(FetchDescriptor<GeschaeftTyp>())
        #expect(alle.count == 1)
        #expect(alle.first?.id == lokalerTyp.id)
    }

    @Test
    func geschaeftWirdPerKoordinateGematchtUndKategorienVereinigt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let eigeneKategorie = ArtikelKategorie(name: "Obst", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        context.insert(eigeneKategorie)
        let lokal = Geschaeft(name: "Mein Rewe", typen: [typ])
        lokal.breitengrad = 52.5200
        lokal.laengengrad = 13.4050
        lokal.kategorien = [eigeneKategorie]
        context.insert(lokal)
        try context.save()

        let remoteKategorieID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikelKategorien = [
            ArtikelKategorieSnapshot(id: remoteKategorieID, name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF", sortIndex: 0, geschaeftsTypIDs: []),
        ]
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: UUID(), name: "REWE Musterstadt", typIDs: [], adresse: nil,
                breitengrad: 52.5201, laengengrad: 13.4051, erkennungsradius: 120,
                kategorieIDs: [remoteKategorieID], ausgeschlosseneKategorieIDs: [], alternativeNamen: ["Rewe Center"],
                ignorierteArtikelNamen: ["Pfand"], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleGeschaefte = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(alleGeschaefte.count == 1)
        #expect(lokal.name == "Mein Rewe") // Name bleibt lokal, nicht überschrieben.
        #expect(lokal.erkennungsradiusRaw == 120) // War lokal nil -> von Remote übernommen.
        #expect(lokal.kategorien.map(\.name).sorted() == ["Milchprodukte", "Obst"])
        #expect(lokal.alternativeNamen.contains("Rewe Center"))
        #expect(lokal.ignorierteArtikel.map(\.erkannterName) == ["Pfand"])
    }

    /// Prüft das grundlegende G-Counter-Verhalten (siehe
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 17): der
    /// Gesamtwert ist die Summe aus dem eigenen Anteil und dem zuletzt
    /// gemeldeten EIGENEN Beitrag jedes Peers — kein additives Delta mehr
    /// gegenüber einem bereits gemergten Gesamtwert.
    @Test
    func eigenerBeitragJedesPeersWirdGenauEinmalGezaehlt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
        lokal.eigeneAnzahlEinkaufsvorgaenge = 2
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        func snapshotMitEigenemBeitrag(_ wert: Int) -> SyncSnapshot {
            var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
            snapshot.geschaefte = [
                GeschaeftSnapshot(
                    id: remoteID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                    erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                    ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: wert, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
                ),
            ]
            return snapshot
        }

        try schreibeFremdenSnapshot(snapshotMitEigenemBeitrag(3), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 5) // 2 (eigen) + 3 (Peer-Beitrag)

        // Peer meldet zwei weitere echte Einkäufe (eigener Beitrag jetzt 5 statt 3).
        try schreibeFremdenSnapshot(snapshotMitEigenemBeitrag(5), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 7) // 2 (eigen) + 5 (neuer Peer-Beitrag)

        // Erneuter Import desselben (unveränderten) Standes darf nichts addieren.
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 7)
    }

    /// Regressionstest für den in einem echten Zwei-Geräte-Live-Test
    /// beobachteten Fund (`docs/DATENSYNCHRONISATION_VERLAUF.md`
    /// Abschnitt 17): die ursprüngliche "Delta seit zuletzt gesehenem
    /// Gesamtwert"-Regel zählte denselben Beitrag bei jedem Hin-und-Her
    /// zwischen zwei Geräten erneut mit, weil der von einem Peer gemeldete
    /// "Gesamtwert" selbst schon zurückenthaltene eigene Beiträge trug.
    /// Simuliert zwei Geräte, die sich wiederholt gegenseitig importieren
    /// (über zwei getrennte, physische Sync-Ordner, damit sich keine Seite
    /// versehentlich selbst importiert), OHNE dass je ein neuer echter
    /// Einkauf stattfindet — der Gesamtwert darf sich dabei auf keiner Seite
    /// mehr verändern.
    @Test
    func zaehlerWaechstNichtDurchWiederholtesHinUndHerSynchronisieren() async throws {
        let (containerA, contextA) = try machtLeerenContainer()
        _ = containerA
        let (containerB, contextB) = try machtLeerenContainer()
        _ = containerB

        let syncOrdnerVonA = macheTempSyncOrdner()
        let syncOrdnerVonB = macheTempSyncOrdner()
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typA = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        contextA.insert(typA)
        let geschaeftA = Geschaeft(name: "Rewe", typen: [typA])
        geschaeftA.eigeneAnzahlEinkaufsvorgaenge = 1 // Ein echter Einkauf auf Gerät A, sonst nie wieder.
        contextA.insert(geschaeftA)
        try contextA.save()

        let typB = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        contextB.insert(typB)
        let geschaeftB = Geschaeft(name: "Rewe", typen: [typB]) // Per Name gematcht, kein echter Einkauf auf B.
        contextB.insert(geschaeftB)
        try contextB.save()

        func exportiere(_ context: ModelContext, nach ordner: URL) throws {
            let teile = SyncSnapshotExportService.erstellePaketTeile(context: context)
            let manifestURL = SyncSnapshotExportService.manifestURL(fuerPeer: "peer", in: ordner)
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(teile.manifest).write(to: manifestURL)
            try JSONEncoder().encode(teile.tombstones).write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.stamm).write(to: SyncSnapshotExportService.stammURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.lernen).write(to: SyncSnapshotExportService.lernenURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.vorgaenge).write(to: SyncSnapshotExportService.vorgaengeURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.preise).write(to: SyncSnapshotExportService.preiseURL(fuerPeer: "peer", in: ordner))
        }

        for _ in 0..<4 {
            try exportiere(contextA, nach: syncOrdnerVonA)
            try SyncOrdnerService.ordnerFestlegen(syncOrdnerVonA)
            await SyncSnapshotImportService.importiereSnapshots(context: contextB)

            try exportiere(contextB, nach: syncOrdnerVonB)
            try SyncOrdnerService.ordnerFestlegen(syncOrdnerVonB)
            await SyncSnapshotImportService.importiereSnapshots(context: contextA)
        }

        let geschaeftAAktuell = try #require(try contextA.fetch(FetchDescriptor<Geschaeft>()).first)
        let geschaeftBAktuell = try #require(try contextB.fetch(FetchDescriptor<Geschaeft>()).first)
        #expect(geschaeftAAktuell.anzahlEinkaufsvorgaenge == 1)
        #expect(geschaeftBAktuell.anzahlEinkaufsvorgaenge == 1)
    }

    @Test
    func artikelWirdPerNameGematchtUndAliasErlaubtSpaetereBereichAEreignisse() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let lokalerApfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(lokalerApfel)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        try context.save()

        let remoteArtikelID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: remoteArtikelID, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Kein zweiter Artikel entstanden.
        #expect(try context.fetch(FetchDescriptor<Artikel>()).count == 1)

        // Ein später eintreffendes Bereich-A-Event des Peers, das die FREMDE
        // Artikel-ID referenziert, muss über den Alias auf den lokalen Apfel
        // aufgelöst werden.
        let eventOrdner = SyncExportService.eventsOrdner(fuerPeer: "fremdes-geraet", in: syncOrdner)
        try FileManager.default.createDirectory(at: eventOrdner, withIntermediateDirectories: true)
        let event = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: remoteArtikelID)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try JSONEncoder().encode(event).write(to: eventOrdner.appendingPathComponent("0000000001_\(event.id.uuidString).json"))

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(liste.enthaelt(lokalerApfel))
    }

    @Test
    func einkaufslisteWirdPerNameGematchtUndAliasErlaubtSpaetereBereichAEreignisse() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Jedes Gerät legt beim allerersten Start automatisch eine eigene
        // Standardliste "Einkaufsliste" an, bevor je synchronisiert wurde
        // (siehe Einkaufsliste.standard(context:)) — genau dieser Fall.
        let eigeneListe = Einkaufsliste(name: "Einkaufsliste")
        context.insert(eigeneListe)
        try context.save()

        let remoteListenID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [
            EinkaufslisteSnapshot(id: remoteListenID, name: "Einkaufsliste", erstelltAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Keine zweite, für den Nutzer unsichtbare Dublette (GitHub #52-Nachfolgefund).
        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 1)

        // Ein später eintreffendes Bereich-A-Event des Peers, das die FREMDE
        // Listen-ID referenziert, muss über den Alias auf die lokale Liste
        // aufgelöst werden.
        let lokalerApfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(lokalerApfel)
        try context.save()

        let eventOrdner = SyncExportService.eventsOrdner(fuerPeer: "fremdes-geraet", in: syncOrdner)
        try FileManager.default.createDirectory(at: eventOrdner, withIntermediateDirectories: true)
        let event = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: remoteListenID, artikelID: lokalerApfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try JSONEncoder().encode(event).write(to: eventOrdner.appendingPathComponent("0000000001_\(event.id.uuidString).json"))

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(eigeneListe.enthaelt(lokalerApfel))
    }

    @Test
    func tombstoneVerhindertWiederbelebungEinesGeloeschtenGeschaefts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Lokal existiert das Geschäft bereits (z.B. aus einem früheren Sync).
        let geschaeftID = UUID()
        let lokalesGeschaeft = Geschaeft(name: "Netto", typen: [], adresse: nil)
        lokalesGeschaeft.id = geschaeftID
        context.insert(lokalesGeschaeft)
        try context.save()

        // Ein Peer meldet per Tombstone, dass er dieses Geschäft gelöscht hat.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.tombstones = [
            SyncTombstoneSnapshot(entitaetsArt: SyncEntitaetsArt.geschaeft, geloeschteID: geschaeftID, geloeschtAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).isEmpty)

        // Ein zweiter, veralteter Peer listet das Geschäft weiterhin (z.B. weil
        // er die Löschung noch nicht mitbekommen hat) — darf es nicht
        // wiederbeleben (GitHub #52-Nachfolgefund: Tombstones).
        var veralteterSnapshot = leererSnapshot(geraeteID: "veralteter-peer")
        veralteterSnapshot.geschaefte = [
            GeschaeftSnapshot(
                id: geschaeftID, name: "Netto", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(veralteterSnapshot, fremdeGeraeteID: "veralteter-peer", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).isEmpty)
    }

    /// Deckt die beim Einführen der Retention-Tombstones (`PreisHistorieBereinigungService`)
    /// gefundene Lücke ab: ``SyncSnapshotImportService`` prüfte beim Neuanlegen
    /// eines ``Einkaufsvorgang`` bislang nicht gegen Tombstones — anders als
    /// ``Geschaeft``/``Artikel``/``Einkaufsliste``.
    @Test
    func tombstoneVerhindertWiederbelebungEinesGeloeschtenEinkaufsvorgangs() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let vorgangID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.tombstones = [
            SyncTombstoneSnapshot(entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, geloeschteID: vorgangID, geloeschtAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).isEmpty)

        // Ein veralteter Peer listet den (retention-)gelöschten Einkaufsvorgang
        // weiterhin — darf ihn nicht wiederbeleben.
        var veralteterEinkaufsvorgangSnapshot = leererSnapshot(geraeteID: "veralteter-peer")
        veralteterEinkaufsvorgangSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: vorgangID, geschaeftID: nil, einkaufslisteID: nil, startZeit: .distantPast, endZeit: .distantPast),
        ]
        try schreibeFremdenSnapshot(veralteterEinkaufsvorgangSnapshot, fremdeGeraeteID: "veralteter-peer", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).isEmpty)
    }

    /// Analog ``tombstoneVerhindertWiederbelebungEinesGeloeschtenEinkaufsvorgangs()``,
    /// für ``KaufEintrag`` (Union-nach-`id`-Merge kannte bislang ebenfalls
    /// keine Tombstone-Prüfung).
    @Test
    func tombstoneVerhindertWiederbelebungEinesGeloeschtenKaufEintrags() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let kaufEintragID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.tombstones = [
            SyncTombstoneSnapshot(entitaetsArt: SyncEntitaetsArt.kaufEintrag, geloeschteID: kaufEintragID, geloeschtAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)

        var veralteterKaufEintragSnapshot = leererSnapshot(geraeteID: "veralteter-peer")
        veralteterKaufEintragSnapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: kaufEintragID, artikelID: nil, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Milch", geschaeftNameSnapshot: "Netto",
                datum: .distantPast, menge: 1, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(veralteterKaufEintragSnapshot, fremdeGeraeteID: "veralteter-peer", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
    }

    @Test
    func einkaufslistenEintragWirdAusSnapshotNachgeholt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let lokaleListe = Einkaufsliste(name: "Einkaufsliste")
        context.insert(lokaleListe)
        let lokalerArtikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(lokalerArtikel)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: lokaleListe.id, name: "Einkaufsliste", erstelltAm: Date())]
        snapshot.artikel = [
            ArtikelSnapshot(
                id: lokalerArtikel.id, name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufslistenEintraege = [
            EinkaufslistenEintragSnapshot(einkaufslisteID: lokaleListe.id, artikelID: lokalerArtikel.id, menge: 2, notiz: "Bio"),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(lokaleListe.enthaelt(lokalerArtikel))
        #expect(lokaleListe.eintrag(fuer: lokalerArtikel)?.menge == 2)
    }

    @Test
    func bereitsAbgehakterArtikelWirdNichtDurchSnapshotWiederAufDieListeGeholt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let artikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(vorgang)
        try context.save()

        // Nutzer hakt Milch ab — entfernt den EinkaufslistenEintrag als
        // Seiteneffekt, OHNE ein artikelEntfernt-Event (siehe
        // Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung).
        _ = vorgang.artikelAbhakenOhneEventAufzeichnung(artikel, context: context)
        try context.save()
        #expect(!liste.enthaelt(artikel))

        // Ein Peer, der die Abwahl noch nicht mitbekommen hat, listet Milch
        // in seinem Snapshot weiterhin als Mitglied der Liste.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        snapshot.artikel = [
            ArtikelSnapshot(
                id: artikel.id, name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufslistenEintraege = [
            EinkaufslistenEintragSnapshot(einkaufslisteID: liste.id, artikelID: artikel.id, menge: 1, notiz: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Das Sicherheitsnetz darf den bereits abgehakten Artikel nicht
        // wieder auf die offene Liste zurückholen (GitHub #52-Nachfolgefund).
        #expect(!liste.enthaelt(artikel))
    }

    /// Regressionstest: derselbe Bug wie oben, aber für den Fall, dass der
    /// Vorgang mit dem `KaufEintrag` zwischenzeitlich per „Einkauf
    /// abschließen" geschlossen und sofort ein neuer, offener Nachfolger für
    /// dieselbe Liste angelegt wurde (`EinkaufenView.einkaufSicherstellen()`).
    /// `istBereitsAbgehakt` prüfte vorher NUR offene Vorgänge — der Artikel
    /// fiel dadurch aus dem Sicherheitsnetz heraus und wurde vom nächsten,
    /// noch veralteten Peer-Snapshot wieder auf die offene Liste geholt
    /// (sichtbar als reales Wiederauftauchen/Duplizieren nach „Einkauf
    /// abschließen").
    @Test
    func bereitsAbgehakterArtikelInGeschlossenemVorgangWirdNichtDurchSnapshotWiederAufDieListeGeholt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let artikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(artikel)
        let geschlossenerVorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(geschlossenerVorgang)
        _ = geschlossenerVorgang.artikelAbhakenOhneEventAufzeichnung(artikel, context: context)
        geschlossenerVorgang.abschliessen()
        // "Einkauf abschließen" legt sofort einen neuen, offenen Vorgang für
        // dieselbe Liste an (einkaufSicherstellen()).
        let neuerOffenerVorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(neuerOffenerVorgang)
        try context.save()
        #expect(!liste.enthaelt(artikel))

        // Ein Peer, der die Abwahl noch nicht mitbekommen hat, listet Milch
        // in seinem Snapshot weiterhin als Mitglied der Liste.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        snapshot.artikel = [
            ArtikelSnapshot(
                id: artikel.id, name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufslistenEintraege = [
            EinkaufslistenEintragSnapshot(einkaufslisteID: liste.id, artikelID: artikel.id, menge: 1, notiz: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(!liste.enthaelt(artikel))
        #expect(neuerOffenerVorgang.kaufEintraege.isEmpty)
    }

    @Test
    func zuAlterSnapshotWirdIgnoriert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let vorherigeAltersgrenze = SyncSnapshotImportService.maximalesSnapshotAlter
        SyncSnapshotImportService.maximalesSnapshotAlter = 60
        defer { SyncSnapshotImportService.maximalesSnapshotAlter = vorherigeAltersgrenze }

        var snapshot = leererSnapshot(geraeteID: "verwaister-peer")
        snapshot.erzeugtAm = Date().addingTimeInterval(-120)
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: UUID(), name: "Sollte ignoriert werden", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "verwaister-peer", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).isEmpty)
    }

    @Test
    func einkaufsvorgangWirdPerIDUebernommenUndNieWiederGeoeffnet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let laufenderVorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(laufenderVorgang)
        try context.save()

        // Peer kennt denselben Einkaufsvorgang (ID-gleich, gemeinsamer Einkauf)
        // und hat ihn bereits abgeschlossen.
        let abschlusszeit = Date()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: laufenderVorgang.id, geschaeftID: nil, einkaufslisteID: nil, startZeit: laufenderVorgang.startZeit, endZeit: abschlusszeit),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)
        #expect(laufenderVorgang.endZeit == abschlusszeit)

        // Ein zweiter, "älterer" Remote-Stand ohne endZeit darf den bereits
        // abgeschlossenen Einkauf nicht wieder öffnen.
        var aelterSnapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        aelterSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: laufenderVorgang.id, geschaeftID: nil, einkaufslisteID: nil, startZeit: laufenderVorgang.startZeit, endZeit: nil),
        ]
        try schreibeFremdenSnapshot(aelterSnapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(laufenderVorgang.endZeit == abschlusszeit)
    }

    @Test
    func zweiUnabhaengigOffeneEinkaufsvorgaengeFuerDenselbenLadenWerdenZusammengefuehrt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Gerät legt selbst einen offenen Einkaufsvorgang an, bevor je
        // synchronisiert wurde — analog zur Einkaufsliste-Dublette, jetzt für
        // Einkaufsvorgang (GitHub #52-Nachfolgefund).
        let eigenerVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(eigenerVorgang)
        let lokalerApfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(lokalerApfel)
        try context.save()

        // Peer hat für DASSELBE Geschäft/DIESELBE Liste unabhängig einen
        // eigenen, ebenfalls noch offenen Einkaufsvorgang mit ANDERER ID.
        let remoteVorgangID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: geschaeft.id, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: geschaeft.id, einkaufslisteID: liste.id, startZeit: Date(), endZeit: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Keine zweite Dublette — beide gelten als derselbe Einkauf.
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)

        // Ein später eintreffendes Bereich-A-Event des Peers ("Artikel
        // abgehakt"), das die FREMDE Einkaufsvorgang-ID referenziert, muss
        // über den Alias auf den lokalen Einkaufsvorgang aufgelöst werden.
        let eventOrdner = SyncExportService.eventsOrdner(fuerPeer: "fremdes-geraet", in: syncOrdner)
        try FileManager.default.createDirectory(at: eventOrdner, withIntermediateDirectories: true)
        let event = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: remoteVorgangID, artikelID: lokalerApfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try JSONEncoder().encode(event).write(to: eventOrdner.appendingPathComponent("0000000001_\(event.id.uuidString).json"))

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(eigenerVorgang.kaufEintraege.contains { $0.artikel == lokalerApfel })
    }

    /// Regressionstest für einen echten Zwei-Geräte-Live-Test-Fund
    /// (2026-07-31): Enthält ein einzelner Peer-Snapshot MEHRERE Einträge, die
    /// alle denselben, für dieses Gerät noch unbekannten offenen Vorgang für
    /// dieselbe Liste meinen (kein lokaler Treffer per ID/Alias), erzeugte
    /// `mergeEinkaufsvorgaenge` bislang für jeden weiteren Eintrag einen
    /// zusätzlichen, eigenständig offenen Vorgang — der `offenerTreffer`-Zweig
    /// "sah" den im selben Durchlauf gerade erst angelegten Vorgang nicht, da
    /// `alleLokalen` nur einmalig zu Beginn gefetcht wurde. Beobachtete Folge:
    /// mehrere lokale Vorgänge für dieselbe Liste gleichzeitig offen,
    /// nachfolgend abweichende `endZeit`-Zuordnungen.
    @Test
    func mehrereNeueVorgaengeFuerDieselbeListeInEinemSnapshotWerdenZusammengefuehrt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        try context.save()

        // Ein Peer-Snapshot listet zwei verschiedene, beide noch offene
        // Einkaufsvorgänge für dieselbe (store-lose) Liste — z.B. weil auf dem
        // Peer nacheinander mehrere Einkäufe ohne Geschäft liefen.
        let ersteVorgangsID = UUID()
        let zweiteVorgangsID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Urlaub", erstelltAm: liste.erstelltAm)]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: ersteVorgangsID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: Date(), endZeit: nil),
            EinkaufsvorgangSnapshot(id: zweiteVorgangsID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: Date(), endZeit: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Nur EIN lokaler offener Vorgang für diese Liste, nicht zwei.
        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 1)
        #expect(vorgaenge.first?.endZeit == nil)
    }

    /// Regressionstest für einen Live-Test-Nachfolgefund (Abschnitt 20): eine
    /// Referenz ohne auflösbare `einkaufslisteID` (auf dem sendenden Gerät
    /// bereits baumelnd, ``sichereID`` lässt sie deshalb beim Export weg) darf
    /// keinen neuen lokalen Vorgang anlegen — ein solcher Vorgang wäre für die
    /// gesamte App unerreichbar (``EinkaufenView/aktuellerEinkauf`` verlangt
    /// immer eine konkrete Liste) und wuchs auf einem Testgerät unbegrenzt
    /// (907 von 959 lokalen Vorgängen, 107 davon mit real angehängten
    /// ``KaufEintrag``en). Ein fehlendes `geschaeftID` bleibt dagegen legitim
    /// (Einkauf ohne gewähltes Geschäft) und darf weiterhin anlegen.
    @Test
    func einkaufsvorgangOhneAufloesbareListeWirdNichtAngelegt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: UUID(), geschaeftID: nil, einkaufslisteID: nil, startZeit: Date(), endZeit: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.isEmpty)
    }

    /// Regressionstest für einen Audit-Fund (Abschnitt 25): ein bereits
    /// lokal vorhandener, selbst schon kaputter (keine Liste, keine ID-
    /// Entsprechung bekannt) offener Vorgang darf NICHT als "derselbe reale
    /// Einkauf" für einen völlig unabhängigen Fremd-Eintrag durchgehen, nur
    /// weil auch dessen `einkaufslisteID` unauflösbar ist — `nil == nil` ist
    /// in Swift `true`, der bisherige `offenerTreffer`-Vergleich
    /// (`$0.einkaufsliste == remoteListe`) prüfte nicht, ob `remoteListe`
    /// überhaupt ein echter Wert war, und aliaserte zwei unabhängig
    /// baumelnde Referenzen fälschlich zusammen — sichtbar u.a. daran, dass
    /// der lokale, eigentlich unberührte Vorgang danach eine `endZeit` vom
    /// Fremd-Eintrag übernahm.
    @Test
    func bereitsBaumelnderLokalerVorgangWirdNichtMitUnabhaengigemFremdeintragOhneListeVermischt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        // Bereits vorhandener, selbst schon kaputter lokaler Vorgang: offen,
        // ohne Liste, ohne Geschäft — genau die Signatur, die vorher fälschlich
        // als "Treffer" durchging.
        let bereitsKaputt = Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil)
        context.insert(bereitsKaputt)
        try context.save()

        // Unabhängiger Fremd-Eintrag, ebenfalls ohne auflösbare Liste, mit
        // einer eigenen, nie zuvor gesehenen ID und einer endZeit.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        let fremdeEndZeit = Date()
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: UUID(), geschaeftID: nil, einkaufslisteID: nil, startZeit: Date(), endZeit: fremdeEndZeit),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Der bereits vorhandene, kaputte Vorgang bleibt komplett unberührt —
        // insbesondere OHNE die endZeit des unabhängigen Fremd-Eintrags.
        #expect(bereitsKaputt.endZeit == nil)
        // Und es entsteht kein zusätzlicher Vorgang für den unauflösbaren
        // Fremd-Eintrag (Abschnitt 20 greift weiterhin).
        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 1)
        #expect(vorgaenge.first?.id == bereitsKaputt.id)
    }

    /// Regressionstest für dieselbe Live-Test-Session: die neu eingeführte
    /// Plausibilitätsprüfung verwirft eine `endZeit`, die vor dem eigenen
    /// `startZeit` läge — genau das durch den obigen Bug beobachtete Muster
    /// (ein neu angelegter Vorgang übernahm die `endZeit` eines völlig
    /// anderen, längst abgeschlossenen Vorgangs).
    @Test
    func unplausibleEndZeitVorDemStartZeitWirdVerworfen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        try context.save()

        let start = Date()
        let unplausibleEndZeit = start.addingTimeInterval(-3600)
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Urlaub", erstelltAm: liste.erstelltAm)]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: UUID(), geschaeftID: nil, einkaufslisteID: liste.id, startZeit: start, endZeit: unplausibleEndZeit),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 1)
        #expect(vorgaenge.first?.endZeit == nil)
    }

    /// Regressionstest (Code-Review-Fund): dieselbe „dangling Einkaufsvorgang"-
    /// Ursachen-Familie wie die Bereich-A-Umleitung in `SyncImportService`,
    /// hier für den Bereich-C-Snapshot-Merge. Ein Snapshot referenziert per ID
    /// exakt den Vorgang, den dieses Gerät zwischenzeitlich per „Einkauf
    /// abschließen" geschlossen hat (der Peer kennt dessen `endZeit` beim
    /// Export noch nicht) — der zugehörige `KaufEintrag` muss auf den offenen
    /// Nachfolger für dieselbe Liste umgeleitet werden, nicht auf dem
    /// geschlossenen (für die Einkaufsansicht unsichtbaren) landen.
    @Test
    func bereitsAbgeschlossenerBekannterVorgangWirdBeiSnapshotMergeAufOffenenNachfolgerUmgeleitet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(alterVorgang)
        alterVorgang.abschliessen()
        let neuerVorgang = Einkaufsvorgang(geschaeft: nil, einkaufsliste: liste)
        context.insert(neuerVorgang)
        try context.save()

        // Peer kennt denselben (per ID identischen) Vorgang noch als offen
        // und berichtet einen KaufEintrag dafür.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: alterVorgang.id, geschaeftID: nil, einkaufslisteID: nil, startZeit: alterVorgang.startZeit, endZeit: nil),
        ]
        snapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: UUID(), artikelID: apfel.id, einkaufsvorgangID: alterVorgang.id, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "Rewe",
                datum: Date(), menge: 1, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(alterVorgang.kaufEintraege.isEmpty)
        #expect(neuerVorgang.kaufEintraege.contains { $0.artikel == apfel })
        // Der bereits gesetzte Abschluss darf durch den (aus Sicht des Peers
        // noch offenen) Remote-Stand NICHT verlorengehen.
        #expect(alterVorgang.endZeit != nil)
    }

    @Test
    func neuerEinkaufsvorgangVomPeerErhoehtNichtZusaetzlichDenZaehler() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        try context.save()

        let remoteGeschaeftID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteGeschaeftID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 1, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: UUID(), geschaeftID: remoteGeschaeftID, einkaufslisteID: nil, startZeit: Date(), endZeit: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Nur die additive Zähler-Merge-Regel (aus dem Geschaeft-Snapshot) darf
        // den Zähler erhöhen, nicht zusätzlich das Anlegen des Einkaufsvorgangs.
        #expect(geschaeft.anzahlEinkaufsvorgaenge == 1)
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)
    }

    @Test
    func kaufEintragWirdAlsUnveraenderlicheHistorieUebernommenOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        // Ein realer Export enthält jeden referenzierten Artikel immer auch in
        // Bereich B (SyncSnapshotExportService exportiert alle lokalen Artikel
        // unbedingt) — für den Test hier explizit nachgebildet, damit
        // artikelZuordnung den Verweis auflösen kann.
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let kaufEintragID = UUID()
        snapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: kaufEintragID, artikelID: apfel.id, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "",
                datum: Date(), menge: 3, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let alleEintraege = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(alleEintraege.count == 1)
        #expect(alleEintraege.first?.id == kaufEintragID)
        #expect(alleEintraege.first?.artikel?.id == apfel.id)
    }

    /// Wie ``kaufEintragWirdAlsUnveraenderlicheHistorieUebernommenOhneDuplikat``,
    /// für ``Preispunkt`` (GitHub #76) — derselbe Union-nach-`id`-Merge.
    @Test
    func preispunktWirdAlsUnveraenderlicheHistorieUebernommenOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let preispunktID = UUID()
        snapshot.preispunkte = [
            PreispunktSnapshot(
                id: preispunktID, artikelID: apfel.id, geschaeftID: nil, preis: 1.49, datum: Date(),
                produktName: nil, alternativerName: nil, artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: ""
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let allePunkte = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(allePunkte.count == 1)
        #expect(allePunkte.first?.id == preispunktID)
        #expect(allePunkte.first?.artikel?.id == apfel.id)
        #expect(allePunkte.first?.preis == 1.49)
    }

    /// Ein per Snapshot gemergter (also per Konstruktion von einem ANDEREN
    /// Gerät stammender) ``KaufEintrag`` darf seinen `kategorieBesuchsIndex`
    /// NICHT aus dem Snapshot übernehmen — sonst würde ein später auf diesem
    /// Gerät abgeschlossener, mit dem fremden Vorgang zusammengeführter
    /// Einkauf (``mergeEinkaufsvorgaenge``) die Laufreihenfolge des anderen
    /// Geräts in die eigene ``WarengruppenDistanzService``-Analyse mischen
    /// (siehe Typ-Doku ``mergeKaufEintraege``).
    @Test
    func gemergterKaufEintragBekommtKeinenBesuchsindexAusDemSnapshot() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: UUID(), artikelID: apfel.id, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "",
                datum: Date(), menge: 1, kategorieBesuchsIndex: 3
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let eintrag = try #require(try context.fetch(FetchDescriptor<KaufEintrag>()).first)
        #expect(eintrag.kategorieBesuchsIndex == nil)
    }

    /// Regressionstest für einen Analyse-Fund (export.json wuchs trotz aktiver
    /// `KaufEintragBereinigungService`-Läufe, weil verwaiste `KaufEintrag`e —
    /// `einkaufsvorgang == nil` — von deren Filter nie erfasst wurden, siehe
    /// dortige Typ-Doku). Referenziert ein Remote-`KaufEintrag` einen
    /// `Einkaufsvorgang`, der hier nicht auflösbar ist (z.B. bereits gelöscht/
    /// tombstoned), darf `mergeKaufEintraege` ihn NICHT trotzdem mit
    /// `einkaufsvorgang == nil` anlegen (bisheriges Verhalten), sondern muss ihn
    /// wie seinen Vorgang überspringen.
    @Test
    func kaufEintragMitUnaufloesbaremEinkaufsvorgangWirdNichtVerwaistAngelegt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        // Bewusst KEIN passender Eintrag in `snapshot.einkaufsvorgaenge` — simuliert
        // einen `Einkaufsvorgang`, der auf diesem Gerät nicht auflösbar ist (z.B.
        // bereits per Tombstone gelöscht), während der Absender ihn selbst noch
        // führt und seine `KaufEintrag`e weiterhin referenziert.
        snapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: UUID(), artikelID: apfel.id, einkaufsvorgangID: UUID(), geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "",
                datum: Date(), menge: 1, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
    }

    @Test
    func warengruppenDistanzWirdGemitteltBeiVorhandenemEintragSonstUebernommen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let kategorieA = ArtikelKategorie(name: "Obst", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF")
        context.insert(kategorieA)
        context.insert(kategorieB)
        // Wie im echten Code (WarengruppenDistanzService) immer über
        // kanonischesPaar konstruieren, sonst kann die spätere Zuordnung im
        // Merge (der ebenfalls kanonisiert) nicht zuverlässig matchen.
        let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(kategorieA, kategorieB)
        let bestehendeDistanz = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kanonA, kategorieB: kanonB, distanz: 0.2)
        context.insert(bestehendeDistanz)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaeftsTypen = [GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart.fill", farbeHex: "#8E8E93", sortIndex: 0)]
        snapshot.artikelKategorien = [
            ArtikelKategorieSnapshot(id: kategorieA.id, name: "Obst", standardSymbol: "carrot", standardFarbeHex: "#34C759", sortIndex: 0, geschaeftsTypIDs: []),
            ArtikelKategorieSnapshot(id: kategorieB.id, name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF", sortIndex: 1, geschaeftsTypIDs: []),
        ]
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: geschaeft.id, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        snapshot.warengruppenDistanzen = [
            WarengruppenDistanzSnapshot(id: UUID(), geschaeftID: geschaeft.id, kategorieAID: kategorieA.id, kategorieBID: kategorieB.id, distanz: 0.8),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleDistanzen = try context.fetch(FetchDescriptor<WarengruppenDistanz>())
        #expect(alleDistanzen.count == 1)
        #expect(alleDistanzen.first?.distanz == 0.5) // (0.2 + 0.8) / 2
    }

    /// GitHub #48: Der Gerätename aus dem Snapshot muss für die spätere
    /// Auflösung von `SyncEvent.autorGeraeteID` (Überkauf-Hinweis) gemerkt
    /// werden — und bei einem erneuten Sync aktualisiert werden können.
    @Test
    func geraeteNameWirdAusSnapshotGemerktUndAktualisiert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        try schreibeFremdenSnapshot(leererSnapshot(geraeteID: "fremdes-geraet", geraeteName: "Annas iPhone"), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(SyncPeerInfo.geraeteName(fuer: "fremdes-geraet", context: context) == "Annas iPhone")

        try schreibeFremdenSnapshot(leererSnapshot(geraeteID: "fremdes-geraet", geraeteName: "Annas neues iPhone"), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(SyncPeerInfo.geraeteName(fuer: "fremdes-geraet", context: context) == "Annas neues iPhone")
        #expect(try context.fetch(FetchDescriptor<SyncPeerInfo>()).count == 1)
    }

    /// Regressionstest für GitHub #82 (Analyse-Fund: O(n·m)-Merge-Scan) —
    /// `mergeKaufEintraege` fetchte bisher bei jedem Zyklus ALLE lokalen
    /// Einträge und verglich linear gegen jeden Remote-Eintrag. Dieser Test
    /// prüft nur das beobachtbare Verhalten (bereits bekannte Einträge bleiben
    /// unverändert, nur der genuin neue wird übernommen) — der eigentliche
    /// Umbau auf einen indexierten Existenz-Check (``kaufEintragExistiertLokal(id:context:)``)
    /// ist implementierungsintern nicht per Black-Box-Test nachweisbar.
    @Test
    func kaufEintragMergeUebersprintBereitsBekannteEintraege() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        var bekannteIDs: [UUID] = []
        for _ in 0..<20 {
            let eintrag = KaufEintrag(artikel: apfel, geschaeft: geschaeft)
            context.insert(eintrag)
            bekannteIDs.append(eintrag.id)
        }
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let neueID = UUID()
        snapshot.kaufEintraege = (bekannteIDs.map {
            KaufEintragSnapshot(
                id: $0, artikelID: apfel.id, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel (fremd, darf nicht übernommen werden)", geschaeftNameSnapshot: "",
                datum: Date(), menge: 1, kategorieBesuchsIndex: nil
            )
        }) + [
            KaufEintragSnapshot(
                id: neueID, artikelID: apfel.id, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "",
                datum: Date(), menge: 1, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alle = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(alle.count == 21)
        #expect(alle.filter { bekannteIDs.contains($0.id) }.allSatisfy { $0.artikelNameSnapshot != "Apfel (fremd, darf nicht übernommen werden)" })
        #expect(alle.contains { $0.id == neueID })
    }

    /// Wie ``kaufEintragMergeUebersprintBereitsBekannteEintraege``, für
    /// ``mergePreispunkte``.
    @Test
    func preispunktMergeUebersprintBereitsBekannteEintraege() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        var bekannteIDs: [UUID] = []
        for _ in 0..<20 {
            let punkt = Preispunkt(artikel: apfel, geschaeft: nil, preis: 1.49)
            context.insert(punkt)
            bekannteIDs.append(punkt.id)
        }
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        let neueID = UUID()
        snapshot.preispunkte = (bekannteIDs.map {
            PreispunktSnapshot(
                id: $0, artikelID: apfel.id, geschaeftID: nil, preis: 9.99, datum: Date(),
                produktName: nil, alternativerName: nil, artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: ""
            )
        }) + [
            PreispunktSnapshot(
                id: neueID, artikelID: apfel.id, geschaeftID: nil, preis: 1.49, datum: Date(),
                produktName: nil, alternativerName: nil, artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: ""
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alle = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(alle.count == 21)
        #expect(alle.filter { bekannteIDs.contains($0.id) }.allSatisfy { $0.preis == 1.49 })
        #expect(alle.contains { $0.id == neueID })
    }

    /// Vorher ungetestet — GitHub #82 macht dies zum ersten Mal ein
    /// Mehrdatei-/Mehrverzeichnis-Löschvorgang statt eines Einzeldatei-Löschens.
    /// Prüft, dass bei einem über ``SyncSnapshotImportService/maximalesSnapshotAlter``
    /// hinaus veralteten Peer ALLE Paket-Dateien (`manifest.json`,
    /// `tombstones.json`, `stamm.json`, `lernen.json`, `vorgaenge.json`,
    /// `preise.json`) sowie der komplette `kaeufe/`-Ordner entfernt werden —
    /// und dass ein `events/`-Ordner (Bereich A) davon unberührt bleibt, wie
    /// von der Typ-Doku versprochen.
    @Test
    func raeumeVerwaisteFremdeExportsAufLoeschtAllePaketDateien() async throws {
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let vorherigeAltersgrenze = SyncSnapshotImportService.maximalesSnapshotAlter
        SyncSnapshotImportService.maximalesSnapshotAlter = 60
        defer { SyncSnapshotImportService.maximalesSnapshotAlter = vorherigeAltersgrenze }

        var snapshot = leererSnapshot(geraeteID: "altes-geraet")
        snapshot.erzeugtAm = Date().addingTimeInterval(-120)
        snapshot.kaufEintraege = [
            KaufEintragSnapshot(
                id: UUID(), artikelID: nil, einkaufsvorgangID: nil, geschaeftID: nil, kategorieID: nil,
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "", datum: Date(), menge: 1, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "altes-geraet", in: syncOrdner)

        // Bereich-A-Eventordner desselben (fremden) Peers — darf nicht
        // angetastet werden.
        let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: "altes-geraet", in: syncOrdner)
        try FileManager.default.createDirectory(at: eventsOrdner, withIntermediateDirectories: true)
        let eventDatei = eventsOrdner.appendingPathComponent("0000000001_\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: eventDatei)

        await SyncSnapshotImportService.raeumeVerwaisteFremdeExportsAuf()

        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.manifestURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.tombstonesURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.stammURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.lernenURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.vorgaengeURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.preiseURL(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(!FileManager.default.fileExists(atPath: SyncSnapshotExportService.kaeufeOrdner(fuerPeer: "altes-geraet", in: syncOrdner).path))
        #expect(FileManager.default.fileExists(atPath: eventDatei.path))
    }
}
