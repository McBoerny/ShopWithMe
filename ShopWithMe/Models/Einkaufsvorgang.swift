import Foundation
import SwiftData

/// Ergebnis von ``Einkaufsvorgang/artikelAbhaken(_:context:)`` (GitHub #48,
/// Überkauf-Hinweis) — unterscheidet eine tatsächliche Neuanlage von einem
/// bereits (von diesem oder einem anderen Gerät) abgehakten Artikel, damit die
/// UI im zweiten Fall einen kurzen, nicht blockierenden Hinweis zeigen kann,
/// statt den Vorgang stillschweigend zu ignorieren.
enum AbhakErgebnis: Equatable {
    case abgehakt
    /// `geraeteID` ist die `SyncEvent.autorGeraeteID` des ursprünglich
    /// abhakenden Geräts (siehe
    /// ``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``),
    /// `nil` falls kein zugehöriges Event gefunden wurde (z.B. eine vor
    /// Einführung der Datensynchronisation entstandene Altlast). Eine
    /// menschenlesbare Form liefert ``SyncPeerInfo/geraeteName(fuer:context:)``.
    case bereitsAbgehaktVon(geraeteID: String?)
}

/// Ein einzelner Einkaufsvorgang (Ladenbesuch) in einem bestimmten ``Geschaeft``.
///
/// Während eines Einkaufsvorgangs entstehen ``KaufEintrag``e, aus deren
/// Reihenfolge der ``AbteilungsDistanzService`` lernt, welche Abteilungen
/// im jeweiligen Geschäft räumlich nah beieinanderliegen.
@Model
final class Einkaufsvorgang {
    /// Eindeutige Kennung. `@Attribute(.unique)` seit GitHub #102 (vorher
    /// unindiziert, jeder ID-Lookup im Sync-Merge war ein Full-Table-Scan) —
    /// sicher eingeführt erst nach Prüfung des realen Bestands per
    /// ``ModellIDDuplikatService`` auf bereits bestehende Duplikate.
    @Attribute(.unique) var id: UUID
    /// Das Geschäft, in dem dieser Einkauf stattfindet.
    var geschaeft: Geschaeft?
    /// Die Einkaufsliste, aus der dieser Einkauf abgehakt wird.
    var einkaufsliste: Einkaufsliste?
    /// Startzeitpunkt des Einkaufs.
    var startZeit: Date
    /// Endzeitpunkt — `nil`, solange der Einkauf noch läuft.
    var endZeit: Date?
    /// Die einzelnen Käufe dieses Einkaufsvorgangs.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.einkaufsvorgang)
    var kaufEintraege: [KaufEintrag] = []

    init(geschaeft: Geschaeft? = nil, einkaufsliste: Einkaufsliste? = nil, startZeit: Date = Date()) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.einkaufsliste = einkaufsliste
        self.startZeit = startZeit
    }

    /// Ob dieser Einkaufsvorgang bereits abgeschlossen wurde.
    var istAbgeschlossen: Bool { endZeit != nil }

    /// Beendet den Einkaufsvorgang zum angegebenen Zeitpunkt (Standard: jetzt) und
    /// erhöht — falls ``geschaeft`` gesetzt UND `zaehleAlsBesuch` `true` ist —
    /// dessen rein lokalen Anteil ``Geschaeft/eigeneAnzahlEinkaufsvorgaenge``
    /// (GitHub #30; der über alle Geräte gemergte
    /// ``Geschaeft/anzahlEinkaufsvorgaenge`` ergibt sich daraus automatisch beim
    /// Lesen).
    ///
    /// `zaehleAlsBesuch: false` für zusätzliche, zur selben Kombination aus
    /// Geschäft und Liste gehörende Duplikat-Vorgänge, die zusammen mit dem
    /// eigentlichen Vorgang geschlossen werden (Live-Test-Fund, Session
    /// 2026-08-03, siehe ``EinkaufenView/EinkaufslisteView/einkaufAbschliessen()``)
    /// — sie repräsentieren denselben physischen Ladenbesuch und dürfen ihn
    /// nicht zusätzlich mitzählen.
    func abschliessen(am zeitpunkt: Date = Date(), zaehleAlsBesuch: Bool = true) {
        endZeit = zeitpunkt
        guard zaehleAlsBesuch else { return }
        geschaeft?.eigeneAnzahlEinkaufsvorgaenge += 1
    }

    /// Markiert einen Artikel als gekauft: legt einen ``KaufEintrag`` (zunächst ohne
    /// Preis) in diesem Einkaufsvorgang an und entfernt den Artikel von
    /// ``einkaufsliste`` (falls dort noch ein ``EinkaufslistenEintrag`` existiert).
    /// Artikel mit derselben Abteilung erhalten denselben
    /// ``KaufEintrag/abteilungBesuchsIndex``, neue Abteilungen den jeweils nächsten
    /// Index — das ist die Rohdatenbasis für ``AbteilungsDistanzService``. Artikel
    /// ohne eigene Abteilung fallen dabei automatisch unter "Sonstiges". Reine
    /// Zustandsmutation ohne Event-Aufzeichnung, siehe ``artikelAbhaken(_:context:abteilung:)``.
    /// Liefert ``AbhakErgebnis/abgehakt``, falls tatsächlich ein ``KaufEintrag``
    /// entstanden ist (Grundlage dafür, ob die aufzeichnende Variante ein Event
    /// erzeugt) — sonst ``AbhakErgebnis/bereitsAbgehaktVon(geraeteID:)`` (GitHub
    /// #48, Überkauf-Hinweis).
    ///
    /// `ursprungsGeraeteID` (siehe ``SyncImportService``) unterdrückt die
    /// Vergabe eines ``KaufEintrag/abteilungBesuchsIndex`` bewusst, sobald sie
    /// nicht `nil` ist (durchgereicht an ``KaufEintrag/ursprungsGeraeteID``, das
    /// die Unterdrückung zentral im Typ selbst erzwingt, GitHub #68): Ein von
    /// einem Peer per Bereich-A-Event empfangenes Abhaken beschreibt, wo/wann
    /// **dessen** Nutzer durchs Geschäft gelaufen ist, nicht wo dieses Gerät
    /// gerade steht — würde es trotzdem einen Index aus der lokalen
    /// Besuchsreihenfolge bekommen (`naechsterAbteilungBesuchsIndex(fuer:)`),
    /// erschiene es fälschlich als "als Nächstes von diesem Nutzer besucht" und
    /// würde die ladenspezifische Distanzmatrix
    /// (``AbteilungsDistanzService/besuchsreihenfolge(fuer:)`` überspringt
    /// `nil`-Indizes bewusst) mit einer erfundenen Position verfälschen. Der
    /// Artikel gilt dadurch weiterhin korrekt als abgehakt (KaufEintrag
    /// existiert, verschwindet von der offenen Liste), fließt aber nicht in die
    /// Reihenfolge-Analyse ein.
    ///
    /// `abteilung`: explizite Abteilung, aus deren Abschnitt der Nutzer
    /// tatsächlich abgehakt hat (``EinkaufenView`` zeigt einen Artikel mit
    /// mehreren Abteilungen gleichzeitig in allen zugehörigen Abschnitten an) —
    /// `nil` fällt auf ``Artikel/fuehrendeAbteilung(inGeschaeft:context:)`` zurück
    /// (Belegscan, Preisschild-Scan, Sync-Import, wo kein konkreter Abschnitt
    /// getappt wurde). Genau dieses Signal ist die Grundlage dafür, dass
    /// ``AbteilungsDistanzService`` pro Geschäft lernen kann, in welcher der
    /// mehreren zugeordneten Abteilungen ein Artikel dort tatsächlich steht (z.B.
    /// Sojasauce bei Edeka unter "Soßen", bei Aldi unter "Asia") statt einer
    /// global für den Artikel geratenen.
    /// `geschaeftUeberschreibung` ist ein DOPPELT optionaler Parameter
    /// (`Geschaeft??`), um „kein Override" (Standardfall: `nil`, `self.geschaeft`
    /// gilt) von „Override auf explizit KEIN Geschäft" (`.some(nil)`) zu
    /// unterscheiden (GitHub #66) — Letzteres tritt auf, wenn ein per Sync
    /// empfangenes Ereignis meldet, dass auf dem sendenden Gerät gar kein
    /// Geschäft ausgewählt war. Ein Aufrufer, der einen bereits als
    /// `Geschaeft?` typisierten Wert übergibt (auch wenn dessen Inhalt `nil`
    /// ist), wird von Swift automatisch korrekt in die äußere Optionalität
    /// gehoben — nur der reine `nil`-Literal bedeutet „kein Override".
    /// `datum`: Zeitpunkt des ``KaufEintrag``s — Default `Date()` (lokales
    /// Abhaken „jetzt"). **Live-Fund (2026-08-24):** der per Bereich-A-Event
    /// materialisierte Aufrufer (``SyncImportService``) übergab hier bisher
    /// KEINEN Zeitpunkt, obwohl das Event selbst einen ursprünglichen
    /// ``SyncEvent/wallClock`` trägt — jeder `KaufEintrag` aus einem
    /// Event-Replay (z.B. kompletter historischer Nachhol-Lauf nach einem
    /// Geräte-Neuaufbau) bekam dadurch fälschlich den AKTUELLEN
    /// Import-Zeitpunkt statt des tatsächlichen historischen Kaufdatums —
    /// verfälscht sowohl die Kaufhistorie-/Preishistorie-Anzeige als auch
    /// (über ``ArtikelListenKaufService/vermerkeAbgehakt(artikel:einkaufsliste:am:context:)``
    /// unten) den `zuletztAbgehaktAm`-Vergleichswert des Sicherheitsnetzes
    /// (Abschnitt 4.7). Analog zum bereits bestehenden `am:`-Parameter von
    /// ``Einkaufsliste/artikelHinzufuegenOhneEventAufzeichnung(_:produkt:am:context:)``.
    @discardableResult
    func artikelAbhakenOhneEventAufzeichnung(
        _ artikel: Artikel, produkt: Produkt? = nil, am datum: Date = Date(), context: ModelContext, ursprungsGeraeteID: String? = nil,
        abteilung abteilungUeberschreibung: Abteilung? = nil,
        geschaeft geschaeftUeberschreibung: Geschaeft?? = nil
    ) -> AbhakErgebnis {
        artikelAbhakenKern(
            artikel, produkt: produkt, am: datum, context: context, ursprungsGeraeteID: ursprungsGeraeteID,
            abteilung: abteilungUeberschreibung, geschaeft: geschaeftUeberschreibung
        ) { einkaufsliste, eintragDatum in
            ArtikelListenKaufService.vermerkeAbgehakt(
                artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, am: eintragDatum, context: context
            )
        }
    }

    /// Wie ``artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``,
    /// nutzt aber für das ``ArtikelListenKauf``-Sicherheitsnetz-Faktum die
    /// Batch-Variante ``ArtikelListenKaufService/vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``
    /// statt eines eigenen Fetches pro Aufruf — für ``SyncImportService``s
    /// Bereich-A-Batch-Import, der `bekannt` einmal pro Import-Durchlauf lädt
    /// und über viele Events hinweg wiederverwendet (Performance-Fund #159).
    @discardableResult
    func artikelAbhakenAlsEventReplay(
        _ artikel: Artikel, produkt: Produkt? = nil, am datum: Date, context: ModelContext, ursprungsGeraeteID: String? = nil,
        abteilung abteilungUeberschreibung: Abteilung? = nil,
        geschaeft geschaeftUeberschreibung: Geschaeft?? = nil,
        bekannt: inout [ArtikelListenKaufService.Schluessel: ArtikelListenKauf]
    ) -> AbhakErgebnis {
        artikelAbhakenKern(
            artikel, produkt: produkt, am: datum, context: context, ursprungsGeraeteID: ursprungsGeraeteID,
            abteilung: abteilungUeberschreibung, geschaeft: geschaeftUeberschreibung
        ) { einkaufsliste, eintragDatum in
            ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig(
                artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, am: eintragDatum, bekannt: &bekannt, context: context
            )
        }
    }

    /// Gemeinsamer Kern von ``artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``
    /// und ``artikelAbhakenAlsEventReplay(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:bekannt:)``
    /// — beide unterscheiden sich nur darin, WIE das abschließende
    /// ``ArtikelListenKauf``-Sicherheitsnetz-Faktum vermerkt wird (Einzel-Fetch
    /// vs. vorgeladenes Batch-Dictionary); die komplette Dedupe-/KaufEintrag-Logik
    /// bleibt dadurch an genau einer Stelle (Single Source of Truth statt
    /// Duplikat-Pflege).
    private func artikelAbhakenKern(
        _ artikel: Artikel, produkt: Produkt?, am datum: Date, context: ModelContext, ursprungsGeraeteID: String?,
        abteilung abteilungUeberschreibung: Abteilung?,
        geschaeft geschaeftUeberschreibung: Geschaeft??,
        vermerkeAbgehakt: (Einkaufsliste, Date) -> Void
    ) -> AbhakErgebnis {
        // Dedupe-Schutz gegen das in `docs/DATABASE_CONCURRENCY.md` dokumentierte
        // Restrisiko (Sync-Latenz-Kollisionsfenster bei zeitgleichem Abhaken auf zwei
        // Geräten) — bewusst LISTE-weit über alle noch offenen Vorgänge geprüft,
        // nicht nur `self` (Live-Test-Fund, Nachtrag Session 2026-08-03): seit die
        // „abgehakt"-Ansicht listenweit über alle offenen Vorgänge gilt (Abschnitt
        // 35/37), muss auch dieser Schutz auf derselben Ebene greifen. Eine
        // Prüfung nur gegen `self` ließ denselben Artikel unter zwei
        // unterschiedlichen, beide offenen Vorgängen (z.B. zwei verschiedenen
        // Geschäften) unabhängig voneinander abhaken — zwei separate
        // `KaufEintrag`e, von denen „Abwählen" pro Tap nur EINEN entfernte; der
        // Artikel blieb scheinbar dauerhaft „abgehakt" hängen.
        let artikelID = artikel.persistentModelID
        // Produkt-Vergleich (GitHub #172): zwei unterschiedliche Produkte
        // desselben generischen Artikels dürfen einander nicht als „schon
        // abgehakt" ausbremsen — vor diesem Fix matchte der Dedupe-Schutz
        // rein artikelweit und löschte dadurch den Listeneintrag eines ganz
        // anderen Produkts, sobald irgendein Produkt des Artikels im selben
        // Vorgang bereits einen offenen ``KaufEintrag`` hatte.
        let produktID = produkt?.persistentModelID
        let deskriptor = FetchDescriptor<KaufEintrag>(
            predicate: #Predicate { $0.artikel?.persistentModelID == artikelID && $0.produkt?.persistentModelID == produktID }
        )
        let listenEintrag = einkaufsliste?.eintrag(fuer: artikel, produkt: produkt)
        let bereitsVorhanden = ((try? context.fetch(deskriptor)) ?? []).first {
            $0.einkaufsvorgang?.einkaufsliste?.persistentModelID == einkaufsliste?.persistentModelID
                && $0.einkaufsvorgang?.endZeit == nil
        }
        if let bereitsVorhanden {
            // `listenEintragVorhanden`-Zusatz (Nutzerbericht 2026-08-10,
            // „Backup schließt ab, Artikel bleiben trotzdem auf der Liste"):
            // unterscheidet im Log, ob hier tatsächlich noch ein
            // ``EinkaufslistenEintrag`` zum Löschen gefunden wurde, oder ob er
            // zu diesem Zeitpunkt bereits fehlte (z.B. durch einen früher in
            // diesem Zyklus gelaufenen Bereich-C-Merge) — ohne diesen Zusatz
            // ist aus dem Log allein nicht ablesbar, ob DIESER Zweig für den
            // gemeldeten Befund überhaupt ursächlich sein kann.
            DatabaseDebugLogger.log(
                .dedupeConflictDetected,
                details: "artikelAbhaken: \(artikel.name) produkt=\(produkt?.name ?? "-") listenEintragVorhanden=\(listenEintrag != nil)"
            )
            if let listenEintrag { context.delete(listenEintrag) }
            let besitzerID = bereitsVorhanden.einkaufsvorgang?.id ?? id
            let gewinner = SyncEventService.aktuellerGewinner(bezugsID: besitzerID, artikelID: artikel.id, context: context)
            return .bereitsAbgehaktVon(geraeteID: gewinner?.autorGeraeteID)
        }

        let geschaeftFuerEintrag = geschaeftUeberschreibung ?? geschaeft
        let abteilung = abteilungUeberschreibung ?? artikel.fuehrendeAbteilung(inGeschaeft: geschaeftFuerEintrag, context: context)
        let index = ursprungsGeraeteID == nil ? naechsterAbteilungBesuchsIndex(fuer: abteilung) : nil
        let eintrag = KaufEintrag(
            artikel: artikel,
            geschaeft: geschaeftFuerEintrag,
            abteilung: abteilung,
            produkt: produkt,
            menge: listenEintrag?.menge ?? artikel.mengenSchritt,
            datum: datum,
            abteilungBesuchsIndex: index,
            ursprungsGeraeteID: ursprungsGeraeteID
        )
        context.insert(eintrag)
        eintrag.einkaufsvorgang = self
        if let listenEintrag { context.delete(listenEintrag) }
        if let geschaeftFuerEintrag {
            ArtikelVerfuegbarkeitService.vermerkeGekauft(artikel: artikel, geschaeft: geschaeftFuerEintrag, context: context)
        }
        if let einkaufsliste {
            // GitHub #99: dauerhaftes Faktum fürs Sicherheitsnetz gegen
            // wiederbelebte Käufe, unabhängig davon, ob dieser KaufEintrag
            // später per KaufEintragBereinigungService gelöscht wird.
            vermerkeAbgehakt(einkaufsliste, eintrag.datum)
        }
        return .abgehakt
    }

    /// Wie ``artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``,
    /// zeichnet zusätzlich (nur bei tatsächlicher Neuanlage) ein
    /// ``SyncEventArt/artikelAbgehakt``-Event auf (Phase 0,
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md`) — inklusive des eigenen
    /// aktuellen ``geschaeft`` in der Nutzlast (GitHub #66), damit ein
    /// Empfänger den Kaufeintrag auch nach einer Umleitung auf einen anderen
    /// Vorgang mit dem tatsächlich zutreffenden Geschäft anlegen kann.
    @discardableResult
    func artikelAbhaken(_ artikel: Artikel, produkt: Produkt? = nil, context: ModelContext, abteilung: Abteilung? = nil) -> AbhakErgebnis {
        let ergebnis = artikelAbhakenOhneEventAufzeichnung(artikel, produkt: produkt, context: context, abteilung: abteilung)
        if ergebnis == .abgehakt {
            SyncEventService.aufzeichnen(.artikelAbgehakt, bezugsID: id, artikelID: artikel.id, geschaeftID: geschaeft?.id, context: context)
        }
        return ergebnis
    }

    /// Macht ``artikelAbhaken(_:context:)`` rückgängig: löscht den zugehörigen
    /// ``KaufEintrag`` und setzt den Artikel zurück auf ``einkaufsliste`` (inkl.
    /// Zurücksetzen von Menge/temporärer Notiz, siehe
    /// ``Einkaufsliste/artikelHinzufuegenOhneEventAufzeichnung(_:produkt:am:context:)``).
    /// Reine Zustandsmutation ohne eigene Event-Aufzeichnung, siehe
    /// ``artikelAbwaehlen(_:context:)``. Liefert `true`, falls tatsächlich ein
    /// ``KaufEintrag`` gelöscht wurde.
    @discardableResult
    @MainActor
    func artikelAbwaehlenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> Bool {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return false }
        let eintrag = kaufEintraege.remove(at: index)
        // GitHub #126: ohne Tombstone kann ein Peer, dessen periodischer
        // Bereich-C-Export knapp vor dieser Rücknahme lief, den soeben wieder
        // gelöschten KaufEintrag per union-by-id-Merge
        // (`SyncSnapshotImportService.mergeKaufEintraege`) dauerhaft
        // zurückholen — der Artikel erscheint dann gleichzeitig als "gekauft"
        // (Phantom-KaufEintrag) und als "offen" (durch `artikelHinzufuegenOhneEventAufzeichnung`
        // unten korrekt wieder auf die Liste gesetzt).
        SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintrag.id, context: context)
        context.delete(eintrag)
        // Sofort entfernen statt auf den täglichen Catch-all
        // (`SyncKaeufeExportService.raeumeVerwaisteDateienAuf`) zu warten —
        // dieselbe Begründung wie bei `KaufEintragBereinigungService.bereinigen`.
        SyncKaeufeExportService.entferneDateien(fuerKaufEintragIDs: [eintrag.id])
        einkaufsliste?.artikelHinzufuegenOhneEventAufzeichnung(artikel, context: context)
        return true
    }

    /// Wie ``artikelAbwaehlenOhneEventAufzeichnung(_:context:)``, zeichnet
    /// zusätzlich (nur bei tatsächlicher Rücknahme) ein
    /// ``SyncEventArt/artikelAbgewaehlt``-Event auf.
    @MainActor
    func artikelAbwaehlen(_ artikel: Artikel, context: ModelContext) {
        guard artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context) else { return }
        SyncEventService.aufzeichnen(.artikelAbgewaehlt, bezugsID: id, artikelID: artikel.id, context: context)
    }

    /// Entfernt einen bereits abgehakten Artikel dauerhaft aus der Einkaufsliste-Ansicht
    /// dieses Einkaufsvorgangs: anders als ``artikelAbwaehlen(_:context:)`` wird der
    /// Artikel dabei NICHT wieder auf die Einkaufsliste zurückgesetzt (er bleibt, was er
    /// nach ``artikelAbhaken(_:context:)`` bereits war). Nur der zugehörige
    /// ``KaufEintrag`` wird gelöscht, damit der Artikel auch aus der
    /// "abgehakt"-Ansicht dieses Einkaufs verschwindet, statt versehentlich per Tipp
    /// wieder zurückgeholt werden zu können. Reine Zustandsmutation ohne
    /// Event-Aufzeichnung, siehe ``artikelDauerhaftEntfernen(_:context:)``.
    @discardableResult
    @MainActor
    func artikelDauerhaftEntfernenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> Bool {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return false }
        let eintrag = kaufEintraege.remove(at: index)
        // GitHub #126: siehe Begründung an `artikelAbwaehlenOhneEventAufzeichnung`
        // — derselbe Resurrektions-Bug betrifft jede direkte KaufEintrag-Löschung
        // außerhalb von `KaufEintragBereinigungService` (das bereits tombstoned).
        SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintrag.id, context: context)
        context.delete(eintrag)
        // Sofort entfernen statt auf den täglichen Catch-all zu warten, siehe
        // Begründung an `artikelAbwaehlenOhneEventAufzeichnung`.
        SyncKaeufeExportService.entferneDateien(fuerKaufEintragIDs: [eintrag.id])
        return true
    }

    /// Wie ``artikelDauerhaftEntfernenOhneEventAufzeichnung(_:context:)``,
    /// zeichnet zusätzlich (nur bei tatsächlicher Entfernung) ein
    /// ``SyncEventArt/artikelDauerhaftEntfernt``-Event auf.
    @MainActor
    func artikelDauerhaftEntfernen(_ artikel: Artikel, context: ModelContext) {
        guard artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context) else { return }
        SyncEventService.aufzeichnen(.artikelDauerhaftEntfernt, bezugsID: id, artikelID: artikel.id, context: context)
    }

    /// Sucht bewusst nur unter Einträgen mit BEREITS VORHANDENEM Index (nicht per
    /// simplem `first(where:)` über die ungeordnete `kaufEintraege`-Relationship):
    /// seit remote materialisierte/gemergte Einträge bewusst `abteilungBesuchsIndex
    /// == nil` bekommen (siehe ``artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``),
    /// könnte die ungeordnete Aufzählung sonst zuerst auf so einen `nil`-Eintrag
    /// treffen und fälschlich einen NEUEN Index für eine Abteilung vergeben, die
    /// lokal bereits einen echten Index hat — zwei Besuchs-Slots für dieselbe
    /// Abteilung, die die gelernte Distanzmatrix verfälschen.
    private func naechsterAbteilungBesuchsIndex(fuer abteilung: Abteilung) -> Int {
        if let vorhandenerIndex = kaufEintraege.first(where: { $0.abteilung == abteilung && $0.abteilungBesuchsIndex != nil })?.abteilungBesuchsIndex {
            return vorhandenerIndex
        }
        return (kaufEintraege.compactMap(\.abteilungBesuchsIndex).max() ?? -1) + 1
    }
}

extension Einkaufsvorgang {
    /// Wählt aus mehreren gleichzeitig offenen Kandidaten für dieselbe
    /// (Geschäft, Liste)-Kombination deterministisch DEN einen kanonischen
    /// aus, den alle Geräte nach einer Synchronisation übereinstimmend
    /// wählen (GitHub #67-Erweiterung): der älteste ``startZeit`` gewinnt,
    /// bei exaktem Gleichstand die lexikographisch kleinere ``id`` als
    /// stabiler Tiebreaker (analog `LamportTimestamp`).
    ///
    /// **Zwei verbleibende Anwendungsfälle** (seit der Entkopplung der
    /// Live-Ansicht von der Vorgangs-Identität, Session 2026-08-03, nicht
    /// mehr für die Anzeige „was ist abgehakt" gebraucht — siehe
    /// ``SyncImportService`` und `docs/DATENSYNCHRONISATION.md` Abschnitt
    /// 4.3):
    /// - ``SyncSnapshotImportService/mergeEinkaufsvorgaenge(_:geschaeftZuordnung:listeZuordnung:context:)``
    ///   (`offenerTreffer`): verhindert Doppelzählung im Besuchszähler/
    ///   -protokoll, wenn zwei Geräte unabhängig je einen Vorgang für
    ///   denselben (Geschäft, Liste) anlegen, bevor sie das erste Mal
    ///   synchronisieren.
    /// - `EinkaufenView.aktuellerEinkauf`: wählt deterministisch den lokalen
    ///   Anker-Vorgang, an dem NEUE eigene Häkchen landen, falls lokal
    ///   mehrere offene Kandidaten für dieselbe Kombination existieren.
    ///
    /// **Hintergrund:** Zwei Geräte, die kurz nacheinander (vor dem ersten
    /// Sync-Zyklus) unabhängig je einen eigenen Vorgang für dieselbe
    /// Kombination anlegen (Race beim gleichzeitigen Betreten desselben
    /// Ladens), hatten vorher keine gemeinsame Regel, WELCHEN der beiden
    /// jedes Gerät als „den aktuellen" behandelt — jede Stelle wählte einen
    /// beliebigen, per Fetch-Reihenfolge nicht garantierten Treffer. Da
    /// ``startZeit`` beim Sync unverändert übernommen wird (nie lokal neu
    /// gesetzt), kommen alle Geräte nach der Synchronisation zuverlässig auf
    /// denselben Vorgang.
    static func kanonischer(unter kandidaten: [Einkaufsvorgang]) -> Einkaufsvorgang? {
        kandidaten.min { a, b in
            if a.startZeit != b.startZeit { return a.startZeit < b.startZeit }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Alle für die Live-Ansicht relevanten Kaufeinträge von `liste` — von
    /// EGAL welchem der übergebenen `vorgaenge` (eigenem oder
    /// synchronisiertem), solange dessen ``Einkaufsvorgang/endZeit`` noch
    /// `nil` ist. Verwendet von ``EinkaufenView`` als Ersatz für die frühere
    /// Vorgangs-Umleitung (Session 2026-08-03, siehe
    /// `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3): ein von einem anderen
    /// Gerät abgehakter Artikel muss dafür nicht mehr auf „meinen" aktuell
    /// offenen Vorgang umgeleitet werden.
    ///
    /// **Bewusst KEIN Zeitfenster** (Live-Test-Fund, Nachtrag Session
    /// 2026-08-03): eine frühere Fassung filterte stattdessen nach
    /// `KaufEintrag.datum >= aktuellerEinkauf.startZeit` — das koppelte die
    /// Sichtbarkeit an die zufällige, rein lokale Vorgangs-Historie des
    /// BETRACHTENDEN Geräts, nicht an den tatsächlichen Zustand des Vorgangs,
    /// dem der Eintrag gehört. Wählte ein Gerät gerade „Kein Geschäft“ mit
    /// einem alten, seit Stunden offenen Vorgang, blieb ein längst
    /// abgeschlossener Kauf eines anderen Geräts dort sichtbar; wählte
    /// dasselbe Gerät kurz vorher ein Geschäft und rotierte dadurch seinen
    /// eigenen Vorgang, verschwand derselbe Kauf dort wieder — zwei Geräte
    /// (oder zwei Ansichten desselben Geräts) zeigten dieselbe Liste
    /// inkonsistent. Der ursprüngliche Auftrag lautete „sichtbar, SOLANGE DER
    /// EINKAUF NICHT ABGESCHLOSSEN IST“ — das ist der Zustand des Vorgangs
    /// (`endZeit`), kein Zeitpunkt-Vergleich. Filtert `vorgaenge` deshalb
    /// zusätzlich defensiv selbst auf `endZeit == nil`, statt sich auf eine
    /// bereits vorgefilterte Aufrufer-Liste zu verlassen.
    static func abgehakteKaufEintraege(fuerListe liste: Einkaufsliste, unter vorgaenge: [Einkaufsvorgang]) -> [KaufEintrag] {
        vorgaenge.filter { $0.einkaufsliste == liste && $0.endZeit == nil }.flatMap(\.kaufEintraege)
    }
}
