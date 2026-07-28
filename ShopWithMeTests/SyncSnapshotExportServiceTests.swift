import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct SyncSnapshotExportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self, SyncEvent.self,
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
    func erstelleSnapshotEnthaeltAlleBereicheKorrektVerknuepft() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let kategorie = ArtikelKategorie(name: "Obst & Gemüse", standardSymbol: "carrot", standardFarbeHex: "#34C759")
        kategorie.geschaeftsTypen = [typ]
        context.insert(kategorie)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        geschaeft.erkennungsradiusRaw = 150
        geschaeft.kategorien = [kategorie]
        geschaeft.anzahlEinkaufsvorgaenge = 3
        context.insert(geschaeft)
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: geschaeft)
        context.insert(ignoriert)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [kategorie])
        context.insert(apfel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let laufenderEinkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(laufenderEinkauf)
        let eintrag = KaufEintrag(artikel: apfel, geschaeft: geschaeft, kategorie: kategorie, preis: 1.99)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = laufenderEinkauf
        let kategorie2 = ArtikelKategorie(name: "Milchprodukte", standardSymbol: "drop", standardFarbeHex: "#007AFF")
        context.insert(kategorie2)
        let distanz = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kategorie, kategorieB: kategorie2, distanz: 0.3)
        context.insert(distanz)
        try context.save()

        let snapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)

        #expect(snapshot.formatVersion == SyncSnapshot.aktuelleFormatVersion)
        #expect(snapshot.geschaeftsTypen.map(\.id) == [typ.id])

        let kategorieSnapshot = try #require(snapshot.artikelKategorien.first { $0.id == kategorie.id })
        #expect(kategorieSnapshot.geschaeftsTypIDs == [typ.id])

        let geschaeftSnapshot = try #require(snapshot.geschaefte.first { $0.id == geschaeft.id })
        #expect(geschaeftSnapshot.typIDs == [typ.id])
        #expect(geschaeftSnapshot.erkennungsradius == 150)
        #expect(geschaeftSnapshot.kategorieIDs == [kategorie.id])
        #expect(geschaeftSnapshot.ignorierteArtikelNamen == ["Pfand"])
        #expect(geschaeftSnapshot.anzahlEinkaufsvorgaenge == 3)

        let artikelSnapshot = try #require(snapshot.artikel.first { $0.id == apfel.id })
        #expect(artikelSnapshot.kategorieIDs == [kategorie.id])

        #expect(snapshot.einkaufslisten.map(\.id) == [liste.id])

        let einkaufsvorgangSnapshot = try #require(snapshot.einkaufsvorgaenge.first { $0.id == laufenderEinkauf.id })
        #expect(einkaufsvorgangSnapshot.geschaeftID == geschaeft.id)
        #expect(einkaufsvorgangSnapshot.einkaufslisteID == liste.id)
        #expect(einkaufsvorgangSnapshot.endZeit == nil)

        let kaufEintragSnapshot = try #require(snapshot.kaufEintraege.first { $0.id == eintrag.id })
        #expect(kaufEintragSnapshot.artikelID == apfel.id)
        #expect(kaufEintragSnapshot.einkaufsvorgangID == laufenderEinkauf.id)
        #expect(kaufEintragSnapshot.preis == 1.99)

        let distanzSnapshot = try #require(snapshot.warengruppenDistanzen.first { $0.id == distanz.id })
        #expect(distanzSnapshot.kategorieAID == kategorie.id)
        #expect(distanzSnapshot.kategorieBID == kategorie2.id)
    }

    @Test
    func exportiereSnapshotSchreibtExportJsonNachEigenemPeerOrdner() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        try context.save()

        await SyncSnapshotExportService.exportiereSnapshot(context: context)

        let exportURL = SyncSnapshotExportService.eigeneExportURL(in: syncOrdner)
        let daten = try Data(contentsOf: exportURL)
        let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: daten)
        #expect(snapshot.geschaefte.map(\.id) == [geschaeft.id])
        #expect(snapshot.geraeteID == DatabaseLeaseService.geraeteID)
    }

    @Test
    func exportiereSnapshotOhneSyncOrdnerTutNichts() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        SyncOrdnerService.ordnerEntfernen()

        await SyncSnapshotExportService.exportiereSnapshot(context: context)
        // Kein Absturz, keine Datei — nichts weiter zu prüfen ohne einen
        // konfigurierten Ordner, dessen Inhalt man einsehen könnte.
    }
}
