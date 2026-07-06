import CoreLocation
import MapKit

/// Ergebnis der Standort-basierten Ladenerkennung (``GeschaeftErkennungService``) —
/// entweder ein bereits in der eigenen Liste angelegtes ``Geschaeft`` oder ein von
/// Apple Maps bekannter Laden, der dort noch fehlt.
enum GeschaeftVorschlag {
    /// Ein bereits angelegtes ``Geschaeft`` wurde in der Nähe erkannt.
    case bekannt(Geschaeft)
    /// Ein von Apple Maps bekannter Laden in der Nähe wurde erkannt, der noch nicht in
    /// der eigenen Geschäfte-Liste existiert.
    case unbekannt(MKMapItem)
}

/// Erkennt anhand des aktuellen Standorts, ob sich der Anwender bei einem bekannten
/// Laden (Apple Maps) befindet — Grundlage für den automatischen Geschäfts-Vorschlag
/// in ``EinkaufenView``. Details, insbesondere die bewusste Beschränkung auf eine
/// einmalige Standortabfrage ohne Hintergrund-Tracking, in
/// `docs/GESCHAEFTSERKENNUNG.md`.
enum GeschaeftErkennungService {
    /// Kategorien, die für die Ladenerkennung relevant sind — bewusst auf Einzelhandel
    /// beschränkt (keine Restaurants, Museen, Tankstellen o.ä.).
    static let relevanteKategorien: [MKPointOfInterestCategory] = [
        .foodMarket, .store, .pharmacy, .bakery, .winery, .brewery,
    ]

    /// Umkreis in Metern, in dem nach bekannten Läden gesucht wird.
    static let suchradius: CLLocationDistance = 150

    /// Maximale Entfernung zwischen einem gespeicherten ``Geschaeft/breitengrad``/
    /// ``Geschaeft/laengengrad`` und einem Apple-Maps-Treffer, damit beide trotz
    /// unterschiedlichen Namens (z.B. nach Umbenennung) als dasselbe Geschäft gelten.
    static let koordinatenTreffertoleranz: CLLocationDistance = 75

    /// Fragt (falls nötig) die "Bei Nutzung"-Standortberechtigung an, ermittelt den
    /// aktuellen Standort einmalig und sucht in dessen Umkreis nach einem
    /// ``GeschaeftVorschlag``. Liefert `nil`, wenn keine Berechtigung erteilt wurde,
    /// der Standort nicht ermittelt werden konnte oder kein relevanter Laden in der
    /// Nähe ist (z.B. zu Hause) — dann wird bewusst nichts vorgeschlagen.
    @MainActor
    static func vorschlag(vorhandeneGeschaefte: [Geschaeft]) async -> GeschaeftVorschlag? {
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        guard let treffer = try? await nahegelegeneLaeden(bei: standort), !treffer.isEmpty else { return nil }
        return passendenVorschlag(aus: treffer, standort: standort, vorhandeneGeschaefte: vorhandeneGeschaefte)
    }

    /// Baut aus einem per Ladenerkennung gefundenen, noch unbekannten Laden einen
    /// Geschäfts-Entwurf zur Übernahme in ``GeschaeftStammdatenEditView`` — inkl.
    /// geschätztem ``GeschaeftTyp`` und den Koordinaten für künftiges
    /// Koordinaten-Matching (siehe ``koordinatenTreffertoleranz``).
    static func entwurf(aus mapItem: MKMapItem) -> Geschaeft {
        let geschaeft = Geschaeft(
            name: mapItem.name ?? "Neues Geschäft",
            typ: typVorschlag(fuer: mapItem.pointOfInterestCategory),
            adresse: mapItem.placemark.title
        )
        geschaeft.breitengrad = mapItem.placemark.coordinate.latitude
        geschaeft.laengengrad = mapItem.placemark.coordinate.longitude
        return geschaeft
    }

    private static func typVorschlag(fuer kategorie: MKPointOfInterestCategory?) -> GeschaeftTyp {
        switch kategorie {
        case .pharmacy: return .apotheke
        case .foodMarket, .bakery: return .lebensmittel
        case .winery, .brewery: return .getraenkemarkt
        default: return .sonstiges
        }
    }

    @MainActor
    private static func nahegelegeneLaeden(bei standort: CLLocation) async throws -> [MKMapItem] {
        let anfrage = MKLocalPointsOfInterestRequest(center: standort.coordinate, radius: suchradius)
        anfrage.pointOfInterestFilter = MKPointOfInterestFilter(including: relevanteKategorien)
        let antwort = try await MKLocalSearch(request: anfrage).start()
        return antwort.mapItems
    }

    /// Sucht unter `treffer` (nach Entfernung zu `standort` sortiert) zuerst nach
    /// einem bereits bekannten ``Geschaeft`` (Namens- oder Koordinatenübereinstimmung,
    /// siehe ``istBekannterTreffer(_:fuer:)``); findet sich keines, wird der
    /// nächstgelegene Treffer als neuer, unbekannter Laden vorgeschlagen. `internal`
    /// statt `private`, damit die Zuordnungslogik ohne echtes CoreLocation/MapKit
    /// direkt getestet werden kann (siehe `GeschaeftErkennungServiceTests`).
    static func passendenVorschlag(
        aus treffer: [MKMapItem],
        standort: CLLocation,
        vorhandeneGeschaefte: [Geschaeft]
    ) -> GeschaeftVorschlag? {
        let sortiert = treffer.sorted { entfernung(zu: $0, von: standort) < entfernung(zu: $1, von: standort) }
        for item in sortiert {
            if let bekanntesGeschaeft = vorhandeneGeschaefte.first(where: { istBekannterTreffer($0, fuer: item) }) {
                return .bekannt(bekanntesGeschaeft)
            }
        }
        guard let naechster = sortiert.first else { return nil }
        return .unbekannt(naechster)
    }

    static func istBekannterTreffer(_ geschaeft: Geschaeft, fuer item: MKMapItem) -> Bool {
        if let name = item.name {
            if geschaeft.name.localizedCaseInsensitiveCompare(name) == .orderedSame { return true }
            if geschaeft.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(geschaeft.name) {
                return true
            }
        }
        if let breitengrad = geschaeft.breitengrad, let laengengrad = geschaeft.laengengrad {
            let gespeicherterOrt = CLLocation(latitude: breitengrad, longitude: laengengrad)
            let itemOrt = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
            if gespeicherterOrt.distance(from: itemOrt) < koordinatenTreffertoleranz { return true }
        }
        return false
    }

    static func entfernung(zu item: MKMapItem, von standort: CLLocation) -> CLLocationDistance {
        let itemOrt = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        return standort.distance(from: itemOrt)
    }
}

/// Kapselt eine einmalige Standortabfrage (inkl. Berechtigungsanfrage, falls noch
/// nicht entschieden) hinter einer `async`-Schnittstelle. Fragt bewusst nur die
/// "Bei Nutzung"-Berechtigung an und läuft kein Hintergrund-Tracking — siehe
/// `docs/GESCHAEFTSERKENNUNG.md`.
private final class EinmaligerStandortAbruf: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var standortContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func standortErmitteln() async -> CLLocation? {
        await berechtigungSicherstellen()
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            standortContinuation = continuation
            manager.requestLocation()
        }
    }

    private func berechtigungSicherstellen() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authContinuation?.resume()
        authContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        standortContinuation?.resume(returning: locations.last)
        standortContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        standortContinuation?.resume(returning: nil)
        standortContinuation = nil
    }
}
