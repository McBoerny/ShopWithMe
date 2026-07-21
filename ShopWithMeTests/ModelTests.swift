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
            Artikel.self, ArtikelKategorie.self, Regal.self, Geschaeft.self,
            Einkaufsvorgang.self, KaufEintrag.self, KategorieBesuchsStatistik.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func seedDatenWerdenNurEinmalAngelegt() throws {
        let (container, context) = try machtLeerenContainer()
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeStandarddatenFallsLeer(context: context)

        let anzahl = try context.fetchCount(FetchDescriptor<ArtikelKategorie>())
        #expect(anzahl == SeedData.standardKategorien.count)
    }

    @Test
    func verfuegbareKategorienLeitenSichAusRegalenAb() throws {
        let (container, context) = try machtLeerenContainer()
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])
    }

    @Test
    func verfuegbareKategorienEnthaeltDirektZugeordneteKategorienOhneRegal() throws {
        // Kategorien sind wichtiger als Regale: ein Geschäft ohne ein einziges Regal
        // kann trotzdem Kategorien direkt zugeordnet bekommen und damit verfügbar
        // machen.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        geschaeft.kategorien = [obst]

        #expect(geschaeft.regale.isEmpty)
        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])
    }

    @Test
    func verfuegbareKategorienDedupliziertDirekteUndRegalZuordnung() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        geschaeft.kategorien = [obst]

        let regal = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])
    }

    @Test
    func kategorieDirektEntferntMachtSieNichtMehrVerfuegbar() throws {
        // Spiegelt `GeschaeftDetailView.kategorieEntfernen`: eine direkt (ohne Regal)
        // zugeordnete Kategorie wird über `Geschaeft.kategorien` entfernt.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        geschaeft.kategorien = [obst]

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])

        geschaeft.kategorien.removeAll { $0 == obst }

        #expect(geschaeft.verfuegbareKategorien.isEmpty)
    }

    @Test
    func kategorieEntfernenAusRegalMachtSieWiederNichtVerfuegbar() throws {
        // Spiegelt die Entfernen-Aktion im „Kategorien“-Abschnitt von
        // `GeschaeftDetailView`: die Kategorie wird über ihr zuständiges Regal
        // (`Geschaeft.regal(fuer:)`) entfernt, nicht direkt am Geschäft.
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal.kategorien = [obst]
        context.insert(regal)

        #expect(geschaeft.verfuegbareKategorien.map(\.name) == ["Obst"])

        geschaeft.regal(fuer: obst)?.kategorien.removeAll { $0 == obst }

        #expect(geschaeft.verfuegbareKategorien.isEmpty)
    }

    @Test
    func auswaehlbareKategorienSchliessenAnderweitigVerwendeteAus() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let getraenke = ArtikelKategorie(name: "Getränke", standardSymbol: "waterbottle.fill", standardFarbeHex: "#5AC8FA")
        context.insert(obst)
        context.insert(drogerie)
        context.insert(getraenke)

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        let regal1 = Regal(name: "Regal 1", geschaeft: geschaeft)
        regal1.kategorien = [obst]
        context.insert(regal1)

        let regal2 = Regal(name: "Regal 2", geschaeft: geschaeft)
        regal2.kategorien = [drogerie]
        context.insert(regal2)

        let alle = [obst, drogerie, getraenke]

        // Regal 1 darf seine eigene Kategorie ("Obst") weiterhin sehen (um sie
        // abwählen zu können), nicht aber die von Regal 2 ("Drogerie") verwendete.
        #expect(Set(regal1.auswaehlbareKategorien(aus: alle).map(\.name)) == ["Obst", "Getränke"])
        #expect(Set(regal2.auswaehlbareKategorien(aus: alle).map(\.name)) == ["Drogerie", "Getränke"])
    }

    @Test
    func sonstigeKategorieWirdBeiBedarfAngelegtUndWiederverwendet() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let angelegt = ArtikelKategorie.sonstige(context: context)
        #expect(angelegt.name == "Sonstiges")
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)

        let wiederverwendet = ArtikelKategorie.sonstige(context: context)
        #expect(wiederverwendet.persistentModelID == angelegt.persistentModelID)
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)
    }

    @Test
    func regalSortierModusFaelltOhneGespeichertenRohwertAufManuellZurueck() throws {
        // Vor v1.4 angelegte Geschäfte kennen die Spalte für `regalSortierModus`
        // nicht — nach der automatischen Migration bleibt ihr Rohwert `nil`. Der
        // Zugriff auf `regalSortierModus` darf dabei nicht abstürzen (siehe
        // v1.4-Crash: Zuordnung von `nil` auf ein nicht-optionales Enum-Attribut),
        // sondern muss auf `.manuell` zurückfallen.
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)

        #expect(geschaeft.regalSortierModus == .manuell)

        geschaeft.regalSortierModus = .automatisch
        #expect(geschaeft.regalSortierModus == .automatisch)
    }

    @Test
    func kategorieBesuchsStatistikBerechnetDurchschnitt() {
        let statistik = KategorieBesuchsStatistik(geschaeft: nil, kategorie: nil)
        #expect(statistik.durchschnittlichePosition == .infinity)

        statistik.erfassen(sequenzPosition: 1)
        statistik.erfassen(sequenzPosition: 3)
        #expect(statistik.durchschnittlichePosition == 2)
    }

    @Test
    func anzeigeNamePriorisiertAlternativenNamenVorProduktNameVorArtikelVorSnapshot() {
        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let eintrag = KaufEintrag(artikel: artikel, geschaeft: nil)
        eintrag.artikelNameSnapshot = "Zahnpasta"
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
    func gelernteZuordnungFindetJuengstenPassendenAliasMitArtikel() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let aelter = KaufEintrag(artikel: zahnpasta, geschaeft: nil, datum: Date(timeIntervalSince1970: 0))
        aelter.artikelNameSnapshot = "COL-ZAH"
        aelter.produktName = "COL-ZAH"
        aelter.alternativerName = "Colgate (alt)"

        let neuer = KaufEintrag(artikel: zahnpasta, geschaeft: nil, datum: Date(timeIntervalSince1970: 1_000_000))
        neuer.artikelNameSnapshot = "COL-ZAH"
        neuer.produktName = "COL-ZAH"
        neuer.alternativerName = "Colgate"

        let gelernt = KaufEintrag.gelernteZuordnung(fuerErkannterName: "COL-ZAH", in: [aelter, neuer])
        #expect(gelernt?.alias == "Colgate")
        #expect(gelernt?.artikel === zahnpasta)
    }

    @Test
    func gelernteZuordnungIgnoriertEintraegeOhneAliasUndOhnePassendenNamen() {
        let ohneAlias = KaufEintrag(artikel: nil, geschaeft: nil)
        ohneAlias.artikelNameSnapshot = "COL-ZAH"
        ohneAlias.produktName = "COL-ZAH"

        let anderesProdukt = KaufEintrag(artikel: nil, geschaeft: nil)
        anderesProdukt.artikelNameSnapshot = "MIL-VOLL"
        anderesProdukt.produktName = "MIL-VOLL"
        anderesProdukt.alternativerName = "Vollmilch"

        #expect(KaufEintrag.gelernteZuordnung(fuerErkannterName: "COL-ZAH", in: [ohneAlias, anderesProdukt]) == nil)
        #expect(KaufEintrag.gelernteZuordnung(fuerErkannterName: "", in: [anderesProdukt]) == nil)
    }

    @Test
    func artikelPreisSpanneGruppiertUndBerechnetMinMax() throws {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let milch = Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA")

        let eintragEins = KaufEintrag(artikel: zahnpasta, geschaeft: nil, preis: 1.99)
        let eintragZwei = KaufEintrag(artikel: zahnpasta, geschaeft: nil, preis: 2.49)
        let eintragMilch = KaufEintrag(artikel: milch, geschaeft: nil, preis: 1.19)
        let eintragOhneArtikel = KaufEintrag(artikel: nil, geschaeft: nil, preis: 0.99)

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

        let geschaeft = Geschaeft(name: "Testladen", typ: .lebensmittel)
        context.insert(geschaeft)
        let anderesGeschaeft = Geschaeft(name: "Anderer Laden", typ: .lebensmittel)
        context.insert(anderesGeschaeft)

        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, preis: 1.99)
        context.insert(eintrag)
        let andererEintrag = KaufEintrag(artikel: nil, geschaeft: anderesGeschaeft, preis: 2.49)
        context.insert(andererEintrag)
        try context.save()

        context.delete(geschaeft)
        try context.save()

        let verbleibende = try context.fetch(FetchDescriptor<KaufEintrag>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == andererEintrag.id)
    }

    @Test
    func passendesFindetGeschaeftAnhandDesNamensOderEinesAlternativenNamens() {
        let rewe = Geschaeft(name: "Rewe", typ: .lebensmittel)
        rewe.alternativeNamen = ["REWE Center Musterstadt"]
        let edeka = Geschaeft(name: "Edeka", typ: .lebensmittel)

        #expect(Geschaeft.passendes(fuerErkannterName: "REWE Musterstadt", unter: [rewe, edeka]) === rewe)
        #expect(Geschaeft.passendes(fuerErkannterName: "REWE Center Musterstadt Filiale 12", unter: [rewe, edeka]) === rewe)
        #expect(Geschaeft.passendes(fuerErkannterName: "Netto", unter: [rewe, edeka]) == nil)
        #expect(Geschaeft.passendes(fuerErkannterName: "", unter: [rewe, edeka]) == nil)
    }

    @Test
    func passendesNutztAdresseAlsTieBreakerBeiMehrerenNamensgleichenGeschaeften() {
        let filialeA = Geschaeft(name: "Rewe", typ: .lebensmittel, adresse: "Marktstraße 1, 12345 Musterstadt")
        let filialeB = Geschaeft(name: "Rewe", typ: .lebensmittel, adresse: "Bahnhofstraße 9, 12345 Musterstadt")

        let treffer = Geschaeft.passendes(
            fuerErkannterName: "Rewe",
            erkannteAdresse: "Bahnhofstraße 9, 12345 Musterstadt",
            unter: [filialeA, filialeB]
        )

        #expect(treffer === filialeB)
    }

    @Test
    func passendesFaelltBeiMehrdeutigerAdresseAufErstenNamensKandidatenZurueck() {
        let filialeA = Geschaeft(name: "Rewe", typ: .lebensmittel, adresse: "Marktstraße 1, 12345 Musterstadt")
        let filialeB = Geschaeft(name: "Rewe", typ: .lebensmittel)

        // Keine erkannte Adresse → kein Tie-Break möglich, erster Namens-Kandidat gewinnt.
        #expect(Geschaeft.passendes(fuerErkannterName: "Rewe", unter: [filialeA, filialeB]) === filialeA)
        // Erkannte Adresse passt zu keiner der beiden Filialen → ebenfalls Fallback.
        #expect(Geschaeft.passendes(
            fuerErkannterName: "Rewe", erkannteAdresse: "Ganz andere Straße 5, 99999 Woanders", unter: [filialeA, filialeB]
        ) === filialeA)
    }

    @Test
    func kurzeAdresseEntferntPostleitzahl() {
        let geschaeft = Geschaeft(name: "Rewe", typ: .lebensmittel, adresse: "Marktstraße 1, 12345 Musterstadt")
        #expect(geschaeft.kurzeAdresse == "Marktstraße 1, Musterstadt")
    }

    @Test
    func kurzeAdresseOhneKommaWirdUnveraendertDurchgereicht() {
        let geschaeft = Geschaeft(name: "Rewe", typ: .lebensmittel, adresse: "Musterstadt")
        #expect(geschaeft.kurzeAdresse == "Musterstadt")
    }

    @Test
    func kurzeAdresseIstNilOhneHinterlegteAdresse() {
        let geschaeft = Geschaeft(name: "Rewe", typ: .lebensmittel)
        #expect(geschaeft.kurzeAdresse == nil)
    }

    @Test
    func namenMitDuplikatenErkenntCaseInsensitiveDuplikateUndIgnoriertEindeutigeNamen() {
        let reweA = Geschaeft(name: "Rewe", typ: .lebensmittel)
        let reweB = Geschaeft(name: "REWE", typ: .lebensmittel)
        let edeka = Geschaeft(name: "Edeka", typ: .lebensmittel)

        let duplikate = Geschaeft.namenMitDuplikaten(unter: [reweA, reweB, edeka])

        #expect(duplikate == ["rewe"])
    }

    @Test
    func alternativenNamenLernenIgnoriertLeereUndBereitsBekannteNamen() {
        let rewe = Geschaeft(name: "Rewe", typ: .lebensmittel)

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
    func istIgnoriertErkenntTrefferBeiGleichemGeschaeftUndPassendemNamen() {
        let rewe = Geschaeft(name: "Rewe", typ: .lebensmittel)
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: rewe)

        #expect(IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: rewe, unter: [ignoriert]))
        #expect(IgnorierterArtikel.istIgnoriert("PFAND 0,25", geschaeft: rewe, unter: [ignoriert]))
    }

    @Test
    func istIgnoriertLiefertFalseBeiAnderemGeschaeftOderOhneGeschaeft() {
        let rewe = Geschaeft(name: "Rewe", typ: .lebensmittel)
        let edeka = Geschaeft(name: "Edeka", typ: .lebensmittel)
        let ignoriert = IgnorierterArtikel(erkannterName: "Pfand", geschaeft: rewe)

        #expect(!IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: edeka, unter: [ignoriert]))
        #expect(!IgnorierterArtikel.istIgnoriert("Pfand", geschaeft: nil, unter: [ignoriert]))
    }
}
