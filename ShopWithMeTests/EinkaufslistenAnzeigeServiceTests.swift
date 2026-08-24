import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``EinkaufslistenAnzeigeService`` (GitHub #107/#110, extrahiert aus
/// `EinkaufenView.swift`s privater `EinkaufslisteView`) — reines
/// Struktur-Refactoring ohne historischen Live-Test-Bug, Fokus liegt auf der
/// Komposition der drei Funktionen (Verfügbarkeitsfilter, Mehrfachkategorie-
/// Anzeige, Gruppierung/Sortierung), nicht auf einer erneuten Prüfung der
/// bereits anderswo getesteten ``AbteilungsDistanzService``-Sortieralgorithmen.
@MainActor
struct EinkaufslistenAnzeigeServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: SchemaDefinition.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SchemaDefinition.schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    // MARK: - verfuegbarkeitsgefiltert

    @Test
    func verfuegbarkeitsgefiltertOhneGeschaeftLiefertAlleEintraege() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: 1)
        context.insert(eintrag)

        let ergebnis = EinkaufslistenAnzeigeService.verfuegbarkeitsgefiltert(
            [eintrag], geschaeft: nil, zeigeAlleArtikel: false, context: context
        )

        #expect(ergebnis.count == 1)
    }

    @Test
    func verfuegbarkeitsgefiltertMitLernmodusUmgehtFilter() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.kategorien = [kategorieA] // Zahnpasta (Kategorie B) NICHT im Geschäft verfügbar
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: 1)
        context.insert(eintrag)

        let gefiltert = EinkaufslistenAnzeigeService.verfuegbarkeitsgefiltert(
            [eintrag], geschaeft: geschaeft, zeigeAlleArtikel: false, context: context
        )
        let ungefiltert = EinkaufslistenAnzeigeService.verfuegbarkeitsgefiltert(
            [eintrag], geschaeft: geschaeft, zeigeAlleArtikel: true, context: context
        )

        #expect(gefiltert.isEmpty)
        #expect(ungefiltert.count == 1)
    }

    @Test
    func verfuegbarkeitsgefiltertLaesstNurArtikelDerGeschaeftsKategorienDurch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikelVerfuegbar = Artikel(name: "Karotte", symbolName: "carrot", farbeHex: "#000000", kategorien: [kategorieA])
        let artikelNicht = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieB])
        context.insert(artikelVerfuegbar)
        context.insert(artikelNicht)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.kategorien = [kategorieA]
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragVerfuegbar = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelVerfuegbar, menge: 1)
        let eintragNicht = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelNicht, menge: 1)
        context.insert(eintragVerfuegbar)
        context.insert(eintragNicht)

        let ergebnis = EinkaufslistenAnzeigeService.verfuegbarkeitsgefiltert(
            [eintragVerfuegbar, eintragNicht], geschaeft: geschaeft, zeigeAlleArtikel: false, context: context
        )

        #expect(ergebnis == [eintragVerfuegbar])
    }

    // MARK: - kategorienFuerAnzeige

    @Test
    func kategorienFuerAnzeigeOhneGeschaeftLiefertAlleZugeordneten() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieA, kategorieB])
        context.insert(artikel)

        let ergebnis = EinkaufslistenAnzeigeService.kategorienFuerAnzeige(
            artikel, geschaeft: nil, zeigeAlleArtikel: false, context: context
        )

        #expect(Set(ergebnis) == Set([kategorieA, kategorieB]))
    }

    @Test
    func kategorienFuerAnzeigeMitGelernterKategorieReduziertAufEine() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieA, kategorieB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        // 5 Käufe, davon 5/5 (>= 80%-Schwelle) unter Kategorie A → "gelernt".
        for _ in 0..<5 {
            let eintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, kategorie: kategorieA)
            context.insert(eintrag)
        }

        let ergebnis = EinkaufslistenAnzeigeService.kategorienFuerAnzeige(
            artikel, geschaeft: geschaeft, zeigeAlleArtikel: false, context: context
        )

        #expect(ergebnis == [kategorieA])
    }

    @Test
    func kategorienFuerAnzeigeLernmodusUmgehtGelernteKategorie() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieA, kategorieB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        for _ in 0..<5 {
            let eintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, kategorie: kategorieA)
            context.insert(eintrag)
        }

        let ergebnis = EinkaufslistenAnzeigeService.kategorienFuerAnzeige(
            artikel, geschaeft: geschaeft, zeigeAlleArtikel: true, context: context
        )

        #expect(Set(ergebnis) == Set([kategorieA, kategorieB]))
    }

    // MARK: - kategorieGruppen

    @Test
    func kategorieGruppenDupliziertArtikelMitMehrerenKategorien() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieA, kategorieB])
        context.insert(artikel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: 1)
        context.insert(eintrag)

        let gruppen = EinkaufslistenAnzeigeService.kategorieGruppen(
            offeneEintraege: [eintrag], abgehakteArtikel: [], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteKategorie: nil, context: context
        )

        #expect(gruppen.count == 2)
        #expect(gruppen.allSatisfy { $0.elemente.count == 1 })
    }

    @Test
    func kategorieGruppenBlendetAbgehakteArtikelNurBeiFlagEin() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorie = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(kategorie)
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorie])
        context.insert(artikel)

        let ohneAbgehakt = EinkaufslistenAnzeigeService.kategorieGruppen(
            offeneEintraege: [], abgehakteArtikel: [artikel], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteKategorie: nil, context: context
        )
        let mitAbgehakt = EinkaufslistenAnzeigeService.kategorieGruppen(
            offeneEintraege: [], abgehakteArtikel: [artikel], zeigeAbgehakteArtikel: true,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteKategorie: nil, context: context
        )

        #expect(ohneAbgehakt.isEmpty)
        #expect(mitAbgehakt.count == 1)
        #expect(mitAbgehakt.first?.elemente.first?.eintrag == nil)
    }

    @Test
    func kategorieGruppenOhneGeschaeftSortiertAlphabetisch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieZ = ArtikelKategorie(name: "Zoo", standardSymbol: "pawprint", standardFarbeHex: "#34C759")
        let kategorieA = ArtikelKategorie(name: "Ananas", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(kategorieZ)
        context.insert(kategorieA)
        let artikelZ = Artikel(name: "Zebra-Artikel", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieZ])
        let artikelA = Artikel(name: "Ananas-Artikel", symbolName: "sparkles", farbeHex: "#000000", kategorien: [kategorieA])
        context.insert(artikelZ)
        context.insert(artikelA)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragZ = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelZ, menge: 1)
        let eintragA = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelA, menge: 1)
        context.insert(eintragZ)
        context.insert(eintragA)

        let gruppen = EinkaufslistenAnzeigeService.kategorieGruppen(
            offeneEintraege: [eintragZ, eintragA], abgehakteArtikel: [], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteKategorie: nil, context: context
        )

        #expect(gruppen.map(\.kategorie.name) == ["Ananas", "Zoo"])
    }
}
