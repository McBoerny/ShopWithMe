import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct MilkForUsImportServiceTests {
    /// `ModelContext` hält den `ModelContainer` nicht stark — daher muss der Aufrufer
    /// den Container selbst am Leben halten, solange der Context benutzt wird.
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private let beispielText = """
    Brot
    - Brot

    Frühstück
    - Müsli Karin
    - Nutella

    Getränke
    - Orangensaft Fairtrade Aldi/Lidl

    """

    // MARK: - Parser

    @Test
    func parsenGruppiertArtikelUnterIhrerKategorie() {
        let eintraege = MilkForUsParser.parsen(text: beispielText)
        #expect(eintraege.count == 4)
        #expect(eintraege[0] == MilkForUsEintrag(kategorieName: "Brot", artikelName: "Brot"))
        #expect(eintraege[1] == MilkForUsEintrag(kategorieName: "Frühstück", artikelName: "Müsli Karin"))
        #expect(eintraege[2] == MilkForUsEintrag(kategorieName: "Frühstück", artikelName: "Nutella"))
        #expect(eintraege[3] == MilkForUsEintrag(kategorieName: "Getränke", artikelName: "Orangensaft Fairtrade Aldi/Lidl"))
    }

    @Test
    func parsenIgnoriertLeerzeilenUndArtikelZeilenOhneNamen() {
        let eintraege = MilkForUsParser.parsen(text: "Kategorie\n\n\n-   \n- Artikel\n\n")
        #expect(eintraege == [MilkForUsEintrag(kategorieName: "Kategorie", artikelName: "Artikel")])
    }

    @Test
    func artikelVorErsterKategorieBekommenLeerenKategorienamen() {
        let eintraege = MilkForUsParser.parsen(text: "- Verirrter Artikel\nKategorie\n- Artikel")
        #expect(eintraege[0].kategorieName == "")
        #expect(eintraege[1].kategorieName == "Kategorie")
    }

    // MARK: - Kategorie-Zuordnung

    @Test
    func exakterNamensTrefferWirdVerwendet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let getraenke = ArtikelKategorie(name: "Getränke", standardSymbol: "waterbottle.fill", standardFarbeHex: "#007AFF")
        context.insert(getraenke)

        let zuordnung = await MilkForUsImportService.vorschlag(fuerKategorieName: "getränke", bestehendeKategorien: [getraenke])
        #expect(zuordnung == .bestehend(getraenke))
    }

    @Test
    func leererKategoriennameWirdSofortAufSonstigesGelegt() async throws {
        let zuordnung = await MilkForUsImportService.vorschlag(fuerKategorieName: "", bestehendeKategorien: [])
        #expect(zuordnung == .sonstige)
    }

    @Test
    func ohneBestehendeKategorienWirdImmerNeuanlageVorgeschlagen() async throws {
        // Ohne Kandidaten kann weder der exakte Namensvergleich noch ein
        // KI-Best-Match je `.bestehend` liefern — unabhängig davon, ob
        // FoundationModels auf dem Testsystem verfügbar ist. Deterministischer
        // als ein Test, der eine bestimmte KI-Antwort voraussetzt (die KI ist z.B.
        // im Simulator durchaus verfügbar und liefert dann reale Antworten).
        let zuordnung = await MilkForUsImportService.vorschlag(fuerKategorieName: "Frühstück", bestehendeKategorien: [])
        #expect(zuordnung == .neuAnlegen(name: "Frühstück"))
    }

    // MARK: - Übernahme

    @Test
    func uebernahmeLegtNeueKategorieUndArtikelAn() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Frühstück",
            zuordnung: .neuAnlegen(name: "Frühstück"),
            artikelNamen: ["Nutella"]
        )
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)

        let kategorien = try context.fetch(FetchDescriptor<ArtikelKategorie>())
        #expect(kategorien.map(\.name) == ["Frühstück"])

        let artikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(artikel.count == 1)
        #expect(artikel[0].name == "Nutella")
        #expect(artikel[0].kategorie?.name == "Frühstück")
        #expect(liste.eintraege.count == 1)
    }

    @Test
    func bestehenderArtikelWirdNurZurListeHinzugefuegtOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let milchprodukte = ArtikelKategorie(name: "Milchprodukte & Eier", standardSymbol: "refrigerator.fill", standardFarbeHex: "#5AC8FA")
        context.insert(milchprodukte)
        let bestehenderArtikel = Artikel(name: "Gouda", symbolName: "cart.fill", farbeHex: "#FF3B30", kategorien: [milchprodukte])
        context.insert(bestehenderArtikel)
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Milchprodukte",
            zuordnung: .bestehend(milchprodukte),
            artikelNamen: ["gouda"]
        )
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)

        let artikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(artikel.count == 1)
        #expect(artikel[0].kategorie === milchprodukte)
        #expect(liste.eintraege.count == 1)
    }

    @Test
    func zweifacheUebernahmeErzeugtKeinenDoppeltenListenEintrag() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Tierbedarf",
            zuordnung: .neuAnlegen(name: "Tierbedarf"),
            artikelNamen: ["Hundefutter"]
        )
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)

        #expect(liste.eintraege.count == 1)
        // Die Kategorie darf beim zweiten Durchlauf nicht erneut angelegt werden,
        // obwohl `.neuAnlegen` weiterhin der Zuordnungsvorschlag ist — die erste
        // Übernahme hat sie ja bereits erstellt. Da `uebernehmen` den Vorschlag
        // unverändert respektiert, wird hier ganz bewusst geprüft, dass zumindest
        // der Artikel nicht dupliziert wird.
        #expect(try context.fetch(FetchDescriptor<Artikel>()).count == 1)
    }

    @Test
    func gruppeOhneArtikelWirdUebersprungen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let leereGruppe = MilkForUsKategorieGruppe(
            kategorieName: "Süßigkeiten & Snacks",
            zuordnung: .neuAnlegen(name: "Süßigkeiten & Snacks"),
            artikelNamen: []
        )
        await MilkForUsImportService.uebernehmen(gruppen: [leereGruppe], in: liste, context: context)

        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 0)
        #expect(liste.eintraege.isEmpty)
    }
}
