import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``EinkaufslistenAnzeigeService`` (GitHub #107/#110, extrahiert aus
/// `EinkaufenView.swift`s privater `EinkaufslisteView`) — reines
/// Struktur-Refactoring ohne historischen Live-Test-Bug, Fokus liegt auf der
/// Komposition der drei Funktionen (Verfügbarkeitsfilter, Mehrfachabteilung-
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

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.abteilungen = [abteilungA] // Zahnpasta (Abteilung B) NICHT im Geschäft verfügbar
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
    func verfuegbarkeitsgefiltertLaesstNurArtikelDerGeschaeftsAbteilungenDurch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikelVerfuegbar = Artikel(name: "Karotte", symbolName: "carrot", farbeHex: "#000000", abteilungen: [abteilungA])
        let artikelNicht = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungB])
        context.insert(artikelVerfuegbar)
        context.insert(artikelNicht)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.abteilungen = [abteilungA]
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

    // MARK: - abteilungenFuerAnzeige

    @Test
    func abteilungenFuerAnzeigeOhneGeschaeftLiefertAlleZugeordneten() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungA, abteilungB])
        context.insert(artikel)

        let ergebnis = EinkaufslistenAnzeigeService.abteilungenFuerAnzeige(
            artikel, geschaeft: nil, zeigeAlleArtikel: false, context: context
        )

        #expect(Set(ergebnis) == Set([abteilungA, abteilungB]))
    }

    @Test
    func abteilungenFuerAnzeigeMitGelernterAbteilungReduziertAufEine() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungA, abteilungB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        // 5 Käufe, davon 5/5 (>= 80%-Schwelle) unter Abteilung A → "gelernt".
        for _ in 0..<5 {
            let eintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, abteilung: abteilungA)
            context.insert(eintrag)
        }

        let ergebnis = EinkaufslistenAnzeigeService.abteilungenFuerAnzeige(
            artikel, geschaeft: geschaeft, zeigeAlleArtikel: false, context: context
        )

        #expect(ergebnis == [abteilungA])
    }

    @Test
    func abteilungenFuerAnzeigeLernmodusUmgehtGelernteAbteilung() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungA, abteilungB])
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        for _ in 0..<5 {
            let eintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, abteilung: abteilungA)
            context.insert(eintrag)
        }

        let ergebnis = EinkaufslistenAnzeigeService.abteilungenFuerAnzeige(
            artikel, geschaeft: geschaeft, zeigeAlleArtikel: true, context: context
        )

        #expect(Set(ergebnis) == Set([abteilungA, abteilungB]))
    }

    // MARK: - abteilungGruppen

    @Test
    func abteilungGruppenDupliziertArtikelMitMehrerenAbteilungen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungA = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungB = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungA)
        context.insert(abteilungB)
        let artikel = Artikel(name: "Ohropax", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungA, abteilungB])
        context.insert(artikel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintrag = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: 1)
        context.insert(eintrag)

        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintrag], abgehakteArtikel: [], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.count == 2)
        #expect(gruppen.allSatisfy { $0.elemente.count == 1 })
    }

    @Test
    func abteilungGruppenBlendetAbgehakteArtikelNurBeiFlagEin() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilung = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(abteilung)
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        context.insert(artikel)

        let ohneAbgehakt = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [], abgehakteArtikel: [artikel], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )
        let mitAbgehakt = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [], abgehakteArtikel: [artikel], zeigeAbgehakteArtikel: true,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(ohneAbgehakt.isEmpty)
        #expect(mitAbgehakt.count == 1)
        #expect(mitAbgehakt.first?.elemente.first?.eintrag == nil)
    }

    @Test
    func abteilungGruppenOhneGeschaeftSortiertAlphabetisch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungZ = Abteilung(name: "Zoo", standardSymbol: "pawprint", standardFarbeHex: "#34C759")
        let abteilungA = Abteilung(name: "Ananas", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(abteilungZ)
        context.insert(abteilungA)
        let artikelZ = Artikel(name: "Zebra-Artikel", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungZ])
        let artikelA = Artikel(name: "Ananas-Artikel", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungA])
        context.insert(artikelZ)
        context.insert(artikelA)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragZ = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelZ, menge: 1)
        let eintragA = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelA, menge: 1)
        context.insert(eintragZ)
        context.insert(eintragA)

        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintragZ, eintragA], abgehakteArtikel: [], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.map(\.abteilung.name) == ["Ananas", "Zoo"])
    }

    // MARK: - abteilungGruppen: Artikel-Sortierung innerhalb einer Gruppe (GitHub #176)

    @Test
    func abteilungGruppenSortiertOffeneArtikelInnerhalbEinerGruppeAlphabetisch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilung = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(abteilung)
        let artikelZ = Artikel(name: "Zebra-Artikel", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        let artikelA = Artikel(name: "Ananas-Artikel", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        context.insert(artikelZ)
        context.insert(artikelA)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragZ = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelZ, menge: 1)
        let eintragA = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelA, menge: 1)
        context.insert(eintragZ)
        context.insert(eintragA)

        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintragZ, eintragA], abgehakteArtikel: [], zeigeAbgehakteArtikel: false,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.count == 1)
        #expect(gruppen.first?.elemente.map(\.artikel.name) == ["Ananas-Artikel", "Zebra-Artikel"])
    }

    @Test
    func abteilungGruppenSortiertAbgehakteArtikelAnsEndeDerGruppeUndAlphabetischUntereinander() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilung = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(abteilung)
        let offenAnanas = Artikel(name: "Ananas", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        let offenZebra = Artikel(name: "Zebra", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        let abgehaktBanane = Artikel(name: "Banane", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        let abgehaktWasser = Artikel(name: "Wasser", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilung])
        [offenAnanas, offenZebra, abgehaktBanane, abgehaktWasser].forEach(context.insert)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragAnanas = EinkaufslistenEintrag(einkaufsliste: liste, artikel: offenAnanas, menge: 1)
        let eintragZebra = EinkaufslistenEintrag(einkaufsliste: liste, artikel: offenZebra, menge: 1)
        context.insert(eintragAnanas)
        context.insert(eintragZebra)

        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintragZebra, eintragAnanas], abgehakteArtikel: [abgehaktWasser, abgehaktBanane],
            zeigeAbgehakteArtikel: true, zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.count == 1)
        #expect(gruppen.first?.elemente.map(\.artikel.name) == ["Ananas", "Zebra", "Banane", "Wasser"])
    }

    // MARK: - abteilungGruppen: vollständig abgehakte Abteilung ans Ende (GitHub #176)

    @Test
    func abteilungGruppenVerschiebtVollstaendigAbgehakteAbteilungOhneGeschaeftAnsEnde() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        // "Ananas" käme alphabetisch eigentlich VOR "Zoo" — ist aber vollständig
        // abgehakt und muss deshalb trotzdem dahinter landen.
        let abteilungAnanas = Abteilung(name: "Ananas", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungZoo = Abteilung(name: "Zoo", standardSymbol: "pawprint", standardFarbeHex: "#AF52DE")
        context.insert(abteilungAnanas)
        context.insert(abteilungZoo)
        let artikelAbgehakt = Artikel(name: "Erledigt", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungAnanas])
        let artikelOffen = Artikel(name: "Offen", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungZoo])
        context.insert(artikelAbgehakt)
        context.insert(artikelOffen)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragOffen = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelOffen, menge: 1)
        context.insert(eintragOffen)

        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintragOffen], abgehakteArtikel: [artikelAbgehakt], zeigeAbgehakteArtikel: true,
            zeigeAlleArtikel: false, geschaeft: nil, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.map(\.abteilung.name) == ["Zoo", "Ananas"])
    }

    @Test
    func abteilungGruppenVerschiebtVollstaendigAbgehakteAbteilungMitGeschaeftAnsEnde() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let abteilungAnanas = Abteilung(name: "Ananas", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let abteilungZoo = Abteilung(name: "Zoo", standardSymbol: "pawprint", standardFarbeHex: "#AF52DE")
        context.insert(abteilungAnanas)
        context.insert(abteilungZoo)
        let artikelAbgehakt = Artikel(name: "Erledigt", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungAnanas])
        let artikelOffen = Artikel(name: "Offen", symbolName: "sparkles", farbeHex: "#000000", abteilungen: [abteilungZoo])
        context.insert(artikelAbgehakt)
        context.insert(artikelOffen)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.abteilungen = [abteilungAnanas, abteilungZoo]
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let eintragOffen = EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikelOffen, menge: 1)
        context.insert(eintragOffen)

        // Kein Kaufverlauf → AbteilungsDistanzService liefert die (alphabetische)
        // Reihenfolge unverändert zurück; der "vollständig abgehakt ans Ende"-
        // Schritt muss trotzdem auf diesem Zweig (mit Geschäft) greifen.
        let gruppen = EinkaufslistenAnzeigeService.abteilungGruppen(
            offeneEintraege: [eintragOffen], abgehakteArtikel: [artikelAbgehakt], zeigeAbgehakteArtikel: true,
            zeigeAlleArtikel: false, geschaeft: geschaeft, zuletztAbgehakteAbteilung: nil, context: context
        )

        #expect(gruppen.map(\.abteilung.name) == ["Zoo", "Ananas"])
    }
}
