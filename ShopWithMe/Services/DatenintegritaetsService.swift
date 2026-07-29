import Foundation
import SwiftData

/// Erkennt baumelnde Beziehungen, die vor der vollständigen Einführung von
/// `@Relationship(inverse:)`-Deklarationen (siehe `docs/DATABASE_CONCURRENCY.md`)
/// bereits im lokalen Datenbestand entstanden sind.
///
/// **Bewusst nur Erkennung, keine automatische Reparatur mehr** — ein früherer
/// Versuch, eine baumelnde Referenz einfach auf `nil` zu setzen (z.B.
/// `eintrag.artikel = nil`), führte selbst zum Absturz: SwiftDatas Setter für
/// eine Beziehung mit `inverse:`-Deklaration muss beim Nullen die **alte**
/// Gegenseite auffalten, um sich selbst aus deren inversem Array zu entfernen
/// (hier `Artikel.kaufEintraege`) — ist genau diese alte Gegenseite die bereits
/// baumelnde, stürzt exakt dort derselbe SwiftData-Fatal-Error, den die
/// Reparatur eigentlich beheben sollte. `persistentModelID` bleibt zwar sicher
/// lesbar (siehe ``SyncSnapshotExportService/sichereID(_:gueltigeIDs:)``), das
/// schützt aber nur Lesezugriffe — **jede** schreibende Operation auf eine
/// bereits baumelnde Beziehung (Nullen wie Löschen, da Löschen dieselbe
/// Inverse-Pflege auslöst) ist über die normale SwiftData-Objektgraph-API
/// unsicher, gerade WEIL die `inverse:`-Deklaration (die künftige Korruption
/// verhindert) hier existiert. Eine echte rückwirkende Reparatur bräuchte einen
/// direkten Zugriff auf die SQLite-Datei unterhalb von SwiftData/CoreData
/// (nicht trivial, noch nicht umgesetzt).
///
/// Bis dahin liefert ``pruefe(context:)`` nur einen Bericht (persistiert in
/// ``letzterBericht``, einsehbar/exportierbar über ``DebuggingView``) — die
/// eigentliche Absicherung gegen Abstürze muss an den einzelnen Lesepfaden
/// erfolgen (siehe z.B. ``GeschaeftHaeufigkeitService/favoriten(aus:anzahl:zeitfensterTage:jetzt:)``).
enum DatenintegritaetsService {
    struct Befund: Identifiable {
        let id = UUID()
        let beschreibung: String
    }

    private static let letzterBerichtSchluessel = "datenintegritaetLetzterBericht"

    /// Bericht des letzten Aufrufs von ``pruefe(context:)`` — persistiert,
    /// damit ``DebuggingView`` ihn auch nach einem App-Neustart noch anzeigen
    /// kann, ohne die Prüfung erneut auszuführen.
    static var letzterBericht: [String] {
        get { UserDefaults.standard.stringArray(forKey: letzterBerichtSchluessel) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: letzterBerichtSchluessel) }
    }

    /// Rein lesende Bestandsaufnahme baumelnder Referenzen — verändert nichts
    /// am Datenbestand (siehe Typ-Dokumentation, warum eine automatische
    /// Reparatur hier nicht sicher möglich ist). Liest ausschließlich
    /// `persistentModelID` der geprüften Beziehungen sowie bereits vorhandene,
    /// crash-sichere Namens-Schnappschüsse (`artikelNameSnapshot`/
    /// `geschaeftNameSnapshot`) — keine Eigenschaft einer möglicherweise
    /// baumelnden Referenz selbst.
    @discardableResult
    @MainActor
    static func pruefe(context: ModelContext) -> [Befund] {
        let gueltigeGeschaeftIDs = Set(((try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []).map(\.persistentModelID))
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let gueltigeKategorieIDs = Set(((try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))

        var befunde: [Befund] = []

        for artikel in (try? context.fetch(FetchDescriptor<Artikel>())) ?? [] {
            guard istBaumelnd(artikel.kategorie, gueltigeIDs: gueltigeKategorieIDs) else { continue }
            befunde.append(Befund(beschreibung: "Artikel „\(artikel.name)“: veraltete Einzelkategorie-Referenz zeigt auf eine nicht mehr existierende Warengruppe"))
        }

        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            var betroffeneFelder: [String] = []
            if istBaumelnd(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs) { betroffeneFelder.append("Artikel") }
            if istBaumelnd(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) { betroffeneFelder.append("Geschäft") }
            if istBaumelnd(eintrag.kategorie, gueltigeIDs: gueltigeKategorieIDs) { betroffeneFelder.append("Warengruppe") }
            if istBaumelnd(eintrag.einkaufsvorgang, gueltigeIDs: nil) { betroffeneFelder.append("Einkaufsvorgang") }
            guard !betroffeneFelder.isEmpty else { continue }
            // Bewusst `artikelNameSnapshot`/`geschaeftNameSnapshot` statt
            // `anzeigeName`/`eintrag.artikel?.name` — letztere lesen im
            // Zweifel selbst wieder eine gerade als baumelnd erkannte Referenz.
            let datum = eintrag.datum.formatted(date: .abbreviated, time: .omitted)
            befunde.append(Befund(
                beschreibung: "Kaufeintrag vom \(datum) (Schnappschuss: „\(eintrag.artikelNameSnapshot)“ bei \(eintrag.geschaeftNameSnapshot)): Bezug zu \(betroffeneFelder.joined(separator: ", ")) zeigt auf nicht mehr Existierendes"
            ))
        }

        for vorgang in (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? [] {
            let datum = vorgang.startZeit.formatted(date: .abbreviated, time: .omitted)
            if istBaumelnd(vorgang.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                let vermutetesGeschaeft = vorgang.kaufEintraege.map(\.geschaeftNameSnapshot).first { !$0.isEmpty }
                let zusatz = vermutetesGeschaeft.map { " (vermutlich „\($0)“, aus zugehörigen Kaufeinträgen rekonstruiert)" } ?? " (Laden nicht mehr rekonstruierbar)"
                befunde.append(Befund(beschreibung: "Einkaufsvorgang vom \(datum): Geschäftsbezug zeigt auf nicht mehr Existierendes\(zusatz)"))
            }
            if istBaumelnd(vorgang.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs) {
                befunde.append(Befund(beschreibung: "Einkaufsvorgang vom \(datum): Einkaufslistenbezug zeigt auf nicht mehr Existierendes"))
            }
        }

        for distanz in (try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? [] {
            let kategorienBaumelnd = istBaumelnd(distanz.kategorieA, gueltigeIDs: gueltigeKategorieIDs)
                || istBaumelnd(distanz.kategorieB, gueltigeIDs: gueltigeKategorieIDs)
            if kategorienBaumelnd {
                befunde.append(Befund(beschreibung: "Gelernter Warengruppen-Abstand: beteiligte Warengruppe zeigt auf nicht mehr Existierendes"))
            } else if istBaumelnd(distanz.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                befunde.append(Befund(beschreibung: "Gelernter Warengruppen-Abstand: Geschäftsbezug zeigt auf nicht mehr Existierendes"))
            }
        }

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
