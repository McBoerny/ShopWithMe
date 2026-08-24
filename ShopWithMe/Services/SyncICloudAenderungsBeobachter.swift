import Foundation

/// Langlebiger `NSMetadataQuery`-Beobachter für Änderungen im Sync-Ordner
/// (GitHub #91, dritter Anlauf). Der erste Versuch (`SyncICloudWeckerService`,
/// entfernt, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md` §39/40) erzeugte
/// jeden Sync-Zyklus eine neue Query, ließ sie maximal 2s laufen und stoppte
/// sie sofort wieder — erreichte dadurch nie `enableUpdates()` und bekam
/// praktisch nie eine echte Update-Benachrichtigung. Apples „Designing for
/// Documents in iCloud"-Guide dokumentiert stattdessen explizit: Query früh
/// erzeugen, **dauerhaft laufen lassen**, auf
/// `NSMetadataQueryDidUpdateNotification` reagieren — genau das macht dieser
/// Typ.
///
/// **Scope-Limitierung beachtet** (unbeantworteter Apple-Forenthread #783958
/// zu genau diesem Szenario — externer, per Dokumenten-Picker gewählter
/// Ordner, nicht der App-eigene Ubiquity-Container): `NSMetadataQuery`
/// beobachtet zuverlässig nur die WURZEL jedes gescopten Ordners, nicht
/// dessen Unterordner. Deshalb hier ein eigener Scope-Eintrag pro
/// tatsächlich relevantem Ordner (der `peers/`-Ordner selbst, sowie je
/// bekanntem Peer dessen Ordner plus `events/`/`kaeufe/`-Unterordner) statt
/// nur der Sync-Ordner-Wurzel wie beim ersten Versuch.
///
/// **Neue Peers/ein neuer Sync-Ordner werden nicht automatisch erfasst**,
/// solange die Query bereits läuft — ``aktualisiereScopeFallsNoetig()``
/// gleicht die bekannte Peer-Liste deshalb sowohl reaktiv (bei jeder eigenen
/// Benachrichtigung) als auch periodisch (bei jedem regulären Sync-Zyklus,
/// siehe ``SyncPollingService``) neu ab und baut die Query bei Bedarf mit
/// aktualisierten Scopes neu auf.
@MainActor
final class SyncICloudAenderungsBeobachter {
    private var query: NSMetadataQuery?
    private var beobachter: [NSObjectProtocol] = []
    private var bekanntePeerOrdnerNamen: Set<String> = []
    private var ausloesen: (() -> Void)?

    /// Startet die Beobachtung (wirkungslos, falls bereits gestartet).
    /// `ausloesen` wird bei jeder über die Query erkannten Änderung
    /// aufgerufen — der Aufrufer soll dort einen normalen Sync-Zyklus
    /// anstoßen.
    func starten(ausloesen: @escaping () -> Void) {
        guard query == nil else { return }
        self.ausloesen = ausloesen
        bekanntePeerOrdnerNamen = []
        aktualisiereScopeFallsNoetig()
    }

    func stoppen() {
        beendeAktuelleQuery()
        ausloesen = nil
        bekanntePeerOrdnerNamen = []
    }

    private func beendeAktuelleQuery() {
        query?.disableUpdates()
        query?.stop()
        beobachter.forEach { NotificationCenter.default.removeObserver($0) }
        beobachter = []
        query = nil
    }

    /// Öffentlich, damit ``SyncPollingService`` sie zusätzlich zur
    /// reaktiven Aktualisierung bei jedem regulären Sync-Zyklus mit
    /// aufrufen kann — schließt die Lücke, dass ein gerade erst gewechselter
    /// Sync-Ordner sonst erst nach der ersten Fremdänderung im NEUEN Ordner
    /// erkannt würde. Wirkungslos (kein Neuaufbau), solange sich weder der
    /// Ordner noch die bekannte Peer-Liste geändert haben.
    func aktualisiereScopeFallsNoetig() {
        // GitHub #171: kein eigener Security-Scope mehr — setzt die
        // sitzungsweit (über ``SyncOrdnerZugriffsSitzung``) bereits offene
        // Sitzung voraus, statt selbst zu öffnen/schließen.
        guard let syncOrdner = SyncOrdnerZugriffsSitzung.offen else {
            beendeAktuelleQuery()
            return
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let peerNamen = Set(
            (SyncDateiZugriff.listeKoordiniert(peersOrdner) ?? []).map(\.lastPathComponent)
        )
        guard query == nil || peerNamen != bekanntePeerOrdnerNamen else { return }
        bekanntePeerOrdnerNamen = peerNamen
        baueQueryNeuAuf(peersOrdner: peersOrdner, peerNamen: peerNamen)
    }

    private func baueQueryNeuAuf(peersOrdner: URL, peerNamen: Set<String>) {
        beendeAktuelleQuery()

        var scopes: [URL] = [peersOrdner]
        for name in peerNamen {
            let peerOrdner = peersOrdner.appendingPathComponent(name, isDirectory: true)
            scopes.append(peerOrdner)
            scopes.append(peerOrdner.appendingPathComponent("events", isDirectory: true))
            scopes.append(peerOrdner.appendingPathComponent("kaeufe", isDirectory: true))
        }

        let neueQuery = NSMetadataQuery()
        neueQuery.searchScopes = scopes
        neueQuery.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        // Serielle Queue zwingend vorgeschrieben (GitHub #91, Build-133-Fund):
        // ein unkonfiguriertes `OperationQueue()` crasht zur Laufzeit mit
        // "[CRIT] API MISUSE ... maxConcurrentOperationCount != 1".
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        neueQuery.operationQueue = queue

        let gatheringBeobachter = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: neueQuery, queue: queue
        ) { notification in
            (notification.object as? NSMetadataQuery)?.enableUpdates()
        }
        let updateBeobachter = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: neueQuery, queue: queue
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reagiereAufAenderung()
            }
        }

        query = neueQuery
        beobachter = [gatheringBeobachter, updateBeobachter]
        SyncDebugLogger.log(
            .iCloudBeobachterScopeAktualisiert,
            details: "peers=\(peerNamen.count) scopes=\(scopes.count)"
        )
        neueQuery.start()
    }

    private func reagiereAufAenderung() {
        SyncDebugLogger.log(.iCloudBeobachterAusgeloest, details: "")
        ausloesen?()
        aktualisiereScopeFallsNoetig()
    }
}
