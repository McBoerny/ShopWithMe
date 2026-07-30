import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Simuliert zwei Geräte, die sich über einen echten (temporären) gemeinsamen
/// Sync-Ordner austauschen — jedes Gerät bekommt seinen eigenen In-Memory-
/// `ModelContainer`, beide teilen sich dieselbe `SyncOrdnerService`/
/// `DatabaseLeaseService`-Konfiguration (prozessweite Singletons), daher werden
/// diese vor/nach jedem Testfall explizit zurückgesetzt bzw. isoliert
/// (`geraeteID` wird für „das andere Gerät" nicht über den echten
/// `DatabaseLeaseService.geraeteID` simuliert, sondern per direktem
/// Dateisystem-Layout, siehe ``schreibeFremdesEvent``).
@MainActor
struct SyncImportServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncEntitaetsAlias.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    /// Schreibt ein Event so, als käme es von einem fremden Gerät `fremdeGeraeteID`
    /// (nutzt direkt `SyncExportService.eventsOrdner`, um nicht auf den echten,
    /// prozessweiten ``DatabaseLeaseService/geraeteID`` angewiesen zu sein).
    private func schreibeFremdesEvent(
        _ event: SyncEventExportDarstellung, fremdeGeraeteID: String, in syncOrdner: URL
    ) throws {
        let ordner = SyncExportService.eventsOrdner(fuerPeer: fremdeGeraeteID, in: syncOrdner)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let dateiname = "\(String(format: "%010d", event.lamportZaehler))_\(event.id.uuidString).json"
        try JSONEncoder().encode(event).write(to: ordner.appendingPathComponent(dateiname))
    }

    @Test
    func importiertArtikelHinzugefuegtVonFremdemGeraet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(liste.enthaelt(apfel))
        let uebernommeneEvents = try context.fetch(FetchDescriptor<SyncEvent>())
        let uebernommen = try #require(uebernommeneEvents.first { $0.id == fremdesEvent.id })
        #expect(uebernommen.autorGeraeteID == "fremdes-geraet")
        #expect(uebernommen.hochgeladen == true)
    }

    @Test
    func importVonBereitsBekanntemEventWirdNichtErneutAngewendet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)
        liste.artikelEntfernenOhneEventAufzeichnung(apfel, context: context)
        try context.save()
        await SyncImportService.importiereNeueEvents(context: context)

        // Das (identische) Event darf beim zweiten Lauf nicht erneut angewendet
        // werden — sonst wäre der Artikel wieder auf der Liste.
        #expect(!liste.enthaelt(apfel))
    }

    @Test
    func abwaehlenGewinntGegenAbhakenUnabhaengigVonReihenfolge() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegenOhneEventAufzeichnung(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        // Lokal (dieses Gerät) abgehakt, mit niedrigerem Lamport-Zähler.
        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        let lokalesEvent = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id),
            lamportZaehler: 5, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(lokalesEvent)
        try context.save()

        // Fremdes Gerät hat (kausal unabhängig, höherer Lamport-Zähler) denselben
        // Artikel wieder abgewählt.
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 10, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(einkauf.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(apfel))
    }

    @Test
    func schwaechesAbwaehlenGewinntNichtGegenBekanntesDauerhaftEntfernen() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        // Lokal bereits dauerhaft entfernt, mit HÖHEREM Lamport-Zähler als das
        // gleich ankommende, fremde "abgewählt".
        let lokalesEvent = SyncEvent(
            art: .artikelDauerhaftEntfernt,
            nutzlast: SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id),
            lamportZaehler: 20, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(lokalesEvent)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 3, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        // "Dauerhaft entfernt" schlägt alles — der Artikel darf NICHT wieder auf
        // die Liste zurückgesetzt worden sein.
        #expect(!liste.enthaelt(apfel))
    }

    @Test
    func referenzierterEinkaufsvorgangNochNichtLokalBekanntWirdNichtAlsBekanntMarkiert() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        // bezugsID verweist auf einen Einkaufsvorgang, den dieses Gerät (noch)
        // nicht kennt (Bereich-B/C-Import ist erst Phase 3).
        let unbekannteVorgangsID = UUID()
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: unbekannteVorgangsID, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        // Nicht als bekannt markiert -> beim nächsten Zyklus wird ein erneuter
        // Versuch unternommen (kein permanenter Datenverlust).
        #expect(SyncEventService.istBereitsBekannt(fremdesEvent.id, context: context) == false)
    }

    /// Regressionstest für einen echten Zwei-Geräte-Live-Test-Fund
    /// (2026-07-30): ein referenzierter ``Einkaufsvorgang`` kann dauerhaft
    /// unauflösbar werden, OHNE je einen Tombstone zu bekommen (z.B. durch
    /// eine Nachfolger-Umleitung auf dem Ursprungsgerät, bevor die alte ID je
    /// Teil eines Snapshots wurde) — beobachtet als endloses,
    /// nie konvergierendes `sync_event_nicht_anwendbar`-Retrying über mehrere
    /// Minuten. Ein ausreichend altes Event wird deshalb aufgegeben (als
    /// bekannt markiert) statt für immer erneut versucht.
    @Test
    func dauerhaftUnaufloesbareReferenzOhneTombstoneWirdNachMaximalemAlterAufgegeben() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let vorherigeSchwelle = SyncImportService.maximalesEventAlterFuerRetry
        SyncImportService.maximalesEventAlterFuerRetry = 60
        defer { SyncImportService.maximalesEventAlterFuerRetry = vorherigeSchwelle }

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        // bezugsID verweist auf einen Einkaufsvorgang, den dieses Gerät nie
        // kennenlernen wird (kein Tombstone, aber auch nie Teil eines
        // Snapshots) — Event ist bereits älter als die (hier verkürzte) Schwelle.
        let verschwundeneVorgangsID = UUID()
        let altesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: verschwundeneVorgangsID, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet",
            wallClock: Date().addingTimeInterval(-120)
        )
        try schreibeFremdesEvent(altesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        // Als bekannt markiert -> kein weiterer Retry-Versuch mehr, obwohl nie
        // materialisiert.
        #expect(SyncEventService.istBereitsBekannt(altesEvent.id, context: context) == true)
        #expect(try context.fetch(FetchDescriptor<KaufEintrag>()).isEmpty)
    }

    /// Regressionstest für den Absturz-Loop-Serie zugrundeliegenden „dangling
    /// Einkaufsvorgang"-Fall: Gerät A beendet den Einkauf (der Vorgang wird
    /// dadurch lokal abgeschlossen und ein neuer, offener Nachfolge-Vorgang für
    /// dieselbe Liste angelegt — analog ``EinkaufenView/einkaufSicherstellen()``),
    /// BEVOR ein Peer erfährt, dass der alte Vorgang beendet wurde. Ein knapp
    /// danach vom Peer gesendetes `artikelAbgehakt`-Event referenziert deshalb
    /// noch den alten, mittlerweile geschlossenen Vorgang. Ohne Umleitung
    /// würde der `KaufEintrag` dort landen — unsichtbar in der aktuellen
    /// Einkaufsansicht und (weil `istBereitsAbgehakt` nur offene Vorgänge
    /// prüft) beim nächsten Snapshot-Merge fälschlich wieder auf die offene
    /// Liste zurückgeholt.
    ///
    /// Der neue Nachfolge-Vorgang hat hier bewusst `geschaeft == nil`: „Einkauf
    /// abschließen" setzt die Geschäftsauswahl des schließenden Geräts zurück
    /// (GitHub #51) — ein harter Geschäft-Abgleich bei der Umleitung würde
    /// genau diesen (häufigsten) Fall verfehlen.
    @Test
    func artikelAbgehaktFuerBereitsAbgeschlossenenVorgangLandetAufOffenemNachfolger() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegenOhneEventAufzeichnung(apfel, context: context)

        // Gerät A: alter Vorgang (mit Geschäft) bereits abgeschlossen, neuer
        // Vorgang für dieselbe Liste bereits angelegt und noch offen — aber
        // mit zurückgesetzter Geschäftsauswahl (`geschaeft: nil`), wie es
        // `einkaufSicherstellen()` nach „Einkauf abschließen" tatsächlich tut.
        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(alterVorgang)
        alterVorgang.abschliessen()
        let neuerVorgang = Einkaufsvorgang(geschaeft: nil, einkaufsliste: liste)
        context.insert(neuerVorgang)
        try context.save()

        // Peer hatte den alten Vorgang beim Abhaken noch als offen gesehen.
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: alterVorgang.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(alterVorgang.kaufEintraege.isEmpty)
        #expect(neuerVorgang.kaufEintraege.contains { $0.artikel == apfel })
        #expect(!liste.enthaelt(apfel))
    }

    /// Existieren für dieselbe Liste gleichzeitig ZWEI offene Vorgänge an
    /// unterschiedlichen Geschäften (zwei Geräte kaufen parallel an
    /// verschiedenen Läden dieselbe Liste ein), muss die Umleitung den
    /// Geschäft-Treffer bevorzugen, statt die beiden realen Einkäufe
    /// versehentlich zu vermischen.
    @Test
    func beiMehrerenOffenenNachfolgernWirdDerMitGleichemGeschaeftBevorzugt() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let aldi = Geschaeft(name: "Aldi", typen: [typ])
        context.insert(aldi)
        let rewe = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(rewe)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegenOhneEventAufzeichnung(apfel, context: context)

        let alterVorgang = Einkaufsvorgang(geschaeft: aldi, einkaufsliste: liste)
        context.insert(alterVorgang)
        alterVorgang.abschliessen()
        let neuerVorgangAldi = Einkaufsvorgang(geschaeft: aldi, einkaufsliste: liste)
        context.insert(neuerVorgangAldi)
        let parallelerVorgangRewe = Einkaufsvorgang(geschaeft: rewe, einkaufsliste: liste)
        context.insert(parallelerVorgangRewe)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: alterVorgang.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(neuerVorgangAldi.kaufEintraege.contains { $0.artikel == apfel })
        #expect(parallelerVorgangRewe.kaufEintraege.isEmpty)
    }

    /// Ein importiertes `artikelAbgehakt`-Event beschreibt die Laufreihenfolge
    /// des SENDENDEN Geräts durchs Geschäft, nicht die dieses Geräts — der
    /// dadurch entstehende `KaufEintrag` darf deshalb keinen
    /// `kategorieBesuchsIndex` bekommen (sonst würde
    /// `WarengruppenDistanzService` mit einer erfundenen Besuchsposition für
    /// diesen Nutzer gefüttert). Ein bereits lokal abgehakter Artikel (mit
    /// echtem Index) bleibt davon unberührt, und sein Index verschiebt sich
    /// durch das importierte Event nicht.
    @Test
    func importiertesArtikelAbgehaktEventBekommtKeinenBesuchsindex() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(birne)
        liste.artikelHinzufuegenOhneEventAufzeichnung(birne, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        // Dieses Gerät hat selbst schon einen Artikel abgehakt — bekommt
        // regulär Index 0.
        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: birne.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        let apfelEintrag = einkauf.kaufEintraege.first { $0.artikel == apfel }
        let birnenEintrag = einkauf.kaufEintraege.first { $0.artikel == birne }
        #expect(apfelEintrag?.kategorieBesuchsIndex == 0)
        #expect(birnenEintrag?.kategorieBesuchsIndex == nil)
        #expect(birnenEintrag?.kategorie == obst)
        #expect(!liste.enthaelt(birne))
    }

    /// Regressionstest (Code-Review-Fund): anders als `.artikelAbgehakt` darf
    /// `.artikelAbgewaehlt` NICHT auf den offenen Nachfolger umgeleitet werden
    /// — der abzuwählende `KaufEintrag` liegt auf dem ursprünglich
    /// referenzierten, mittlerweile geschlossenen Vorgang. Eine Umleitung würde
    /// dort ins Leere laufen (kein Treffer), das Event aber trotzdem als
    /// materialisiert gelten, wodurch der Abwähl-Wunsch des Peers dauerhaft
    /// verworfen würde.
    @Test
    func artikelAbgewaehltFuerBereitsAbgeschlossenenVorgangFindetEintragOhneUmleitung() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Testladen", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        // Artikel wurde im alten Vorgang abgehakt, bevor "Einkauf abschließen"
        // ihn schloss und den offenen Nachfolger anlegte.
        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(alterVorgang)
        alterVorgang.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        alterVorgang.abschliessen()
        let neuerVorgang = Einkaufsvorgang(geschaeft: nil, einkaufsliste: liste)
        context.insert(neuerVorgang)
        try context.save()

        // Peer wählt den (auf den alten Vorgang bezogenen) Artikel wieder ab.
        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: alterVorgang.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(alterVorgang.kaufEintraege.isEmpty)
        #expect(neuerVorgang.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(apfel))
    }

    /// Wie oben, für `.artikelDauerhaftEntfernt` — ebenfalls keine Umleitung.
    @Test
    func artikelDauerhaftEntferntFuerBereitsAbgeschlossenenVorgangFindetEintragOhneUmleitung() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let syncOrdner = macheTempSyncOrdner()
        try SyncOrdnerService.ordnerFestlegen(syncOrdner)
        defer { SyncOrdnerService.ordnerEntfernen() }

        let geschaeft = Geschaeft(name: "Testladen", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)

        let alterVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(alterVorgang)
        alterVorgang.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        alterVorgang.abschliessen()
        let neuerVorgang = Einkaufsvorgang(geschaeft: nil, einkaufsliste: liste)
        context.insert(neuerVorgang)
        try context.save()

        let fremdesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelDauerhaftEntfernt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: alterVorgang.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        try schreibeFremdesEvent(fremdesEvent, fremdeGeraeteID: "fremdes-geraet", in: syncOrdner)

        await SyncImportService.importiereNeueEvents(context: context)

        #expect(alterVorgang.kaufEintraege.isEmpty)
        #expect(neuerVorgang.kaufEintraege.isEmpty)
        #expect(!liste.enthaelt(apfel))
    }
}
