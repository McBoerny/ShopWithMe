import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncSnapshotImportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self, WarengruppenDistanzPeerZaehlerStand.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerZaehlerStand.self, SyncPeerInfo.self,
            SyncTombstone.self, Preispunkt.self, ArtikelAlias.self, SyncAbgleichKandidat.self,
            ArtikelGeschaeftVerfuegbarkeit.self, GeschaeftBesuch.self, ArtikelListenKauf.self,
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
            artikelAliase: snapshot.artikelAliase
        )
        let listen = SyncListenSnapshot(einkaufslistenEintraege: snapshot.einkaufslistenEintraege)
        let lernen = SyncLernenSnapshot(
            warengruppenDistanzen: snapshot.warengruppenDistanzen,
            artikelGeschaeftVerfuegbarkeiten: snapshot.artikelGeschaeftVerfuegbarkeiten,
            geschaeftBesuche: snapshot.geschaeftBesuche,
            artikelListenKaeufe: snapshot.artikelListenKaeufe
        )
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

    // MARK: - Peer-Lebenszyklus, Baustein C: aktuellerAufraeumWasserstand

    @Test
    func aktuellerAufraeumWasserstandBildetMinimumMehrererPeers() async throws {
        let syncOrdner = macheTempSyncOrdner()

        var aelterer = leererSnapshot(geraeteID: "peer-a")
        aelterer.erzeugtAm = Date().addingTimeInterval(-120)
        try schreibeFremdenSnapshot(aelterer, fremdeGeraeteID: "peer-a", in: syncOrdner)

        var neuerer = leererSnapshot(geraeteID: "peer-b")
        neuerer.erzeugtAm = Date().addingTimeInterval(-30)
        try schreibeFremdenSnapshot(neuerer, fremdeGeraeteID: "peer-b", in: syncOrdner)

        let wasserstand = await SyncSnapshotImportService.aktuellerAufraeumWasserstand(in: syncOrdner)
        let erwartet = aelterer.erzeugtAm
        #expect(wasserstand.map { abs($0.timeIntervalSince(erwartet)) < 1 } == true)
    }

    /// Kein anderer Peer bekannt -> keine Grundlage, um sicher aufzuräumen.
    @Test
    func aktuellerAufraeumWasserstandLiefertNilOhneAnderenPeer() async throws {
        let syncOrdner = macheTempSyncOrdner()
        try FileManager.default.createDirectory(
            at: syncOrdner.appendingPathComponent("peers", isDirectory: true), withIntermediateDirectories: true
        )

        let wasserstand = await SyncSnapshotImportService.aktuellerAufraeumWasserstand(in: syncOrdner)
        #expect(wasserstand == nil)
    }

    /// Ein aktuell vorhandener Peer-Ordner ohne lesbares Manifest darf den
    /// Wasserstand NICHT einfach überspringen — sonst könnte er an genau dem
    /// Peer vorbei fortschreiten, der ihn eigentlich zurückhalten müsste.
    @Test
    func aktuellerAufraeumWasserstandLiefertNilBeiUnlesbaremPeerManifest() async throws {
        let syncOrdner = macheTempSyncOrdner()

        try schreibeFremdenSnapshot(leererSnapshot(geraeteID: "peer-a"), fremdeGeraeteID: "peer-a", in: syncOrdner)

        let kaputterOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent("peer-b", isDirectory: true)
        try FileManager.default.createDirectory(at: kaputterOrdner, withIntermediateDirectories: true)

        let wasserstand = await SyncSnapshotImportService.aktuellerAufraeumWasserstand(in: syncOrdner)
        #expect(wasserstand == nil)
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

    /// Ergänzende Abdeckung zum Stale-Lookup-Nachfolgefund unten (Session
    /// 2026-08-04): ``mergeGeschaeftsTypen`` delegiert an ``GeschaeftTyp/mitNamen(_:symbolName:context:)``,
    /// das bei jedem Aufruf frisch aus dem `ModelContext` fetcht statt eine
    /// Momentaufnahme vor der Schleife zwischenzuspeichern — von der
    /// Bug-Klasse der anderen Merge-Funktionen (siehe unten) strukturell
    /// nicht betroffen, hier trotzdem als Regressionsschutz mitgetestet.
    @Test
    func geschaeftstypMitGleichemNamenImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaeftsTypen = [
            GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart", farbeHex: "#FF0000", sortIndex: 0),
            GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart", farbeHex: "#FF0000", sortIndex: 1),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<GeschaeftTyp>()).count == 1)
    }

    /// GitHub #86: automatischer Merge verlangt EXAKTEN Namen (case-insensitive)
    /// UND Distanz innerhalb der strengeren der beiden individuellen Radien —
    /// bewusst kein Teilstring-Namensvergleich mehr (siehe
    /// ``geschaeftMitAehnlichemNamenAberNaheKoordinatenWirdNichtGemergt`` für
    /// den davon abgegrenzten Negativfall).
    @Test
    func geschaeftWirdPerNameUndKoordinateGematchtUndKategorienVereinigt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let eigeneKategorie = ArtikelKategorie(name: "Obst", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        context.insert(eigeneKategorie)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
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
                // Groß-/Kleinschreibung darf abweichen (localizedCaseInsensitiveCompare),
                // der Name selbst muss aber exakt übereinstimmen — anders als vorher
                // reicht ein reiner Koordinatentreffer mit abweichendem Namen nicht mehr.
                id: UUID(), name: "REWE", typIDs: [], adresse: nil,
                breitengrad: 52.5201, laengengrad: 13.4051, erkennungsradius: 120,
                kategorieIDs: [remoteKategorieID], ausgeschlosseneKategorieIDs: [], alternativeNamen: ["Rewe Center"],
                ignorierteArtikelNamen: ["Pfand"], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleGeschaefte = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(alleGeschaefte.count == 1)
        #expect(lokal.name == "Rewe") // Name bleibt lokal, nicht überschrieben.
        #expect(lokal.erkennungsradiusRaw == 120) // War lokal nil -> von Remote übernommen.
        #expect(lokal.kategorien.map(\.name).sorted() == ["Milchprodukte", "Obst"])
        #expect(lokal.alternativeNamen.contains("Rewe Center"))
        #expect(lokal.ignorierteArtikel.map(\.erkannterName) == ["Pfand"])
    }

    /// Stale-Lookup-Nachfolgefund (Session 2026-08-04): ``mergeArtikelKategorien``
    /// fetchte den lokalen Bestand einmalig vor der Merge-Schleife und führte
    /// ihn nie nach — ein zweiter gleichnamiger Remote-Eintrag im selben Batch
    /// fand den gerade erst angelegten ersten nicht und legte eine Dublette an.
    @Test
    func artikelKategorieMitGleichemNamenImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikelKategorien = [
            ArtikelKategorieSnapshot(
                id: UUID(), name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF", sortIndex: 0, geschaeftsTypIDs: []
            ),
            ArtikelKategorieSnapshot(
                id: UUID(), name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF", sortIndex: 1, geschaeftsTypIDs: []
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<ArtikelKategorie>()).count == 1)
    }

    /// Stale-Lookup-Nachfolgefund (Session 2026-08-04): derselbe Bug wie bei
    /// ``mergeArtikelKategorien`` — zwei gleichnamige, koordinatengleiche
    /// Remote-Geschäfte im selben Batch erzeugten vor dem Fix zwei lokale
    /// Dubletten statt eines Namens-/Koordinaten-Treffers.
    @Test
    func geschaeftMitGleichemNamenUndKoordinateImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        func macheGeschaeftSnapshot() -> GeschaeftSnapshot {
            GeschaeftSnapshot(
                id: UUID(), name: "Aldi", typIDs: [], adresse: nil,
                breitengrad: 52.5, laengengrad: 13.4, erkennungsradius: 100,
                kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            )
        }
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [macheGeschaeftSnapshot(), macheGeschaeftSnapshot()]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 1)
    }

    /// GitHub #86 (Kernfund): Zwei unterschiedlich benannte Geschäfte in
    /// unmittelbarer Nähe (z.B. Bäckerei/Blumenladen in einem Einkaufszentrum)
    /// dürfen beim automatischen Sync-Merge NIEMALS zusammengeführt werden,
    /// selbst wenn ein Name im anderen enthalten ist ("Rewe" ⊂ "Rewe Nord") —
    /// vor dem Fix hätte der reine Koordinatenvergleich/Teilstring-Vergleich
    /// sie fälschlich vereint. **Aktualisiert** (Ambiguitäts-Rückstellung):
    /// dieselbe Konstellation trifft jetzt zusätzlich
    /// `istMehrdeutigerBeitrittsKandidat` (großzügiger Treffer, aber nicht
    /// streng genug) — statt wie vorher sofort eine zweite, unabhängige
    /// Dublette anzulegen, bleibt der Remote-Eintrag als
    /// ``SyncAbgleichKandidat`` zurückgestellt. Die eigentliche Garantie
    /// bleibt unverändert bestehen: kein automatisches, stilles
    /// Zusammenführen — nur der „nicht gemergt"-Zweig sieht jetzt anders aus
    /// (zurückgestellt statt sofort dupliziert).
    @Test
    func geschaeftMitAehnlichemNamenAberNaheKoordinatenWirdNichtGemergt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let lokal = Geschaeft(name: "Rewe", typen: [])
        lokal.breitengrad = 52.5200
        lokal.laengengrad = 13.4050
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteID, name: "Rewe Nord", typIDs: [], adresse: nil,
                breitengrad: 52.5201, laengengrad: 13.4051, erkennungsradius: nil,
                kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Kein automatisches, stilles Zusammenführen: weiterhin nur das
        // ursprüngliche lokale "Rewe" — "Rewe Nord" bleibt zurückgestellt.
        let alleGeschaefte = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(alleGeschaefte.count == 1)
        #expect(alleGeschaefte.first?.name == "Rewe")
        let kandidaten = try context.fetch(FetchDescriptor<SyncAbgleichKandidat>())
        #expect(kandidaten.count == 1)
        #expect(kandidaten.first?.fremdeID == remoteID)
        #expect(kandidaten.first?.fremderName == "Rewe Nord")
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
        // Koordinaten auf beiden Seiten setzen (GitHub #86: automatischer
        // Merge verlangt seither exakten Namen UND Distanz-Treffer, kein
        // reiner Namensvergleich mehr) — ohne sie würde nie gematcht, und
        // dieser Test würde statt des Zähler-Merges den (separat abgedeckten)
        // Neuanlage-Fall prüfen.
        lokal.breitengrad = 52.5200
        lokal.laengengrad = 13.4050
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        func snapshotMitEigenemBeitrag(_ wert: Int) -> SyncSnapshot {
            var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
            snapshot.geschaefte = [
                GeschaeftSnapshot(
                    id: remoteID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: 52.5201, laengengrad: 13.4051,
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
        // Koordinaten auf beiden Seiten setzen (GitHub #86, siehe Kommentar
        // im vorherigen Test) — sonst matcht der automatische Merge nie.
        geschaeftA.breitengrad = 52.5200
        geschaeftA.laengengrad = 13.4050
        contextA.insert(geschaeftA)
        try contextA.save()

        let typB = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        contextB.insert(typB)
        let geschaeftB = Geschaeft(name: "Rewe", typen: [typB]) // Per Name gematcht, kein echter Einkauf auf B.
        geschaeftB.breitengrad = 52.5201
        geschaeftB.laengengrad = 13.4051
        contextB.insert(geschaeftB)
        try contextB.save()

        func exportiere(_ context: ModelContext, nach ordner: URL) throws {
            let teile = SyncSnapshotExportService.erstellePaketTeile(context: context)
            let manifestURL = SyncSnapshotExportService.manifestURL(fuerPeer: "peer", in: ordner)
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(teile.manifest).write(to: manifestURL)
            try JSONEncoder().encode(teile.tombstones).write(to: SyncSnapshotExportService.tombstonesURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.stamm).write(to: SyncSnapshotExportService.stammURL(fuerPeer: "peer", in: ordner))
            try JSONEncoder().encode(teile.listen).write(to: SyncSnapshotExportService.listenURL(fuerPeer: "peer", in: ordner))
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

    /// Root-Cause-Fund (Session 2026-08-04, Live-Bericht "Brot doppelt auf
    /// Urlaub-Liste"): ``mergeArtikel`` fetchte den lokalen Bestand einmalig
    /// vor der Merge-Schleife und führte ihn nie nach. Enthielt ein einzelner
    /// Sync-Batch mehrere gleichnamige Fremdeinträge (z.B. mehrfach schnell
    /// hintereinander hinzugefügtes "Brot"), fand der zweite Eintrag den
    /// gerade erst vom ersten angelegten lokalen Artikel nicht — pro
    /// zusätzlichem Eintrag entstand ein weiterer lokaler Artikel statt eines
    /// Alias auf den ersten.
    @Test
    func artikelMitGleichemNamenImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        func macheArtikelSnapshot() -> ArtikelSnapshot {
            ArtikelSnapshot(
                id: UUID(), name: "Brot", symbolName: "birthday.cake", farbeHex: "#8E5B3A",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            )
        }
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [macheArtikelSnapshot(), macheArtikelSnapshot(), macheArtikelSnapshot()]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Artikel>()).count == 1)
    }

    /// Stale-Lookup-Nachfolgefund (Session 2026-08-04): derselbe Bug wie bei
    /// ``mergeArtikel`` — zwei Remote-Aliase mit demselben `erkannterName` im
    /// selben Batch erzeugten vor dem Fix zwei lokale Dubletten statt dass
    /// der zweite als bereits bekannt übersprungen wurde.
    @Test
    func artikelAliasMitGleichemErkanntenNamenImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikelAliase = [
            ArtikelAliasSnapshot(id: UUID(), erkannterName: "Vollmilch 3.5%", alternativerName: "Milch", artikelID: nil),
            ArtikelAliasSnapshot(id: UUID(), erkannterName: "Vollmilch 3.5%", alternativerName: "Milch", artikelID: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<ArtikelAlias>()).count == 1)
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

    /// Stale-Lookup-Nachfolgefund (Session 2026-08-04): derselbe Bug wie bei
    /// ``mergeArtikel`` — zwei gleichnamige Remote-Listen im selben Batch
    /// erzeugten vor dem Fix zwei lokale Dubletten statt eines Namens-Treffers.
    @Test
    func einkaufslisteMitGleichemNamenImSelbenBatchWirdNichtDupliziert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [
            EinkaufslisteSnapshot(id: UUID(), name: "Urlaub", erstelltAm: Date()),
            EinkaufslisteSnapshot(id: UUID(), name: "Urlaub", erstelltAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 1)
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

    /// Erweiterung von ``zweiUnabhaengigOffeneEinkaufsvorgaengeFuerDenselbenLadenWerdenZusammengefuehrt()``
    /// um einen zweiten Sync-Zyklus: nachdem zwei unabhängig entstandene
    /// Einkaufsvorgänge einmal per `offenerTreffer` zusammengeführt und
    /// aliasiert wurden, muss ein SPÄTERER Zyklus, in dem der Peer seinen
    /// Vorgang abschließt (`endZeit` gesetzt), diese `endZeit` über den
    /// bereits registrierten Alias auf den lokalen Vorgang übertragen.
    /// Regressionstest für einen Nutzerbericht (2026-08-02): "Abhaken
    /// synchronisiert, Einkauf abschließen nicht" — die bestehenden Tests
    /// deckten bislang nur den ID-gleichen Fall
    /// (``bereitsAbgeschlossenerBekannterVorgangWirdBeiSnapshotMergeAufOffenenNachfolgerUmgeleitet()``
    /// u.a.) ab, nicht den in der Praxis häufigeren Fall zweier unabhängig
    /// entstandener, erst per Alias verknüpfter Vorgänge.
    @Test
    func abschlussEinesUeberOffenenTrefferAliasiertenVorgangsWirdBeimZweitenZyklusUebernommen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Gerät legt selbst einen offenen Einkaufsvorgang an, bevor je
        // synchronisiert wurde — ohne Geschäft (Einkauf ohne gewählten Laden
        // ist der Normalfall).
        let eigenerVorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(eigenerVorgang)
        try context.save()

        // Peer hat für DIESELBE Liste unabhängig einen eigenen, noch offenen
        // Einkaufsvorgang mit ANDERER ID.
        let remoteVorgangID = UUID()
        var ersterSnapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        ersterSnapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        ersterSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: eigenerVorgang.startZeit, endZeit: nil),
        ]
        try schreibeFremdenSnapshot(ersterSnapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Vorbedingung wie im Nachbartest: keine Dublette, Alias registriert,
        // noch kein Abschluss.
        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)
        #expect(eigenerVorgang.endZeit == nil)

        // Peer schließt SEINEN Einkauf ab und synchronisiert erneut —
        // dieselbe remoteVorgangID, jetzt mit endZeit.
        let abschlusszeit = Date()
        var zweiterSnapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        zweiterSnapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        zweiterSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: eigenerVorgang.startZeit, endZeit: abschlusszeit),
        ]
        try schreibeFremdenSnapshot(zweiterSnapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)
        #expect(eigenerVorgang.endZeit == abschlusszeit)
    }

    /// Regressionstest (Nutzerbericht 2026-08-06, Peer-Beitritt/-Rückkehr):
    /// ein lokal offener Vorgang mit bereits eigenen `KaufEintrag`en (kein
    /// frischer, leerer Race-Kandidat wie im Nachbartest oben, sondern ein
    /// alter, vor einem (Wieder-)Beitritt vergessener Rest) darf NICHT per
    /// `offenerTreffer` mit einem tatsächlich aktiven Vorgang eines Peers
    /// zusammengeführt werden — sonst blieben seine eigenen, u.U. längst
    /// veralteten Käufe zusätzlich in der listenweiten "abgehakt"-Ansicht des
    /// zusammengeführten Vorgangs hängen (`docs/DATENSYNCHRONISATION.md`
    /// §4.3). ``EinkaufsvorgangAbschlussService/schliesseAlleOffenenEinkaufsvorgaenge(context:)``
    /// verhindert das bereits beim eigentlichen Beitrittsmoment — dieser
    /// Test deckt die zusätzliche, unabhängige Absicherung im Merge selbst ab.
    @Test
    func offenerVorgangMitEigenenKaufEintraegenWirdNichtAlsOffenerTrefferGematcht() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Gerät hat einen ALTEN, offenen Einkaufsvorgang mit bereits eigenen
        // Käufen — z.B. aus der Zeit vor einem Wieder-Beitritt zur Sync-Gruppe.
        let alterVorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(alterVorgang)
        let alterKauf = KaufEintrag(artikel: nil, geschaeft: nil, datum: Date())
        context.insert(alterKauf)
        alterKauf.einkaufsvorgang = alterVorgang
        try context.save()

        // Peer hat für DIESELBE Liste unabhängig einen eigenen, tatsächlich
        // aktiven, noch offenen Einkaufsvorgang.
        let remoteVorgangID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: Date(), endZeit: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Zwei getrennte offene Vorgänge statt einer Vermischung — der alte
        // behält seinen eigenen Kaufeintrag, der neu angelegte hat keinen.
        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 2)
        #expect(alterVorgang.kaufEintraege.count == 1)
        let neuerVorgang = vorgaenge.first { $0.persistentModelID != alterVorgang.persistentModelID }
        #expect(neuerVorgang?.kaufEintraege.isEmpty == true)
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

    /// Regressionstest für einen echten Zwei-Geräte-Nutzerbericht (2026-08-09,
    /// frischer Beitritt/„Ersetzen durch Peer"): ein frisch angelegter, noch
    /// völlig leerer lokaler Platzhalter-Vorgang (z.B. durch
    /// `EinkaufenView.einkaufSicherstellen()`, sobald die Einkaufsliste nach
    /// dem Neuaufbau sichtbar wird) darf NICHT mit MEHREREN bereits
    /// abgeschlossenen Vorgängen eines Peers für dieselbe Liste
    /// zusammengeführt werden — jeder abgeschlossene Peer-Vorgang ist ein
    /// eigenständiger, historischer Einkauf, kein Kandidat für das
    /// `offenerTreffer`-Race (das nur zwei noch offene, unabhängig
    /// angelegte Vorgänge meint). Vor dem Fix aliasierte der Zweig alle drei
    /// fremden Vorgänge auf denselben lokalen Platzhalter; dessen `startZeit`
    /// ("gerade eben" angelegt) lag danach nach jeder echten `endZeit`, die
    /// defensive Plausibilitätsprüfung verwarf deshalb jeden Abschluss, der
    /// Platzhalter blieb dauerhaft offen — und alle per `mergeKaufEintraege`
    /// daran hängenden, längst abgehakten Artikel dreier vergangener Einkäufe
    /// erschienen fälschlich als aktuell abgehakt.
    @Test
    func mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Frischer, leerer lokaler Platzhalter — wie ihn `einkaufSicherstellen()`
        // anlegt, sobald die (gerade erst importierte) Liste sichtbar wird.
        let platzhalter = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(platzhalter)
        try context.save()

        // Peer hat DREI unabhängige, jeweils bereits abgeschlossene Einkäufe
        // ohne Geschäft für dieselbe Liste — alle vor dem lokalen Platzhalter.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        let jetzt = Date()
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(
                id: UUID(), geschaeftID: nil, einkaufslisteID: liste.id,
                startZeit: jetzt.addingTimeInterval(-7200), endZeit: jetzt.addingTimeInterval(-7000)
            ),
            EinkaufsvorgangSnapshot(
                id: UUID(), geschaeftID: nil, einkaufslisteID: liste.id,
                startZeit: jetzt.addingTimeInterval(-3600), endZeit: jetzt.addingTimeInterval(-3500)
            ),
            EinkaufsvorgangSnapshot(
                id: UUID(), geschaeftID: nil, einkaufslisteID: liste.id,
                startZeit: jetzt.addingTimeInterval(-1800), endZeit: jetzt.addingTimeInterval(-1700)
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Vier lokale Vorgänge: der unberührte Platzhalter plus je ein
        // eigenständiger, korrekt abgeschlossener Vorgang pro Peer-Einkauf —
        // NICHT alle drei fälschlich auf den Platzhalter zusammengeführt.
        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 4)
        #expect(platzhalter.endZeit == nil)
        #expect(platzhalter.kaufEintraege.isEmpty)
        let abgeschlossene = vorgaenge.filter { $0.persistentModelID != platzhalter.persistentModelID }
        #expect(abgeschlossene.count == 3)
        #expect(abgeschlossene.allSatisfy { $0.endZeit != nil })
    }

    /// Regressionstest für einen echten Zwei-Geräte-Nutzerbericht (2026-08-10,
    /// gemeinsames Live-Einkaufen): Gerät B hat einen eigenen, noch offenen
    /// Platzhalter-Vorgang für dieselbe Liste (z.B. weil sein vorheriger
    /// gerade erst abgeschlossen wurde und `einkaufSicherstellen()` sofort
    /// einen neuen anlegte). Gerät A schließt SEINEN Einkauf für dieselbe
    /// Liste ab, BEVOR Gerät B je einen Sync-Zyklus hatte, der beide noch
    /// offen sah — der erste Snapshot, den Gerät B von Gerät A empfängt,
    /// zeigt den Vorgang deshalb bereits als abgeschlossen. Das muss trotzdem
    /// per `offenerTreffer` auf Gerät Bs Platzhalter matchen (plausibel
    /// dieselbe, gerade noch laufende Sitzung — Gerät As `endZeit` liegt NACH
    /// Gerät Bs `startZeit`), nicht wie ein längst vergangener,
    /// eigenständiger historischer Einkauf behandelt werden (das deckt bereits
    /// ``mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert()``
    /// ab, dort liegt die `endZeit` klar VOR dem `startZeit` des Platzhalters).
    @Test
    func bereitsAbgeschlossenerVorgangDerselbenSitzungMatchtNochOffenenLokalenPlatzhalter() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Gerät B: eigener, noch offener Platzhalter — bereits einige Zeit
        // aktiv (nicht "gerade eben" angelegt), genau wie beim gemeinsamen
        // Einkaufen üblich.
        let platzhalter = Einkaufsvorgang(einkaufsliste: liste, startZeit: Date().addingTimeInterval(-300))
        context.insert(platzhalter)
        try context.save()

        // Gerät A hat denselben Einkauf (dieselbe Liste, kein Geschäft)
        // bereits abgeschlossen — NACH dem startZeit von Gerät Bs Platzhalter.
        var snapshot = leererSnapshot(geraeteID: "geraet-a")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        let abschlusszeit = Date()
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(
                id: UUID(), geschaeftID: nil, einkaufslisteID: liste.id,
                startZeit: Date().addingTimeInterval(-250), endZeit: abschlusszeit
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "geraet-a", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Nur EIN lokaler Vorgang — Gerät As Abschluss wurde auf Gerät Bs
        // Platzhalter übertragen, kein zweiter, eigenständig offen bleibender
        // Vorgang für dieselbe Liste.
        let vorgaenge = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(vorgaenge.count == 1)
        #expect(platzhalter.endZeit == abschlusszeit)
    }

    /// Regressionstest für einen echten Zwei-Geräte-Nutzerbericht (2026-08-10,
    /// Folgefund zu Abschnitt 52): der eigene Platzhalter wird per
    /// `offenerTreffer` bereits im ERSTEN Zyklus (Peer-Vorgang dort noch
    /// offen) mit einem echten, real deutlich FRÜHER gestarteten Peer-Vorgang
    /// zusammengeführt — der Platzhalter selbst wurde aber ERST NACH diesem
    /// realen Beginn angelegt (z.B. weil das Gerät erst nach einem
    /// Neustart/Sync-Beitritt wieder online kam). Schließt der Peer im
    /// ZWEITEN Zyklus ab, liegt seine `endZeit` plausibel NACH dem realen
    /// Beginn, aber VOR dem (zu späten) `startZeit` des eigenen Platzhalters
    /// — die Plausibilitätsprüfung darf das nicht mehr gegen dieses zu späte
    /// `startZeit` verwerfen, sonst kommt "Einkauf abschließen" nie an.
    @Test
    func vorhandenerVorgangUebernimmtFruehereEintragStartzeitBeimAliasieren() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        // Eigener Platzhalter, deutlich SPÄTER angelegt als der reale Beginn
        // des gemeinsamen Einkaufs auf der Gegenseite.
        let platzhalter = Einkaufsvorgang(einkaufsliste: liste, startZeit: Date())
        context.insert(platzhalter)
        try context.save()

        // Erster Zyklus: Peer-Vorgang noch offen, real deutlich früher
        // gestartet — matcht per offenerTreffer (Regelfall für noch offene
        // Einträge, unabhängig vom Zeitabstand).
        let remoteVorgangID = UUID()
        let realerBeginn = platzhalter.startZeit.addingTimeInterval(-600)
        var ersterSnapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        ersterSnapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        ersterSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: realerBeginn, endZeit: nil),
        ]
        try schreibeFremdenSnapshot(ersterSnapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)

        // Zweiter Zyklus: Peer schließt ab — endZeit klar NACH dem realen
        // Beginn, aber VOR dem ursprünglichen (zu späten) Platzhalter-startZeit.
        let abschlusszeit = realerBeginn.addingTimeInterval(60)
        var zweiterSnapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        zweiterSnapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Einkaufsliste", erstelltAm: liste.erstelltAm)]
        zweiterSnapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: remoteVorgangID, geschaeftID: nil, einkaufslisteID: liste.id, startZeit: realerBeginn, endZeit: abschlusszeit),
        ]
        try schreibeFremdenSnapshot(zweiterSnapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsvorgang>()).count == 1)
        #expect(platzhalter.endZeit == abschlusszeit)
    }

    /// Seit der Entkopplung der Live-Ansicht von der Vorgangs-Identität
    /// (Session 2026-08-03, `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3)
    /// gibt es keine Umleitung mehr: Ein Snapshot referenziert per ID exakt
    /// den Vorgang, den dieses Gerät zwischenzeitlich per „Einkauf
    /// abschließen" geschlossen hat (der Peer kennt dessen `endZeit` beim
    /// Export noch nicht) — der zugehörige `KaufEintrag` bleibt einfach an
    /// diesem (bereits geschlossenen) Vorgang hängen. Sichtbar wird er trotzdem
    /// sofort, weil `EinkaufenView.abgehakteKaufEintraegeFuerAktuelleListe`
    /// alle Vorgänge der Liste einbezieht.
    @Test
    func bereitsAbgeschlossenerBekannterVorgangBehaeltKaufEintragBeiSnapshotMerge() async throws {
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

        #expect(alterVorgang.kaufEintraege.contains { $0.artikel == apfel })
        #expect(neuerVorgang.kaufEintraege.isEmpty)
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
        // Koordinaten auf beiden Seiten setzen (GitHub #86, siehe Kommentar
        // im ersten Zähler-Test) — sonst matcht der automatische Merge nie.
        geschaeft.breitengrad = 52.5200
        geschaeft.laengengrad = 13.4050
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        try context.save()

        let remoteGeschaeftID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteGeschaeftID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: 52.5201, laengengrad: 13.4051,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 1, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        // Auflösbare `einkaufslisteID` (Abschnitt-25-Guard, GitHub #79): ohne
        // bereits bekannten ID-/Alias-Treffer wird ein Eintrag mit unauflösbarer
        // Liste absichtlich übersprungen statt angelegt — dieser Test prüft
        // gezielt den regulären Neuanlage-Fall, also referenziert der Snapshot
        // eine lokal bereits vorhandene Liste (analog benachbarter Tests).
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: liste.name, erstelltAm: liste.erstelltAm)]
        snapshot.einkaufsvorgaenge = [
            EinkaufsvorgangSnapshot(id: UUID(), geschaeftID: remoteGeschaeftID, einkaufslisteID: liste.id, startZeit: Date(), endZeit: Date()),
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

    /// `docs/GESCHAEFTS_AGGREGATE.md`: Union nach (Artikel, Geschäft)-Paar,
    /// kein Duplikat bei wiederholtem Sync, kein Tombstone-Bedarf (die
    /// Tatsache wird vom Nutzer nie direkt gelöscht).
    @Test
    func artikelGeschaeftVerfuegbarkeitWirdAlsExistenzTatsacheUebernommenOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        context.insert(rewe)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: rewe.id, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        snapshot.artikelGeschaeftVerfuegbarkeiten = [
            ArtikelGeschaeftVerfuegbarkeitSnapshot(artikelID: apfel.id, geschaeftID: rewe.id),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        #expect(try context.fetchCount(FetchDescriptor<ArtikelGeschaeftVerfuegbarkeit>()) == 1)
        #expect(ArtikelVerfuegbarkeitService.wurdeBereitsGekauft(apfel, in: rewe, context: context))
    }

    /// GitHub #99: Union nach (Artikel, Einkaufsliste)-Paar, kein Duplikat bei
    /// wiederholtem Sync, kein Tombstone-Bedarf (analog
    /// ``artikelGeschaeftVerfuegbarkeitWirdAlsExistenzTatsacheUebernommenOhneDuplikat``).
    @Test
    func artikelListenKaufWirdAlsExistenzTatsacheUebernommenOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: apfel.id, name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Urlaub", erstelltAm: liste.erstelltAm)]
        snapshot.artikelListenKaeufe = [
            ArtikelListenKaufSnapshot(artikelID: apfel.id, einkaufslisteID: liste.id),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        #expect(try context.fetchCount(FetchDescriptor<ArtikelListenKauf>()) == 1)
        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: apfel, einkaufsliste: liste, context: context))
    }

    /// **Regressionstest für GitHub #99** — die ursprünglich gemeldete
    /// Live-Test-Divergenz (oszillierende Mitgliederzahl der Liste „Urlaub"):
    /// Ein Artikel wird abgehakt, sein `KaufEintrag` läuft anschließend durch
    /// `KaufEintragBereinigungService`s 48h-Karenzzeit ab (hier direkt
    /// simuliert durch Löschen von `KaufEintrag`+`Einkaufsvorgang`, exakt wie
    /// der reale Service es tut — OHNE das neue ``ArtikelListenKauf``-Faktum
    /// anzutasten, das dieser Service nie berührt). Ein Peer mit veraltetem
    /// `listen.json` (per Fingerabdruck-Skip nie aktualisiert) listet den
    /// Artikel weiterhin als offenes Listenmitglied. Vor dem Fix hätte
    /// `istBereitsAbgehakt` an dieser Stelle `false` geliefert (keine
    /// existierenden `KaufEintrag`e mehr) und der Artikel wäre auf die offene
    /// Liste zurückgeholt worden.
    @Test
    func bereitsAbgehakterArtikelUeberlebtKaufEintragBereinigungUndWirdNichtDurchStalenPeerZurueckgeholt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(vorgang)
        _ = vorgang.artikelAbhakenOhneEventAufzeichnung(artikel, context: context)
        try context.save()
        #expect(!liste.enthaelt(artikel))
        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))

        // KaufEintragBereinigungService.bereinigen() nach Ablauf der
        // Karenzzeit: löscht KaufEintrag + leer gewordenen Vorgang, rührt
        // ArtikelListenKauf nicht an.
        for eintrag in try context.fetch(FetchDescriptor<KaufEintrag>()) {
            context.delete(eintrag)
        }
        context.delete(vorgang)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)

        // Ein Peer, der die Abwahl/das Abhaken noch nicht mitbekommen hat,
        // listet Sonnencreme in seinem (per Fingerabdruck-Skip veralteten)
        // Snapshot weiterhin als Mitglied der Liste.
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [EinkaufslisteSnapshot(id: liste.id, name: "Urlaub", erstelltAm: liste.erstelltAm)]
        snapshot.artikel = [
            ArtikelSnapshot(
                id: artikel.id, name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00",
                kategorieIDs: [], notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        snapshot.einkaufslistenEintraege = [
            EinkaufslistenEintragSnapshot(einkaufslisteID: liste.id, artikelID: artikel.id, menge: 1, notiz: nil),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Das dauerhafte Faktum verhindert die Wiederbelebung, obwohl der
        // KaufEintrag längst weg ist.
        #expect(!liste.enthaelt(artikel))
    }

    /// `docs/GESCHAEFTS_AGGREGATE.md`: Union nach `id` (= `id` des
    /// ursprünglichen ``Einkaufsvorgang``s), analog dem `KaufEintrag`-Merge.
    @Test
    func geschaeftBesuchWirdAlsUnveraenderlicheHistorieUebernommenOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let rewe = Geschaeft(name: "Rewe", typen: [])
        context.insert(rewe)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: rewe.id, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        let besuchID = UUID()
        let start = Date().addingTimeInterval(-600)
        let ende = Date()
        snapshot.geschaeftBesuche = [
            GeschaeftBesuchSnapshot(id: besuchID, geschaeftID: rewe.id, startZeit: start, endZeit: ende, anzahlProdukte: 4),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let alleBesuche = try context.fetch(FetchDescriptor<GeschaeftBesuch>())
        #expect(alleBesuche.count == 1)
        #expect(alleBesuche.first?.id == besuchID)
        #expect(alleBesuche.first?.geschaeft?.id == rewe.id)
        #expect(alleBesuche.first?.anzahlProdukte == 4)
    }

    /// Ein per Snapshot gemergter (also per Konstruktion von einem ANDEREN
    /// Gerät stammender) ``KaufEintrag`` darf seinen `kategorieBesuchsIndex`
    /// NICHT aus dem Snapshot übernehmen — sonst würde ein später auf diesem
    /// Gerät abgeschlossener, mit dem fremden Vorgang zusammengeführter
    /// Einkauf (``mergeEinkaufsvorgaenge``) die Laufreihenfolge des anderen
    /// Geräts in die eigene ``AbteilungsDistanzService``-Analyse mischen
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
        #expect(eintrag.ursprungsGeraeteID == "fremdes-geraet")
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

    /// Aufbau-Helfer für die folgenden drei Tests (GitHub #87): legt Geschäft
    /// und ein kanonisches Kategorie-Paar an und liefert eine
    /// `WarengruppenDistanzSnapshot`-Fabrik für dasselbe Paar.
    private func machtWarengruppenDistanzSzenario(context: ModelContext) throws -> (
        geschaeft: Geschaeft, kategorieA: ArtikelKategorie, kategorieB: ArtikelKategorie,
        macheSnapshot: (SyncSnapshot, Double, Int) -> SyncSnapshot
    ) {
        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let kategorieA = ArtikelKategorie(name: "Obst", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF")
        context.insert(kategorieA)
        context.insert(kategorieB)
        try context.save()

        func macheSnapshot(_ basis: SyncSnapshot, _ distanz: Double, _ eigeneAnzahlBeobachtungen: Int) -> SyncSnapshot {
            var snapshot = basis
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
                WarengruppenDistanzSnapshot(
                    id: UUID(), geschaeftID: geschaeft.id, kategorieAID: kategorieA.id, kategorieBID: kategorieB.id,
                    distanz: distanz, eigeneAnzahlBeobachtungen: eigeneAnzahlBeobachtungen
                ),
            ]
            return snapshot
        }
        return (geschaeft, kategorieA, kategorieB, macheSnapshot)
    }

    /// Gleich viele Beobachtungen auf beiden Seiten (je 1) — Kontrollfall, in
    /// dem der gewichtete Mittelwert auf dasselbe Ergebnis wie die frühere
    /// naive 50/50-Mittelung fällt.
    @Test
    func abteilungsDistanzWirdGewichtetGemitteltBeiGleicherBeobachtungsanzahl() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let (geschaeft, kategorieA, kategorieB, macheSnapshot) = try machtWarengruppenDistanzSzenario(context: context)
        let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(kategorieA, kategorieB)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kanonA, kategorieB: kanonB, distanz: 0.2))
        try context.save()

        let snapshot = macheSnapshot(leererSnapshot(geraeteID: "fremdes-geraet"), 0.8, 1)
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleDistanzen = try context.fetch(FetchDescriptor<WarengruppenDistanz>())
        #expect(alleDistanzen.count == 1)
        #expect(alleDistanzen.first?.distanz == 0.5) // (0.2*1 + 0.8*1) / 2
        #expect(alleDistanzen.first?.beobachtungsAnzahl == 2)
    }

    /// GitHub #87 — Kernfall: ein Gerät mit vielen (5) stabilen Beobachtungen
    /// darf von einem einzelnen Ausreißer eines frisch synchronisierten
    /// Peers (1 Beobachtung) nicht mehr zur Hälfte verschoben werden, sondern
    /// nur proportional zu dessen Gewicht.
    @Test
    func abteilungsDistanzWirdNachBeobachtungsanzahlGewichtetStattNaiv50zu50Gemittelt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let (geschaeft, kategorieA, kategorieB, macheSnapshot) = try machtWarengruppenDistanzSzenario(context: context)
        let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(kategorieA, kategorieB)
        let bestehendeDistanz = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kanonA, kategorieB: kanonB, distanz: 0.2)
        bestehendeDistanz.eigeneBeobachtungsAnzahl = 5
        context.insert(bestehendeDistanz)
        try context.save()

        let snapshot = macheSnapshot(leererSnapshot(geraeteID: "fremdes-geraet"), 0.8, 1)
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let alleDistanzen = try context.fetch(FetchDescriptor<WarengruppenDistanz>())
        #expect(alleDistanzen.count == 1)
        // (0.2*5 + 0.8*1) / 6 = 0.3 — statt der naiven 0.5.
        #expect(abs((alleDistanzen.first?.distanz ?? -1) - 0.3) < 0.0001)
        #expect(alleDistanzen.first?.beobachtungsAnzahl == 6)
    }

    /// GitHub #87 — ein wiederholter Sync-Zyklus desselben, inhaltlich
    /// unveränderten Peer-Standes darf den bereits gemergten Wert nicht
    /// erneut Richtung Peer-Wert verschieben (sonst würde derselbe Beitrag
    /// bei jedem Zyklus erneut mitgezählt, siehe ``WarengruppenDistanzPeerZaehlerStand``).
    @Test
    func abteilungsDistanzMergeIstBeiUnveraendertemPeerStandIdempotent() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let (geschaeft, kategorieA, kategorieB, macheSnapshot) = try machtWarengruppenDistanzSzenario(context: context)
        let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(kategorieA, kategorieB)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kanonA, kategorieB: kanonB, distanz: 0.2))
        try context.save()

        let snapshot = macheSnapshot(leererSnapshot(geraeteID: "fremdes-geraet"), 0.8, 1)
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        let nachErstemSync = try context.fetch(FetchDescriptor<WarengruppenDistanz>()).first
        #expect(nachErstemSync?.distanz == 0.5)
        #expect(nachErstemSync?.beobachtungsAnzahl == 2)

        // Zweiter Zyklus, exakt derselbe (unveränderte) Peer-Stand — kein
        // neuer Sync-Zyklus lässt den Wert erneut Richtung 0.8 wandern.
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        let nachZweitemSync = try context.fetch(FetchDescriptor<WarengruppenDistanz>()).first
        #expect(nachZweitemSync?.distanz == 0.5)
        #expect(nachZweitemSync?.beobachtungsAnzahl == 2)
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
    /// `mergeKaufEintraege` fetchte ursprünglich bei jedem Zyklus ALLE lokalen
    /// Einträge und verglich linear gegen jeden Remote-Eintrag (später über
    /// einen indizierten Existenz-Check pro Remote-Eintrag, seit
    /// Code-Review 2026-08-05 über ein einmalig vorab geladenes `Set<UUID>`
    /// abgelöst). Dieser Test prüft nur das beobachtbare Verhalten (bereits
    /// bekannte Einträge bleiben unverändert, nur der genuin neue wird
    /// übernommen) — die konkrete interne Optimierung ist per Black-Box-Test
    /// nicht nachweisbar.
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

    // MARK: - Ambiguitäts-Rückstellung (SyncAbgleichKandidat)

    /// Ein `Geschaeft` ohne Koordinaten auf beiden Seiten matcht nie nach der
    /// strengen Sync-Merge-Regel (GitHub #86) — vor dieser Änderung entstand
    /// dadurch bei jedem Sync-Zyklus eine neue Dublette. Jetzt: einmalig als
    /// ``SyncAbgleichKandidat`` zurückgestellt, danach idempotent (kein
    /// zweiter Kandidat, keine Dublette) über mehrere Zyklen ohne
    /// Nutzerreaktion.
    @Test
    func geschaeftMehrdeutigerKandidatWirdZurueckgestelltUndIstIdempotent() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 3, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 1)
        var kandidaten = try context.fetch(FetchDescriptor<SyncAbgleichKandidat>())
        #expect(kandidaten.count == 1)
        #expect(kandidaten.first?.entitaetsArt == SyncEntitaetsArt.geschaeft)
        #expect(kandidaten.first?.fremdeID == remoteID)
        #expect(kandidaten.first?.lokalerName == "Rewe")

        // Zweiter Zyklus ohne Nutzerreaktion: weiterhin genau ein Kandidat,
        // keine Dublette.
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 1)
        kandidaten = try context.fetch(FetchDescriptor<SyncAbgleichKandidat>())
        #expect(kandidaten.count == 1)
    }

    /// „Gleich"-Auflösung: Alias wird registriert, Name übernommen, Kandidat
    /// entfernt — ein anschließender Sync-Zyklus merged den Peer-Beitrag
    /// dann ganz normal über den Alias-Fast-Path.
    @Test
    func geschaeftMehrdeutigerKandidatWirdAlsGleichAufgeloest() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteID, name: "REWE Nord", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 4, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let kandidat = try #require(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).first)
        SyncSnapshotImportService.abgleichKandidatBestaetigen(kandidat, gewaehlterName: "REWE Nord", context: context)

        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 1)
        #expect(lokal.name == "REWE Nord")

        // Erneuter Zyklus: Alias löst den Remote-Eintrag jetzt direkt auf
        // dasselbe lokale Geschäft auf, kein neuer Kandidat, Peer-Beitrag
        // fließt additiv in den Zähler ein.
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
        #expect(lokal.anzahlEinkaufsvorgaenge == 4)
    }

    /// „Unterschiedlich"-Auflösung: das zurückgehaltene Remote-Objekt wird
    /// jetzt aktiv angelegt (`id = fremdeID`) — ein Folgezyklus erkennt es
    /// danach direkt über den ID-Fast-Path, ohne erneut als mehrdeutig
    /// aufzufallen.
    @Test
    func geschaeftMehrdeutigerKandidatWirdAlsUnterschiedlichAufgeloest() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.geschaefte = [
            GeschaeftSnapshot(
                id: remoteID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                ignorierteArtikelNamen: [], eigeneAnzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        let kandidat = try #require(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).first)
        SyncSnapshotImportService.abgleichKandidatAlsUnterschiedlichBestaetigen(kandidat, context: context)

        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
        let alle = try context.fetch(FetchDescriptor<Geschaeft>())
        #expect(alle.count == 2)
        #expect(alle.contains { $0.id == remoteID })

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(try context.fetch(FetchDescriptor<Geschaeft>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
    }

    /// Neu ab dieser Änderung: `Artikel` hat keine zweite Vergleichsdimension
    /// wie Koordinaten — Ambiguität ist deshalb ein reiner
    /// Teilstring-Treffer ohne exakte Übereinstimmung. Deckt Rückstellung UND
    /// beide Auflösungswege ab (leichter gehalten als die Geschaeft-Tests
    /// oben, da dieselbe generische Auflösungslogik nur einen weiteren
    /// `switch`-Zweig durchläuft).
    @Test
    func artikelMehrdeutigerKandidatWirdZurueckgestelltUndAufgeloest() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let milch = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(milch)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.artikel = [
            ArtikelSnapshot(
                id: remoteID, name: "H-Milch", symbolName: "drop.fill", farbeHex: "#34C759", kategorieIDs: [],
                notiz: nil, einheit: "stueck", mengenSchritt: 1, erstelltAm: Date()
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Artikel>()).count == 1)
        let kandidat = try #require(
            try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).first { $0.entitaetsArt == SyncEntitaetsArt.artikel }
        )
        #expect(kandidat.fremdeID == remoteID)
        #expect(kandidat.fremderName == "H-Milch")

        SyncSnapshotImportService.abgleichKandidatAlsUnterschiedlichBestaetigen(kandidat, context: context)
        let alleArtikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(alleArtikel.count == 2)
        #expect(alleArtikel.contains { $0.id == remoteID && $0.name == "H-Milch" })
        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
    }

    /// Wie oben, für `Einkaufsliste` — ebenfalls reiner Teilstring-Vergleich,
    /// diesmal über die „Gleich"-Auflösung geprüft (Alias-Registrierung).
    @Test
    func einkaufslisteMehrdeutigerKandidatWirdZurueckgestelltUndAufgeloest() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let urlaub = Einkaufsliste(name: "Urlaub")
        context.insert(urlaub)
        try context.save()

        let remoteID = UUID()
        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [
            EinkaufslisteSnapshot(id: remoteID, name: "Urlaub 2024", erstelltAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)

        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 1)
        let kandidat = try #require(
            try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).first { $0.entitaetsArt == SyncEntitaetsArt.einkaufsliste }
        )

        SyncSnapshotImportService.abgleichKandidatBestaetigen(kandidat, gewaehlterName: urlaub.name, context: context)
        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 1)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SyncAbgleichKandidat>()).isEmpty)
    }
}
