import CoreLocation
import MapKit
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct GeschaeftErkennungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Geschaeft.self, GeschaeftTyp.self, ArtikelKategorie.self, SyncEvent.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    private func mapItem(name: String, latitude: CLLocationDegrees, longitude: CLLocationDegrees) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }

    @Test
    func erkenntBereitsAngelegtesGeschaeftAnhandDesNamens() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let rewe = Geschaeft(name: "Rewe am Markt", typen: [lebensmittelTyp()])
        context.insert(rewe)

        let standort = CLLocation(latitude: 52.5, longitude: 13.4)
        let treffer = mapItem(name: "REWE", latitude: 52.5, longitude: 13.4)

        let vorschlag = GeschaeftErkennungService.passendenVorschlag(
            aus: [treffer], standort: standort, vorhandeneGeschaefte: [rewe]
        )

        guard case .bekannt(let erkanntesGeschaeft) = vorschlag else {
            Issue.record("Erwartet .bekannt, erhalten \(String(describing: vorschlag))")
            return
        }
        #expect(erkanntesGeschaeft === rewe)
    }

    @Test
    func erkenntBereitsAngelegtesGeschaeftAnhandDerKoordinatenTrotzAbweichendemNamen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Mein Supermarkt", typen: [lebensmittelTyp()])
        geschaeft.breitengrad = 52.5
        geschaeft.laengengrad = 13.4
        context.insert(geschaeft)

        let standort = CLLocation(latitude: 52.5, longitude: 13.4)
        let treffer = mapItem(name: "Edeka Meyer", latitude: 52.5001, longitude: 13.4001)

        let vorschlag = GeschaeftErkennungService.passendenVorschlag(
            aus: [treffer], standort: standort, vorhandeneGeschaefte: [geschaeft]
        )

        guard case .bekannt(let erkanntesGeschaeft) = vorschlag else {
            Issue.record("Erwartet .bekannt, erhalten \(String(describing: vorschlag))")
            return
        }
        #expect(erkanntesGeschaeft === geschaeft)
    }

    @Test
    func schlaegtNaechstgelegenenUnbekanntenLadenVor() throws {
        let ferner = mapItem(name: "Ferner Laden", latitude: 52.51, longitude: 13.41)
        let naeher = mapItem(name: "Näherer Laden", latitude: 52.5001, longitude: 13.4001)
        let standort = CLLocation(latitude: 52.5, longitude: 13.4)

        let vorschlag = GeschaeftErkennungService.passendenVorschlag(
            aus: [ferner, naeher], standort: standort, vorhandeneGeschaefte: []
        )

        guard case .unbekannt(let mapItem) = vorschlag else {
            Issue.record("Erwartet .unbekannt, erhalten \(String(describing: vorschlag))")
            return
        }
        #expect(mapItem.name == "Näherer Laden")
    }

    @Test
    func liefertNilOhneTreffer() {
        let standort = CLLocation(latitude: 52.5, longitude: 13.4)
        let vorschlag = GeschaeftErkennungService.passendenVorschlag(aus: [], standort: standort, vorhandeneGeschaefte: [])
        #expect(vorschlag == nil)
    }

    @Test
    func entwurfUebernimmtNamenAdresseUndKoordinaten() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4))
        let item = MKMapItem(placemark: placemark)
        item.name = "Bio-Markt"

        let entwurf = GeschaeftErkennungService.entwurf(aus: item, context: context)

        #expect(entwurf.name == "Bio-Markt")
        #expect(entwurf.breitengrad == 52.5)
        #expect(entwurf.laengengrad == 13.4)
    }

    @Test
    func ignorierterTrefferWirdAnhandDesNamensErkannt() {
        let treffer = mapItem(name: "Bio-Markt", latitude: 52.6, longitude: 13.5)
        let ignoriert = IgnorierterGeschaeftsVorschlag(name: "Bio-Markt", breitengrad: nil, laengengrad: nil)

        #expect(GeschaeftErkennungService.istIgnoriert(treffer, ignorierte: [ignoriert]))
    }

    @Test
    func ignorierterTrefferWirdAnhandDerKoordinatenErkannt() {
        let treffer = mapItem(name: "Neuer Name", latitude: 52.5001, longitude: 13.4001)
        let ignoriert = IgnorierterGeschaeftsVorschlag(name: "Alter Name", breitengrad: 52.5, laengengrad: 13.4)

        #expect(GeschaeftErkennungService.istIgnoriert(treffer, ignorierte: [ignoriert]))
    }

    @Test
    func nichtIgnorierterTrefferWirdNichtErkannt() {
        let treffer = mapItem(name: "Anderer Laden", latitude: 52.9, longitude: 13.9)
        let ignoriert = IgnorierterGeschaeftsVorschlag(name: "Bio-Markt", breitengrad: 52.5, laengengrad: 13.4)

        #expect(!GeschaeftErkennungService.istIgnoriert(treffer, ignorierte: [ignoriert]))
    }

    @Test
    func vorschlagMitIgnoriertemTrefferWirdAussortiert() {
        let ferner = mapItem(name: "Ferner Laden", latitude: 52.51, longitude: 13.41)
        let ignorierterNaeherer = mapItem(name: "Ignorierter Laden", latitude: 52.5001, longitude: 13.4001)
        let standort = CLLocation(latitude: 52.5, longitude: 13.4)
        let ignoriert = IgnorierterGeschaeftsVorschlag(name: "Ignorierter Laden", breitengrad: nil, laengengrad: nil)

        let relevante = [ferner, ignorierterNaeherer].filter { !GeschaeftErkennungService.istIgnoriert($0, ignorierte: [ignoriert]) }
        let vorschlag = GeschaeftErkennungService.passendenVorschlag(aus: relevante, standort: standort, vorhandeneGeschaefte: [])

        guard case .unbekannt(let mapItem) = vorschlag else {
            Issue.record("Erwartet .unbekannt, erhalten \(String(describing: vorschlag))")
            return
        }
        #expect(mapItem.name == "Ferner Laden")
    }

    @Test
    func dedupliziertDoppelteApppleMapsTrefferDesselbenBekanntenGeschaefts() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let rewe = Geschaeft(name: "Rewe am Markt", typen: [lebensmittelTyp()])
        context.insert(rewe)

        // Zwei Apple-Maps-Einträge für denselben physischen Laden (z.B. unter
        // leicht unterschiedlichen POI-Kategorien) — beide matchen `rewe`.
        let eintraege = [
            GeschaeftInDerNaeheEintrag(vorschlag: .bekannt(rewe), istIgnoriert: false),
            GeschaeftInDerNaeheEintrag(vorschlag: .bekannt(rewe), istIgnoriert: true),
        ]

        let dedupliziert = GeschaeftErkennungService.dedupliziert(eintraege)

        #expect(dedupliziert.count == 1)
    }

    @Test
    func dedupliziertDoppelteApppleMapsTrefferDesselbenUnbekanntenLadensAnhandDesNamens() {
        let a = mapItem(name: "Bio-Markt", latitude: 52.5, longitude: 13.4)
        let b = mapItem(name: "Bio-Markt", latitude: 52.5002, longitude: 13.4002)
        let eintraege = [
            GeschaeftInDerNaeheEintrag(vorschlag: .unbekannt(a), istIgnoriert: false),
            GeschaeftInDerNaeheEintrag(vorschlag: .unbekannt(b), istIgnoriert: false),
        ]

        let dedupliziert = GeschaeftErkennungService.dedupliziert(eintraege)

        #expect(dedupliziert.count == 1)
    }

    @Test
    func behaeltVerschiedeneLaedenBeimDeduplizieren() {
        let a = mapItem(name: "Bio-Markt", latitude: 52.5, longitude: 13.4)
        let b = mapItem(name: "Anderer Laden", latitude: 52.9, longitude: 13.9)
        let eintraege = [
            GeschaeftInDerNaeheEintrag(vorschlag: .unbekannt(a), istIgnoriert: false),
            GeschaeftInDerNaeheEintrag(vorschlag: .unbekannt(b), istIgnoriert: false),
        ]

        let dedupliziert = GeschaeftErkennungService.dedupliziert(eintraege)

        #expect(dedupliziert.count == 2)
    }

    @Test
    func dedupliziertBekanntenTrefferOhneKoordinatenGegenUnbekanntenPerNamensTeilstring() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        // Manuell angelegtes Geschäft ohne gespeicherten Standort (breitengrad/
        // laengengrad nil) — der Koordinatenabgleich in `istSelberLaden` kann hier
        // nicht greifen, nur der (Teilstring-)Namensabgleich. Vor der Konsolidierung
        // auf `istGleicherOrt` prüfte `istSelberLaden` nur exakte Namensgleichheit
        // und hätte diesen Fall fälschlich als zwei verschiedene Läden gelistet.
        let bioEcke = Geschaeft(name: "Bio Ecke", typen: [lebensmittelTyp()])
        context.insert(bioEcke)

        // Ein zweiter Apple-Maps-Treffer für denselben physischen Laden, dessen Name
        // "Bio Ecke" als Teilstring enthält, aber nicht exakt gleich ist.
        let unbekannterTreffer = mapItem(name: "Bio Ecke Frankfurt", latitude: 52.5, longitude: 13.4)

        let eintraege = [
            GeschaeftInDerNaeheEintrag(vorschlag: .bekannt(bioEcke), istIgnoriert: false),
            GeschaeftInDerNaeheEintrag(vorschlag: .unbekannt(unbekannterTreffer), istIgnoriert: false),
        ]

        let dedupliziert = GeschaeftErkennungService.dedupliziert(eintraege)

        #expect(dedupliziert.count == 1)
    }

    @Test
    func erkenntGeschaeftNurMitVergroessertemIndividuellenRadius() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let geschaeft = Geschaeft(name: "Handelshof", typen: [lebensmittelTyp()])
        geschaeft.breitengrad = 52.5
        geschaeft.laengengrad = 13.4
        context.insert(geschaeft)

        // ~200m entfernt (Namen bewusst ohne jede Teilstring-Überschneidung, damit
        // nur der Koordinatenabgleich greift) — außerhalb der globalen
        // Standardtoleranz (75m), aber innerhalb eines individuell größeren Radius.
        let treffer = mapItem(name: "Nordmarkt", latitude: 52.5018, longitude: 13.4)

        #expect(GeschaeftErkennungService.istBekannterTreffer(geschaeft, fuer: treffer) == false)

        geschaeft.erkennungsradius = 300
        #expect(GeschaeftErkennungService.istBekannterTreffer(geschaeft, fuer: treffer) == true)
    }

    @Test
    func effektiverSuchradiusErweitertSichAufGroesstenIndividuellenRadius() {
        let a = Geschaeft(name: "A", typen: [lebensmittelTyp()])
        let b = Geschaeft(name: "B", typen: [lebensmittelTyp()])
        b.erkennungsradius = 400

        let radius = GeschaeftErkennungService.effektiverSuchradius(basis: 150, vorhandeneGeschaefte: [a, b])

        #expect(radius == 400)
    }

    @Test
    func effektiverSuchradiusBleibtBeiBasisOhneIndividuelleRadien() {
        let a = Geschaeft(name: "A", typen: [lebensmittelTyp()])

        let radius = GeschaeftErkennungService.effektiverSuchradius(basis: 150, vorhandeneGeschaefte: [a])

        #expect(radius == 150)
    }
}
