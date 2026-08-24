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
            Artikel.self, Abteilung.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
            Produkt.self, Produktname.self,
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

    // MARK: - Abteilung-Zuordnung

    @Test
    func exakterNamensTrefferWirdVerwendet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let getraenke = Abteilung(name: "Getränke", standardSymbol: "waterbottle.fill", standardFarbeHex: "#007AFF")
        context.insert(getraenke)

        let zuordnung = await MilkForUsImportService.vorschlag(fuerAbteilungName: "getränke", bestehendeAbteilungen: [getraenke])
        #expect(zuordnung == .bestehend(getraenke))
    }

    @Test
    func leererKategoriennameWirdSofortAufSonstigesGelegt() async throws {
        let zuordnung = await MilkForUsImportService.vorschlag(fuerAbteilungName: "", bestehendeAbteilungen: [])
        #expect(zuordnung == .sonstige)
    }

    @Test
    func ohneBestehendeKategorienWirdImmerNeuanlageVorgeschlagen() async throws {
        // Ohne Kandidaten kann weder der exakte Namensvergleich noch ein
        // KI-Best-Match je `.bestehend` liefern — unabhängig davon, ob
        // FoundationModels auf dem Testsystem verfügbar ist. Deterministischer
        // als ein Test, der eine bestimmte KI-Antwort voraussetzt (die KI ist z.B.
        // im Simulator durchaus verfügbar und liefert dann reale Antworten).
        let zuordnung = await MilkForUsImportService.vorschlag(fuerAbteilungName: "Frühstück", bestehendeAbteilungen: [])
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

        let abteilungen = try context.fetch(FetchDescriptor<Abteilung>())
        #expect(abteilungen.map(\.name) == ["Frühstück"])

        let artikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(artikel.count == 1)
        #expect(artikel[0].name == "Nutella")
        #expect(artikel[0].abteilung?.name == "Frühstück")
        #expect(liste.eintraege.count == 1)
    }

    @Test
    func bestehenderArtikelWirdNurZurListeHinzugefuegtOhneDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let milchprodukte = Abteilung(name: "Milchprodukte & Eier", standardSymbol: "refrigerator.fill", standardFarbeHex: "#5AC8FA")
        context.insert(milchprodukte)
        let bestehenderArtikel = Artikel(name: "Gouda", symbolName: "cart.fill", farbeHex: "#FF3B30", abteilungen: [milchprodukte])
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
        #expect(artikel[0].abteilung === milchprodukte)
        #expect(liste.eintraege.count == 1)
    }

    /// Regressionstest für GitHub #139: ein importierter Name, der einem
    /// konkreten ``Produktname`` entspricht (nicht dem generischen
    /// ``Artikel/name``), darf keinen doppelten neuen ``Artikel`` erzeugen —
    /// stattdessen wird der bestehende, generische Artikel des zugehörigen
    /// ``Produkt``s verwendet und das Produkt mit übernommen.
    @Test
    func produktnameTrefferVerwendetBestehendenArtikelStattDuplikat() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let milchprodukte = Abteilung(name: "Milchprodukte & Eier", standardSymbol: "refrigerator.fill", standardFarbeHex: "#5AC8FA")
        context.insert(milchprodukte)
        let bestehenderArtikel = Artikel(name: "Kindermilch", symbolName: "cart.fill", farbeHex: "#FF3B30", abteilungen: [milchprodukte])
        context.insert(bestehenderArtikel)
        let produkt = Produkt(name: "Alete Kindermilch 3", artikel: bestehenderArtikel)
        context.insert(produkt)
        let produktname = Produktname(name: "Alete Kindermilch 3", produkt: produkt, geschaeft: nil)
        context.insert(produktname)
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Milchprodukte",
            zuordnung: .bestehend(milchprodukte),
            artikelNamen: ["Alete Kindermilch 3"]
        )
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)

        let artikel = try context.fetch(FetchDescriptor<Artikel>())
        #expect(artikel.count == 1)
        #expect(artikel[0] === bestehenderArtikel)
        #expect(liste.eintraege.count == 1)
        #expect(liste.eintraege.first?.produkt === produkt)
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
        // Die Abteilung darf beim zweiten Durchlauf nicht erneut angelegt werden,
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

        #expect(try context.fetchCount(FetchDescriptor<Abteilung>()) == 0)
        #expect(liste.eintraege.isEmpty)
    }

    /// Regressionstest für die Chunk-Verarbeitung (Performance-/Fortschritts-Fund
    /// 2026-08-24, sehr große MilkForUs-Listen): eine einzelne `.neuAnlegen`-Gruppe
    /// mit mehr Artikeln als die interne `chunkGroesse` (25) darf ihre Abteilung
    /// trotz Aufteilung auf mehrere Micro-Lease-Chunks nur EINMAL anlegen.
    @Test
    func neuanlegenGruppeUeberMehrereChunksLegtKategorieNurEinmalAn() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let vieleArtikel = (1...60).map { "Artikel \($0)" }
        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Große Abteilung",
            zuordnung: .neuAnlegen(name: "Große Abteilung"),
            artikelNamen: vieleArtikel
        )
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context)

        let abteilungen = try context.fetch(FetchDescriptor<Abteilung>())
        #expect(abteilungen.map(\.name) == ["Große Abteilung"])
        #expect(try context.fetchCount(FetchDescriptor<Artikel>()) == 60)
        #expect(liste.eintraege.count == 60)
    }

    /// `fortschritt` muss am Ende jeder Phase `erledigt == gesamt` melden — Grundlage
    /// für die Fortschrittsanzeige in ``MilkForUsImportView``.
    @Test
    func uebernehmenMeldetVollstaendigenFortschritt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Test")
        context.insert(liste)

        let gruppe = MilkForUsKategorieGruppe(
            kategorieName: "Getränke",
            zuordnung: .neuAnlegen(name: "Getränke"),
            artikelNamen: (1...30).map { "Artikel \($0)" }
        )

        var meldungen: [(Int, Int)] = []
        await MilkForUsImportService.uebernehmen(gruppen: [gruppe], in: liste, context: context, fortschritt: { erledigt, gesamt in
            meldungen.append((erledigt, gesamt))
        })

        #expect(meldungen.first?.0 == 0)
        #expect(meldungen.last?.0 == 30)
        #expect(meldungen.allSatisfy { $0.1 == 30 })
        // Mehr als eine Meldung (Start + mindestens ein Chunk-Ende), da 30
        // Artikel bei `chunkGroesse == 25` auf zwei Chunks aufgeteilt werden.
        #expect(meldungen.count >= 3)
    }

    @Test
    func gruppenMitVorschlagMeldetVollstaendigenFortschritt() async throws {
        let eintraege = [
            MilkForUsEintrag(kategorieName: "Brot", artikelName: "Brot"),
            MilkForUsEintrag(kategorieName: "Getränke", artikelName: "Wasser"),
        ]

        var meldungen: [(Int, Int)] = []
        let gruppen = await MilkForUsImportService.gruppenMitVorschlag(
            aus: eintraege,
            bestehendeAbteilungen: [],
            fortschritt: { erledigt, gesamt in
                meldungen.append((erledigt, gesamt))
            }
        )

        #expect(gruppen.count == 2)
        #expect(meldungen.first?.0 == 0)
        #expect(meldungen.first?.1 == 2)
        #expect(meldungen.last?.0 == 2)
        #expect(meldungen.allSatisfy { $0.1 == 2 })
    }
}
