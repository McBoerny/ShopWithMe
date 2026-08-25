import Foundation
import SwiftData

/// Erkennt baumelnde Beziehungen, die vor der vollständigen Einführung von
/// `@Relationship(inverse:)`-Deklarationen (siehe `docs/DATABASE_CONCURRENCY.md`)
/// bereits im lokalen Datenbestand entstanden sind.
///
/// **`pruefe(context:)` selbst bleibt bewusst rein lesend** — ein früherer
/// Versuch, eine baumelnde Referenz direkt auf `nil` zu setzen (z.B.
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
/// verhindert) hier existiert.
///
/// **Tatsächliche Reparatur läuft seitdem über einen indirekten Weg, kein
/// SQLite-Direktzugriff nötig:** ``SyncErsetzenService/planeBereinigungBaumelnderReferenzen(context:)``
/// nutzt aus, dass ein frischer Export (``SyncSnapshotExportService/erstelleSnapshot(context:)``)
/// baumelnde Referenzen bereits beim Schreiben stillschweigend zu `nil`
/// auflöst (er liest dafür nur die sicher lesbare `persistentModelID`, nie
/// eine andere Eigenschaft) — ein Wipe-und-Neuaufbau ausschließlich aus
/// diesem eigenen, frischen Snapshot enthält sie danach strukturell nicht
/// mehr. `pruefe(context:)` liefert dafür weiterhin nur den Bericht
/// (persistiert in ``letzterBericht``, einsehbar/exportierbar über
/// ``DebuggingView``) — die eigentliche Absicherung gegen Abstürze muss
/// zusätzlich an den einzelnen Lesepfaden erfolgen (siehe z.B.
/// ``GeschaeftHaeufigkeitService/favoriten(aus:anzahl:zeitfensterTage:jetzt:)``).
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
        let gueltigeProduktIDs = Set(((try? context.fetch(FetchDescriptor<Produkt>())) ?? []).map(\.persistentModelID))
        let gueltigeAbteilungIDs = Set(((try? context.fetch(FetchDescriptor<Abteilung>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))
        // Einmal geladen, statt wie zuvor dreimal in dieser Funktion neu zu
        // fetchen (Performance-Fund #154) — alle drei Verwendungen weiter
        // unten lasen exakt denselben Bestand.
        let alleEinkaufsvorgaenge = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        let gueltigeEinkaufsvorgangIDs = Set(alleEinkaufsvorgaenge.map(\.persistentModelID))

        var befunde: [Befund] = []

        for artikel in (try? context.fetch(FetchDescriptor<Artikel>())) ?? [] {
            guard istBaumelnd(artikel.abteilung, gueltigeIDs: gueltigeAbteilungIDs) else { continue }
            befunde.append(Befund(beschreibung: "Artikel „\(artikel.name)“: veraltete Einzelabteilung-Referenz zeigt auf eine nicht mehr existierende Abteilung"))
        }

        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            var betroffeneFelder: [String] = []
            if istBaumelnd(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs) { betroffeneFelder.append("Artikel") }
            if istBaumelnd(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) { betroffeneFelder.append("Geschäft") }
            if istBaumelnd(eintrag.abteilung, gueltigeIDs: gueltigeAbteilungIDs) { betroffeneFelder.append("Abteilung") }
            if istBaumelnd(eintrag.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs) { betroffeneFelder.append("Einkaufsvorgang") }
            guard !betroffeneFelder.isEmpty else { continue }
            // Bewusst `artikelNameSnapshot`/`geschaeftNameSnapshot` statt
            // `anzeigeName`/`eintrag.artikel?.name` — letztere lesen im
            // Zweifel selbst wieder eine gerade als baumelnd erkannte Referenz.
            let datum = eintrag.datum.formatted(date: .abbreviated, time: .omitted)
            befunde.append(Befund(
                beschreibung: "Kaufeintrag vom \(datum) (Schnappschuss: „\(eintrag.artikelNameSnapshot)“ bei \(eintrag.geschaeftNameSnapshot)): Bezug zu \(betroffeneFelder.joined(separator: ", ")) zeigt auf nicht mehr Existierendes"
            ))
        }

        for punkt in (try? context.fetch(FetchDescriptor<Preispunkt>())) ?? [] {
            var betroffeneFelder: [String] = []
            // Bewusst `punkt.produkt` statt der abgeleiteten `punkt.artikel`
            // geprüft — Letztere läse im Zweifel selbst wieder eine gerade
            // als baumelnd erkannte `produkt`-Referenz (siehe Kommentar unten).
            if istBaumelnd(punkt.produkt, gueltigeIDs: gueltigeProduktIDs) { betroffeneFelder.append("Produkt") }
            if istBaumelnd(punkt.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) { betroffeneFelder.append("Geschäft") }
            guard !betroffeneFelder.isEmpty else { continue }
            // Bewusst `produktName`/`geschaeftNameSnapshot` statt
            // `anzeigeName`/`punkt.produkt?.name` — Letztere lesen im Zweifel
            // selbst wieder eine gerade als baumelnd erkannte Referenz.
            let datum = punkt.datum.formatted(date: .abbreviated, time: .omitted)
            befunde.append(Befund(
                beschreibung: "Preispunkt vom \(datum) (Schnappschuss: „\(punkt.produktName ?? "unbekannt")“ bei \(punkt.geschaeftNameSnapshot)): Bezug zu \(betroffeneFelder.joined(separator: ", ")) zeigt auf nicht mehr Existierendes"
            ))
        }

        // Nutzerbericht (2026-08-10): eine baumelnde Referenz auf dieser
        // Beziehung blieb bisher komplett unsichtbar für den Nutzer — trotz
        // `@Relationship(deleteRule: .cascade, inverse:)` auf beiden Seiten
        // (`Einkaufsliste.eintraege`/`Artikel.einkaufslistenEintraege`, seit
        // deren Einführung über eine normale App-Operation nicht mehr neu
        // entstehbar, siehe Typ-Doku von ``DatenintegritaetsServiceTests``)
        // reproduzierte sich auf einem länger genutzten Testgerät weiterhin
        // ein Alt-Fall (vor Einführung dieser Deklarationen entstanden), live
        // bestätigt über wiederholte `sync_baumelnde_referenz_gefunden`-
        // Protokolleinträge. Konsequenz ohne diese Prüfung: unbemerkt, da
        // ``SyncSnapshotExportService/erstelleSnapshot(context:)`` einen
        // solchen Eintrag beim Export über ``SyncSnapshotExportService/sichereID(_:gueltigeIDs:)``
        // stillschweigend komplett überspringt (`guard let einkaufslisteID =
        // sichereID(...), let artikelID = sichereID(...) else { return nil
        // }`) — ein Peer, der seinen kompletten Bestand aus so einem Export
        // neu aufbaut (``SyncErsetzenService``), erhält dadurch dauerhaft
        // weniger Einkaufslisten-Einträge als tatsächlich vorhanden, ohne
        // dass irgendein Fehler sichtbar wird.
        for eintrag in (try? context.fetch(FetchDescriptor<EinkaufslistenEintrag>())) ?? [] {
            let artikelBaumelnd = istBaumelnd(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs)
            let listeBaumelnd = istBaumelnd(eintrag.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs)
            guard artikelBaumelnd || listeBaumelnd else { continue }
            var betroffeneFelder: [String] = []
            if artikelBaumelnd { betroffeneFelder.append("Artikel") }
            if listeBaumelnd { betroffeneFelder.append("Einkaufsliste") }
            // Nur die jeweils NICHT selbst baumelnde Seite ist sicher lesbar
            // (analog dem Snapshot-Muster bei `KaufEintrag`/`Preispunkt` oben).
            let listenName = listeBaumelnd ? nil : eintrag.einkaufsliste?.name
            let ortszusatz = listenName.map { " auf Liste „\($0)“" } ?? ""
            let datum = eintrag.erstelltAm.formatted(date: .abbreviated, time: .omitted)
            befunde.append(Befund(
                beschreibung: "Einkaufslisten-Eintrag vom \(datum)\(ortszusatz): Bezug zu \(betroffeneFelder.joined(separator: ", ")) zeigt auf nicht mehr Existierendes — wird beim Sync-Export stillschweigend übersprungen"
            ))
        }

        for vorgang in alleEinkaufsvorgaenge {
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
        // Liste) — eine eigene, andere Fehlerabteilung („orphaned" statt
        // „dangling"), die ohne diese Prüfung monatelang unbemerkt
        // akkumulieren kann. Als EINE aggregierte Zeile statt einer je
        // betroffenem Vorgang, damit ein künftiger ähnlicher Bug den Bericht
        // nicht selbst wieder unbrauchbar macht (siehe Fund: 907 Einträge).
        let listenloseVorgaenge = alleEinkaufsvorgaenge.filter { $0.einkaufsliste == nil }
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
            let abteilungenBaumelnd = istBaumelnd(distanz.abteilungA, gueltigeIDs: gueltigeAbteilungIDs)
                || istBaumelnd(distanz.abteilungB, gueltigeIDs: gueltigeAbteilungIDs)
            if abteilungenBaumelnd {
                befunde.append(Befund(beschreibung: "Gelernter Abteilungs-Abstand: beteiligte Abteilung zeigt auf nicht mehr Existierendes"))
            } else if istBaumelnd(distanz.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs) {
                befunde.append(Befund(beschreibung: "Gelernter Abteilungs-Abstand: Geschäftsbezug zeigt auf nicht mehr Existierendes"))
            }
        }

        for befund in befunde {
            DatenintegritaetsLogger.log(befund.beschreibung)
        }
        letzterBericht = befunde.map(\.beschreibung)
        return befunde
    }

    /// Löscht ``Einkaufsvorgang``e ohne ``Einkaufsliste`` UND ohne
    /// angehängte ``KaufEintrag``e — beweisbar verlustfrei (anders als die
    /// „baumelnde Referenz"-Fälle oben): ein `nil`-Bezug ist kein
    /// Absturzrisiko, das Löschen muss also keine bereits ungültige
    /// Gegenseite auffalten. Ein solcher Vorgang ist für die App ohnehin
    /// unerreichbar (siehe ``pruefe(context:)``) und referenziert nichts,
    /// das dabei verloren ginge. Vorgänge MIT angehängten `KaufEintrag`en
    /// werden bewusst NICHT gelöscht (`deleteRule: .cascade` würde echte
    /// Käufe mitlöschen) — die bleiben Gegenstand des Berichts oben, bis
    /// eine gezielte Wiederherstellung möglich ist. Läuft automatisch bei
    /// jedem App-Start, vor ``pruefe(context:)`` (siehe `ShopWithMeApp`).
    @discardableResult
    @MainActor
    static func raeumeLeereListenloseVorgaengeAuf(context: ModelContext) -> Int {
        let betroffene = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? [])
            .filter { $0.einkaufsliste == nil && $0.kaufEintraege.isEmpty }
        guard !betroffene.isEmpty else { return 0 }
        for vorgang in betroffene { context.delete(vorgang) }
        try? context.save()
        DatenintegritaetsLogger.log("\(betroffene.count) leere, listenlose Einkaufsvorgänge automatisch bereinigt")
        return betroffene.count
    }

    /// Einmalige Migration (siehe `docs/GESCHAEFTS_AGGREGATE.md`): sichert für
    /// jeden bereits vorhandenen ``KaufEintrag``/abgeschlossenen
    /// ``Einkaufsvorgang`` die beiden neuen, dauerhaften Ableitungen
    /// (``ArtikelGeschaeftVerfuegbarkeit``/``GeschaeftBesuch``), BEVOR
    /// ``Einkaufsvorgang``e ohne ``Einkaufsliste`` — vormals durch `.nullify`
    /// entstanden, seit der Umstellung von ``Einkaufsliste/einkaufsvorgaenge``
    /// auf `.cascade` strukturell nicht mehr neu entstehbar — endgültig
    /// gelöscht werden (inklusive ihrer ``KaufEintrag``e per Kaskade). Ohne
    /// diese Reihenfolge würden Artikel, die nur über eine inzwischen
    /// gelöschte Liste gekauft wurden, fälschlich wieder als „nie hier
    /// gekauft" gelten, und ihr Ladenbesuch verschwände aus dem
    /// Besuchsprotokoll.
    ///
    /// Idempotent wie ``KaufEintrag/preisverlaufMigrierenFallsNoetig(context:)``
    /// (kein separates „schon gelaufen"-Flag): jeder Schritt prüft vor dem
    /// Schreiben/Löschen den aktuellen Bestand, ein wiederholter Aufruf findet
    /// beim zweiten Mal nichts mehr vor. Läuft beim App-Start (siehe
    /// ``ShopWithMeApp``), vor ``raeumeLeereListenloseVorgaengeAuf(context:)``.
    @MainActor
    static func migriereGeschaeftsAggregateFallsNoetig(context: ModelContext) {
        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            guard let artikel = eintrag.artikel, let geschaeft = eintrag.geschaeft else { continue }
            ArtikelVerfuegbarkeitService.vermerkeGekauft(artikel: artikel, geschaeft: geschaeft, context: context)
        }
        // Einmal geladen, statt wie zuvor zweimal in dieser Funktion neu zu
        // fetchen (Performance-Fund #154).
        let alleVorgaenge = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        for vorgang in alleVorgaenge where vorgang.endZeit != nil {
            GeschaeftBesuchService.erfassen(fuer: vorgang, context: context)
        }

        let verwaist = alleVorgaenge.filter { $0.einkaufsliste == nil }
        guard !verwaist.isEmpty else { return }
        for vorgang in verwaist { context.delete(vorgang) }
        try? context.save()
        DatenintegritaetsLogger.log(
            "\(verwaist.count) Einkaufsvorgänge ohne Einkaufsliste endgültig bereinigt (Artikel-Verfügbarkeit/Besuchsprotokoll vorher gesichert)"
        )
    }

    /// Einmalige Migration (GitHub #99): sichert für jeden noch existierenden
    /// ``KaufEintrag`` mit auflösbarem ``Artikel``/``Einkaufsliste`` das neue,
    /// dauerhafte Sicherheitsnetz-Faktum (``ArtikelListenKauf``), bevor der
    /// jeweilige Kaufeintrag durch die reguläre 48h-Karenzzeit
    /// (``KaufEintragBereinigungService``) verschwindet — reduziert die
    /// Übergangslücke direkt beim Rollout dieses Fixes. Kann naturgemäß nur
    /// erfassen, was zu diesem Zeitpunkt noch existiert; bereits zuvor
    /// bereinigte Käufe sind nicht rückwirkend rekonstruierbar (siehe
    /// `docs/DATENSYNCHRONISATION.md` Abschnitt 4.7). Ein `KaufEintrag` ohne
    /// auflösbare ``Einkaufsliste`` (z.B. ein bereits listenloser, gleich
    /// darauf per Kaskade gelöschter Vorgang) trägt ohnehin nichts zu einem
    /// (Artikel, Einkaufsliste)-Faktum bei — die Reihenfolge relativ zu
    /// ``migriereGeschaeftsAggregateFallsNoetig(context:)`` ist deshalb
    /// unkritisch.
    ///
    /// Idempotent (``ArtikelListenKaufService/vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``
    /// prüft selbst vor dem Schreiben): ein wiederholter Aufruf legt keine
    /// Dubletten an. Läuft beim App-Start, siehe ``ShopWithMeApp``.
    ///
    /// **Erweiterung (Architektur-Review 2026-08-10):** befüllt zusätzlich das
    /// symmetrische Gegenstück ``ArtikelListenKauf/zuletztHinzugefuegtAm``
    /// rückwirkend aus jedem noch existierenden, offenen
    /// ``EinkaufslistenEintrag`` (dessen ``EinkaufslistenEintrag/erstelltAm``
    /// ist zu diesem Zeitpunkt der einzig verfügbare Anhaltspunkt) — ohne
    /// diesen Backfill hätte ein Bestandsgerät für JEDEN zum
    /// Update-Zeitpunkt bereits offenen Artikel zunächst kein Faktum, bis er
    /// das nächste Mal lokal oder per Sync bewegt wird (siehe
    /// ``SyncSnapshotImportService/mergeKaufEintraege(_:artikelZuordnung:einkaufsvorgangZuordnung:geschaeftZuordnung:abteilungZuordnung:peerGeraeteID:context:)``s
    /// konservativen `nil`-Fallback dafür).
    @MainActor
    static func migriereArtikelListenKaeufeFallsNoetig(context: ModelContext) {
        var bekannt = ArtikelListenKaufService.alleEintraege(context: context)
        let vorherAnzahl = bekannt.count
        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            guard let artikel = eintrag.artikel, let einkaufsliste = eintrag.einkaufsvorgang?.einkaufsliste else { continue }
            ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig(
                artikel: artikel, produkt: eintrag.produkt, einkaufsliste: einkaufsliste, am: eintrag.datum, bekannt: &bekannt,
                context: context
            )
        }
        for eintrag in (try? context.fetch(FetchDescriptor<EinkaufslistenEintrag>())) ?? [] {
            guard let artikel = eintrag.artikel, let einkaufsliste = eintrag.einkaufsliste else { continue }
            ArtikelListenKaufService.vermerkeHinzugefuegtFallsNoetig(
                artikel: artikel, produkt: eintrag.produkt, einkaufsliste: einkaufsliste, am: eintrag.erstelltAm, bekannt: &bekannt,
                context: context
            )
        }
        let neuVermerkt = bekannt.count - vorherAnzahl
        guard neuVermerkt > 0 else { return }
        try? context.save()
        DatenintegritaetsLogger.log(
            "\(neuVermerkt) Artikel-Listen-Kauf-Fakten rückwirkend aus bestehenden Kaufeinträgen/offenen Listen-Einträgen ergänzt (GitHub #99, Architektur-Review 2026-08-10)"
        )
    }

    /// Wiederkehrendes Sicherheitsnetz (GitHub #126): entfernt (+ tombstoned)
    /// ``KaufEintrag``e, die denselben ``Artikel`` ein zweites Mal im
    /// SELBEN ``Einkaufsvorgang`` abbilden — strukturell IMMER ein Fehler
    /// (ein Artikel wird pro Einkaufsvorgang höchstens einmal gekauft, siehe
    /// den lokalen `bereitsVorhanden`-Schutz in
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``).
    /// Dieser Schutz greift nur beim direkten lokalen Abhaken —
    /// ``SyncSnapshotImportService/mergeKaufEintraege(_:artikelZuordnung:einkaufsvorgangZuordnung:geschaeftZuordnung:abteilungZuordnung:peerGeraeteID:context:)``
    /// legt `KaufEintrag`e aus einem Bereich-C-Snapshot ohne dieselbe Prüfung
    /// an und konnte dadurch, kombiniert mit dem inzwischen behobenen
    /// fehlenden Tombstoning bei
    /// ``Einkaufsvorgang/artikelAbwaehlenOhneEventAufzeichnung(_:context:)``/
    /// ``Einkaufsvorgang/artikelDauerhaftEntfernenOhneEventAufzeichnung(_:context:)``,
    /// Phantom-Duplikate entstehen lassen (Live-Vorfall „Buns", 2026-08-21).
    ///
    /// **Bewusst NICHT anhand von Zeitstempel-Heuristiken über verschiedene
    /// Einkaufsvorgänge hinweg entschieden** — ein Artikel darf über mehrere
    /// Einkäufe hinweg legitim wiederholt gekauft werden (z.B. Milch jede
    /// Woche); ein Vergleich gegen ``ArtikelListenKauf/zuletztHinzugefuegtAm``
    /// (wie in `mergeKaufEintraege`) würde dort fälschlich echte Kaufhistorie
    /// löschen. Nur die enge, unzweideutige Bedingung „zwei `KaufEintrag`e,
    /// ein Vorgang, ein Artikel, dasselbe Produkt" ist in jedem Fall ein
    /// Fehler. Behält den `KaufEintrag` mit dem SPÄTEREN `datum` (der zuletzt
    /// bestätigte Stand), löscht + tombstoned die übrigen.
    ///
    /// **Produkt-Vergleich (GitHub #172):** vor diesem Fix gruppierte diese
    /// Bereinigung rein nach (Vorgang, Artikel) — zwei ECHTE, unterschiedliche
    /// Produkte desselben generischen Artikels, die beide im selben Vorgang
    /// gekauft wurden (z.B. zwei verschiedene Batterie-Typen in einem
    /// Einkauf), hätte sie fälschlich als Duplikat behandelt und den
    /// KaufEintrag des älteren Produkts dauerhaft gelöscht.
    ///
    /// Läuft dauerhaft bei jedem App-Start (kein einmaliges Migrationsflag,
    /// anders als ``migriereGeschaeftsAggregateFallsNoetig(context:)``) — dient
    /// damit sowohl der einmaligen Bereinigung bereits bestehender
    /// Dopplungen als auch als generelles Sicherheitsnetz gegen einen
    /// künftigen, heute unbekannten Bug mit demselben Symptom. Bei den hier
    /// relevanten Datenmengen (Anzahl `KaufEintrag`e pro Gerät, siehe
    /// ``KaufEintragBereinigungService``) unkritisch teuer.
    @MainActor
    static func bereinigeDoppelteKaufEintraegeFallsNoetig(context: ModelContext) {
        struct Schluessel: Hashable {
            let vorgangID: PersistentIdentifier
            let artikelID: PersistentIdentifier
            let produktID: PersistentIdentifier?
        }
        var gruppen: [Schluessel: [KaufEintrag]] = [:]
        for eintrag in (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [] {
            guard let vorgang = eintrag.einkaufsvorgang, let artikel = eintrag.artikel else { continue }
            gruppen[
                Schluessel(vorgangID: vorgang.persistentModelID, artikelID: artikel.persistentModelID, produktID: eintrag.produkt?.persistentModelID),
                default: []
            ].append(eintrag)
        }

        var entfernt = 0
        for (_, eintraege) in gruppen where eintraege.count > 1 {
            let sortiert = eintraege.sorted { $0.datum < $1.datum }
            for duplikat in sortiert.dropLast() {
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: duplikat.id, context: context)
                context.delete(duplikat)
                entfernt += 1
            }
        }
        guard entfernt > 0 else { return }
        try? context.save()
        DatenintegritaetsLogger.log("\(entfernt) doppelte KaufEintraege (gleicher Artikel im selben Einkaufsvorgang) bereinigt (GitHub #126)")
    }

    /// `nil` gilt nie als baumelnd (ein leerer Bezug ist ein gültiger
    /// Fachzustand, siehe z.B. den `Einkaufsvorgang.einkaufsliste`-Sonderfall
    /// weiter unten) — nur ein gesetztes `objekt`, dessen `persistentModelID`
    /// nicht (mehr) unter `gueltigeIDs` ist, gilt als baumelnd.
    private static func istBaumelnd<T: PersistentModel>(_ objekt: T?, gueltigeIDs: Set<PersistentIdentifier>) -> Bool {
        guard let objekt else { return false }
        return !gueltigeIDs.contains(objekt.persistentModelID)
    }
}
