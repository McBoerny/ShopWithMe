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
/// ``wendeAn(_:gewinner:aliase:abgehaktZeitstempel:context:)``). Ein konkurrierendes, aber bereits anwendbares
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

    /// Läuft gerade ein vollständiger Batch-Zyklus (``importiereNeueEvents(context:)``)?
    /// Dessen `gewinner`-Index wird einmalig zu Beginn gebaut und über mehrere
    /// `await`-Punkte (Datei-I/O, teils mehrere Sekunden) hinweg unverändert
    /// weiterverwendet — währenddessen kann ein per Multipeer (GitHub #49,
    /// ``MultipeerSyncService``) empfangenes Event, das auf einem eigenen
    /// `@MainActor`-`Task` unabhängig materialisiert wird, denselben
    /// (`bezugsID`,`artikelID`)-Konflikt bereits entscheiden, ohne dass der
    /// Batch-Zyklus davon erfährt — sein veralteter Snapshot könnte danach ein
    /// eigentlich unterlegenes Event fälschlich für gewinnend halten und den
    /// gerade erst korrekt gesetzten Zustand überschreiben. Diese Sperre lässt
    /// ``wendeEinzelnesEmpfangenesEventAn(_:context:)`` währenddessen bewusst
    /// nichts tun (siehe dort) — kein Datenverlust, da dasselbe Event dem
    /// Absender ohnehin zusätzlich als Datei vorliegt und beim nächsten
    /// regulären Zyklus ganz normal übernommen wird.
    @MainActor private(set) static var batchZyklusLaeuft = false

    /// Läuft gerade ein VOLLSTÄNDIGER Sync-Zyklus (``SyncPollingService/syncZyklus()``
    /// — Bereich A UND B/C/D zusammen, nicht nur der Bereich-A-Batch wie
    /// ``batchZyklusLaeuft`` oben)? Nutzerbericht 2026-08-11 (Architektur-
    /// Review, direkter Folgefund zur ``ArtikelListenKauf/zuletztHinzugefuegtAm``-
    /// Härtung): `SyncPollingService.syncZyklus()` hat VIER voneinander
    /// unabhängige, unkoordinierte Auslöser (eigener Polling-Loop,
    /// `SyncICloudAenderungsBeobachter`-Callback — spawnt bei JEDER
    /// Fremdänderungs-Benachrichtigung einen frischen, unabhängigen `Task`,
    /// `RootView.vollAbgleichAusloesen()`, `SyncOrdnerSettingsView.jetztSynchronisieren()`)
    /// — `@MainActor` verhindert dabei NUR, dass zwei Stücke Code im exakt
    /// selben Instant laufen, nicht aber, dass ein zweiter `syncZyklus()`-Aufruf
    /// startet, während der erste an einem seiner vielen `await`-Punkte
    /// (Datei-I/O) unterbrochen ist — genau das passiert bei einem frischen
    /// Geräte-Neuaufbau mit großem Nachhol-Volumen regelmäßig (viele schnell
    /// aufeinanderfolgende Datei-Schreibvorgänge lösen viele
    /// iCloud-Änderungsbenachrichtigungen aus). Live per Log bestätigt:
    /// `sync_scope_zugriff importiereSnapshots … gleichzeitigOffen=importiereSnapshots`,
    /// gefolgt von einem `sync_einkaufslisten_stand`, der binnen derselben
    /// Sekunde von 0 auf 6 sprang, bevor ein späterer Zyklus bei 3 „einpendelte"
    /// — drei zu diesem Zeitpunkt tatsächlich noch offene Artikel verschwanden
    /// spurlos, ohne dass irgendein Merge-Zweig sie (nachweislich per
    /// `entfernt=…`-Diagnose) gelöscht hätte. Zwei nebenläufige, unkoordinierte
    /// Durchläufe von ``SyncSnapshotImportService/importiereSnapshots(context:)``
    /// gegen denselben `ModelContext` erklären dieses Verhalten strukturell,
    /// ohne dass ein einzelner Merge-Zweig „falsch" entscheiden müsste.
    ///
    /// Analog zu ``batchZyklusLaeuft`` bewusst hier (statt in
    /// `SyncPollingService`) platziert — hält alle „läuft gerade eine
    /// Mutationsphase"-Merkposten an einer Stelle, `SyncPollingService`
    /// bleibt reiner Aufrufer über ``versucheVollstaendigenZyklusZuStarten()``/
    /// ``beendeVollstaendigenZyklus()`` unten.
    @MainActor private(set) static var vollstaendigerZyklusLaeuft = false

    /// Von ``SyncPollingService/syncZyklus()`` als erste Anweisung aufgerufen
    /// (vor jedem `await`, damit Prüfen+Setzen für gleichzeitige
    /// `@MainActor`-Aufrufer atomar wirkt). Liefert `false`, falls bereits ein
    /// anderer vollständiger Zyklus läuft — der Aufrufer überspringt seinen
    /// Durchlauf dann vollständig (kein zweiter, konkurrierender Merge-Pass),
    /// siehe Typ-Doku ``vollstaendigerZyklusLaeuft`` oben.
    @MainActor
    static func versucheVollstaendigenZyklusZuStarten() -> Bool {
        guard !vollstaendigerZyklusLaeuft else { return false }
        vollstaendigerZyklusLaeuft = true
        return true
    }

    /// Gegenstück zu ``versucheVollstaendigenZyklusZuStarten()`` — von
    /// `SyncPollingService.syncZyklus()` in einem `defer` aufgerufen, NUR
    /// wenn der vorangegangene Start-Versuch `true` lieferte.
    @MainActor
    static func beendeVollstaendigenZyklus() {
        vollstaendigerZyklusLaeuft = false
    }

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
        // Einmal für den gesamten Aufruf geladen statt pro Event frisch per
        // ``SyncEntitaetsAliasService/aufgeloesteID(fuer:art:context:)`` gefetcht
        // (Architektur-Review, Vorbereitung GitHub #125): garantiert, dass
        // JEDES Event in diesem Batch dieselbe Auflösung sieht wie
        // ``SyncSnapshotImportService/importiereSnapshots(context:)``, das im
        // selben Zyklus unmittelbar davor lief und ggf. neue Aliase
        // registriert hat (``SyncEntitaetsAliasService/registriere(entitaetsArt:fremdeID:lokaleID:context:)``,
        // in ``SyncSnapshotImportService/mergeArtikel(_:abteilungZuordnung:peerGeraeteID:aliase:context:)``
        // u.a.) — ohne diesen einmaligen Schnappschuss könnte ein später in
        // diesem Batch verarbeitetes Event zwar dieselbe, bereits registrierte
        // Auflösung sehen wie der Snapshot-Import, ein früher verarbeitetes
        // Event aber (bei mehreren Peers/Batches) potenziell nicht — ein
        // einmaliger Schnappschuss macht die Reihenfolge irrelevant, statt sie
        // implizit vorauszusetzen.
        let aliase = SyncEntitaetsAliasService.alleAliaseNachArt(context: context)
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "importiereNeueEvents", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereNeueEvents")
            return false
        }
        batchZyklusLaeuft = true
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "importiereNeueEvents")
            batchZyklusLaeuft = false
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        // `nil` bedeutet hier Zeitüberschreitung/Lesefehler (Ordner nicht
        // erreichbar) — bewusst als echter Fehlschlag gemeldet (nicht mehr
        // wie zuvor stillschweigend als „keine Peers" behandelt), sonst würde
        // ``SyncAktualitaetsService/vermerkeErfolgreichenZyklus()`` fälschlich
        // einen erfolgreichen Zyklus vermerken, während der Ordner tatsächlich
        // nicht erreichbar war (GitHub #49-Nachfolgefund).
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.listeKoordiniert(peersOrdner) }) ?? nil else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereNeueEvents-peers")
            return false
        }

        // Einmal für den gesamten Zyklus aufgebaut statt pro eingehendem Event
        // per ``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``
        // neu gefetcht+dekodiert (Performance-Fund, O(n) statt O(n²) bei n
        // eingehenden Events) — ``wendeAn(_:gewinner:aliase:abgehaktZeitstempel:context:)`` hält den
        // Gewinner-Index während der Verarbeitung selbst aktuell, siehe dort.
        // `bekannteIDs` dient unten als Vorfilter gegen unnötige Datei-Lesevorgänge.
        var (gewinner, bekannteIDs) = SyncEventService.alleAktuellenGewinnerUndBekannteIDs(context: context)
        // Sicherheitsnetz gegen wiederbelebte Käufe (GitHub #99), bisher nur
        // in ``SyncSnapshotImportService/mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:produktZuordnung:context:)``
        // (Bereich B) angewendet — siehe ``wendeAn(_:gewinner:aliase:abgehaktZeitstempel:context:)``
        // für die Begründung, warum derselbe Schutz jetzt auch hier (Bereich A)
        // gilt. Einmal pro Batch geladen statt pro Event, analog `aliase` oben.
        let abgehaktZeitstempel = ArtikelListenKaufService.alleZeitstempel(context: context)

        for peerOrdner in peerVerzeichnisse where !PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: eigeneGeraeteID) {
            let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: peerOrdner.lastPathComponent, in: syncOrdner)
            // Zeitlimit statt unbegrenztem Warten, damit ein einzelner
            // hängender Peer-Ordner nicht ``batchZyklusLaeuft`` (und damit
            // die stillschweigende Verwerfung per Multipeer empfangener
            // Events, siehe ``wendeEinzelnesEmpfangenesEventAn(_:context:)``)
            // unbegrenzt lange offen hält — bewusst weiterhin nur „diesen
            // Peer überspringen", nicht den ganzen Zyklus als fehlgeschlagen
            // werten, da ein einzelner flakiger Peer-Ordner kein Anzeichen für
            // einen insgesamt nicht erreichbaren Sync-Ordner ist.
            guard let dateien = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.listeKoordiniert(eventsOrdner) }) ?? nil else { continue }

            // Vorfilter gegen die im Dateinamen kodierte ID (Performance-Fund,
            // siehe Typ-Doku „Bekannte Grenze" oben und
            // ``SyncEventService/alleAktuellenGewinnerUndBekannteIDs(context:)``):
            // Event-Dateien werden seit GitHub #89 nach 30 Tagen automatisch
            // gelöscht (Abschnitt 9), aber innerhalb dieses Fensters läse und
            // dekodierte jeder Zyklus ohne diesen Vorfilter weiterhin jede
            // noch nicht abgelaufene Datei erneut, auch längst entschiedene. Ein Event,
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
                wendeAn(empfangen, gewinner: &gewinner, aliase: aliase, abgehaktZeitstempel: abgehaktZeitstempel, context: context)
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

    /// Reine Diagnose-Zählung für die Sync-Status-Übersicht (`DebuggingView`):
    /// wie viele Event-Dateien je Peer beim nächsten Zyklus noch übernommen
    /// würden — derselbe Vorfilter (Dateiname minus ``bekannteIDs``) wie in
    /// ``importiereNeueEvents(context:)``, aber rein lesend, ohne
    /// ``batchZyklusLaeuft`` zu setzen und ohne die Dateien selbst zu laden/zu
    /// dekodieren (nur ihre Anzahl interessiert hier). Peers ohne
    /// Events-Ordner oder mit null ausstehenden Dateien tauchen NICHT im
    /// Ergebnis auf (leeres statt Null-Eintrag).
    @MainActor
    static func ausstehendeEventAnzahlJePeer(context: ModelContext) async -> [String: Int] {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return [:] }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return [:] }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.listeKoordiniert(peersOrdner) }) ?? nil else {
            return [:]
        }
        let bekannteIDs = SyncEventService.alleAktuellenGewinnerUndBekannteIDs(context: context).bekannteIDs

        var ergebnis: [String: Int] = [:]
        for peerOrdner in peerVerzeichnisse where !PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: eigeneGeraeteID) {
            let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: peerOrdner.lastPathComponent, in: syncOrdner)
            guard let dateien = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.listeKoordiniert(eventsOrdner) }) ?? nil else { continue }
            let anzahl = dateien.filter { $0.pathExtension == "json" }.filter { url in
                guard let id = eventID(ausDateiname: url) else { return true }
                return !bekannteIDs.contains(id)
            }.count
            if anzahl > 0 {
                ergebnis[peerOrdner.lastPathComponent] = anzahl
            }
        }
        return ergebnis
    }

    /// Wendet ein einzeln empfangenes Event sofort an (Multipeer-
    /// Beschleunigungskanal, GitHub #49, ``MultipeerSyncService``) — dieselbe
    /// Konfliktauflösung/Materialisierung wie beim Datei-Import
    /// (``wendeAn(_:gewinner:aliase:abgehaktZeitstempel:context:)``), nur für ein einzelnes Event statt
    /// einen ganzen Peer-Ordner-Batch, damit hier keine zweite, parallel
    /// gepflegte Kopie dieser Logik entsteht.
    ///
    /// **Kein Batch-Index-Aufbau:** Anders als ``importiereNeueEvents(context:)``
    /// baut diese Funktion NICHT ``SyncEventService/alleAktuellenGewinnerUndBekannteIDs(context:)``
    /// auf (laut deren eigener Doku „nur für diesen Batch-Anwendungsfall") —
    /// bei aktivem Multipeer-Kanal trifft jede einzelne lokale Liste-/
    /// Abhak-Aktion auf beiden Geräten sofort hier ein, ein voller
    /// Tabellen-Scan+Decode pro Event ist dafür kein seltener, sondern der
    /// normale Fall. Stattdessen zuerst der günstige Duplikat-Check
    /// (``SyncEventService/istBereitsBekannt(_:context:)``, bricht früh ab,
    /// bevor überhaupt etwas dekodiert wird — dasselbe Event trifft z.B. oft
    /// zusätzlich später über den Datei-Kanal ein), dann bei Bedarf die
    /// gezielte Einzelabfrage ``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``
    /// für nur das eine betroffene Paar statt eines vollen Index.
    ///
    /// **Läuft parallel kein Datei-Batch-Zyklus:** siehe ``batchZyklusLaeuft``
    /// — während `importiereNeueEvents(context:)` seinen eigenen, über
    /// mehrere `await`-Punkte hinweg unveränderten Gewinner-Snapshot nutzt,
    /// bewusst nichts tun, um dessen Entscheidung nicht mit einem hier
    /// zwischenzeitlich materialisierten, dem Snapshot unbekannten Ergebnis
    /// zu unterlaufen. Kein Datenverlust: der Datei-Kanal liefert dasselbe
    /// Event ohnehin zusätzlich, spätestens beim nächsten Zyklus.
    ///
    /// **Ebenso zurückhalten, während ein vollständiger Sync-Zyklus läuft**
    /// (``vollstaendigerZyklusLaeuft``, Nutzerbericht 2026-08-11): dieser
    /// deckt zusätzlich `importiereSnapshots` (Bereich B/C/D) ab — genau dort
    /// entstand die live bestätigte Korruption, nicht nur im schmaleren
    /// Bereich-A-Batch-Fenster von ``batchZyklusLaeuft``. Dieselbe
    /// Selbstheilungs-Begründung wie dort: das Multipeer-Event liegt dem
    /// Absender ohnehin zusätzlich als Datei vor.
    @MainActor
    static func wendeEinzelnesEmpfangenesEventAn(_ empfangen: SyncEventExportDarstellung, context: ModelContext) {
        guard !batchZyklusLaeuft, !vollstaendigerZyklusLaeuft else { return }
        guard !SyncEventService.istBereitsBekannt(empfangen.id, context: context) else { return }

        var gewinner: [SyncEventService.PaarSchluessel: SyncEvent] = [:]
        if let nutzlast = try? JSONDecoder().decode(SyncEventNutzlast.self, from: empfangen.nutzlast) {
            let schluessel = SyncEventService.PaarSchluessel(bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID)
            if let bisheriger = SyncEventService.aktuellerGewinner(bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID, context: context) {
                gewinner[schluessel] = bisheriger
            }
        }
        let aliase = SyncEntitaetsAliasService.alleAliaseNachArt(context: context)
        // Kein Batch-Cache hier (anders als ``importiereNeueEvents(context:)``)
        // — ein einzelnes Multipeer-Event ist bereits die Ausnahme, kein
        // Massen-Batch, siehe Typ-Doku „Kein Batch-Index-Aufbau" oben.
        let abgehaktZeitstempel = ArtikelListenKaufService.alleZeitstempel(context: context)
        wendeAn(empfangen, gewinner: &gewinner, aliase: aliase, abgehaktZeitstempel: abgehaktZeitstempel, context: context)
        guard context.hasChanges else { return }
        try? context.save()
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
    /// (``SyncDateiZugriff``, GitHub #52) — pro Datei einzeln über
    /// ``SyncDateiZugriff/mitZeitlimit(sekunden:_:)`` begrenzt (statt vormals
    /// unbegrenzt in einem einzigen `Task.detached`), damit eine einzelne
    /// hängende Datei nicht den gesamten Batch (und damit
    /// ``batchZyklusLaeuft``) unbegrenzt lange blockiert.
    nonisolated private static func ladeEvents(aus dateien: [URL]) async -> [SyncEventExportDarstellung] {
        var ergebnis: [SyncEventExportDarstellung] = []
        for url in dateien {
            guard let daten = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.leseKoordiniert(url) }) ?? nil else { continue }
            guard let event = try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: daten) else { continue }
            ergebnis.append(event)
        }
        return ergebnis
    }

    @MainActor
    private static func wendeAn(
        _ empfangen: SyncEventExportDarstellung, gewinner: inout [SyncEventService.PaarSchluessel: SyncEvent],
        aliase: [String: [UUID: UUID]], abgehaktZeitstempel: [ArtikelListenKaufService.Schluessel: Date?], context: ModelContext
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

        let materialisierungsErgebnis = materialisiere(
            art, nutzlast: nutzlast, autorGeraeteID: empfangen.autorGeraeteID, wallClock: empfangen.wallClock,
            aliase: aliase, abgehaktZeitstempel: abgehaktZeitstempel, context: context
        )
        guard materialisierungsErgebnis == .erfolgreich else {
            guard !referenzDauerhaftGeloescht(art: art, bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID, aliase: aliase, context: context) else {
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
                    details: "art=\(art.rawValue) bezugsID=\(nutzlast.bezugsID) artikelID=\(nutzlast.artikelID) fehlt=\(materialisierungsErgebnis.rawValue)"
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
                details: "art=\(art.rawValue) bezugsID=\(nutzlast.bezugsID) artikelID=\(nutzlast.artikelID) fehlt=\(materialisierungsErgebnis.rawValue)"
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

    /// Unterscheidet, WELCHE der beiden Referenzen einer nicht anwendbaren
    /// ``SyncEvent``-Nutzlast (noch) fehlt — reines Diagnose-Detail für
    /// ``eventNichtAnwendbar``/``eventAufgegeben`` (Live-Test-Fund 2026-08-04:
    /// ein dauerhaft hängendes Event ließ sich aus dem bisherigen einheitlichen
    /// „nicht anwendbar"-Log nicht mehr in „Bezug fehlt" vs. „Artikel fehlt"
    /// auflösen, siehe `docs/GESCHAEFTS_AGGREGATE.md`). Ändert nichts an der
    /// Retry-/Aufgeben-Semantik selbst.
    private enum MaterialisierungsErgebnis: String {
        case erfolgreich
        /// Referenzierte Liste/Einkaufsvorgang (`bezugsID`) noch nicht lokal auflösbar.
        case bezugFehlt = "bezug"
        /// Referenzierter Artikel (`artikelID`) noch nicht lokal auflösbar.
        case artikelFehlt = "artikel"
        /// Beide Referenzen noch nicht lokal auflösbar.
        case bezugUndArtikelFehlen = "beide"
    }

    /// Bildet aus zwei aufgelösten (oder fehlgeschlagenen) Referenzen das
    /// passende ``MaterialisierungsErgebnis`` — nur für den `nil`/`nil`-,
    /// `nil`/Wert- und Wert/`nil`-Fall gedacht, der Erfolgsfall wird von den
    /// Aufrufern bereits über das `guard let` selbst behandelt.
    private static func fehlendeReferenz(bezug: AnyObject?, artikel: AnyObject?) -> MaterialisierungsErgebnis {
        switch (bezug, artikel) {
        case (nil, nil): return .bezugUndArtikelFehlen
        case (nil, _): return .bezugFehlt
        case (_, nil): return .artikelFehlt
        default: return .erfolgreich
        }
    }

    /// Wendet die dem `art` entsprechende, nicht-aufzeichnende Mutationsfunktion
    /// an. Liefert ungleich ``MaterialisierungsErgebnis/erfolgreich``, falls die
    /// referenzierte Liste/der Einkauf oder der Artikel lokal (noch) nicht
    /// existiert — siehe Typ-Dokumentation zur Retry-Semantik.
    ///
    /// `wallClock`: der ursprüngliche ``SyncEvent/wallClock``-Zeitpunkt des
    /// Absenders — ausschließlich für den `.artikelHinzugefuegt`-Zweig
    /// gebraucht (siehe ``Einkaufsliste/artikelHinzufuegenOhneEventAufzeichnung(_:am:context:)``-Doku),
    /// alle anderen Zweige ignorieren ihn.
    ///
    /// `abgehaktZeitstempel`: Sicherheitsnetz gegen wiederbelebte Käufe
    /// (GitHub #99) — bisher nur beim Bereich-B-Snapshot-Merge angewendet
    /// (``SyncSnapshotImportService/mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:produktZuordnung:context:)``).
    /// **Live-Fund (2026-08-24):** genau dieser Zweig hier hatte KEIN
    /// äquivalentes Sicherheitsnetz — nach einem Geräte-Neuaufbau, der die
    /// komplette historische Bereich-A-Event-Datei erneut abspielt, holte ein
    /// längst per `KaufEintrag` als gekauft bekannter Artikel klaglos zurück
    /// auf die offene Liste, obwohl derselbe Merge-Durchlauf ihn Sekunden
    /// zuvor über den Snapshot-Kanal bereits korrekt ausgeschlossen hatte
    /// (live bestätigt: 22 Artikel sprangen nach Reset+Event-Replay von
    /// korrekt 1239 zurück auf 1265). Nur der zeitstempel-basierte Vergleich
    /// (``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)``) wird
    /// hier repliziert, NICHT der `alleVorgaenge`-Fallback von
    /// ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``
    /// für Altbestand ohne Zeitstempel — bewusste Vereinfachung, da dieser
    /// Zweig zuvor GAR keinen Schutz hatte (reine Verbesserung) und der
    /// Fallback zusätzliches Batch-Fetching von `Einkaufsvorgang`en erfordert
    /// hätte.
    @MainActor
    private static func materialisiere(
        _ art: SyncEventArt, nutzlast: SyncEventNutzlast, autorGeraeteID: String, wallClock: Date,
        aliase: [String: [UUID: UUID]], abgehaktZeitstempel: [ArtikelListenKaufService.Schluessel: Date?], context: ModelContext
    ) -> MaterialisierungsErgebnis {
        switch art {
        case .artikelHinzugefuegt:
            let liste = einkaufsliste(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let liste, let artikel else { return fehlendeReferenz(bezug: liste, artikel: artikel) }
            let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, einkaufslisteID: liste.id)
            let zuletztAbgehaktAm = abgehaktZeitstempel[schluessel] ?? nil
            guard ArtikelListenKaufService.istOffen(hinzugefuegtAm: wallClock, abgehaktAm: zuletztAbgehaktAm) else {
                SyncDebugLogger.log(
                    .einkaufslistenEintragSicherheitsnetzUebersprungen,
                    details: "artikel=\(artikel.name) liste=\(liste.name) pfad=bereichA"
                )
                return .erfolgreich
            }
            liste.artikelHinzufuegenOhneEventAufzeichnung(artikel, am: wallClock, context: context)
            return .erfolgreich
        case .artikelEntfernt:
            let liste = einkaufsliste(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let liste, let artikel else { return fehlendeReferenz(bezug: liste, artikel: artikel) }
            liste.artikelEntfernenOhneEventAufzeichnung(artikel, context: context)
            return .erfolgreich
        case .artikelAbgehakt:
            let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let vorgang, let artikel else { return fehlendeReferenz(bezug: vorgang, artikel: artikel) }
            // ursprungsGeraeteID: autorGeraeteID (nie nil) — dieses Abhaken
            // beschreibt die Laufreihenfolge des SENDENDEN Geräts durchs
            // Geschäft, nicht die dieses Geräts (siehe Einkaufsvorgang-Typ-Doku).
            // Ein hier vergebener Index würde AbteilungsDistanzService mit einer
            // erfundenen Position für diesen Nutzer füttern.
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
            let geschaeftUeberschreibung: Geschaeft? = nutzlast.geschaeftID.flatMap { geschaeft(mitID: $0, aliase: aliase, context: context) }
            vorgang.artikelAbhakenOhneEventAufzeichnung(
                artikel, context: context, ursprungsGeraeteID: autorGeraeteID, geschaeft: geschaeftUeberschreibung
            )
            return .erfolgreich
        case .artikelAbgewaehlt:
            let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let vorgang, let artikel else { return fehlendeReferenz(bezug: vorgang, artikel: artikel) }
            vorgang.artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context)
            return .erfolgreich
        case .artikelDauerhaftEntfernt:
            let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let vorgang, let artikel else { return fehlendeReferenz(bezug: vorgang, artikel: artikel) }
            vorgang.artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context)
            return .erfolgreich
        }
    }

    /// Unterscheidet die beiden nicht-erfolgreichen Fälle von ``materialisiere(_:nutzlast:autorGeraeteID:wallClock:aliase:abgehaktZeitstempel:context:)``:
    /// Referenz nur *noch nicht* lokal bekannt (retrywürdig) vs. Referenz
    /// *bewusst gelöscht* (Tombstone, siehe ``SyncTombstoneService``) und damit
    /// dauerhaft unauflösbar — ein Retry würde hier bei jedem Sync-Zyklus
    /// erneut fehlschlagen und protokolliert werden, ohne je zu konvergieren.
    /// Prüft sowohl `artikelID` (immer ein ``Artikel``) als auch `bezugsID`
    /// (je nach `art` eine ``Einkaufsliste`` oder ein ``Einkaufsvorgang``,
    /// jeweils über denselben Alias-Pfad wie die zugehörige Lookup-Funktion
    /// aufgelöst).
    private static func referenzDauerhaftGeloescht(
        art: SyncEventArt, bezugsID: UUID, artikelID: UUID, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> Bool {
        let aufgeloesteArtikelID = SyncEntitaetsAliasService.aufgeloesteID(fuer: artikelID, art: SyncEntitaetsArt.artikel, in: aliase)
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
        let aufgeloesteBezugsID = SyncEntitaetsAliasService.aufgeloesteID(fuer: bezugsID, art: bezugsArt, in: aliase)
        return SyncTombstoneService.istGeloescht(art: bezugsArt, id: aufgeloesteBezugsID, context: context)
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3/GitHub #52-Nachfolgefund, kann eine
    /// fremde Einkaufsliste mit einer anderen lokalen zusammengeführt haben),
    /// bevor direkt per `id` gesucht wird — analog ``artikel(mitID:aliase:context:)``.
    /// `aliase` ist ein einmalig pro Aufrufer-Batch geladener Schnappschuss
    /// (siehe ``importiereNeueEvents(context:)``), kein Live-Fetch — garantiert
    /// dieselbe Auflösung für alle Events desselben Batches.
    private static func einkaufsliste(mitID id: UUID, aliase: [String: [UUID: UUID]], context: ModelContext) -> Einkaufsliste? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsliste, in: aliase)
        var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Matching kann einen fremden Einkaufsvorgang mit einem anderen
    /// lokalen zusammengeführt haben, GitHub #52-Nachfolgefund), bevor direkt
    /// per `id` gesucht wird — analog ``einkaufsliste(mitID:aliase:context:)``.
    private static func einkaufsvorgang(mitID id: UUID, aliase: [String: [UUID: UUID]], context: ModelContext) -> Einkaufsvorgang? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsvorgang, in: aliase)
        var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3, kann einen fremden Artikel mit einem
    /// anderen lokalen zusammengeführt haben), bevor direkt per `id` gesucht
    /// wird.
    private static func artikel(mitID id: UUID, aliase: [String: [UUID: UUID]], context: ModelContext) -> Artikel? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.artikel, in: aliase)
        var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namens-/Koordinatenmatching, GitHub #86, kann ein fremdes
    /// Geschäft mit einem anderen lokalen zusammengeführt haben), bevor
    /// direkt per `id` gesucht wird — genutzt für die Geschäfts-Überschreibung
    /// beim Abhaken-Materialisieren (GitHub #66).
    private static func geschaeft(mitID id: UUID, aliase: [String: [UUID: UUID]], context: ModelContext) -> Geschaeft? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.geschaeft, in: aliase)
        var deskriptor = FetchDescriptor<Geschaeft>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }
}
