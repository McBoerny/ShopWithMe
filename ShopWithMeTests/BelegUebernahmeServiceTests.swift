import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``BelegUebernahmeService`` (GitHub #107/#109, extrahiert aus
/// `BelegScanView.uebernehmen()`) — deckt die drei ``BelegScanKontext``-
/// Verzweigungen, die Tages-Kollisionsbehandlung (GitHub #76-Folgearbeit),
/// die automatische Produkt-Neuanlage und die Regressionsschutz-Fälle für
/// zwischenzeitlich gelöschte Referenzen (gleiche Bug-Klasse wie GitHub #100) ab.
@MainActor
struct BelegUebernahmeServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: SchemaDefinition.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SchemaDefinition.schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    /// Baut eine Standard-Position für "Zahnpasta", 3,10 €, ohne bereits
    /// zugeordnetes Produkt — Grundlage für die meisten Testfälle.
    private func position(
        artikelName: String = "Zahnpasta",
        erkannterName: String = "COLGATE TOTAL",
        produktKlarname: String = "Colgate Total",
        preisText: String = "3.10",
        zugeordneterArtikel: Artikel? = nil,
        zugeordnetesProdukt: Produkt? = nil,
        bestehenderPreisHeute: Decimal? = nil,
        behalteBestehendenPreisHeute: Bool = false
    ) -> BearbeitbarePosition {
        BearbeitbarePosition(
            erkannterName: erkannterName,
            artikelName: artikelName,
            produktKlarname: produktKlarname,
            preisText: preisText,
            zugeordneterArtikel: zugeordneterArtikel,
            zugeordnetesProdukt: zugeordnetesProdukt,
            zuordnungsQuelle: nil,
            boundingBox: nil,
            bestehenderPreisHeute: bestehenderPreisHeute,
            behalteBestehendenPreisHeute: behalteBestehendenPreisHeute
        )
    }

    // MARK: - .einkaufsvorgang: neuer KaufEintrag + Preispunkt

    @Test
    func einkaufsvorgangOhneVorhandenenEintragLegtKaufEintragUndPreispunktAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(vorgang)

        let pos = position(zugeordneterArtikel: artikel)
        BelegUebernahmeService.uebernehmen(
            kontext: .einkaufsvorgang(vorgang),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: ModelReference(vorgang),
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [nil],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(vorgang.kaufEintraege.count == 1)
        #expect(vorgang.kaufEintraege.first?.artikel == artikel)
        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 1)
        #expect(artikel.produkte.contains { $0.name == "Colgate Total" })
    }

    // MARK: - .einkaufsvorgang: bereits abgehakter KaufEintrag wird nur im Datum aktualisiert

    @Test
    func einkaufsvorgangMitVorhandenemEintragAktualisiertNurDasDatum() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(vorgang)
        let altesDatum = Date().addingTimeInterval(-86_400)
        let vorhandenerEintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, datum: altesDatum)
        context.insert(vorhandenerEintrag)
        vorhandenerEintrag.einkaufsvorgang = vorgang

        let neuesDatum = Date()
        let pos = position(zugeordneterArtikel: artikel)
        BelegUebernahmeService.uebernehmen(
            kontext: .einkaufsvorgang(vorgang),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: ModelReference(vorgang),
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: neuesDatum,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [nil],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(vorgang.kaufEintraege.count == 1)
        #expect(vorgang.kaufEintraege.first === vorhandenerEintrag)
        #expect(vorhandenerEintrag.datum == neuesDatum)
    }

    // MARK: - .geschaeft: nur Preispunkt, kein KaufEintrag

    @Test
    func geschaeftKontextLegtNurPreispunktAnOhneKaufEintrag() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let pos = position(zugeordneterArtikel: artikel)
        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [nil],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 1)
    }

    // MARK: - .unbekannt ohne aufgelöstes Geschäft: Position wird übersprungen

    @Test
    func unbekannterKontextOhneGeschaeftUeberspringtPosition() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)

        let pos = position(zugeordneterArtikel: artikel)
        BelegUebernahmeService.uebernehmen(
            kontext: .unbekannt,
            erkanntesGeschaeftReferenz: nil,
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [nil],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 0)
    }

    // MARK: - Tages-Kollision: "Bisherigen behalten" verwirft den neu erkannten Preis

    @Test
    func tagesKollisionBehaltBestehendenLegtKeinenNeuenPreispunktAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let produkt = Produkt(name: "Colgate Total", artikel: artikel)
        context.insert(produkt)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let bestehenderPunkt = Preispunkt(produkt: produkt, geschaeft: geschaeft, preis: 2.99, datum: .now)
        context.insert(bestehenderPunkt)

        let pos = position(
            preisText: "3.10", zugeordneterArtikel: artikel, zugeordnetesProdukt: produkt,
            bestehenderPreisHeute: 2.99, behalteBestehendenPreisHeute: true
        )
        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [ModelReference(produkt)],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 1)
        #expect(produkt.preispunkte.first?.preis == 2.99)
    }

    // MARK: - Tages-Kollision: Standard ersetzt den bestehenden Punkt

    @Test
    func tagesKollisionStandardErsetztBestehendenPunkt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let produkt = Produkt(name: "Colgate Total", artikel: artikel)
        context.insert(produkt)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let bestehenderPunkt = Preispunkt(produkt: produkt, geschaeft: geschaeft, preis: 2.99, datum: .now)
        context.insert(bestehenderPunkt)

        let pos = position(
            preisText: "3.10", zugeordneterArtikel: artikel, zugeordnetesProdukt: produkt,
            bestehenderPreisHeute: 2.99, behalteBestehendenPreisHeute: false
        )
        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [ModelReference(produkt)],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        let punkte = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(punkte.count == 1)
        #expect(punkte.first?.preis == 3.10)
    }

    // MARK: - Automatische Produkt-Neuanlage nur, wenn noch kein Produkt zugeordnet ist

    @Test
    func nutztBereitsZugeordnetesProduktStattNeuAnzulegen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let produkt = Produkt(name: "Colgate Total", artikel: artikel)
        context.insert(produkt)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let pos = position(zugeordneterArtikel: artikel, zugeordnetesProdukt: produkt)
        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [ModelReference(produkt)],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(artikel.produkte.count == 1)
        #expect(produkt.preispunkte.count == 1)
    }

    // MARK: - Geschäfts-Adresse/Alias werden gelernt

    @Test
    func lerntFehlendeAdresseUndAlternativenNamen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "REWE Musterstadt",
            getrimmteErkannteAdresse: "Musterstraße 1, 12345 Musterstadt",
            gelernteKoordinaten: (breitengrad: 52.5, laengengrad: 13.4),
            belegDatum: .now,
            positionen: [],
            positionsArtikelReferenzen: [],
            positionsProduktReferenzen: [],
            positionsKlarnamen: [],
            context: context
        )

        #expect(geschaeft.adresse == "Musterstraße 1, 12345 Musterstadt")
        #expect(geschaeft.breitengrad == 52.5)
        #expect(geschaeft.alternativeNamen.contains("REWE Musterstadt"))
    }

    // MARK: - Regressionsschutz: zwischenzeitlich gelöschter Einkaufsvorgang (GitHub #100-Bug-Klasse)

    @Test
    func geloeschterEinkaufsvorgangUeberspringtPositionOhneAbsturz() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikel = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikel)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(vorgang)
        try context.save()
        // Referenz VOR dem Löschen bauen — genau das Muster, das der Aufrufer
        // (`BelegScanView.uebernehmen()`) einhalten muss.
        let vorgangReferenz = ModelReference(vorgang)
        context.delete(vorgang)
        try context.save()

        let pos = position(zugeordneterArtikel: artikel)
        BelegUebernahmeService.uebernehmen(
            kontext: .einkaufsvorgang(vorgang),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: vorgangReferenz,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [pos],
            positionsArtikelReferenzen: [ModelReference(artikel)],
            positionsProduktReferenzen: [nil],
            positionsKlarnamen: ["Colgate Total"],
            context: context
        )

        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 0)
    }

    // MARK: - Position ohne Preis wird übersprungen, restliche Positionen bleiben unberührt

    @Test
    func positionOhnePreisWirdUebersprungenAndereNichtBeeintraechtigt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let artikelOhnePreis = Artikel(name: "Kaugummi", symbolName: "sparkles", farbeHex: "#000000")
        let artikelMitPreis = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#000000")
        context.insert(artikelOhnePreis)
        context.insert(artikelMitPreis)
        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let posOhnePreis = position(artikelName: "Kaugummi", preisText: "", zugeordneterArtikel: artikelOhnePreis)
        let posMitPreis = position(artikelName: "Zahnpasta", zugeordneterArtikel: artikelMitPreis)
        BelegUebernahmeService.uebernehmen(
            kontext: .geschaeft(geschaeft),
            erkanntesGeschaeftReferenz: ModelReference(geschaeft),
            einkaufsvorgangReferenz: nil,
            erkannterGeschaeftName: "",
            getrimmteErkannteAdresse: "",
            gelernteKoordinaten: nil,
            belegDatum: .now,
            positionen: [posOhnePreis, posMitPreis],
            positionsArtikelReferenzen: [ModelReference(artikelOhnePreis), ModelReference(artikelMitPreis)],
            positionsProduktReferenzen: [nil, nil],
            positionsKlarnamen: ["Kaugummi", "Colgate Total"],
            context: context
        )

        #expect(try context.fetchCount(FetchDescriptor<Preispunkt>()) == 1)
        #expect(artikelOhnePreis.produkte.isEmpty)
    }
}
