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
/// Reihenfolge der ``WarengruppenDistanzService`` lernt, welche Artikelkategorien
/// im jeweiligen Geschäft räumlich nah beieinanderliegen.
@Model
final class Einkaufsvorgang {
    /// Eindeutige Kennung.
    var id: UUID
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
    /// Artikel mit derselben Kategorie erhalten denselben
    /// ``KaufEintrag/kategorieBesuchsIndex``, neue Kategorien den jeweils nächsten
    /// Index — das ist die Rohdatenbasis für ``WarengruppenDistanzService``. Artikel
    /// ohne eigene Kategorie fallen dabei automatisch unter "Sonstiges". Reine
    /// Zustandsmutation ohne Event-Aufzeichnung, siehe ``artikelAbhaken(_:context:kategorie:)``.
    /// Liefert ``AbhakErgebnis/abgehakt``, falls tatsächlich ein ``KaufEintrag``
    /// entstanden ist (Grundlage dafür, ob die aufzeichnende Variante ein Event
    /// erzeugt) — sonst ``AbhakErgebnis/bereitsAbgehaktVon(geraeteID:)`` (GitHub
    /// #48, Überkauf-Hinweis).
    ///
    /// `indexFuerDistanzlernen: false` (siehe ``SyncImportService``) unterdrückt
    /// die Vergabe eines ``KaufEintrag/kategorieBesuchsIndex`` bewusst: Ein von
    /// einem Peer per Bereich-A-Event empfangenes Abhaken beschreibt, wo/wann
    /// **dessen** Nutzer durchs Geschäft gelaufen ist, nicht wo dieses Gerät
    /// gerade steht — würde es trotzdem einen Index aus der lokalen
    /// Besuchsreihenfolge bekommen (`naechsterKategorieBesuchsIndex(fuer:)`),
    /// erschiene es fälschlich als "als Nächstes von diesem Nutzer besucht" und
    /// würde die ladenspezifische Distanzmatrix
    /// (``WarengruppenDistanzService/besuchsreihenfolge(fuer:)`` überspringt
    /// `nil`-Indizes bewusst) mit einer erfundenen Position verfälschen. Der
    /// Artikel gilt dadurch weiterhin korrekt als abgehakt (KaufEintrag
    /// existiert, verschwindet von der offenen Liste), fließt aber nicht in die
    /// Reihenfolge-Analyse ein.
    ///
    /// `kategorie`: explizite Kategorie, aus deren Abschnitt der Nutzer
    /// tatsächlich abgehakt hat (``EinkaufenView`` zeigt einen Artikel mit
    /// mehreren Kategorien gleichzeitig in allen zugehörigen Abschnitten an) —
    /// `nil` fällt auf ``Artikel/fuehrendeKategorie(inGeschaeft:context:)`` zurück
    /// (Belegscan, Preisschild-Scan, Sync-Import, wo kein konkreter Abschnitt
    /// getappt wurde). Genau dieses Signal ist die Grundlage dafür, dass
    /// ``WarengruppenDistanzService`` pro Geschäft lernen kann, in welcher der
    /// mehreren zugeordneten Kategorien ein Artikel dort tatsächlich steht (z.B.
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
    @discardableResult
    func artikelAbhakenOhneEventAufzeichnung(
        _ artikel: Artikel, context: ModelContext, indexFuerDistanzlernen: Bool = true,
        kategorie kategorieUeberschreibung: ArtikelKategorie? = nil,
        geschaeft geschaeftUeberschreibung: Geschaeft?? = nil
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
        let deskriptor = FetchDescriptor<KaufEintrag>(predicate: #Predicate { $0.artikel?.persistentModelID == artikelID })
        let listenEintrag = einkaufsliste?.eintrag(fuer: artikel)
        let bereitsVorhanden = ((try? context.fetch(deskriptor)) ?? []).first {
            $0.einkaufsvorgang?.einkaufsliste?.persistentModelID == einkaufsliste?.persistentModelID
                && $0.einkaufsvorgang?.endZeit == nil
        }
        if let bereitsVorhanden {
            DatabaseDebugLogger.log(.dedupeConflictDetected, details: "artikelAbhaken: \(artikel.name)")
            if let listenEintrag {
                context.delete(listenEintrag)
            }
            let besitzerID = bereitsVorhanden.einkaufsvorgang?.id ?? id
            let gewinner = SyncEventService.aktuellerGewinner(bezugsID: besitzerID, artikelID: artikel.id, context: context)
            return .bereitsAbgehaktVon(geraeteID: gewinner?.autorGeraeteID)
        }

        let geschaeftFuerEintrag = geschaeftUeberschreibung ?? geschaeft
        let kategorie = kategorieUeberschreibung ?? artikel.fuehrendeKategorie(inGeschaeft: geschaeftFuerEintrag, context: context)
        let index = indexFuerDistanzlernen ? naechsterKategorieBesuchsIndex(fuer: kategorie) : nil
        let eintrag = KaufEintrag(
            artikel: artikel,
            geschaeft: geschaeftFuerEintrag,
            kategorie: kategorie,
            menge: listenEintrag?.menge ?? artikel.mengenSchritt,
            kategorieBesuchsIndex: index
        )
        context.insert(eintrag)
        eintrag.einkaufsvorgang = self
        if let listenEintrag {
            context.delete(listenEintrag)
        }
        return .abgehakt
    }

    /// Wie ``artikelAbhakenOhneEventAufzeichnung(_:context:indexFuerDistanzlernen:kategorie:geschaeft:)``,
    /// zeichnet zusätzlich (nur bei tatsächlicher Neuanlage) ein
    /// ``SyncEventArt/artikelAbgehakt``-Event auf (Phase 0,
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md`) — inklusive des eigenen
    /// aktuellen ``geschaeft`` in der Nutzlast (GitHub #66), damit ein
    /// Empfänger den Kaufeintrag auch nach einer Umleitung auf einen anderen
    /// Vorgang mit dem tatsächlich zutreffenden Geschäft anlegen kann.
    @discardableResult
    func artikelAbhaken(_ artikel: Artikel, context: ModelContext, kategorie: ArtikelKategorie? = nil) -> AbhakErgebnis {
        let ergebnis = artikelAbhakenOhneEventAufzeichnung(artikel, context: context, kategorie: kategorie)
        if ergebnis == .abgehakt {
            SyncEventService.aufzeichnen(.artikelAbgehakt, bezugsID: id, artikelID: artikel.id, geschaeftID: geschaeft?.id, context: context)
        }
        return ergebnis
    }

    /// Macht ``artikelAbhaken(_:context:)`` rückgängig: löscht den zugehörigen
    /// ``KaufEintrag`` und setzt den Artikel zurück auf ``einkaufsliste`` (inkl.
    /// Zurücksetzen von Menge/temporärer Notiz, siehe
    /// ``Einkaufsliste/artikelHinzufuegenOhneEventAufzeichnung(_:context:)``).
    /// Reine Zustandsmutation ohne eigene Event-Aufzeichnung, siehe
    /// ``artikelAbwaehlen(_:context:)``. Liefert `true`, falls tatsächlich ein
    /// ``KaufEintrag`` gelöscht wurde.
    @discardableResult
    func artikelAbwaehlenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> Bool {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return false }
        let eintrag = kaufEintraege.remove(at: index)
        context.delete(eintrag)
        einkaufsliste?.artikelHinzufuegenOhneEventAufzeichnung(artikel, context: context)
        return true
    }

    /// Wie ``artikelAbwaehlenOhneEventAufzeichnung(_:context:)``, zeichnet
    /// zusätzlich (nur bei tatsächlicher Rücknahme) ein
    /// ``SyncEventArt/artikelAbgewaehlt``-Event auf.
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
    func artikelDauerhaftEntfernenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> Bool {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return false }
        let eintrag = kaufEintraege.remove(at: index)
        context.delete(eintrag)
        return true
    }

    /// Wie ``artikelDauerhaftEntfernenOhneEventAufzeichnung(_:context:)``,
    /// zeichnet zusätzlich (nur bei tatsächlicher Entfernung) ein
    /// ``SyncEventArt/artikelDauerhaftEntfernt``-Event auf.
    func artikelDauerhaftEntfernen(_ artikel: Artikel, context: ModelContext) {
        guard artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context) else { return }
        SyncEventService.aufzeichnen(.artikelDauerhaftEntfernt, bezugsID: id, artikelID: artikel.id, context: context)
    }

    /// Sucht bewusst nur unter Einträgen mit BEREITS VORHANDENEM Index (nicht per
    /// simplem `first(where:)` über die ungeordnete `kaufEintraege`-Relationship):
    /// seit remote materialisierte/gemergte Einträge bewusst `kategorieBesuchsIndex
    /// == nil` bekommen (siehe ``artikelAbhakenOhneEventAufzeichnung(_:context:indexFuerDistanzlernen:kategorie:)``),
    /// könnte die ungeordnete Aufzählung sonst zuerst auf so einen `nil`-Eintrag
    /// treffen und fälschlich einen NEUEN Index für eine Kategorie vergeben, die
    /// lokal bereits einen echten Index hat — zwei Besuchs-Slots für dieselbe
    /// Kategorie, die die gelernte Distanzmatrix verfälschen.
    private func naechsterKategorieBesuchsIndex(fuer kategorie: ArtikelKategorie) -> Int {
        if let vorhandenerIndex = kaufEintraege.first(where: { $0.kategorie == kategorie && $0.kategorieBesuchsIndex != nil })?.kategorieBesuchsIndex {
            return vorhandenerIndex
        }
        return (kaufEintraege.compactMap(\.kategorieBesuchsIndex).max() ?? -1) + 1
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
