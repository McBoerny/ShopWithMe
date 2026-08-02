import CoreLocation
import MapKit
import SwiftData

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

    /// Beschriftung des primären Aktions-Buttons in ``GeschaeftVorschlagBanner`` und
    /// ``GeschaeftInDerNaeheZeile``.
    var aktionsTitel: String {
        switch self {
        case .bekannt: return "Auswählen"
        case .unbekannt: return "Hinzufügen"
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
    /// `var` statt `let`, damit ``GeschaeftAlleInDerNaeheSheet`` nach „Wieder
    /// aufnehmen“ den Ignoriert-Status optimistisch lokal aktualisieren kann, ohne
    /// die ganze Liste neu von ``GeschaeftErkennungService`` abzufragen.
    var istIgnoriert: Bool
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

    /// Standard-Umkreis in Metern, in dem nach bekannten Läden gesucht wird.
    static let standardSuchradius: CLLocationDistance = 150

    /// Standard-Umkreis für „Alle Geschäfte in der Nähe“
    /// (``alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)``) — enger als
    /// ``standardSuchradius``, da der Anwender hier bewusst und gezielt in einer
    /// kurzen, überschaubaren Liste stöbert statt automatisch einen einzelnen
    /// Vorschlag zu erhalten.
    static let standardAlleInDerNaeheRadius: CLLocationDistance = 100

    /// Umkreis in Metern, in dem nach bekannten Läden gesucht wird — in Debug-Builds
    /// über ``DebugEinstellungen/sucheRadiusUeberschreibung`` testweise erhöhbar
    /// (siehe `docs/GESCHAEFTSERKENNUNG.md`), in Release-Builds immer
    /// ``standardSuchradius``.
    static var suchradius: CLLocationDistance {
        #if DEBUG
        DebugEinstellungen.sucheRadiusUeberschreibung ?? standardSuchradius
        #else
        standardSuchradius
        #endif
    }

    /// Umkreis für „Alle Geschäfte in der Nähe“ — dieselbe Debug-Überschreibung wie
    /// ``suchradius``, damit sich beide Ladenerkennungs-Wege gemeinsam testen lassen.
    static var alleInDerNaeheRadius: CLLocationDistance {
        #if DEBUG
        DebugEinstellungen.sucheRadiusUeberschreibung ?? standardAlleInDerNaeheRadius
        #else
        standardAlleInDerNaeheRadius
        #endif
    }

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
    ///
    /// `context` dient ausschließlich dazu, `vorhandeneGeschaefte` nach den
    /// beiden `await`-Wartepunkten (Standortermittlung, MapKit-Suche — in der
    /// Praxis mehrere Sekunden) frisch neu zu laden, statt die zu Beginn
    /// übergebenen Objekte weiterzuverwenden: sie könnten in der Zwischenzeit
    /// gelöscht worden sein (z.B. durch den Nutzer selbst in
    /// ``GeschaeftListView`` oder — seit GitHub #39 — durch einen
    /// automatischen Sync-Zyklus im Hintergrund, siehe ``SyncPollingService``).
    /// Ohne diese Auffrischung crasht der Zugriff auf eine Eigenschaft eines
    /// zwischenzeitlich gelöschten ``Geschaeft`` mit einem SwiftData-Fatal-Error
    /// („backing data could no longer be found").
    @MainActor
    static func vorschlag(
        vorhandeneGeschaefte: [Geschaeft],
        ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag] = [],
        context: ModelContext
    ) async -> GeschaeftVorschlag? {
        // Radius bewusst VOR dem ersten `await` berechnet (noch garantiert
        // frische Objekte, siehe Typ-Doku).
        let radius = effektiverSuchradius(basis: suchradius, vorhandeneGeschaefte: vorhandeneGeschaefte)
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        guard let treffer = try? await nahegelegeneLaeden(bei: standort, radius: radius), !treffer.isEmpty else { return nil }
        let relevante = treffer.filter { !istIgnoriert($0, ignorierte: ignorierteVorschlaege) }
        let aktuelleGeschaefte = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? vorhandeneGeschaefte
        return passendenVorschlag(aus: relevante, standort: standort, vorhandeneGeschaefte: aktuelleGeschaefte)
    }

    /// Erweitert `basis` (den globalen Standard-Suchradius) auf den größten unter
    /// `vorhandeneGeschaefte` individuell gesetzten ``Geschaeft/erkennungsradius``
    /// (GitHub #41) — sonst würde ein größerer individueller Radius wirkungslos
    /// bleiben, weil `MKLocalPointsOfInterestRequest` den betreffenden Laden bei
    /// größerer Entfernung als `basis` gar nicht erst zurückliefert, bevor
    /// ``istBekannterTreffer(_:fuer:)`` überhaupt geprüft werden kann.
    static func effektiverSuchradius(basis: CLLocationDistance, vorhandeneGeschaefte: [Geschaeft]) -> CLLocationDistance {
        max(basis, vorhandeneGeschaefte.compactMap(\.erkennungsradiusRaw).max() ?? 0)
    }

    /// Sucht (unabhängig vom automatischen Einzelvorschlag) alle Läden im engeren
    /// ``alleInDerNaeheRadius``-Umkreis, sortiert nach Entfernung — Grundlage für
    /// „Alle Geschäfte in der Nähe“, mit der der Anwender nachträglich manuell
    /// auswählen oder einen zuvor ignorierten Vorschlag wieder aufnehmen kann. Anders
    /// als ``vorschlag(vorhandeneGeschaefte:ignorierteVorschlaege:)`` werden ignorierte
    /// Treffer hier bewusst NICHT aussortiert, sondern zusammen mit ihrem
    /// Ignoriert-Status geliefert. Liefert `nil` ohne Standortberechtigung.
    /// `context` dient wie bei ``vorschlag(vorhandeneGeschaefte:ignorierteVorschlaege:context:)``
    /// ausschließlich dazu, `vorhandeneGeschaefte` nach den `await`-Wartepunkten
    /// frisch neu zu laden, siehe dortige Typ-Doku.
    @MainActor
    static func alleInDerNaehe(
        vorhandeneGeschaefte: [Geschaeft],
        ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag],
        context: ModelContext
    ) async -> [GeschaeftInDerNaeheEintrag]? {
        let radius = effektiverSuchradius(basis: alleInDerNaeheRadius, vorhandeneGeschaefte: vorhandeneGeschaefte)
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        guard let treffer = try? await nahegelegeneLaeden(bei: standort, radius: radius) else { return nil }
        let aktuelleGeschaefte = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? vorhandeneGeschaefte
        let sortiert = treffer.sorted { entfernung(zu: $0, von: standort) < entfernung(zu: $1, von: standort) }
        let eintraege = sortiert.map { item -> GeschaeftInDerNaeheEintrag in
            let vorschlag: GeschaeftVorschlag
            if let bekanntesGeschaeft = aktuelleGeschaefte.first(where: { istBekannterTreffer($0, fuer: item) }) {
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
    /// Koordinatenübereinstimmung (``istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:)``).
    private static func istSelberLaden(_ a: GeschaeftVorschlag, _ b: GeschaeftVorschlag) -> Bool {
        if case .bekannt(let g1) = a, case .bekannt(let g2) = b {
            return g1.persistentModelID == g2.persistentModelID
        }
        return istGleicherOrt(nameA: a.name, koordinatenA: a.koordinaten, nameB: b.name, koordinatenB: b.koordinaten)
    }

    /// Zentrale Namens-/Koordinaten-Matching-Logik, die
    /// ``istBekannterTreffer(_:fuer:)``, ``istIgnoriert(_:ignorierte:)``,
    /// ``istSelberLaden(_:_:)`` und ``ignorierteEintraege(fuer:in:)`` gemeinsam
    /// nutzen: Namensübereinstimmung (exakt ODER Teilstring in beide Richtungen —
    /// deckt Kurzformen wie Apple-Maps-„REWE“ vs. selbst vergebenem „Rewe am Markt“
    /// ab) ODER Koordinaten innerhalb `toleranz`, falls für beide Seiten vorhanden.
    /// `toleranz` ist standardmäßig ``koordinatenTreffertoleranz``, aber für ein
    /// konkretes ``Geschaeft`` mit individuellem ``Geschaeft/erkennungsradius``
    /// überschreibbar (siehe ``istBekannterTreffer(_:fuer:)``, GitHub #41).
    ///
    /// **Bewusst NICHT für den automatischen Sync-Merge verwendet** (GitHub
    /// #86) — dort nutzt ``istGleicherOrtFuerSyncMerge(nameA:koordinatenA:radiusA:nameB:koordinatenB:radiusB:)``
    /// eine strengere Regel. Diese großzügige Variante bleibt nur für die
    /// interaktiven, vom Nutzer bestätigbaren Fälle hier (Standort-Erkennung,
    /// Ignorieren-Abgleich) — dort ist ein gelegentlicher falscher Vorschlag
    /// unkritisch, weil ablehnbar.
    private static func istGleicherOrt(
        nameA: String,
        koordinatenA: (breitengrad: Double, laengengrad: Double)?,
        nameB: String,
        koordinatenB: (breitengrad: Double, laengengrad: Double)?,
        toleranz: CLLocationDistance = koordinatenTreffertoleranz
    ) -> Bool {
        if nameA.localizedCaseInsensitiveCompare(nameB) == .orderedSame { return true }
        if nameA.localizedCaseInsensitiveContains(nameB) || nameB.localizedCaseInsensitiveContains(nameA) { return true }
        if let koordinatenA, let koordinatenB {
            let ortA = CLLocation(latitude: koordinatenA.breitengrad, longitude: koordinatenA.laengengrad)
            let ortB = CLLocation(latitude: koordinatenB.breitengrad, longitude: koordinatenB.laengengrad)
            return ortA.distance(from: ortB) < toleranz
        }
        return false
    }

    /// Strengere Vergleichsregel speziell für den automatischen Sync-Merge
    /// (``SyncSnapshotImportService``, GitHub #86) — anders als die
    /// interaktiven Aufrufer von ``istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:toleranz:)``
    /// oben passiert das Zusammenführen zweier Geräte-Bestände automatisch im
    /// Hintergrund, ohne Bestätigungsmöglichkeit. Ein falscher Treffer dort
    /// vermischt zwei echte, unterschiedliche Geschäfte unsichtbar und
    /// dauerhaft — deshalb bewusst kein Teilstring-Namensvergleich (hätte z.B.
    /// "Rewe" fälschlich mit "Rewe Center" gematcht) und kein reiner
    /// Koordinatenvergleich ohne Namensgleichheit (hätte z.B. zwei
    /// unterschiedliche Filialen derselben Kette an unterschiedlichen Orten
    /// NICHT betroffen, aber umgekehrt zwei dicht benachbarte, unterschiedlich
    /// benannte Läden wie Bäckerei/Blumenladen fälschlich zusammengeführt).
    ///
    /// Gilt nur als derselbe Ort, wenn der Name EXAKT übereinstimmt UND beide
    /// Koordinaten vorhanden UND innerhalb der strengeren (kleineren) der
    /// beiden individuellen ``Geschaeft/erkennungsradius``-Werte liegen —
    /// analog dem für #41 eingeführten, aber hier auf beide Seiten bezogenen
    /// Radius. Ohne Koordinaten auf einer Seite: kein Treffer, kein Fallback
    /// auf reinen Namensvergleich.
    static func istGleicherOrtFuerSyncMerge(
        nameA: String,
        koordinatenA: (breitengrad: Double, laengengrad: Double)?,
        radiusA: CLLocationDistance,
        nameB: String,
        koordinatenB: (breitengrad: Double, laengengrad: Double)?,
        radiusB: CLLocationDistance
    ) -> Bool {
        guard nameA.localizedCaseInsensitiveCompare(nameB) == .orderedSame else { return false }
        guard let koordinatenA, let koordinatenB else { return false }
        let ortA = CLLocation(latitude: koordinatenA.breitengrad, longitude: koordinatenA.laengengrad)
        let ortB = CLLocation(latitude: koordinatenB.breitengrad, longitude: koordinatenB.laengengrad)
        return ortA.distance(from: ortB) < min(radiusA, radiusB)
    }

    /// Kandidat für eine aktive Rückfrage beim Sync-Ordner-Beitritt (GitHub
    /// #86, Teil 2): gilt nach der großzügigen, interaktiven Regel
    /// (``istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:toleranz:)``,
    /// mit dem größeren der beiden Radien als Toleranz) als möglicherweise
    /// derselbe Ort, aber NICHT nach der strengeren automatischen
    /// Sync-Merge-Regel (``istGleicherOrtFuerSyncMerge(nameA:koordinatenA:radiusA:nameB:koordinatenB:radiusB:)``).
    /// Genau diese Differenzmenge lohnt eine bewusste Entscheidung beim
    /// einmaligen, nutzerinitiierten Beitritt zu einem Sync-Ordner — danach
    /// (laufender Betrieb) bleibt eine solche Konstellation absichtlich
    /// unbeachtet stehen (siehe `docs/GESCHAEFTSERKENNUNG.md`).
    static func istMehrdeutigerBeitrittsKandidat(
        nameA: String,
        koordinatenA: (breitengrad: Double, laengengrad: Double)?,
        radiusA: CLLocationDistance,
        nameB: String,
        koordinatenB: (breitengrad: Double, laengengrad: Double)?,
        radiusB: CLLocationDistance
    ) -> Bool {
        let grosszuegigerTreffer = istGleicherOrt(
            nameA: nameA, koordinatenA: koordinatenA, nameB: nameB, koordinatenB: koordinatenB,
            toleranz: max(radiusA, radiusB)
        )
        guard grosszuegigerTreffer else { return false }
        let strengerTreffer = istGleicherOrtFuerSyncMerge(
            nameA: nameA, koordinatenA: koordinatenA, radiusA: radiusA,
            nameB: nameB, koordinatenB: koordinatenB, radiusB: radiusB
        )
        return !strengerTreffer
    }

    /// Baut aus einem per Ladenerkennung gefundenen, noch unbekannten Laden einen
    /// Geschäfts-Entwurf zur Übernahme in ``GeschaeftStammdatenEditView`` — inkl.
    /// geschätztem ``GeschaeftTyp`` und den Koordinaten für künftiges
    /// Koordinaten-Matching (siehe ``koordinatenTreffertoleranz``). `context` dient
    /// nur dem Nachschlagen/Anlegen des vorgeschlagenen ``GeschaeftTyp`` (GitHub #25),
    /// der Entwurf selbst wird nicht in ihn eingefügt.
    static func entwurf(aus mapItem: MKMapItem, context: ModelContext) -> Geschaeft {
        let geschaeft = Geschaeft(
            name: mapItem.name ?? "Neues Geschäft",
            typen: [typVorschlag(fuer: mapItem.pointOfInterestCategory, context: context)],
            adresse: mapItem.address?.fullAddress
        )
        geschaeft.breitengrad = mapItem.location.coordinate.latitude
        geschaeft.laengengrad = mapItem.location.coordinate.longitude
        return geschaeft
    }

    /// Baut einen leeren Geschäfts-Entwurf mit den Koordinaten des aktuellen
    /// Standorts (ohne Apple-Maps-Treffer) — für den Fall, dass an einem Ort kein
    /// bekannter Laden gefunden wurde, der Anwender ihn aber trotzdem für künftiges
    /// Koordinaten-Matching (``koordinatenTreffertoleranz``) protokollieren möchte.
    /// `nil`, wenn keine Standortberechtigung erteilt wurde oder der Standort nicht
    /// ermittelt werden konnte.
    @MainActor
    static func entwurfAusAktuellemStandort(context: ModelContext) async -> Geschaeft? {
        guard let koordinaten = await standortKoordinaten() else { return nil }
        let geschaeft = Geschaeft(name: "", typen: [GeschaeftTyp.mitNamen("Lebensmittel", symbolName: "cart.fill", context: context)])
        geschaeft.breitengrad = koordinaten.breitengrad
        geschaeft.laengengrad = koordinaten.laengengrad
        return geschaeft
    }

    /// Koordinaten des aktuellen Standorts — für ein bereits bestehendes
    /// ``Geschaeft``, dem nachträglich ein Standort ergänzt werden soll (im
    /// Unterschied zu ``entwurfAusAktuellemStandort()``, das einen komplett neuen
    /// Entwurf baut). `nil`, wenn keine Standortberechtigung erteilt wurde oder der
    /// Standort nicht ermittelt werden konnte.
    @MainActor
    static func koordinatenAusAktuellerPosition() async -> (breitengrad: Double, laengengrad: Double)? {
        await standortKoordinaten()
    }

    /// Ermittelt Koordinaten für eine vom Anwender eingegebene oder bereits
    /// hinterlegte ``Geschaeft/adresse`` per Geocoding (`MKGeocodingRequest` — die
    /// seit iOS 26 vorgesehene Ablösung des deprecateten `CLGeocoder`) —
    /// Alternative zum GPS-Standort für den Fall, dass der Anwender sich nicht am
    /// Ort des Geschäfts befindet oder keine Standortberechtigung erteilen möchte.
    /// `nil` bei leerem Text, ohne Treffer oder bei Geocoding-Fehler (z.B. kein
    /// Netzwerk).
    @MainActor
    static func koordinaten(fuerAdresse adresse: String) async -> (breitengrad: Double, laengengrad: Double)? {
        let getrimmt = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmt.isEmpty, let anfrage = MKGeocodingRequest(addressString: getrimmt) else { return nil }
        guard let treffer = try? await anfrage.mapItems, let erster = treffer.first else { return nil }
        let koordinate = erster.location.coordinate
        return (koordinate.latitude, koordinate.longitude)
    }

    /// Ermittelt eine textuelle Adresse für gegebene Koordinaten per
    /// Reverse-Geocoding (`MKReverseGeocodingRequest`, das Gegenstück zu
    /// ``koordinaten(fuerAdresse:)``) — genutzt, wenn der Anwender den
    /// Standort-Pin manuell auf der Karte setzt oder den aktuellen GPS-Standort
    /// übernimmt, damit das Adressfeld automatisch vorausgefüllt wird (GitHub #24).
    /// `nil` ohne Treffer oder bei Geocoding-Fehler (z.B. kein Netzwerk).
    @MainActor
    static func adresse(fuerKoordinaten koordinate: CLLocationCoordinate2D) async -> String? {
        guard let anfrage = MKReverseGeocodingRequest(location: CLLocation(latitude: koordinate.latitude, longitude: koordinate.longitude))
        else { return nil }
        guard let treffer = try? await anfrage.mapItems, let erster = treffer.first else { return nil }
        return erster.address?.fullAddress
    }

    @MainActor
    private static func standortKoordinaten() async -> (breitengrad: Double, laengengrad: Double)? {
        guard let standort = await EinmaligerStandortAbruf().standortErmitteln() else { return nil }
        return (standort.coordinate.latitude, standort.coordinate.longitude)
    }

    private static func typVorschlag(fuer kategorie: MKPointOfInterestCategory?, context: ModelContext) -> GeschaeftTyp {
        switch kategorie {
        case .pharmacy: return GeschaeftTyp.mitNamen("Apotheke", symbolName: "cross.case.fill", context: context)
        case .foodMarket, .bakery: return GeschaeftTyp.mitNamen("Lebensmittel", symbolName: "cart.fill", context: context)
        case .winery, .brewery: return GeschaeftTyp.mitNamen("Getränkemarkt", symbolName: "waterbottle.fill", context: context)
        default: return GeschaeftTyp.sonstiges(context: context)
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
        istGleicherOrt(
            nameA: geschaeft.name, koordinatenA: koordinatenPaar(geschaeft.breitengrad, geschaeft.laengengrad),
            nameB: item.name ?? "", koordinatenB: koordinaten(fuer: item),
            toleranz: geschaeft.erkennungsradius
        )
    }

    /// Prüft, ob `item` einem vom Anwender ignorierten Vorschlag (siehe
    /// ``IgnorierterGeschaeftsVorschlag``) entspricht — Namens- ODER
    /// Koordinatenübereinstimmung genügt, analog ``istBekannterTreffer(_:fuer:)``.
    static func istIgnoriert(_ item: MKMapItem, ignorierte: [IgnorierterGeschaeftsVorschlag]) -> Bool {
        ignorierte.contains { ignoriert in
            istGleicherOrt(
                nameA: ignoriert.name, koordinatenA: koordinatenPaar(ignoriert.breitengrad, ignoriert.laengengrad),
                nameB: item.name ?? "", koordinatenB: koordinaten(fuer: item)
            )
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
            istGleicherOrt(
                nameA: eintrag.name, koordinatenA: koordinatenPaar(eintrag.breitengrad, eintrag.laengengrad),
                nameB: vorschlag.name, koordinatenB: vorschlag.koordinaten
            )
        }
    }

    private static func koordinatenPaar(_ breitengrad: Double?, _ laengengrad: Double?) -> (breitengrad: Double, laengengrad: Double)? {
        guard let breitengrad, let laengengrad else { return nil }
        return (breitengrad, laengengrad)
    }

    private static func koordinaten(fuer item: MKMapItem) -> (breitengrad: Double, laengengrad: Double) {
        (item.location.coordinate.latitude, item.location.coordinate.longitude)
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
