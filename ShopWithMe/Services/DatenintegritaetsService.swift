import Foundation
import SwiftData

/// Repariert baumelnde Beziehungen, die vor der vollständigen Einführung von
/// `@Relationship(inverse:)`-Deklarationen (siehe `docs/DATABASE_CONCURRENCY.md`)
/// bereits im lokalen Datenbestand entstanden sind. Ohne `inverse`-Deklaration
/// ließ SwiftData beim Löschen des referenzierten Objekts die Referenz stehen,
/// statt sie zu nullen — der Zugriff auf irgendeine Eigenschaft (`.name`, `.id`,
/// …) einer solchen Referenz stürzt mit einem SwiftData-Fatal-Error ab, während
/// `persistentModelID` allein sicher lesbar bleibt (siehe
/// ``SyncSnapshotExportService/sichereID(_:gueltigeIDs:)``, dieselbe
/// Absicherungstechnik, dort nur für den Export-Lesepfad).
///
/// **Zweistufiges Vorgehen** (mit dem Anwender abgestimmt, GitHub-Absturzmeldung
/// zu `Geschaeft/p9`):
/// - ``repariereFallsNoetig(context:)`` läuft still bei jedem App-Start (siehe
///   ``ShopWithMeApp``) und behebt alles Nötige automatisch — auch dort, wo
///   (z.B. ``Einkaufsvorgang/geschaeft``) kein Namens-Schnappschuss existiert und
///   dadurch Kontext verloren geht: Ein Absturz (z.B.
///   ``GeschaeftHaeufigkeitService/favoriten(aus:anzahl:zeitfensterTage:jetzt:)``,
///   das ungeschützt `.geschaeft.name` liest) kann jederzeit auf dem
///   allerersten Bildschirm auftreten und darf nicht auf eine manuelle
///   Bestätigung im Debug-Menü warten.
/// - Jede Reparatur wird über ``DatenintegritaetsLogger`` protokolliert und im
///   zurückgegebenen sowie in ``letzterBericht`` persistierten Bericht
///   festgehalten — einsehbar und exportierbar im Debugging-Bildschirm
///   (``DebuggingView``), damit auch Fälle mit echtem Kontextverlust
///   nachvollziehbar bleiben, ohne den Start zu blockieren.
enum DatenintegritaetsService {
    struct Befund: Identifiable {
        let id = UUID()
        let beschreibung: String
    }

    private static let letzterBerichtSchluessel = "datenintegritaetLetzterBericht"

    /// Bericht des letzten Aufrufs von ``repariereFallsNoetig(context:)`` —
    /// persistiert, damit ``DebuggingView`` ihn auch nach einem App-Neustart
    /// noch anzeigen kann, ohne die Prüfung erneut auszuführen.
    static var letzterBericht: [String] {
        get { UserDefaults.standard.stringArray(forKey: letzterBerichtSchluessel) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: letzterBerichtSchluessel) }
    }

    /// Findet und behebt baumelnde Referenzen im aktuellen Datenbestand.
    /// Idempotent — ein erneuter Aufruf auf bereits bereinigten Daten liefert
    /// einen leeren Bericht und verändert nichts.
    @discardableResult
    @MainActor
    static func repariereFallsNoetig(context: ModelContext) -> [Befund] {
        let gueltigeGeschaeftIDs = Set(((try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []).map(\.persistentModelID))
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let gueltigeKategorieIDs = Set(((try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))

        var befunde: [Befund] = []

        for artikel in (try? context.fetch(FetchDescriptor<Artikel>())) ?? [] {
            guard istBaumelnd(artikel.kategorie, gueltigeIDs: gueltigeKategorieIDs) else { continue }
            artikel.kategorie = nil
            befunde.append(Befund(beschreibung: "Artikel „\(artikel.name)“: veraltete Einzelkategorie-Referenz entfernt (Warengruppe existiert nicht mehr)"))
        }

        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            var geheilteFelder: [String] = []
            if istBaumelnd(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs) {
                eintrag.artikel = nil
                geheilteFelder.append("Artikel")
            }
            if istBaumelnd(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                eintrag.geschaeft = nil
                geheilteFelder.append("Geschäft")
            }
            if istBaumelnd(eintrag.kategorie, gueltigeIDs: gueltigeKategorieIDs) {
                eintrag.kategorie = nil
                geheilteFelder.append("Warengruppe")
            }
            if istBaumelnd(eintrag.einkaufsvorgang, gueltigeIDs: nil) {
                eintrag.einkaufsvorgang = nil
                geheilteFelder.append("Einkaufsvorgang")
            }
            guard !geheilteFelder.isEmpty else { continue }
            // Erst nullen, dann `anzeigeName` lesen — sonst würde die
            // Beschreibung selbst wieder auf einer baumelnden Referenz abstürzen.
            let datum = eintrag.datum.formatted(date: .abbreviated, time: .omitted)
            befunde.append(Befund(
                beschreibung: "Kaufeintrag vom \(datum) („\(eintrag.anzeigeName)“ bei \(eintrag.geschaeftNameSnapshot)): Bezug zu \(geheilteFelder.joined(separator: ", ")) entfernt (existiert nicht mehr)"
            ))
        }

        for vorgang in (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? [] {
            let datum = vorgang.startZeit.formatted(date: .abbreviated, time: .omitted)
            if istBaumelnd(vorgang.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                let vermutetesGeschaeft = vorgang.kaufEintraege.map(\.geschaeftNameSnapshot).first { !$0.isEmpty }
                vorgang.geschaeft = nil
                let zusatz = vermutetesGeschaeft.map { " (vermutlich „\($0)“, aus zugehörigen Kaufeinträgen rekonstruiert)" } ?? " (Laden nicht mehr rekonstruierbar)"
                befunde.append(Befund(beschreibung: "Einkaufsvorgang vom \(datum): Geschäftsbezug entfernt, Geschäft existiert nicht mehr\(zusatz)"))
            }
            if istBaumelnd(vorgang.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs) {
                vorgang.einkaufsliste = nil
                befunde.append(Befund(beschreibung: "Einkaufsvorgang vom \(datum): Einkaufslistenbezug entfernt, Einkaufsliste existiert nicht mehr"))
            }
        }

        for distanz in (try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? [] {
            let kategorienBaumelnd = istBaumelnd(distanz.kategorieA, gueltigeIDs: gueltigeKategorieIDs)
                || istBaumelnd(distanz.kategorieB, gueltigeIDs: gueltigeKategorieIDs)
            if kategorienBaumelnd {
                context.delete(distanz)
                befunde.append(Befund(beschreibung: "Gelernter Warengruppen-Abstand entfernt (beteiligte Warengruppe existiert nicht mehr) — wird beim nächsten Einkauf neu gelernt"))
            } else if istBaumelnd(distanz.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                distanz.geschaeft = nil
                befunde.append(Befund(beschreibung: "Gelernter Warengruppen-Abstand: Geschäftsbezug entfernt (Geschäft existiert nicht mehr), gilt jetzt geschäftsübergreifend"))
            }
        }

        guard !befunde.isEmpty else {
            letzterBericht = []
            return []
        }

        try? context.save()
        for befund in befunde {
            DatenintegritaetsLogger.log(befund.beschreibung)
        }
        letzterBericht = befunde.map(\.beschreibung)
        return befunde
    }

    /// `gueltigeIDs: nil` prüft nur, ob `objekt` überhaupt gesetzt ist, ohne
    /// gegen eine konkrete Gültigkeitsmenge abzugleichen — für
    /// ``KaufEintrag/einkaufsvorgang``, wo ein eigener Fetch für nur diese eine
    /// Prüfung nicht lohnt; `persistentModelID` bleibt auch hier sicher lesbar.
    private static func istBaumelnd<T: PersistentModel>(_ objekt: T?, gueltigeIDs: Set<PersistentIdentifier>?) -> Bool {
        guard let objekt else { return false }
        guard let gueltigeIDs else { return false }
        return !gueltigeIDs.contains(objekt.persistentModelID)
    }
}
