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
    private static let anzahlOhneListeSchluessel = "datenintegritaetAnzahlOhneListe"
    private static let anzahlOhneListeZeitpunktSchluessel = "datenintegritaetAnzahlOhneListeZeitpunkt"

    /// Ab diesem Zuwachs seit der letzten Prüfung gilt die Anzahl
    /// listenloser Einkaufsvorgänge (siehe ``pruefe(context:)``) als
    /// ungewöhnlich schnell wachsend statt als gewöhnlicher, seltener
    /// Einzelfall — Live-Test-Fund (Abschnitt 20/21): eine reine
    /// Bestandszahl („907 insgesamt") verrät für sich genommen nicht, ob sie
    /// über Wochen langsam getröpfelt ist oder gerade akut explodiert (im
    /// beobachteten Fall: 875 an einem einzigen Tag). `static var` statt
    /// Konstante, damit Tests sie verkürzen können.
    @MainActor static var warnschwelleSchnellesWachstum = 10

    /// Bericht des letzten Aufrufs von ``pruefe(context:)`` — persistiert,
    /// damit ``DebuggingView`` ihn auch nach einem App-Neustart noch anzeigen
    /// kann, ohne die Prüfung erneut auszuführen.
    static var letzterBericht: [String] {
        get { UserDefaults.standard.stringArray(forKey: letzterBerichtSchluessel) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: letzterBerichtSchluessel) }
    }

    /// Test-Hilfsmittel: setzt die zwischen Aufrufen persistierte Vorher-
    /// Anzahl für die Wachstums-Warnung zurück, damit Tests unabhängig von
    /// zuvor im selben Prozess gelaufenen Prüfungen sind.
    static func wachstumsUeberwachungZuruecksetzen() {
        UserDefaults.standard.removeObject(forKey: anzahlOhneListeSchluessel)
        UserDefaults.standard.removeObject(forKey: anzahlOhneListeZeitpunktSchluessel)
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

        // Live-Test-Fund (Abschnitt 20): eine fehlende Einkaufsliste ist
        // hier bewusst NICHT über ``istBaumelnd`` erfasst — ein `nil`-Bezug
        // ist für SwiftData ein gültiger, nicht-abstürzender Zustand, anders
        // als eine baumelnde `persistentModelID`. Trotzdem ist ein
        // ``Einkaufsvorgang`` ohne Liste für die gesamte App unerreichbar
        // (``EinkaufenView/aktuellerEinkauf`` verlangt immer eine konkrete
        // Liste) — eine eigene, andere Fehlerkategorie („orphaned" statt
        // „dangling"), die ohne diese Prüfung monatelang unbemerkt
        // akkumulieren kann. Als EINE aggregierte Zeile statt einer je
        // betroffenem Vorgang, damit ein künftiger ähnlicher Bug den Bericht
        // nicht selbst wieder unbrauchbar macht (siehe Fund: 907 Einträge).
        let listenloseVorgaenge = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []).filter { $0.einkaufsliste == nil }
        if !listenloseVorgaenge.isEmpty {
            let mitKaeufen = listenloseVorgaenge.filter { !$0.kaufEintraege.isEmpty }
            let kaeufeGesamt = mitKaeufen.reduce(0) { $0 + $1.kaufEintraege.count }
            let kaeufeZusatz = mitKaeufen.isEmpty ? "" : " (\(mitKaeufen.count) davon mit insgesamt \(kaeufeGesamt) angehängten Käufen)"

            let vorherigeAnzahl = UserDefaults.standard.object(forKey: anzahlOhneListeSchluessel) as? Int
            var wachstumsZusatz = ""
            if let vorherigeAnzahl, listenloseVorgaenge.count - vorherigeAnzahl >= warnschwelleSchnellesWachstum {
                let vorherigerZeitpunkt = UserDefaults.standard.object(forKey: anzahlOhneListeZeitpunktSchluessel) as? Date
                let seit = vorherigerZeitpunkt.map { " seit \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                wachstumsZusatz = " ⚠️ +\(listenloseVorgaenge.count - vorherigeAnzahl)\(seit) — ungewöhnlich schnelles Wachstum, deutet auf einen aktiven Fehler statt auf Einzelfälle hin"
            }

            befunde.append(Befund(
                beschreibung: "\(listenloseVorgaenge.count) Einkaufsvorgänge ohne Einkaufsliste — für die App unerreichbar\(kaeufeZusatz)\(wachstumsZusatz)"
            ))
            UserDefaults.standard.set(listenloseVorgaenge.count, forKey: anzahlOhneListeSchluessel)
            UserDefaults.standard.set(Date(), forKey: anzahlOhneListeZeitpunktSchluessel)
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
