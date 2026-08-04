import Foundation
import SwiftData

/// Bereich-A-Import (`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt
/// 5.3, Phase 2): liest Event-Dateien aus allen fremden Peer-Ordnern, wendet
/// ``SyncKonfliktAufloesung`` auf konkurrierende Events desselben
/// (`bezugsID`, `artikelID`)-Paares an und materialisiert das Ergebnis über
/// dieselben Mutationsfunktionen, die auch lokale Aktionen auslösen — nur ohne
/// erneute Event-Aufzeichnung (siehe ``SyncEventService/uebernehmen(_:context:)``).
///
/// **Bekannte Grenze dieser Phase:** Ein empfangenes Event referenziert seine
/// ``Einkaufsliste``/seinen ``Einkaufsvorgang``/seinen ``Artikel`` nur über
/// deren `UUID`. Existiert die referenzierte Entität lokal noch nicht (Bereich-
/// B/C-Import ist erst Phase 3), wird das Event bewusst NICHT als bekannt
/// markiert, sondern beim nächsten Sync-Zyklus automatisch erneut versucht —
/// die Peer-Event-Datei bleibt dafür unverändert liegen (siehe
/// ``wendeAn(_:gewinner:context:)``). Ein konkurrierendes, aber bereits anwendbares
/// schwächeres Event kann dadurch übergangsweise vor einem noch nicht
/// anwendbaren stärkeren Event materialisiert werden — das System konvergiert
/// aber selbstständig auf den korrekten Endzustand, sobald auch das stärkere
/// Event anwendbar wird (die Mutationsfunktionen sind für genau diesen Fall
/// bereits idempotent/selbstkorrigierend ausgelegt).
///
/// **Ausnahme vom Retry:** Ist die referenzierte Entität nicht bloß noch
/// nicht angekommen, sondern per ``SyncTombstoneService`` als absichtlich
/// gelöscht markiert, wird sie nie entstehen — ein endloser Retry würde das
/// Event bei jedem Sync-Zyklus erneut protokollieren, ohne je zu
/// konvergieren. Dieser Fall wird daher wie ein bereits entschiedener
/// Konflikt behandelt und sofort als bekannt markiert (siehe
/// ``referenzDauerhaftGeloescht(art:bezugsID:artikelID:context:)``).
///
/// **Zweite Ausnahme, aus einem echten Zwei-Geräte-Live-Test (2026-07-30):**
/// Ein referenzierter ``Einkaufsvorgang`` kann dauerhaft unauflösbar werden,
/// OHNE je einen Tombstone zu bekommen — beobachtet z.B., wenn er auf dem
/// Ursprungsgerät durch eine Nachfolger-Umleitung ersetzt wurde, bevor seine
/// ID je Teil eines Bereich-C-Snapshots wurde (die ursprüngliche ID
/// verschwindet dadurch spurlos aus jedem künftigen Snapshot, ohne dass
/// irgendein Gerät sie je als "gelöscht" vermerkt hätte). Ohne Gegenmaßnahme
/// würde ein solches Event für immer bei jedem Sync-Zyklus erneut versucht
/// und protokolliert, ohne je zu konvergieren — beobachtet über mehr als
/// sieben Minuten durchgehender Zyklen ohne Fortschritt. Events, deren
/// ``SyncEvent/wallClock`` älter als ``maximalesEventAlterFuerRetry`` ist,
/// werden deshalb aufgegeben (als bekannt markiert, distinkt protokolliert)
/// statt endlos weiterversucht.
enum SyncImportService {
    /// Ab diesem Alter (gemessen an ``SyncEventExportDarstellung/wallClock``)
    /// wird ein Event, dessen Referenz sich nicht auflösen lässt, aufgegeben
    /// statt weiter versucht — siehe Typ-Doku, zweite Ausnahme. Bewusst
    /// großzügig (statt Stunden): ein Peer, der länger offline war, oder eine
    /// langsame Cloud-Sync-Latenz sollen nicht fälschlich als "nie auflösbar"
    /// gewertet werden. `static var` statt Konstante, damit Tests sie
    /// verkürzen können.
    @MainActor static var maximalesEventAlterFuerRetry: TimeInterval = 48 * 60 * 60

    /// Debug-Werkzeug für manuelle Statuskonsolidierung
    /// (``SyncOrdnerSettingsView``): gibt alle aktuell nicht anwendbaren
    /// empfangenen Events sofort auf, statt auf ``maximalesEventAlterFuerRetry``
    /// zu warten — indem die Schwelle für einen einzelnen Durchlauf auf 0
    /// gesetzt wird. Rührt bewusst NICHT an den eigenen, noch nicht
    /// abgeholten ausgehenden Event-Dateien (siehe Revert-Begründung in
    /// ``SyncExportService``, „Kein Aufräumen alter Event-Dateien") — nur der
    /// bereits bestehende, sichere Give-up-Pfad wird vorgezogen.
    @discardableResult
    @MainActor
    static func raeumeNichtAnwendbareEventsAuf(context: ModelContext) async -> Bool {
        let vorherigeSchwelle = maximalesEventAlterFuerRetry
        maximalesEventAlterFuerRetry = 0
        defer { maximalesEventAlterFuerRetry = vorherigeSchwelle }
        return await importiereNeueEvents(context: context)
    }

    /// Rückgabewert meldet ausschließlich, ob der Ordnerzugriff (Berechtigung)
    /// geklappt hat, analog ``SyncSnapshotImportService/importiereSnapshots(context:)``.
    @discardableResult
    @MainActor
    static func importiereNeueEvents(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "importiereNeueEvents", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereNeueEvents")
            return false
        }
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "importiereNeueEvents")
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await Task.detached(priority: .utility, operation: {
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }).value else { return true }

        // Einmal für den gesamten Zyklus aufgebaut statt pro eingehendem Event
        // per ``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``
        // neu gefetcht+dekodiert (Performance-Fund, O(n) statt O(n²) bei n
        // eingehenden Events) — ``wendeAn(_:gewinner:context:)`` hält den
        // Gewinner-Index während der Verarbeitung selbst aktuell, siehe dort.
        // `bekannteIDs` dient unten als Vorfilter gegen unnötige Datei-Lesevorgänge.
        var (gewinner, bekannteIDs) = SyncEventService.alleAktuellenGewinnerUndBekannteIDs(context: context)

        for peerOrdner in peerVerzeichnisse where !PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: eigeneGeraeteID) {
            let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: peerOrdner.lastPathComponent, in: syncOrdner)
            guard let dateien = await Task.detached(priority: .utility, operation: {
                SyncDateiZugriff.listeKoordiniert(eventsOrdner)
            }).value else { continue }

            // Vorfilter gegen die im Dateinamen kodierte ID (Performance-Fund,
            // siehe Typ-Doku „Bekannte Grenze" oben und
            // ``SyncEventService/alleAktuellenGewinnerUndBekannteIDs(context:)``):
            // Event-Dateien werden nie gelöscht (Abschnitt 9), ohne diesen
            // Vorfilter läse und dekodierte jeder Zyklus JEDE jemals
            // exportierte Datei erneut, auch längst entschiedene. Ein Event,
            // dessen Referenz noch nicht auflösbar ist, wird laut Typ-Doku
            // NIE als bekannt markiert — bleibt also außerhalb von
            // `bekannteIDs` und wird hier weiterhin jeden Zyklus neu
            // gelesen/versucht, die Retry-Semantik bleibt dadurch unverändert
            // korrekt. Ein Dateiname, dessen ID sich nicht parsen lässt (z.B.
            // fremdes/beschädigtes Format), wird sicherheitshalber NICHT
            // gefiltert, sondern wie bisher gelesen.
            let jsonDateien = dateien.filter { $0.pathExtension == "json" }.filter { url in
                guard let id = eventID(ausDateiname: url) else { return true }
                return !bekannteIDs.contains(id)
            }
            let empfangeneEvents = await ladeEvents(aus: jsonDateien)
                .sorted { $0.lamportZaehler < $1.lamportZaehler }

            for empfangen in empfangeneEvents {
                wendeAn(empfangen, gewinner: &gewinner, context: context)
            }
        }

        // Nur speichern, wenn tatsächlich etwas übernommen wurde — ein reiner
        // Poll-Zyklus ohne neue fremde Events (der Normalfall) soll keine
        // Store-Änderung erzwingen (GitHub #60/#70, siehe Typ-Doku
        // ``SyncSnapshotImportService``).
        guard context.hasChanges else { return true }
        try? context.save()
        return true
    }

    /// Extrahiert die ``SyncEvent/id`` aus dem Dateinamen einer Peer-Event-Datei
    /// (`{zehnstelliger Lamport-Zähler}_{uuid}.json`, siehe
    /// ``SyncExportService/dateiname(fuer:)``) — OHNE die Datei zu lesen.
    /// Grundlage für den Vorfilter in ``importiereNeueEvents(context:)``, `nil`
    /// bei jedem nicht zum erwarteten Muster passenden Namen (sicherheitshalber
    /// nicht gefiltert, siehe Aufrufer).
    nonisolated private static func eventID(ausDateiname url: URL) -> UUID? {
        let basisname = url.deletingPathExtension().lastPathComponent
        guard let unterstrichIndex = basisname.firstIndex(of: "_") else { return nil }
        return UUID(uuidString: String(basisname[basisname.index(after: unterstrichIndex)...]))
    }

    /// Lädt und dekodiert Event-Dateien über einen koordinierten Lesezugriff
    /// (``SyncDateiZugriff``, GitHub #52) — in einem `Task.detached`, damit ein
    /// bei Bedarf ausgelöster Download nicht den `MainActor` blockiert.
    nonisolated private static func ladeEvents(aus dateien: [URL]) async -> [SyncEventExportDarstellung] {
        await Task.detached(priority: .utility) {
            dateien.compactMap { url -> SyncEventExportDarstellung? in
                guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
                return try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: daten)
            }
        }.value
    }

    @MainActor
    private static func wendeAn(
        _ empfangen: SyncEventExportDarstellung, gewinner: inout [SyncEventService.PaarSchluessel: SyncEvent], context: ModelContext
    ) {
        guard !SyncEventService.istBereitsBekannt(empfangen.id, context: context) else { return }

        guard let art = SyncEventArt(rawValue: empfangen.art),
              let nutzlast = try? JSONDecoder().decode(SyncEventNutzlast.self, from: empfangen.nutzlast)
        else {
            // Unbekannte Art (neuere Peer-App-Version) oder korrupte Nutzlast —
            // niemals interpretierbar, ein Retry würde nichts ändern. Keine
            // gültige Nutzlast → kein Gewinner-Index-Eintrag möglich/nötig.
            SyncEventService.uebernehmen(empfangen, context: context)
            return
        }
        let schluessel = SyncEventService.PaarSchluessel(bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID)

        guard darfAngewendetWerden(art: art, lamportZaehler: empfangen.lamportZaehler, schluessel: schluessel, gewinner: gewinner) else {
            // Ein bereits bekanntes, stärkeres Event hat dieses Paar schon
            // entschieden (siehe SyncKonfliktAufloesung) — das gilt dauerhaft,
            // ein Retry ist hier (anders als bei fehlender Referenz) nie nötig.
            // Der Gewinner für dieses Paar ändert sich durch einen Verlierer
            // nicht, der Index bleibt unverändert.
            SyncEventService.uebernehmen(empfangen, context: context)
            return
        }

        guard materialisiere(art, nutzlast: nutzlast, context: context) else {
            guard !referenzDauerhaftGeloescht(art: art, bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID, context: context) else {
                // Liste/Einkauf/Artikel wurde absichtlich gelöscht (Tombstone) und
                // wird deshalb NIE mehr lokal entstehen — anders als bei einer
                // bloß noch nicht eingetroffenen Referenz ist ein Retry hier
                // sinnlos und würde das Event jeden Zyklus erneut protokollieren.
                // Es hat den Konfliktcheck oben bereits gewonnen, ist also der
                // neue Gewinner für sein Paar, auch wenn es lokal nicht
                // materialisierbar ist.
                gewinner[schluessel] = SyncEventService.uebernehmen(empfangen, context: context)
                return
            }
            guard Date().timeIntervalSince(empfangen.wallClock) <= maximalesEventAlterFuerRetry else {
                // Seit ``maximalesEventAlterFuerRetry`` unauflösbar, ohne dass
                // ein Tombstone existiert (siehe Typ-Doku, zweite Ausnahme) —
                // weiteres Retrying würde nur noch endlos denselben Fehlschlag
                // protokollieren, ohne je zu konvergieren. Wie beim
                // Tombstone-Fall bereits der neue Gewinner für sein Paar.
                SyncDebugLogger.log(
                    .eventAufgegeben,
                    details: "art=\(art.rawValue) bezugsID=\(nutzlast.bezugsID) artikelID=\(nutzlast.artikelID)"
                )
                gewinner[schluessel] = SyncEventService.uebernehmen(empfangen, context: context)
                return
            }
            // Referenzierte Liste/Einkauf/Artikel noch nicht lokal bekannt.
            // Bewusst NICHT als bekannt markieren, siehe Typ-Dokumentation —
            // wird also bei jedem weiteren Zyklus erneut protokolliert, bis
            // die Referenz auflösbar wird (z.B. durch einen künftigen
            // Bereich-B-Namens-Alias, siehe GitHub #52-Nachfolgefund). Nicht
            // übernommen → kein Gewinner-Index-Eintrag.
            SyncDebugLogger.log(
                .eventNichtAnwendbar,
                details: "art=\(art.rawValue) bezugsID=\(nutzlast.bezugsID) artikelID=\(nutzlast.artikelID)"
            )
            return
        }

        gewinner[schluessel] = SyncEventService.uebernehmen(empfangen, context: context)
        // Beobachtete Latenz dieses Updates (siehe SyncDebugLogger-Typ-Doku) —
        // nur für tatsächlich neu angewendete Events, nicht für Verlierer im
        // Konfliktfall oder unbekannte Arten (dort fand keine reale
        // Zustandsänderung statt).
        SyncDebugLogger.protokolliereAlter(.eventEmpfangen, erzeugtAm: empfangen.wallClock, zusatz: "art=\(art.rawValue)")
    }

    /// Prüft gegen den vorab per ``SyncEventService/alleAktuellenGewinnerUndBekannteIDs(context:)``
    /// aufgebauten und vom Aufrufer aktuell gehaltenen Index, ob das neue Event
    /// gegen den bisher bekannten Gewinner für dasselbe (`bezugsID`,
    /// `artikelID`)-Paar besteht. Ohne konkurrierende Events gewinnt das neue
    /// Event automatisch.
    @MainActor
    private static func darfAngewendetWerden(
        art: SyncEventArt, lamportZaehler: UInt64, schluessel: SyncEventService.PaarSchluessel,
        gewinner: [SyncEventService.PaarSchluessel: SyncEvent]
    ) -> Bool {
        guard let bisherigerGewinner = gewinner[schluessel], let bisherigeArt = bisherigerGewinner.art
        else { return true }

        let neuerKandidat = SyncKonfliktAufloesung.Kandidat(art: art, lamportZaehler: lamportZaehler)
        let bisherigerKandidat = SyncKonfliktAufloesung.Kandidat(art: bisherigeArt, lamportZaehler: bisherigerGewinner.lamportZaehler)
        return SyncKonfliktAufloesung.gewinnt(neuerKandidat, ueber: bisherigerKandidat)
    }

    /// Wendet die dem `art` entsprechende, nicht-aufzeichnende Mutationsfunktion
    /// an. Liefert `false`, falls die referenzierte Liste/der Einkauf oder der
    /// Artikel lokal (noch) nicht existiert — siehe Typ-Dokumentation zur
    /// Retry-Semantik.
    @MainActor
    private static func materialisiere(_ art: SyncEventArt, nutzlast: SyncEventNutzlast, context: ModelContext) -> Bool {
        switch art {
        case .artikelHinzugefuegt:
            guard let liste = einkaufsliste(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            liste.artikelHinzufuegenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelEntfernt:
            guard let liste = einkaufsliste(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            liste.artikelEntfernenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelAbgehakt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            // indexFuerDistanzlernen: false — dieses Abhaken beschreibt die
            // Laufreihenfolge des SENDENDEN Geräts durchs Geschäft, nicht die
            // dieses Geräts (siehe Einkaufsvorgang-Typ-Doku). Ein hier vergebener
            // Index würde AbteilungsDistanzService mit einer erfundenen
            // Position für diesen Nutzer füttern.
            //
            // geschaeft: explizit aus der Nutzlast statt aus `vorgang.geschaeft`
            // (GitHub #66) — der Kaufeintrag soll das Geschäft tragen, an dem
            // dieser Kauf laut sendendem Gerät tatsächlich stattfand, nicht das
            // (ggf. abweichende) Geschäft des Container-Vorgangs.
            // `geschaeftUeberschreibung` ist bewusst als bereits typisierter
            // `Geschaeft?`-Wert übergeben (nicht der Literal `nil`), damit Swift
            // ihn korrekt in die äußere Optionalität hebt — auch ein
            // `nil`-Ergebnis (kein Geschäft ausgewählt) gilt so als expliziter
            // Override, nicht als „kein Override, self.geschaeft gilt".
            let geschaeftUeberschreibung: Geschaeft? = nutzlast.geschaeftID.flatMap { geschaeft(mitID: $0, context: context) }
            vorgang.artikelAbhakenOhneEventAufzeichnung(
                artikel, context: context, indexFuerDistanzlernen: false, geschaeft: geschaeftUeberschreibung
            )
            return true
        case .artikelAbgewaehlt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelDauerhaftEntfernt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context)
            return true
        }
    }

    /// Unterscheidet die beiden `false`-Fälle von ``materialisiere(_:nutzlast:context:)``:
    /// Referenz nur *noch nicht* lokal bekannt (retrywürdig) vs. Referenz
    /// *bewusst gelöscht* (Tombstone, siehe ``SyncTombstoneService``) und damit
    /// dauerhaft unauflösbar — ein Retry würde hier bei jedem Sync-Zyklus
    /// erneut fehlschlagen und protokolliert werden, ohne je zu konvergieren.
    /// Prüft sowohl `artikelID` (immer ein ``Artikel``) als auch `bezugsID`
    /// (je nach `art` eine ``Einkaufsliste`` oder ein ``Einkaufsvorgang``,
    /// jeweils über denselben Alias-Pfad wie die zugehörige Lookup-Funktion
    /// aufgelöst).
    private static func referenzDauerhaftGeloescht(
        art: SyncEventArt, bezugsID: UUID, artikelID: UUID, context: ModelContext
    ) -> Bool {
        let aufgeloesteArtikelID = SyncEntitaetsAliasService.aufgeloesteID(fuer: artikelID, art: SyncEntitaetsArt.artikel, context: context)
        if SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.artikel, id: aufgeloesteArtikelID, context: context) {
            return true
        }

        let bezugsArt: String
        switch art {
        case .artikelHinzugefuegt, .artikelEntfernt:
            bezugsArt = SyncEntitaetsArt.einkaufsliste
        case .artikelAbgehakt, .artikelAbgewaehlt, .artikelDauerhaftEntfernt:
            bezugsArt = SyncEntitaetsArt.einkaufsvorgang
        }
        let aufgeloesteBezugsID = SyncEntitaetsAliasService.aufgeloesteID(fuer: bezugsID, art: bezugsArt, context: context)
        return SyncTombstoneService.istGeloescht(art: bezugsArt, id: aufgeloesteBezugsID, context: context)
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3/GitHub #52-Nachfolgefund, kann eine
    /// fremde Einkaufsliste mit einer anderen lokalen zusammengeführt haben),
    /// bevor direkt per `id` gesucht wird — analog ``artikel(mitID:context:)``.
    private static func einkaufsliste(mitID id: UUID, context: ModelContext) -> Einkaufsliste? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsliste, context: context)
        var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Matching kann einen fremden Einkaufsvorgang mit einem anderen
    /// lokalen zusammengeführt haben, GitHub #52-Nachfolgefund), bevor direkt
    /// per `id` gesucht wird — analog ``einkaufsliste(mitID:context:)``.
    private static func einkaufsvorgang(mitID id: UUID, context: ModelContext) -> Einkaufsvorgang? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsvorgang, context: context)
        var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3, kann einen fremden Artikel mit einem
    /// anderen lokalen zusammengeführt haben), bevor direkt per `id` gesucht
    /// wird.
    private static func artikel(mitID id: UUID, context: ModelContext) -> Artikel? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.artikel, context: context)
        var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namens-/Koordinatenmatching, GitHub #86, kann ein fremdes
    /// Geschäft mit einem anderen lokalen zusammengeführt haben), bevor
    /// direkt per `id` gesucht wird — genutzt für die Geschäfts-Überschreibung
    /// beim Abhaken-Materialisieren (GitHub #66).
    private static func geschaeft(mitID id: UUID, context: ModelContext) -> Geschaeft? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.geschaeft, context: context)
        var deskriptor = FetchDescriptor<Geschaeft>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }
}
