import CoreLocation
import MapKit
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct GeschaeftErkennungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Geschaeft.self, Regal.self, ArtikelKategorie.self])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

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
        let rewe = Geschaeft(name: "Rewe am Markt", typ: .lebensmittel)
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
        let geschaeft = Geschaeft(name: "Mein Supermarkt", typ: .lebensmittel)
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
    func entwurfUebernimmtNamenAdresseUndKoordinaten() {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4))
        let item = MKMapItem(placemark: placemark)
        item.name = "Bio-Markt"

        let entwurf = GeschaeftErkennungService.entwurf(aus: item)

        #expect(entwurf.name == "Bio-Markt")
        #expect(entwurf.breitengrad == 52.5)
        #expect(entwurf.laengengrad == 13.4)
    }
}
