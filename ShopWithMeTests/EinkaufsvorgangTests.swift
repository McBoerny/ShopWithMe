import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct EinkaufsvorgangTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    @Test
    func abhakenErstelltKaufEintragUndEntferntVonEinkaufsliste() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst], einheit: .stueck, mengenSchritt: 3)
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        // In der App löst `DatabaseLeaseService.performMicroLease` nach jeder
        // Mutation ein `save()` aus — erst danach spiegelt sich ein `context.delete()`
        // auch in Relationship-Arrays anderer Objekte (hier `liste.eintraege`) wider.
        try context.save()

        #expect(liste.enthaelt(apfel) == false)
        #expect(einkauf.kaufEintraege.count == 1)
        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
        #expect(einkauf.kaufEintraege.first?.kategorieBesuchsIndex == 0)
        #expect(einkauf.kaufEintraege.first?.preis == nil)
        #expect(einkauf.kaufEintraege.first?.menge == 3)
    }

    @Test
    func gleicheKategorieTeiltSichDenBesuchsIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(birne)
        context.insert(shampoo)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbhaken(birne, context: context)
        einkauf.artikelAbhaken(shampoo, context: context)

        let apfelEintrag = einkauf.kaufEintraege.first { $0.artikel == apfel }
        let birneEintrag = einkauf.kaufEintraege.first { $0.artikel == birne }
        let shampooEintrag = einkauf.kaufEintraege.first { $0.artikel == shampoo }

        #expect(apfelEintrag?.kategorieBesuchsIndex == 0)
        #expect(birneEintrag?.kategorieBesuchsIndex == 0)
        #expect(shampooEintrag?.kategorieBesuchsIndex == 1)
    }

    @Test
    func unkategorisierterArtikelFaelltUnterSonstigesUndTeiltSichDenIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let ohneKategorie = Artikel(name: "Mysteriöses Ding", symbolName: "questionmark", farbeHex: "#8E8E93")
        let explizitSonstiges = Artikel(name: "Kerzen", symbolName: "flame.fill", farbeHex: "#8E8E93", kategorien: [sonstiges])
        context.insert(ohneKategorie)
        context.insert(explizitSonstiges)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(ohneKategorie, context: context)
        einkauf.artikelAbhaken(explizitSonstiges, context: context)

        let ohneKategorieEintrag = einkauf.kaufEintraege.first { $0.artikel == ohneKategorie }
        let sonstigesEintrag = einkauf.kaufEintraege.first { $0.artikel == explizitSonstiges }

        #expect(ohneKategorieEintrag?.kategorie == sonstiges)
        #expect(ohneKategorieEintrag?.kategorieBesuchsIndex == 0)
        #expect(sonstigesEintrag?.kategorieBesuchsIndex == 0)
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)
    }

    @Test
    func abwaehlenMachtAbhakenRueckgaengig() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst], mengenSchritt: 2)
        context.insert(apfel)
        let listenEintrag = liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        listenEintrag.mengeErhoehen()
        listenEintrag.notiz = "Nur grüne"
        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbwaehlen(apfel, context: context)

        #expect(liste.enthaelt(apfel) == true)
        #expect(einkauf.kaufEintraege.isEmpty)
        // Menge/temporäre Notiz werden beim erneuten Auf-die-Liste-Setzen
        // zurückgesetzt, siehe `Einkaufsliste.artikelHinzufuegen(_:context:)`.
        let neuerEintrag = try #require(liste.eintrag(fuer: apfel))
        #expect(neuerEintrag.menge == apfel.mengenSchritt)
        #expect(neuerEintrag.notiz == nil)
    }

    /// Dedupe-Schutz gegen das in `docs/DATABASE_CONCURRENCY.md` dokumentierte
    /// Sync-Latenz-Restrisiko: ein zweiter Aufruf von `artikelAbhaken` für denselben
    /// Artikel im selben Einkaufsvorgang darf keinen zweiten `KaufEintrag` anlegen.
    @Test
    func abhakenErstelltBeiWiederholtemAufrufKeinDuplikat() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()
        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()

        #expect(einkauf.kaufEintraege.count == 1)
        #expect(liste.enthaelt(apfel) == false)
    }

    @Test
    func artikelAbhakenLiefertAbgehaktBeimErstenUndBereitsAbgehaktVonBeimZweitenAufruf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        let erstesErgebnis = einkauf.artikelAbhaken(apfel, context: context)
        try context.save()
        let zweitesErgebnis = einkauf.artikelAbhaken(apfel, context: context)

        #expect(erstesErgebnis == .abgehakt)
        guard case .bereitsAbgehaktVon(let geraeteID) = zweitesErgebnis else {
            Issue.record("Erwartete .bereitsAbgehaktVon, bekam \(zweitesErgebnis)")
            return
        }
        #expect(geraeteID == DatabaseLeaseService.geraeteID)
    }

    /// Ein per Sync-Import materialisiertes Abhaken (siehe
    /// `SyncImportService.materialisiere`) beschreibt die Laufreihenfolge des
    /// SENDENDEN Geräts, nicht die dieses Geräts — es darf deshalb keinen
    /// ``KaufEintrag/kategorieBesuchsIndex`` bekommen, sonst würde
    /// ``WarengruppenDistanzService`` mit einer erfundenen Besuchsposition für
    /// diesen Nutzer gefüttert (siehe Typ-Doku
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:indexFuerDistanzlernen:)``).
    @Test
    func syncMaterialisiertesAbhakenBekommtKeinenBesuchsindex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context, indexFuerDistanzlernen: false)
        // Siehe `abhakenErstelltKaufEintragUndEntferntVonEinkaufsliste`: ein
        // `context.delete()` spiegelt sich in `liste.eintraege` erst nach `save()`.
        try context.save()

        #expect(einkauf.kaufEintraege.first?.kategorieBesuchsIndex == nil)
        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
        #expect(liste.enthaelt(apfel) == false)
    }

    /// GitHub #48: Ein von einem Peer per Bereich-A-Import empfangenes
    /// "abgehakt"-Event (siehe `SyncImportServiceTests`) muss beim eigenen
    /// `artikelAbhaken`-Aufruf als `.bereitsAbgehaktVon` mit der Geräte-ID des
    /// ursprünglichen Peers erkannt werden, nicht als neue eigene Aktion.
    @Test
    func artikelAbhakenErkenntFremdesGeraetAlsUrsprungNachBereichAImport() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        // Simuliert ein bereits importiertes Fremd-Event (siehe
        // SyncEventService.uebernehmen) statt den echten Dateisystem-Import
        // aufzurufen — der Kern hier ist SyncEventService.aktuellerGewinner.
        let empfangenesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        SyncEventService.uebernehmen(empfangenesEvent, context: context)
        // Das eigentliche Abhaken (KaufEintrag) übernimmt der Import separat —
        // hier direkt nachgebildet, um den Fokus auf aktuellerGewinner zu halten.
        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        try context.save()

        let ergebnis = einkauf.artikelAbhaken(apfel, context: context)

        guard case .bereitsAbgehaktVon(let geraeteID) = ergebnis else {
            Issue.record("Erwartete .bereitsAbgehaktVon, bekam \(ergebnis)")
            return
        }
        #expect(geraeteID == "fremdes-geraet")
    }
}
