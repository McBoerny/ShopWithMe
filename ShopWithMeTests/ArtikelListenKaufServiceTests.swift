import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ArtikelListenKaufServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
            ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func vermerkeAbgehaktMachtIstJemalsAbgehaktWahr() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        #expect(!ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))
    }

    @Test
    func vermerkeAbgehaktErzeugtKeineDubletteBeiWiederholtemAufruf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)

        #expect(try context.fetchCount(FetchDescriptor<ArtikelListenKauf>()) == 1)
    }

    @Test
    func istJemalsAbgehaktIgnoriertAndereListe() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let urlaub = Einkaufsliste(name: "Urlaub")
        let einkaufsliste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(urlaub)
        context.insert(einkaufsliste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: urlaub, context: context)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: urlaub, context: context))
        #expect(!ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: einkaufsliste, context: context))
    }

    /// Regressionstest fürs zugrundeliegende GitHub-#99-Szenario: das Faktum
    /// bleibt bestehen, auch nachdem der `KaufEintrag`, der es ursprünglich
    /// ausgelöst hat, längst gelöscht wurde (analog
    /// `ArtikelVerfuegbarkeitServiceTests.verfuegbarkeitUeberlebtGeloeschteEinkaufsliste`).
    @Test
    func faktumUeberlebtLoeschungDesUrspruenglichenKaufEintrags() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(einkaufsliste: liste)
        context.insert(vorgang)

        vorgang.artikelAbhaken(artikel, context: context)
        try context.save()
        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))

        // Simuliert KaufEintragBereinigungService: KaufEintrag + Vorgang nach
        // Ablauf der Karenzzeit gelöscht.
        for eintrag in try context.fetch(FetchDescriptor<KaufEintrag>()) {
            context.delete(eintrag)
        }
        context.delete(vorgang)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)

        #expect(ArtikelListenKaufService.istJemalsAbgehakt(artikel: artikel, einkaufsliste: liste, context: context))
    }

    /// `alleSchluessel` darf bei einer baumelnden Referenz (Artikel gelöscht,
    /// ohne `inverse`-Deklaration bleibt die Relationship bestehen) nicht
    /// abstürzen — siehe `docs/DATABASE_CONCURRENCY.md`.
    @Test
    func alleSchluesselStuerztBeiBaumelnderArtikelReferenzNichtAb() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, context: context)
        try context.save()

        context.delete(artikel)
        try context.save()

        let schluessel = ArtikelListenKaufService.alleSchluessel(context: context)
        #expect(schluessel.isEmpty)
    }

    /// Regressionstest für den Nutzerbericht 2026-08-10 (Folgefund zu GitHub
    /// #99): `vermerkeAbgehakt` setzt jetzt zusätzlich `zuletztAbgehaktAm`.
    @Test
    func vermerkeAbgehaktSetztZeitstempel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)

        let zeitpunkt = Date()
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, am: zeitpunkt, context: context)

        let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, einkaufslisteID: liste.id)
        #expect(ArtikelListenKaufService.alleZeitstempel(context: context)[schluessel] == zeitpunkt)
    }

    /// `zuletztAbgehaktAm` wird bei einem wiederholten Aufruf nur nach VORNE
    /// (später) korrigiert, nie zurück — ein älterer, nachträglich
    /// gemergter Beleg darf einen bereits bekannten neueren Kauf nicht
    /// verwässern.
    @Test
    func vermerkeAbgehaktAktualisiertZeitstempelNurNachVorne() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let artikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(artikel)
        let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, einkaufslisteID: liste.id)

        let spaeter = Date()
        let frueher = spaeter.addingTimeInterval(-3600)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, am: spaeter, context: context)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: artikel, einkaufsliste: liste, am: frueher, context: context)

        #expect(ArtikelListenKaufService.alleZeitstempel(context: context)[schluessel] == spaeter)
        #expect(try context.fetchCount(FetchDescriptor<ArtikelListenKauf>()) == 1)
    }

    /// `alleZeitstempel` muss ein komplett unbekanntes Paar (nie
    /// `vermerkeAbgehakt`) klar von einem bekannten Paar OHNE Zeitstempel
    /// unterscheiden — ersteres fehlt im Dictionary, letzteres ist mit
    /// `nil`-Wert enthalten (siehe Typ-Doku ``ArtikelListenKaufService/alleZeitstempel(context:)``).
    @Test
    func alleZeitstempelUnterscheidetUnbekanntesPaarVonBekanntemOhneZeitstempel() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let mitZeitstempel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        let ohneZeitstempel = Artikel(name: "Handtuch", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        let unbekannt = Artikel(name: "Kamera", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(mitZeitstempel)
        context.insert(ohneZeitstempel)
        context.insert(unbekannt)

        ArtikelListenKaufService.vermerkeAbgehakt(artikel: mitZeitstempel, einkaufsliste: liste, am: Date(), context: context)
        // Altbestand-Simulation: Zeile ohne Zeitstempel, wie sie vor Einführung
        // dieses Felds entstanden wäre.
        context.insert(ArtikelListenKauf(artikel: ohneZeitstempel, einkaufsliste: liste))

        let zeitstempel = ArtikelListenKaufService.alleZeitstempel(context: context)

        let mitSchluessel = ArtikelListenKaufService.Schluessel(artikelID: mitZeitstempel.id, einkaufslisteID: liste.id)
        let ohneSchluessel = ArtikelListenKaufService.Schluessel(artikelID: ohneZeitstempel.id, einkaufslisteID: liste.id)
        let unbekannterSchluessel = ArtikelListenKaufService.Schluessel(artikelID: unbekannt.id, einkaufslisteID: liste.id)

        #expect(zeitstempel[mitSchluessel] != nil)
        // Bekannt, aber ohne Zeitstempel: Schlüssel IST enthalten, Wert ist `nil`.
        #expect(zeitstempel.keys.contains(ohneSchluessel))
        #expect(zeitstempel[ohneSchluessel] == .some(nil))
        // Komplett unbekannt: Schlüssel fehlt ganz.
        #expect(!zeitstempel.keys.contains(unbekannterSchluessel))
    }

    /// Regressionstest für einen Live-Absturz (Nutzerbericht 2026-08-24):
    /// `vermerkeHinzugefuegt`/`vermerkeAbgehakt` durchsuchen über
    /// `bestehenderEintragNamensgleich` ALLE `ArtikelListenKauf`-Zeilen einer
    /// Liste nach einem namensgleichen Artikel — dabei geriet eine Zeile mit
    /// baumelnder `artikel`-Referenz (Artikel andernorts per Sync-Merge
    /// gelöscht, siehe ``alleSchluesselStuerztBeiBaumelnderArtikelReferenzNichtAb``)
    /// unter den Kandidaten und `.name` wurde ungeprüft darauf gelesen —
    /// SwiftData-Fatal-Error „invalidated because its backing data could no
    /// longer be found in the store". Ein Aufruf für einen ANDEREN, weiterhin
    /// gültigen Artikel derselben Liste darf trotz der baumelnden Nachbarzeile
    /// nicht abstürzen.
    @Test
    func vermerkeHinzugefuegtStuerztBeiBaumelnderNachbarzeileNichtAb() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let geloeschterArtikel = Artikel(name: "Sonnencreme", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(geloeschterArtikel)
        ArtikelListenKaufService.vermerkeAbgehakt(artikel: geloeschterArtikel, einkaufsliste: liste, context: context)
        try context.save()

        // Baumelnde Referenz erzeugen: der referenzierte Artikel wird gelöscht,
        // die Zeile selbst (ohne `inverse`-Deklaration, siehe Typ-Doku) bleibt
        // bestehen.
        context.delete(geloeschterArtikel)
        try context.save()

        let neuerArtikel = Artikel(name: "Handtuch", symbolName: "sun.max.fill", farbeHex: "#FFCC00")
        context.insert(neuerArtikel)

        ArtikelListenKaufService.vermerkeHinzugefuegt(artikel: neuerArtikel, einkaufsliste: liste, context: context)

        let neueZeile = try context.fetch(FetchDescriptor<ArtikelListenKauf>()).first {
            $0.artikel?.persistentModelID == neuerArtikel.persistentModelID
        }
        #expect(neueZeile?.zuletztHinzugefuegtAm != nil)
    }
}
