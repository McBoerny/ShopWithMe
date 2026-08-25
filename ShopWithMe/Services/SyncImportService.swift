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
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return true }
        // GitHub #171: kein eigener Security-Scope mehr — setzt die
        // sitzungsweit bereits offene Sitzung voraus (``SyncOrdnerZugriffsSitzung``).
        guard let syncOrdner = SyncOrdnerZugriffsSitzung.offen else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereNeueEvents")
            return false
        }
        batchZyklusLaeuft = true
        defer { batchZyklusLaeuft = false }

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
        // Batch-Cache fürs `ArtikelListenKauf`-Sicherheitsnetz-Faktum (GitHub #99)
        // UND fürs Sicherheitsnetz-Faktum selbst (Performance-Fund #159) — dient
        // beiden Zwecken: (a) ``materialisiereAlsBatch(_:nutzlast:autorGeraeteID:wallClock:aliase:artikelListenKaufBekannt:context:)``s
        // `.artikelHinzugefuegt`-Zweig liest daraus, ob der Artikel bereits
        // bekannt gekauft wurde (GitHub #166: bewusst dieser LIVE, während des
        // Batches aktuell gehaltene Cache statt eines separaten Vor-Batch-
        // Snapshots — sonst sieht ein später im selben Batch verarbeitetes
        // `.artikelHinzugefuegt`-Event ein davor im selben Batch verarbeitetes
        // `.artikelAbgehakt`-Event für dasselbe Paar nicht); (b) vermeidet einen
        // eigenen Fetch pro Event beim Vermerken des Sicherheitsnetz-Fakts
        // selbst, bei einem vollständigen Event-Log-Replay nach Geräte-Neuaufbau
        // potenziell hunderte Male. Einmal pro Batch geladen statt pro Event,
        // analog `aliase` oben.
        var artikelListenKaufBekannt = ArtikelListenKaufService.alleEintraege(context: context)

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
                wendeAnAlsBatch(
                    empfangen, gewinner: &gewinner, aliase: aliase,
                    artikelListenKaufBekannt: &artikelListenKaufBekannt, context: context
                )
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
        // GitHub #171: kein eigener Security-Scope mehr — läuft alle 5s als
        // `DebuggingView`-Auto-Refresh, deshalb ``sicherstellenOffen()``.
        guard SyncOrdnerZugriffsSitzung.sicherstellenOffen(), let syncOrdner = SyncOrdnerZugriffsSitzung.offen else { return [:] }

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
        wendeAnKern(empfangen, gewinner: &gewinner, aliase: aliase, context: context) { art, nutzlast, autorGeraeteID, wallClock in
            materialisiere(
                art, nutzlast: nutzlast, autorGeraeteID: autorGeraeteID, wallClock: wallClock,
                aliase: aliase, abgehaktZeitstempel: abgehaktZeitstempel, context: context
            )
        }
    }

    /// Batch-Variante für ``importiereNeueEvents(context:)`` — reicht
    /// `artikelListenKaufBekannt` bis zu ``materialisiereAlsBatch(_:nutzlast:autorGeraeteID:wallClock:aliase:artikelListenKaufBekannt:context:)``
    /// durch (Performance-Fund #159). Kein separater `abgehaktZeitstempel`-Parameter
    /// mehr (GitHub #166) — `artikelListenKaufBekannt` ist bereits während des
    /// gesamten Batches aktuell gehalten und deckt denselben Bedarf ab, siehe
    /// dortige Typ-Doku.
    @MainActor
    private static func wendeAnAlsBatch(
        _ empfangen: SyncEventExportDarstellung, gewinner: inout [SyncEventService.PaarSchluessel: SyncEvent],
        aliase: [String: [UUID: UUID]],
        artikelListenKaufBekannt: inout [ArtikelListenKaufService.Schluessel: ArtikelListenKauf], context: ModelContext
    ) {
        wendeAnKern(empfangen, gewinner: &gewinner, aliase: aliase, context: context) { art, nutzlast, autorGeraeteID, wallClock in
            materialisiereAlsBatch(
                art, nutzlast: nutzlast, autorGeraeteID: autorGeraeteID, wallClock: wallClock,
                aliase: aliase, artikelListenKaufBekannt: &artikelListenKaufBekannt, context: context
            )
        }
    }

    /// Gemeinsamer Kern von ``wendeAn(_:gewinner:aliase:abgehaktZeitstempel:context:)``
    /// und ``wendeAnAlsBatch(_:gewinner:aliase:artikelListenKaufBekannt:context:)``
    /// — beide unterscheiden sich nur darin, welche ``materialisiere``-Variante
    /// aufgerufen wird.
    @MainActor
    private static func wendeAnKern(
        _ empfangen: SyncEventExportDarstellung, gewinner: inout [SyncEventService.PaarSchluessel: SyncEvent],
        aliase: [String: [UUID: UUID]], context: ModelContext,
        materialisierer: (SyncEventArt, SyncEventNutzlast, String, Date) -> MaterialisierungsErgebnis
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

        let materialisierungsErgebnis = materialisierer(art, nutzlast, empfangen.autorGeraeteID, empfangen.wallClock)
        guard materialisierungsErgebnis == .erfolgreich else {
            guard !referenzDauerhaftGeloescht(
                art: art, bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID, produktID: nutzlast.produktID,
                aliase: aliase, context: context
            ) else {
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
        /// Referenziertes Produkt (`produktID`, GitHub #172) noch nicht lokal
        /// auflösbar — Liste/Einkaufsvorgang UND Artikel waren bereits
        /// auflösbar, sonst hätte einer der Fälle oben bereits gegriffen.
        /// Bewusst gleichrangig mit `artikelFehlt` behandelt (dieselbe Retry-/
        /// Aufgeben-Semantik): aus Nutzersicht ist die Wahl eines konkreten
        /// Produkts genauso Teil dessen, was auf die Liste gesetzt wurde, wie
        /// der Artikel selbst — kein stiller Fallback auf „ohne Produkt".
        case produktFehlt = "produkt"
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
    /// korrekt 1239 zurück auf 1265).
    ///
    /// **Bewusst NICHT über ``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)``
    /// direkt mit dem rohen Dictionary-Lookup verwendet** (siehe Kommentar an
    /// der Aufrufstelle in ``materialisiereKern(_:nutzlast:autorGeraeteID:wallClock:aliase:context:zuletztAbgehaktAm:artikelHinzufuegen:artikelAbhaken:)``
    /// für die aktuelle Begründung, GitHub #165/#166) — folgt demselben,
    /// bereits an ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``
    /// etablierten und regressionsgetesteten Muster: eine bekannte
    /// ``ArtikelListenKauf``-Zeile OHNE `zuletztAbgehaktAm` (z.B. eine nur vom
    /// symmetrischen `zuletztHinzugefuegtAm`-Fakt erzeugte Zeile, nie ein
    /// bestätigter Kauf) blockt NICHT — nur ein tatsächlich bekannter,
    /// konkreter Zeitstempel tut das.
    @MainActor
    private static func materialisiere(
        _ art: SyncEventArt, nutzlast: SyncEventNutzlast, autorGeraeteID: String, wallClock: Date,
        aliase: [String: [UUID: UUID]], abgehaktZeitstempel: [ArtikelListenKaufService.Schluessel: Date?], context: ModelContext
    ) -> MaterialisierungsErgebnis {
        materialisiereKern(
            art, nutzlast: nutzlast, autorGeraeteID: autorGeraeteID, wallClock: wallClock,
            aliase: aliase, context: context,
            zuletztAbgehaktAm: { abgehaktZeitstempel[$0] ?? nil },
            artikelHinzufuegen: { liste, artikel, produkt, zeitpunkt in
                liste.artikelHinzufuegenOhneEventAufzeichnung(artikel, produkt: produkt, am: zeitpunkt, context: context)
            },
            artikelAbhaken: { vorgang, artikel, produkt, zeitpunkt, ursprungsGeraeteID, geschaeftUeberschreibung in
                vorgang.artikelAbhakenOhneEventAufzeichnung(
                    artikel, produkt: produkt, am: zeitpunkt, context: context, ursprungsGeraeteID: ursprungsGeraeteID,
                    geschaeft: geschaeftUeberschreibung
                )
            }
        )
    }

    /// Batch-Variante für ``importiereNeueEvents(context:)``s Datei-Batch-Import
    /// (Performance-Fund #159): nutzt die ``ArtikelListenKauf``-Batch-Schreibpfade
    /// (``Einkaufsliste/artikelHinzufuegenAlsEventReplay(_:produkt:am:bekannt:context:)``/
    /// ``Einkaufsvorgang/artikelAbhakenAlsEventReplay(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:bekannt:)``)
    /// statt eines eigenen Fetches pro Event — `artikelListenKaufBekannt` wird
    /// vom Aufrufer einmal pro Batch geladen und über den gesamten
    /// Import-Zyklus wiederverwendet. Bewusst NICHT für den
    /// Multipeer-Einzelevent-Pfad (``wendeEinzelnesEmpfangenesEventAn(_:context:)``)
    /// verwendet — dort gilt laut dessen eigener Typ-Doku „Kein
    /// Batch-Index-Aufbau": ein einzelnes Event amortisiert die Kosten eines
    /// vollständigen Vorab-Ladens nie.
    ///
    /// **Speist das Sicherheitsnetz gegen wiederbelebte Käufe (GitHub #99) aus
    /// `artikelListenKaufBekannt` selbst, statt aus einem separaten Vor-Batch-
    /// Snapshot (GitHub #166-Fix):** `artikelListenKaufBekannt` wird während
    /// des gesamten Batches laufend aktuell gehalten (jedes materialisierte
    /// `.artikelAbgehakt`-Event aktualisiert es sofort über
    /// ``Einkaufsvorgang/artikelAbhakenAlsEventReplay(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:bekannt:)``
    /// → ``ArtikelListenKaufService/vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``).
    /// Ein separater, einmalig VOR dem Batch geladener Snapshot (wie er hier
    /// bis GitHub #166 zusätzlich existierte) sieht Änderungen aus früher im
    /// selben Batch verarbeiteten Events nicht — ein `.artikelAbgehakt`-Event
    /// gefolgt von einem `.artikelHinzugefuegt`-Event für dasselbe
    /// (Artikel, Liste)-Paar im selben Batch (z.B. von zwei verschiedenen
    /// Peer-Ordnern, deren Verarbeitungsreihenfolge nicht garantiert ist)
    /// hätte die Sperre sonst verpasst, siehe
    /// `SyncImportServiceTests/artikelHinzugefuegtNachAbhakenImSelbenBatchWirdBlockiert`.
    @MainActor
    private static func materialisiereAlsBatch(
        _ art: SyncEventArt, nutzlast: SyncEventNutzlast, autorGeraeteID: String, wallClock: Date,
        aliase: [String: [UUID: UUID]],
        artikelListenKaufBekannt: inout [ArtikelListenKaufService.Schluessel: ArtikelListenKauf], context: ModelContext
    ) -> MaterialisierungsErgebnis {
        materialisiereKern(
            art, nutzlast: nutzlast, autorGeraeteID: autorGeraeteID, wallClock: wallClock,
            aliase: aliase, context: context,
            zuletztAbgehaktAm: { artikelListenKaufBekannt[$0]?.zuletztAbgehaktAm },
            artikelHinzufuegen: { liste, artikel, produkt, zeitpunkt in
                liste.artikelHinzufuegenAlsEventReplay(
                    artikel, produkt: produkt, am: zeitpunkt, bekannt: &artikelListenKaufBekannt, context: context
                )
            },
            artikelAbhaken: { vorgang, artikel, produkt, zeitpunkt, ursprungsGeraeteID, geschaeftUeberschreibung in
                vorgang.artikelAbhakenAlsEventReplay(
                    artikel, produkt: produkt, am: zeitpunkt, context: context, ursprungsGeraeteID: ursprungsGeraeteID,
                    geschaeft: geschaeftUeberschreibung, bekannt: &artikelListenKaufBekannt
                )
            }
        )
    }

    /// Gemeinsamer Kern von ``materialisiere(_:nutzlast:autorGeraeteID:wallClock:aliase:abgehaktZeitstempel:context:)``
    /// und ``materialisiereAlsBatch(_:nutzlast:autorGeraeteID:wallClock:aliase:artikelListenKaufBekannt:context:)``
    /// — beide unterscheiden sich nur darin, WIE die beiden
    /// `ArtikelListenKauf`-Schreibfälle (`.artikelHinzugefuegt`/`.artikelAbgehakt`)
    /// das Sicherheitsnetz-Faktum vermerken bzw. abfragen (`zuletztAbgehaktAm`);
    /// die restliche Referenzauflösung/Fallunterscheidung bleibt an genau
    /// einer Stelle.
    @MainActor
    private static func materialisiereKern(
        _ art: SyncEventArt, nutzlast: SyncEventNutzlast, autorGeraeteID: String, wallClock: Date,
        aliase: [String: [UUID: UUID]], context: ModelContext,
        zuletztAbgehaktAm: (ArtikelListenKaufService.Schluessel) -> Date?,
        artikelHinzufuegen: (Einkaufsliste, Artikel, Produkt?, Date) -> Void,
        artikelAbhaken: (Einkaufsvorgang, Artikel, Produkt?, Date, String?, Geschaeft??) -> Void
    ) -> MaterialisierungsErgebnis {
        switch art {
        case .artikelHinzugefuegt:
            let liste = einkaufsliste(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let liste, let artikel else { return fehlendeReferenz(bezug: liste, artikel: artikel) }
            // GitHub #172: Produkt wird gleichrangig zu Artikel aufgelöst —
            // siehe ``MaterialisierungsErgebnis/produktFehlt``-Doku.
            let (produktAufgeloest, produkt) = aufgeloestesProdukt(nutzlast.produktID, aliase: aliase, context: context)
            guard produktAufgeloest else { return .produktFehlt }
            let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, produktID: produkt?.id, einkaufslisteID: liste.id)
            // NICHT ``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)``
            // direkt mit dem rohen `zuletztAbgehaktAm(schluessel)`-Ergebnis
            // verwendet: dessen Vertrag behandelt ein fehlendes `abgehaktAm`
            // IMMER als „nicht offen" (siehe dortige Typ-Doku „kein
            // Default-offen bei fehlendem abgehaktAm"). Das passt für eine
            // ``ArtikelListenKauf``-Zeile, die tatsächlich einen bekannten Kauf
            // repräsentiert, aber `zuletztAbgehaktAm` ist AUCH bei einer Zeile
            // `nil`, die nur wegen des symmetrischen `zuletztHinzugefuegtAm`-
            // Fakts existiert (Artikel wurde nur zur Liste hinzugefügt, nie
            // gekauft) — der hier weitaus häufigere Fall. Ein direkter
            // `istOffen`-Aufruf würde diese beiden Fälle nicht unterscheiden
            // können und JEDES normale `artikelHinzugefuegt`-Event blockieren
            // (Regressionsfund im Test-Lauf vor dem v0.17-Release, siehe
            // `SyncImportServiceTests/importiertArtikelHinzugefuegtVonFremdemGeraet`) —
            // exakt dieselbe Falle, vor der ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``
            // bereits schützt (dort per `bekannterEintrag?.zuletztAbgehaktAm`
            // statt `if let bekannterEintrag`, siehe
            // `SyncSnapshotImportServiceTests/vonSicherheitsnetzGeerbterEintragTaeuschtBeiWeitergabeKeineFrischeVor`
            // sowie `SyncImportServiceTests/artikelHinzugefuegtNichtBlockiertDurchNurHinzugefuegtFaktumOhneKauf`
            // für den hiesigen Bereich-A-Fall). Nur ein tatsächlich bekannter,
            // konkreter Zeitstempel blockt hier.
            if let bekannt = zuletztAbgehaktAm(schluessel), wallClock <= bekannt {
                SyncDebugLogger.log(
                    .einkaufslistenEintragSicherheitsnetzUebersprungen,
                    details: "artikel=\(artikel.name) liste=\(liste.name) pfad=bereichA"
                )
                return .erfolgreich
            }
            artikelHinzufuegen(liste, artikel, produkt, wallClock)
            return .erfolgreich
        case .artikelEntfernt:
            let liste = einkaufsliste(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let liste, let artikel else { return fehlendeReferenz(bezug: liste, artikel: artikel) }
            let (produktAufgeloest, produkt) = aufgeloestesProdukt(nutzlast.produktID, aliase: aliase, context: context)
            guard produktAufgeloest else { return .produktFehlt }
            liste.artikelEntfernenOhneEventAufzeichnung(artikel, produkt: produkt, context: context)
            return .erfolgreich
        case .artikelAbgehakt:
            let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let vorgang, let artikel else { return fehlendeReferenz(bezug: vorgang, artikel: artikel) }
            let (produktAufgeloest, produkt) = aufgeloestesProdukt(nutzlast.produktID, aliase: aliase, context: context)
            guard produktAufgeloest else { return .produktFehlt }
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
            // `am: wallClock` (Live-Fund 2026-08-24, siehe Typ-Doku des
            // Parameters an ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``):
            // ohne diese Weitergabe bekäme jeder per Event-Replay materialisierte
            // ``KaufEintrag`` fälschlich den aktuellen Import-Zeitpunkt statt des
            // tatsächlichen historischen Kaufdatums.
            artikelAbhaken(vorgang, artikel, produkt, wallClock, autorGeraeteID, geschaeftUeberschreibung)
            return .erfolgreich
        case .artikelAbgewaehlt:
            // Bewusst OHNE Produkt-Auflösung (anders als die drei Fälle oben):
            // ``Einkaufsvorgang/artikelAbwaehlenOhneEventAufzeichnung(_:context:)``
            // selbst matcht schon lokal nur über den Artikel, nie über ein
            // konkretes Produkt — die „abgehakt"-Ansicht (``EinkaufenView/abgehakteArtikel``)
            // dedupliziert bewusst ebenfalls rein nach Artikel-Identität (ein
            // Artikel mit mehreren gekauften Produkten erscheint dort als EINE
            // Zeile). Ein Produkt-Feld in der Nutzlast hier würde also nichts
            // auflösen können, was die lokale Mutation überhaupt nutzt.
            let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, aliase: aliase, context: context)
            let artikel = artikel(mitID: nutzlast.artikelID, aliase: aliase, context: context)
            guard let vorgang, let artikel else { return fehlendeReferenz(bezug: vorgang, artikel: artikel) }
            vorgang.artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context)
            return .erfolgreich
        case .artikelDauerhaftEntfernt:
            // Bewusst ohne Produkt-Auflösung — dieselbe Begründung wie bei
            // `.artikelAbgewaehlt` oben (``Einkaufsvorgang/artikelDauerhaftEntfernenOhneEventAufzeichnung(_:context:)``
            // matcht ebenfalls nur über den Artikel).
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
        art: SyncEventArt, bezugsID: UUID, artikelID: UUID, produktID: UUID?, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> Bool {
        let aufgeloesteArtikelID = SyncEntitaetsAliasService.aufgeloesteID(fuer: artikelID, art: SyncEntitaetsArt.artikel, in: aliase)
        if SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.artikel, id: aufgeloesteArtikelID, context: context) {
            return true
        }
        // GitHub #172: ein referenziertes, aber inzwischen gelöschtes Produkt
        // macht das Event genauso dauerhaft unauflösbar wie ein gelöschter
        // Artikel — kein Retry ohne Ende, dieselbe Gleichrangigkeit wie in
        // ``MaterialisierungsErgebnis/produktFehlt``.
        if let produktID {
            let aufgeloesteProduktID = SyncEntitaetsAliasService.aufgeloesteID(fuer: produktID, art: SyncEntitaetsArt.produkt, in: aliase)
            if SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.produkt, id: aufgeloesteProduktID, context: context) {
                return true
            }
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
    /// Bereich-B-Namensmatching kann ein fremdes Produkt mit einem anderen
    /// lokalen zusammengeführt haben, analog ``artikel(mitID:aliase:context:)``),
    /// bevor direkt per `id` gesucht wird. GitHub #172: Produkt reist jetzt
    /// auch über Bereich-A-Events (``SyncEventNutzlast/produktID``), mit
    /// derselben Auflösungs-/Retry-Semantik wie Artikel — siehe
    /// ``aufgeloestesProdukt(_:aliase:context:)``.
    private static func produkt(mitID id: UUID, aliase: [String: [UUID: UUID]], context: ModelContext) -> Produkt? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.produkt, in: aliase)
        var deskriptor = FetchDescriptor<Produkt>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst `produktID` auf, falls in der Nutzlast überhaupt gesetzt (kein
    /// Produkt gewählt bleibt ein gültiger, sofort „aufgelöster" Zustand).
    /// `istAufgeloest == false` unterscheidet „referenziert, aber noch nicht
    /// lokal bekannt" (→ ``MaterialisierungsErgebnis/produktFehlt``, Retry)
    /// klar von „gar nicht referenziert" (→ einfach mit `produkt == nil`
    /// weitermachen) — dieselbe Unterscheidung, die ``fehlendeReferenz(bezug:artikel:)``
    /// für Liste/Artikel bereits trifft.
    private static func aufgeloestesProdukt(
        _ produktID: UUID?, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> (istAufgeloest: Bool, produkt: Produkt?) {
        guard let produktID else { return (true, nil) }
        guard let produkt = produkt(mitID: produktID, aliase: aliase, context: context) else { return (false, nil) }
        return (true, produkt)
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
