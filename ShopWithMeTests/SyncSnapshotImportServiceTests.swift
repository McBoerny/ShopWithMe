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
}
