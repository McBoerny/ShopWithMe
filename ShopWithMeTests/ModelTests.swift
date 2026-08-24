import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct ModelTests {
    /// `ModelContext` hält den `ModelContainer` nicht stark — daher muss der Aufrufer
    /// den Container selbst am Leben halten, solange der Context benutzt wird.
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
            SyncEvent.self, SyncPeerZaehlerStand.self, Preispunkt.self,
            Produkt.self, Produktname.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    /// Erzeugt einen eigenständigen (nicht in einen Context eingefügten)
    /// ``GeschaeftTyp`` für Tests, die lediglich irgendeinen Typ mit passendem
    /// Namen benötigen — seit GitHub #25 ein SwiftData-`@Model` statt eines
    /// `enum`-Falls, daher hier je Aufruf eine neue Instanz statt eines statischen
    /// Falls wie zuvor `.lebensmittel`.
    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }
    private func drogerieTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Drogerie", symbolName: "sparkles") }
    private func baumarktTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Baumarkt", symbolName: "hammer.fill") }

    @Test
    func seedDatenWerdenNurEinmalAngelegt() throws {
        let (container, context) = try machtLeerenContainer()
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeStandarddatenFallsLeer(context: context)

        let anzahl = try context.fetchCount(FetchDescriptor<Abteilung>())
        #expect(anzahl == SeedData.standardAbteilungen.count)
    }

    @Test
    func verfuegbareAbteilungenEnthaeltDirektZugeordneteAbteilungen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        geschaeft.abteilungen = [obst]

        #expect(geschaeft.verfuegbareAbteilungen.map(\.name) == ["Obst"])
    }

    @Test
    func verfuegbareAbteilungenMitAlleAbteilungenEnthaeltTypBasierteAbteilungen() throws {
        // GitHub #5: eine Abteilung ohne jede manuelle Zuordnung zum Geschäft gilt
        // trotzdem als verfügbar, sobald sie einem der Geschäftstypen zugeordnet ist.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let drogerie = drogerieTyp()
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let zahnpasta = Abteilung(name: "Zahnpasta", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        zahnpasta.geschaeftsTypen = [drogerie]
        context.insert(zahnpasta)
        let werkzeug = Abteilung(name: "Werkzeug", standardSymbol: "hammer.fill", standardFarbeHex: "#8E8E93")
        werkzeug.geschaeftsTypen = [baumarktTyp()]
        context.insert(werkzeug)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp(), drogerie])
        context.insert(geschaeft)
        geschaeft.abteilungen = [obst]

        let alleAbteilungen = [obst, zahnpasta, werkzeug]
        #expect(geschaeft.verfuegbareAbteilungen(alleAbteilungen: alleAbteilungen).map(\.name) == ["Obst", "Zahnpasta"])
        // Die parameterlose Variante bleibt unverändert rein manuell:
        #expect(geschaeft.verfuegbareAbteilungen.map(\.name) == ["Obst"])
    }

    @Test
    func abteilungDirektEntferntMachtSieNichtMehrVerfuegbar() throws {
        // Spiegelt `GeschaeftDetailView.abteilungEntfernen`: eine zugeordnete
        // Abteilung wird über `Geschaeft.abteilungen` entfernt.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        geschaeft.abteilungen = [obst]

        #expect(geschaeft.verfuegbareAbteilungen.map(\.name) == ["Obst"])

        geschaeft.abteilungen.removeAll { $0 == obst }

        #expect(geschaeft.verfuegbareAbteilungen.isEmpty)
    }

    @Test
    func sonstigeAbteilungWirdBeiBedarfAngelegtUndWiederverwendet() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let angelegt = Abteilung.sonstige(context: context)
        #expect(angelegt.name == "Sonstiges")
        #expect(try context.fetchCount(FetchDescriptor<Abteilung>()) == 1)

        let wiederverwendet = Abteilung.sonstige(context: context)
        #expect(wiederverwendet.persistentModelID == angelegt.persistentModelID)
        #expect(try context.fetchCount(FetchDescriptor<Abteilung>()) == 1)
    }

    @Test
    func anzeigeNamePriorisiertAlternativenNamenVorProduktNameVorArtikelVorSnapshot() {
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let produkt = Produkt(name: "Zahnpasta", artikel: artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        let eintrag = Preispunkt(produkt: produkt, geschaeft: geschaeft, preis: 2.49, produktName: "Zahnpasta")
        #expect(eintrag.anzeigeName == "Zahnpasta")

        eintrag.produktName = "Colgate Total"
        #expect(eintrag.anzeigeName == "Colgate Total")

        eintrag.alternativerName = "Zahnpasta (groß)"
        #expect(eintrag.anzeigeName == "Zahnpasta (groß)")

        eintrag.alternativerName = "   "
        #expect(eintrag.anzeigeName == "Colgate Total")

        eintrag.alternativerName = nil
        #expect(eintrag.anzeigeName == "Colgate Total")
    }

    @Test
    func produktnamePassendFindetExaktenTrefferVorTeilstringTreffer() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let colgate = Produkt(name: "Colgate", artikel: zahnpasta)
        let exakt = Produktname(name: "COL-ZAH", produkt: colgate, geschaeft: nil)
        let teilstring = Produktname(name: "COL", produkt: colgate, geschaeft: nil)

        let gelernt = Produktname.passend(fuerErkannterName: "COL-ZAH", bevorzugtesGeschaeft: nil, in: [teilstring, exakt])
        #expect(gelernt === exakt)
        #expect(gelernt?.produkt?.artikel === zahnpasta)
    }

    @Test
    func produktnamePassendLiefertNilOhneTrefferUndBeiLeeremNamen() {
        let milch = Produkt(name: "Vollmilch", artikel: nil)
        let anderesProdukt = Produktname(name: "MIL-VOLL", produkt: milch, geschaeft: nil)

        #expect(Produktname.passend(fuerErkannterName: "COL-ZAH", bevorzugtesGeschaeft: nil, in: [anderesProdukt]) == nil)
        #expect(Produktname.passend(fuerErkannterName: "", bevorzugtesGeschaeft: nil, in: [anderesProdukt]) == nil)
    }

    @Test
    func artikelPreisSpanneGruppiertUndBerechnetMinMax() throws {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let milch = Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA")
        let zahnpastaProdukt = Produkt(name: "Zahnpasta", artikel: zahnpasta)
        let milchProdukt = Produkt(name: "Vollmilch", artikel: milch)
        let geschaeft = Geschaeft(name: "Rewe", typen: [])

        let eintragEins = Preispunkt(produkt: zahnpastaProdukt, geschaeft: geschaeft, preis: 1.99)
        let eintragZwei = Preispunkt(produkt: zahnpastaProdukt, geschaeft: geschaeft, preis: 2.49)
        let eintragMilch = Preispunkt(produkt: milchProdukt, geschaeft: geschaeft, preis: 1.19)
        let eintragOhneArtikel = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 0.99)

        let spannen = ArtikelPreisSpanne.gruppieren([eintragEins, eintragZwei, eintragMilch, eintragOhneArtikel])

        #expect(spannen.count == 2)
        let zahnpastaSpanne = try #require(spannen.first { $0.artikel === zahnpasta })
        #expect(zahnpastaSpanne.minimum == 1.99)
        #expect(zahnpastaSpanne.maximum == 2.49)
        let milchSpanne = try #require(spannen.first { $0.artikel === milch })
        #expect(milchSpanne.minimum == 1.19)
        #expect(milchSpanne.maximum == 1.19)
        // Alphabetisch sortiert: "Vollmilch" vor "Zahnpasta".
        #expect(spannen.map(\.artikel.name) == ["Vollmilch", "Zahnpasta"])
    }

    @Test
    func einheitMengeUndMengenSchrittFallenOhneVorgabeAufDefaultsZurueck() {
        let artikel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        #expect(artikel.einheit == .stueck)
        #expect(artikel.mengenSchritt == 1)
    }

    @Test
    func abteilungenSetzenHaeltAbteilungAlsFuehrendeAbteilungSynchron() {
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = Abteilung(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let artikel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        #expect(artikel.abteilung == nil)

        artikel.abteilungen = [obst, drogerie]
        #expect(artikel.abteilungen == [obst, drogerie])
        #expect(artikel.abteilung == obst)
    }

    @Test
    func effektiveAbteilungenFaelltAufAlteAbteilungDannAufSonstigesZurueck() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let mitMehrfachauswahl = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", abteilungen: [obst])
        #expect(mitMehrfachauswahl.effektiveAbteilungen(context: context) == [obst])

        // Simuliert einen vor der Mehrfachauswahl angelegten Artikel: nur die alte,
        // einzelwertige `abteilung` ist gesetzt, `abteilungen` bleibt leer.
        let legacyArtikel = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759")
        legacyArtikel.abteilung = obst
        #expect(legacyArtikel.abteilungen.isEmpty)
        #expect(legacyArtikel.effektiveAbteilungen(context: context) == [obst])

        let ohneAbteilung = Artikel(name: "Nudeln", symbolName: "carrot.fill", farbeHex: "#34C759")
        #expect(ohneAbteilung.effektiveAbteilungen(context: context).map(\.name) == ["Sonstiges"])
    }

    @Test
    func fuehrendeAbteilungNutztVerfuegbareAbteilungImGeschaeft() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = Abteilung(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        geschaeft.abteilungen = [drogerie]

        let artikel = Artikel(name: "Duschgel", symbolName: "sparkles", farbeHex: "#AF52DE", abteilungen: [obst, drogerie])
        #expect(artikel.fuehrendeAbteilung(inGeschaeft: geschaeft, context: context) == drogerie)
    }

    @Test
    func fuehrendeAbteilungFaelltOhneJedenTrefferAufErsteAbteilungZurueck() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        // Explizit unterschiedliche sortIndex-Werte statt beide beim Default (0) zu
        // belassen: `fuehrendeAbteilung` sortiert Kandidaten seit v0.9 deterministisch
        // nach sortIndex (dann `id` als Tiebreaker) statt sich auf die nicht
        // ordnungsgarantierte `abteilungen`-Relationship-Reihenfolge zu verlassen —
        // bei gleichem sortIndex wäre der "erste" Kandidat sonst von der (zufälligen)
        // UUID-Reihenfolge abhängig, nicht von der hier absichtlich getesteten
        // "erste zugeordnete Abteilung gewinnt"-Fallback-Regel.
        let obst = Abteilung(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759", sortIndex: 0)
        let drogerie = Abteilung(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE", sortIndex: 1)
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let artikel = Artikel(name: "Duschgel", symbolName: "sparkles", farbeHex: "#AF52DE", abteilungen: [obst, drogerie])
        #expect(artikel.fuehrendeAbteilung(inGeschaeft: geschaeft, context: context) == obst)
        #expect(artikel.fuehrendeAbteilung(inGeschaeft: nil, context: context) == obst)
    }

    @Test
    func mengenSchrittBeimAnlegenBestimmtStartmenge() {
        let artikel = Artikel(name: "Mehl", symbolName: "carrot.fill", farbeHex: "#34C759", einheit: .kilogramm, mengenSchritt: 0.5)
        #expect(artikel.einheit == .kilogramm)
        #expect(artikel.mengenSchritt == 0.5)
    }

    @Test
    func mengeErhoehenUndVerringernRespektierenSchrittweiteUndUntergrenze() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let artikel = Artikel(name: "Mehl", symbolName: "carrot.fill", farbeHex: "#34C759", einheit: .kilogramm, mengenSchritt: 0.5)
        context.insert(artikel)
        let eintrag = liste.artikelHinzufuegen(artikel, context: context)

        eintrag.mengeErhoehen()
        #expect(eintrag.menge == 1.0)

        eintrag.mengeVerringern()
        #expect(eintrag.menge == 0.5)

        // Darf nicht unter die Schrittweite fallen.
        eintrag.mengeVerringern()
        #expect(eintrag.menge == 0.5)
    }

    @Test
    func artikelHinzufuegenSetztMengeUndTemporaereNotizZurueck() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let artikel = Artikel(name: "Mehl", symbolName: "carrot.fill", farbeHex: "#34C759", einheit: .kilogramm, mengenSchritt: 0.5)
        context.insert(artikel)
        let eintrag = liste.artikelHinzufuegen(artikel, context: context)
        eintrag.mengeErhoehen()
        eintrag.notiz = "Bio, falls vorhanden"

        let erneuterEintrag = liste.artikelHinzufuegen(artikel, context: context)

        #expect(liste.enthaelt(artikel) == true)
        #expect(erneuterEintrag === eintrag)
        #expect(erneuterEintrag.menge == artikel.mengenSchritt)
        #expect(erneuterEintrag.notiz == nil)
    }

    @Test
    func geschaeftLoeschenLoeschtZugehoerigePreishistorie() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let anderesGeschaeft = Geschaeft(name: "Anderer Laden", typen: [lebensmittelTyp()])
        context.insert(anderesGeschaeft)

        let eintrag = Preispunkt(produkt: nil, geschaeft: geschaeft, preis: 1.99)
        context.insert(eintrag)
        let andererEintrag = Preispunkt(produkt: nil, geschaeft: anderesGeschaeft, preis: 2.49)
        context.insert(andererEintrag)
        try context.save()

        context.delete(geschaeft)
        try context.save()

        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == andererEintrag.id)
    }

    @Test
    func passendesFindetGeschaeftAnhandDesNamensOderEinesAlternativenNamens() {
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        rewe.alternativeNamen = ["REWE Center Musterstadt"]
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])

        #expect(Geschaeft.passendes(fuerErkannterName: "REWE Musterstadt", unter: [rewe, edeka]) === rewe)
        #expect(Geschaeft.passendes(fuerErkannterName: "REWE Center Musterstadt Filiale 12", unter: [rewe, edeka]) === rewe)
        #expect(Geschaeft.passendes(fuerErkannterName: "Netto", unter: [rewe, edeka]) == nil)
        #expect(Geschaeft.passendes(fuerErkannterName: "", unter: [rewe, edeka]) == nil)
    }

    @Test
    func passendesNutztAdresseAlsTieBreakerBeiMehrerenNamensgleichenGeschaeften() {
        let filialeA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        let filialeB = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Bahnhofstraße 9, 12345 Musterstadt")

        let treffer = Geschaeft.passendes(
            fuerErkannterName: "Rewe",
            erkannteAdresse: "Bahnhofstraße 9, 12345 Musterstadt",
            unter: [filialeA, filialeB]
        )

        #expect(treffer === filialeB)
    }

    @Test
    func passendesFaelltBeiMehrdeutigerAdresseAufErstenNamensKandidatenZurueck() {
        let filialeA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        let filialeB = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])

        // Keine erkannte Adresse → kein Tie-Break möglich, erster Namens-Kandidat gewinnt.
        #expect(Geschaeft.passendes(fuerErkannterName: "Rewe", unter: [filialeA, filialeB]) === filialeA)
        // Erkannte Adresse passt zu keiner der beiden Filialen → ebenfalls Fallback.
        #expect(Geschaeft.passendes(
            fuerErkannterName: "Rewe", erkannteAdresse: "Ganz andere Straße 5, 99999 Woanders", unter: [filialeA, filialeB]
        ) === filialeA)
    }

    @Test
    func passendesFindetEindeutigenTrefferAlleinUeberDieAdresse() {
        // GitHub #19: erkennt die KI den Namen nicht (leer) oder passt er zu keinem
        // Geschäft, aber die Adresse ist einem bekannten Geschäft eindeutig
        // zuzuordnen, soll das trotzdem als direkter Treffer zählen.
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()], adresse: "Bahnhofstraße 9, 12345 Musterstadt")

        #expect(Geschaeft.passendes(
            fuerErkannterName: "", erkannteAdresse: "Marktstraße 1, 12345 Musterstadt", unter: [rewe, edeka]
        ) === rewe)
        #expect(Geschaeft.passendes(
            fuerErkannterName: "Unbekannter Name XYZ", erkannteAdresse: "Bahnhofstraße 9, 12345 Musterstadt", unter: [rewe, edeka]
        ) === edeka)
        // Adresse passt zu keinem Geschäft → weiterhin nil.
        #expect(Geschaeft.passendes(
            fuerErkannterName: "", erkannteAdresse: "Ganz andere Straße 5, 99999 Woanders", unter: [rewe, edeka]
        ) == nil)
    }

    // MARK: - passendes(fuerErkannterName:erkannteAdressen:unter:context:) — GitHub #132

    @Test
    func passendesMitMehrerenAdressenFindetTrefferUeberSchnellenSubstringPfadOhneKI() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let filialeA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        let filialeB = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Bahnhofstraße 9, 12345 Musterstadt")
        context.insert(filialeA)
        context.insert(filialeB)

        // Erste Adresse (Filiale) passt zu keiner Adresse, zweite (Zentrale) matcht
        // eindeutig filialeB — der schnelle Substring-Pfad muss das ohne KI-Aufruf lösen.
        let treffer = await Geschaeft.passendes(
            fuerErkannterName: "Rewe",
            erkannteAdressen: ["Ganz andere Straße 5, 99999 Woanders", "Bahnhofstraße 9, 12345 Musterstadt"],
            unter: [filialeA, filialeB],
            context: context
        )

        #expect(treffer === filialeB)
    }

    @Test
    func passendesLiefertNilBeiLeeremAdressArray() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(rewe)

        let treffer = await Geschaeft.passendes(
            fuerErkannterName: "Unbekannt", erkannteAdressen: [], unter: [rewe], context: context
        )

        #expect(treffer == nil)
    }

    @Test
    func passendesLiefertNilOhneBekannteAdressenAlsVergleichsgrundlage() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        // Kein Geschäft hat eine hinterlegte Adresse — weder Substring- noch
        // KI-Pfad haben eine Vergleichsgrundlage, unabhängig von der
        // KI-Verfügbarkeit auf dem Testgerät.
        let rewe = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        context.insert(rewe)

        let treffer = await Geschaeft.passendes(
            fuerErkannterName: "Unbekannter Name",
            erkannteAdressen: ["Marktstraße 1, 12345 Musterstadt"],
            unter: [rewe],
            context: context
        )

        #expect(treffer == nil)
    }

    @Test
    func passendesFindetTrefferPerKIBeiOCRVerrauschterAdresse() async throws {
        guard AISuggestionService.istVerfuegbar else { return }
        let (container, context) = try machtLeerenContainer()
        _ = container
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        context.insert(rewe)

        // Verrauschte Adresse (einzelner Zifferndreher in der PLZ, typischer
        // OCR-Fehler) passt bei keinem Substring-Vergleich, sollte der
        // KI-Ähnlichkeitsabgleich aber lösen.
        let treffer = await Geschaeft.passendes(
            fuerErkannterName: "", erkannteAdressen: ["Marktstraße 1, 12354 Musterstadt"], unter: [rewe], context: context
        )

        #expect(treffer === rewe)
    }

    @Test
    func koordinateIstNilOhneBreitenUndLaengengrad() {
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        #expect(geschaeft.koordinate == nil)
    }

    @Test
    func koordinateLiestUndSchreibtBreitenUndLaengengrad() {
        // GitHub #24: praktischer CLLocationCoordinate2D-Zugriff für die
        // Kartenansicht in GeschaeftStammdatenEditView.
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        geschaeft.koordinate = CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4)
        #expect(geschaeft.breitengrad == 52.5)
        #expect(geschaeft.laengengrad == 13.4)
        #expect(geschaeft.koordinate?.latitude == 52.5)
        #expect(geschaeft.koordinate?.longitude == 13.4)

        geschaeft.koordinate = nil
        #expect(geschaeft.breitengrad == nil)
        #expect(geschaeft.laengengrad == nil)
    }

    @Test
    func kurzeAdresseEntferntPostleitzahl() {
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Marktstraße 1, 12345 Musterstadt")
        #expect(geschaeft.kurzeAdresse == "Marktstraße 1, Musterstadt")
    }

    @Test
    func kurzeAdresseOhneKommaWirdUnveraendertDurchgereicht() {
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()], adresse: "Musterstadt")
        #expect(geschaeft.kurzeAdresse == "Musterstadt")
    }

    @Test
    func kurzeAdresseIstNilOhneHinterlegteAdresse() {
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        #expect(geschaeft.kurzeAdresse == nil)
    }

    @Test
    func namenMitDuplikatenErkenntCaseInsensitiveDuplikateUndIgnoriertEindeutigeNamen() {
        let reweA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let reweB = Geschaeft(name: "REWE", typen: [lebensmittelTyp()])
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])

        let duplikate = Geschaeft.namenMitDuplikaten(unter: [reweA, reweB, edeka])

        #expect(duplikate == ["rewe"])
    }

    @Test
    func alternativenNamenLernenIgnoriertLeereUndBereitsBekannteNamen() {
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])

        rewe.alternativenNamenLernen("REWE Center Musterstadt")
        #expect(rewe.alternativeNamen == ["REWE Center Musterstadt"])

        // Erneutes Lernen desselben (auch groß-/kleinschreibungs-abweichenden) Namens
        // legt kein Duplikat an.
        rewe.alternativenNamenLernen("rewe center musterstadt")
        #expect(rewe.alternativeNamen == ["REWE Center Musterstadt"])

        // Der eigentliche Name selbst wird nicht zusätzlich als Alias gelernt.
        rewe.alternativenNamenLernen("Rewe")
        #expect(rewe.alternativeNamen == ["REWE Center Musterstadt"])

        // Leerer Name wird ignoriert.
        rewe.alternativenNamenLernen("   ")
        #expect(rewe.alternativeNamen == ["REWE Center Musterstadt"])
    }

    @Test
    func fuehrenderTypIstDerErsteZugeordneteTyp() {
        let lebensmittel = lebensmittelTyp()
        let drogerie = drogerieTyp()
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittel])
        #expect(geschaeft.fuehrenderTyp === lebensmittel)

        geschaeft.typen = [drogerie, lebensmittel]
        #expect(geschaeft.typen == [drogerie, lebensmittel])
        #expect(geschaeft.fuehrenderTyp === drogerie)

        geschaeft.typen = []
        #expect(geschaeft.fuehrenderTyp == nil)
    }

    @Test
    func typenMigrierenFallsNoetigWandeltAlteRohwerteInGeschaeftTypenUm() throws {
        // GitHub #25: vor Einführung von `GeschaeftTyp` als SwiftData-Modell
        // angelegte Geschäfte kennen nur den alten, enum-basierten Rohwert
        // (`typenRaw`) — die neue Relation `typen` ist noch leer.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        geschaeft.typenRaw = ["drogerie", "lebensmittel"]
        context.insert(geschaeft)

        Geschaeft.typenMigrierenFallsNoetig(context: context)

        #expect(geschaeft.typen.map(\.name) == ["Drogerie", "Lebensmittel"])
    }

    @Test
    func typenMigrierenFallsNoetigLaesstBereitsMigrierteGeschaefteUnveraendert() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let lebensmittel = lebensmittelTyp()
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittel])
        // Ein bereits migriertes (oder neu angelegtes) Geschäft behält seinen
        // Rohwert unverändert im Datensatz, er wird aber nicht mehr gelesen.
        geschaeft.typenRaw = ["drogerie"]
        context.insert(geschaeft)

        Geschaeft.typenMigrierenFallsNoetig(context: context)

        #expect(geschaeft.typen == [lebensmittel])
    }

    @Test
    func typenMigrierenFallsNoetigFaelltBeiUnbekanntemRohwertAufSonstigesZurueck() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Kiosk", typen: [])
        geschaeft.typenRaw = ["unbekannterTyp"]
        context.insert(geschaeft)

        Geschaeft.typenMigrierenFallsNoetig(context: context)

        #expect(geschaeft.typen.map(\.name) == ["Sonstiges"])
    }

    @Test
    func anzahlEinkaufsvorgaengeFaelltOhneGespeichertenRohwertAufNullZurueck() {
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        #expect(geschaeft.anzahlEinkaufsvorgaenge == 0)
    }

    @Test
    func abschliessenErhoehtAnzahlEinkaufsvorgaengeDesGeschaefts() throws {
        // GitHub #30: der Zähler wird unabhängig von der Preishistorie geführt und
        // lässt sich separat zurücksetzen.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.abschliessen()
        #expect(geschaeft.anzahlEinkaufsvorgaenge == 1)

        geschaeft.zaehlerZuruecksetzen(context: context)
        #expect(geschaeft.anzahlEinkaufsvorgaenge == 0)
    }

    @Test
    func istIgnoriertErkenntTrefferBeiGleichemGeschaeftUndPassendemNamen() {
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: rewe)

        #expect(IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: rewe, unter: [ignoriert]))
        #expect(IgnorierterArtikel.istIgnoriert("PFAND 0,25", geschaeft: rewe, unter: [ignoriert]))
    }

    @Test
    func istIgnoriertLiefertFalseBeiAnderemGeschaeftOderOhneGeschaeft() {
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: rewe)

        #expect(!IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: edeka, unter: [ignoriert]))
        #expect(!IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: nil, unter: [ignoriert]))
    }
}
