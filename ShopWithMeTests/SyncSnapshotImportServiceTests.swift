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
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerZaehlerStand.self,
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

    private func leererSnapshot(geraeteID: String) -> SyncSnapshot {
        SyncSnapshot(
            formatVersion: SyncSnapshot.aktuelleFormatVersion, erzeugtAm: Date(), geraeteID: geraeteID,
            geschaeftsTypen: [], artikelKategorien: [], geschaefte: [], artikel: [],
            einkaufslisten: [], einkaufsvorgaenge: [], kaufEintraege: [], warengruppenDistanzen: []
        )
    }

    private func schreibeFremdenSnapshot(_ snapshot: SyncSnapshot, fremdeGeraeteID: String, in syncOrdner: URL) throws {
        let url = SyncSnapshotExportService.exportURL(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
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
                ignorierteArtikelNamen: ["Pfand"], anzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
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

    @Test
    func anzahlEinkaufsvorgaengeWirdUeberMehrereSyncsAdditivGemergtOhneDoppelzaehlung() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let lokal = Geschaeft(name: "Rewe", typen: [typ])
        lokal.anzahlEinkaufsvorgaenge = 2
        context.insert(lokal)
        try context.save()

        let remoteID = UUID()
        func snapshotMitZaehler(_ wert: Int) -> SyncSnapshot {
            var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
            snapshot.geschaefte = [
                GeschaeftSnapshot(
                    id: remoteID, name: "Rewe", typIDs: [], adresse: nil, breitengrad: nil, laengengrad: nil,
                    erkennungsradius: nil, kategorieIDs: [], ausgeschlosseneKategorieIDs: [], alternativeNamen: [],
                    ignorierteArtikelNamen: [], anzahlEinkaufsvorgaenge: wert, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
                ),
            ]
            return snapshot
        }

        try schreibeFremdenSnapshot(snapshotMitZaehler(3), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 5) // 2 (lokal) + 3 (Zuwachs)

        try schreibeFremdenSnapshot(snapshotMitZaehler(5), fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 7) // + 2 Zuwachs (5-3)

        // Erneuter Import desselben (unveränderten) Standes darf nichts addieren.
        await SyncSnapshotImportService.importiereSnapshots(context: context)
        #expect(lokal.anzahlEinkaufsvorgaenge == 7)
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
    func einkaufslisteWirdPerIDGematchtNichtPerName() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let eigeneListe = Einkaufsliste(name: "Einkaufsliste")
        context.insert(eigeneListe)
        try context.save()

        var snapshot = leererSnapshot(geraeteID: "fremdes-geraet")
        snapshot.einkaufslisten = [
            EinkaufslisteSnapshot(id: UUID(), name: "Einkaufsliste", erstelltAm: Date()),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)

        // Zwei verschiedene IDs -> bewusst zwei Listen, auch bei gleichem Namen.
        #expect(try context.fetch(FetchDescriptor<Einkaufsliste>()).count == 2)
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
                ignorierteArtikelNamen: [], anzahlEinkaufsvorgaenge: 1, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
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
                artikelNameSnapshot: "Apfel", geschaeftNameSnapshot: "", produktName: nil, alternativerName: nil,
                datum: Date(), preis: 1.49, menge: 3, kategorieBesuchsIndex: nil
            ),
        ]
        try schreibeFremdenSnapshot(snapshot, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncSnapshotImportService.importiereSnapshots(context: context) // wiederholter Sync

        let alleEintraege = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(alleEintraege.count == 1)
        #expect(alleEintraege.first?.id == kaufEintragID)
        #expect(alleEintraege.first?.artikel?.id == apfel.id)
        #expect(alleEintraege.first?.preis == 1.49)
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
                ignorierteArtikelNamen: [], anzahlEinkaufsvorgaenge: 0, umbauVerdacht: false, unauffaelligeEinkaeufeInFolge: 0
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
}
