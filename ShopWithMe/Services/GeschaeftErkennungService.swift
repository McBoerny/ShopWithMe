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

    var name: String {
        switch self {
        case .bekannt(let geschaeft): return geschaeft.name
        case .unbekannt(let mapItem): return mapItem.name ?? "Unbekannter Laden"
        }
    }

    /// Koordinaten für ``IgnorierterGeschaeftsVorschlag``, sofern vorhanden — bei
    /// ``unbekannt(_:)`` immer der Apple-Maps-Standort, bei ``bekannt(_:)`` nur, wenn
    /// für das ``Geschaeft`` bereits ``Geschaeft/breitengrad``/``laengengrad``
    /// hinterlegt sind.
    var koordinaten: (breitengrad: Double, laengengrad: Double)? {
        switch self {
        case .bekannt(let geschaeft):
            guard let breitengrad = geschaeft.breitengrad, let laengengrad = geschaeft.laengengrad else { return nil }
            return (breitengrad, laengengrad)
        case .unbekannt(let mapItem):
            return (mapItem.location.coordinate.latitude, mapItem.location.coordinate.longitude)
        }
    }
}

/// Ein Eintrag in der Liste „Alle Geschäfte in der Nähe“
/// (``GeschaeftErkennungService/alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)``) —
/// im Unterschied zum automatischen Einzelvorschlag (``GeschaeftVorschlag``) bleiben
/// hier auch ignorierte Treffer sichtbar (``istIgnoriert``), damit der Anwender sie
/// über diese Liste wieder aufnehmen kann.
struct GeschaeftInDerNaeheEintrag: Identifiable {
    let id = UUID()
    let vorschlag: GeschaeftVorschlag
    let istIgnoriert: Bool
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

    /// Umkreis für „Alle Geschäfte in der Nähe“ (``alleInDerNaehe(vorhandeneGeschaefte:)``)
    /// — enger als ``suchradius``, da der Anwender hier bewusst und gezielt in einer
    /// kurzen, überschaubaren Liste stöbert statt automatisch einen einzelnen
    /// Vorschlag zu erhalten.
    static let alleInDerNaeheRadius: CLLocationDistance = 100

    /// Maximale Entfernung zwischen einem gespeicherten ``Geschaeft/breitengrad``/
    /// ``Geschaeft/laengengrad`` und einem Apple-Maps-Treffer, damit beide trotz
    /// unterschiedlichen Namens (z.B. nach Umbenennung) als dasselbe Geschäft gelten.
    static let koordinatenTreffertoleranz: CLLocationDistance = 75

    /// Fragt (falls nötig) die "Bei Nutzung"-Standortberechtigung an, ermittelt den
    /// aktuellen Standort einmalig und sucht in dessen Umkreis nach einem
    /// ``GeschaeftVorschlag``. Liefert `nil`, wenn keine Berechtigung erteilt wurde,
    /// der Standort nicht ermittelt werden konnte oder kein relevanter Laden in der
    /// Nähe ist (z.B. zu Hause) — dann wird bewusst nichts vorgeschlagen. Bereits
    /// über ``IgnorierterGeschaeftsVorschlag`` ignorierte Treffer (siehe
    /// ``istIgnoriert(_:ignorierte:)``) werden vorher aussortiert und deshalb auch
    /// nie erneut automatisch vorgeschlagen.
    @MainActor
    static func vorschlag(
        vorhandeneGeschaefte: [Geschaeft],
        ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag] = []
    ) async -> GeschaeftVorschlag? {
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        guard let treffer = try? await nahegelegeneLaeden(bei: standort, radius: suchradius), !treffer.isEmpty else { return nil }
        let relevante = treffer.filter { !istIgnoriert($0, ignorierte: ignorierteVorschlaege) }
        return passendenVorschlag(aus: relevante, standort: standort, vorhandeneGeschaefte: vorhandeneGeschaefte)
    }

    /// Sucht (unabhängig vom automatischen Einzelvorschlag) alle Läden im engeren
    /// ``alleInDerNaeheRadius``-Umkreis, sortiert nach Entfernung — Grundlage für
    /// „Alle Geschäfte in der Nähe“, mit der der Anwender nachträglich manuell
    /// auswählen oder einen zuvor ignorierten Vorschlag wieder aufnehmen kann. Anders
    /// als ``vorschlag(vorhandeneGeschaefte:ignorierteVorschlaege:)`` werden ignorierte
    /// Treffer hier bewusst NICHT aussortiert, sondern zusammen mit ihrem
    /// Ignoriert-Status geliefert. Liefert `nil` ohne Standortberechtigung.
    @MainActor
    static func alleInDerNaehe(
        vorhandeneGeschaefte: [Geschaeft],
        ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag]
    ) async -> [GeschaeftInDerNaeheEintrag]? {
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        guard let treffer = try? await nahegelegeneLaeden(bei: standort, radius: alleInDerNaeheRadius) else { return nil }
        let sortiert = treffer.sorted { entfernung(zu: $0, von: standort) < entfernung(zu: $1, von: standort) }
        let eintraege = sortiert.map { item -> GeschaeftInDerNaeheEintrag in
            let vorschlag: GeschaeftVorschlag
            if let bekanntesGeschaeft = vorhandeneGeschaefte.first(where: { istBekannterTreffer($0, fuer: item) }) {
                vorschlag = .bekannt(bekanntesGeschaeft)
            } else {
                vorschlag = .unbekannt(item)
            }
            return GeschaeftInDerNaeheEintrag(vorschlag: vorschlag, istIgnoriert: istIgnoriert(item, ignorierte: ignorierteVorschlaege))
        }
        return dedupliziert(eintraege)
    }

    /// Apple Maps liefert für denselben physischen Laden gelegentlich mehrere
    /// `MKMapItem`-Treffer (z.B. unter leicht unterschiedlichen POI-Kategorien) — ohne
    /// Deduplizierung würde ``alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)``
    /// dasselbe (ggf. ignorierte) ``Geschaeft``/denselben unbekannten Laden mehrfach
    /// auflisten. Behält jeweils den ersten (nächstgelegenen, da `treffer` vorher nach
    /// Entfernung sortiert ist) Eintrag pro identifiziertem Laden.
    /// `internal` statt `private` (wie ``passendenVorschlag(aus:standort:vorhandeneGeschaefte:)``),
    /// damit die Deduplizierung ohne echtes CoreLocation/MapKit direkt getestet werden kann.
    static func dedupliziert(_ eintraege: [GeschaeftInDerNaeheEintrag]) -> [GeschaeftInDerNaeheEintrag] {
        var ergebnis: [GeschaeftInDerNaeheEintrag] = []
        for eintrag in eintraege where !ergebnis.contains(where: { istSelberLaden($0.vorschlag, eintrag.vorschlag) }) {
            ergebnis.append(eintrag)
        }
        return ergebnis
    }

    /// Zwei ``GeschaeftVorschlag``e gelten als derselbe Laden, wenn sie auf dasselbe
    /// ``Geschaeft`` verweisen, oder (mind. einer davon `unbekannt`) bei Namens- ODER
    /// Koordinatenübereinstimmung — analog ``istBekannterTreffer(_:fuer:)``.
    private static func istSelberLaden(_ a: GeschaeftVorschlag, _ b: GeschaeftVorschlag) -> Bool {
        if case .bekannt(let g1) = a, case .bekannt(let g2) = b {
            return g1.persistentModelID == g2.persistentModelID
        }
        if a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame { return true }
        if let ka = a.koordinaten, let kb = b.koordinaten {
            let ortA = CLLocation(latitude: ka.breitengrad, longitude: ka.laengengrad)
            let ortB = CLLocation(latitude: kb.breitengrad, longitude: kb.laengengrad)
            return ortA.distance(from: ortB) < koordinatenTreffertoleranz
        }
        return false
    }

    /// Baut aus einem per Ladenerkennung gefundenen, noch unbekannten Laden einen
    /// Geschäfts-Entwurf zur Übernahme in ``GeschaeftStammdatenEditView`` — inkl.
    /// geschätztem ``GeschaeftTyp`` und den Koordinaten für künftiges
    /// Koordinaten-Matching (siehe ``koordinatenTreffertoleranz``).
    static func entwurf(aus mapItem: MKMapItem) -> Geschaeft {
        let geschaeft = Geschaeft(
            name: mapItem.name ?? "Neues Geschäft",
            typ: typVorschlag(fuer: mapItem.pointOfInterestCategory),
            adresse: mapItem.address?.fullAddress
        )
        geschaeft.breitengrad = mapItem.location.coordinate.latitude
        geschaeft.laengengrad = mapItem.location.coordinate.longitude
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
    private static func nahegelegeneLaeden(bei standort: CLLocation, radius: CLLocationDistance) async throws -> [MKMapItem] {
        let anfrage = MKLocalPointsOfInterestRequest(center: standort.coordinate, radius: radius)
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
            if gespeicherterOrt.distance(from: item.location) < koordinatenTreffertoleranz { return true }
        }
        return false
    }

    /// Prüft, ob `item` einem vom Anwender ignorierten Vorschlag (siehe
    /// ``IgnorierterGeschaeftsVorschlag``) entspricht — Namens- ODER
    /// Koordinatenübereinstimmung genügt, analog ``istBekannterTreffer(_:fuer:)``.
    static func istIgnoriert(_ item: MKMapItem, ignorierte: [IgnorierterGeschaeftsVorschlag]) -> Bool {
        ignorierte.contains { ignoriert in
            if let name = item.name, ignoriert.name.localizedCaseInsensitiveCompare(name) == .orderedSame {
                return true
            }
            if let breitengrad = ignoriert.breitengrad, let laengengrad = ignoriert.laengengrad {
                let ort = CLLocation(latitude: breitengrad, longitude: laengengrad)
                if ort.distance(from: item.location) < koordinatenTreffertoleranz { return true }
            }
            return false
        }
    }

    /// Alle `ignorierte`-Einträge, die zu `vorschlag` passen (Namens- ODER
    /// Koordinatenübereinstimmung) — Grundlage für „Wieder aufnehmen“ in „Alle
    /// Geschäfte in der Nähe“, das diese Einträge wieder löscht.
    static func ignorierteEintraege(
        fuer vorschlag: GeschaeftVorschlag,
        in ignorierte: [IgnorierterGeschaeftsVorschlag]
    ) -> [IgnorierterGeschaeftsVorschlag] {
        ignorierte.filter { eintrag in
            if eintrag.name.localizedCaseInsensitiveCompare(vorschlag.name) == .orderedSame { return true }
            if let koordinaten = vorschlag.koordinaten,
               let breitengrad = eintrag.breitengrad, let laengengrad = eintrag.laengengrad {
                let ignoriertOrt = CLLocation(latitude: breitengrad, longitude: laengengrad)
                let vorschlagOrt = CLLocation(latitude: koordinaten.breitengrad, longitude: koordinaten.laengengrad)
                return ignoriertOrt.distance(from: vorschlagOrt) < koordinatenTreffertoleranz
            }
            return false
        }
    }

    static func entfernung(zu item: MKMapItem, von standort: CLLocation) -> CLLocationDistance {
        standort.distance(from: item.location)
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
