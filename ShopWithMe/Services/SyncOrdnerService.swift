import Foundation

/// Reine Diagnose-Instrumentierung um jeden `startAccessingSecurityScopedResource()`/
/// `stopAccessingSecurityScopedResource()`-Aufruf der wiederkehrenden
/// Sync-Zyklus-Funktionen (siehe `docs/DATENSYNCHRONISATION_VERLAUF.md` §30 —
/// verschachtelte/überlappende Zugriffe auf denselben Security-Scoped-
/// Bookmark destabilisieren ihn auf echten Geräten nachweisbar dauerhaft, und
/// ein späterer Live-Fund auf demselben Gerät ließ sich aus dem bisherigen
/// Logging allein nicht mehr sicher von einem rein extern verursachten
/// Ordner-Ausfall unterscheiden — beide erzeugen identisch
/// `sync_ordner_zugriff_fehlgeschlagen`). Protokolliert bei
/// ``Protokollstufe/ausfuehrlich`` für jeden Aufruf Aufrufstelle,
/// Erfolg/Fehlschlag sowie welche anderen Aufrufstellen zu diesem Zeitpunkt
/// selbst noch einen eigenen Scope offen halten.
///
/// **Bewusst nur um die 8 wiederkehrenden Top-Level-Funktionen** (siehe deren
/// jeweilige `SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, …)`-Aufrufe),
/// nicht um `SyncOrdnerService.ordnerFestlegen`/`hatVorhandenePeers` — diese
/// beiden laufen nur einmalig beim Einrichten, nicht wiederkehrend, und sind
/// für eine Tiefenanalyse eines Laufzeit-Stillstands nicht relevant.
enum SyncOrdnerZugriffsDiagnose {
    private static let sperre = NSLock()
    nonisolated(unsafe) private static var offeneAufrufstellen: [String] = []

    /// Direkt nach einem `startAccessingSecurityScopedResource()`-Aufruf
    /// aufzurufen, mit dessen Rückgabewert als `erfolgreich`.
    static func markiereOeffnen(aufrufstelle: String, erfolgreich: Bool) {
        sperre.lock()
        let gleichzeitigOffene = offeneAufrufstellen
        if erfolgreich { offeneAufrufstellen.append(aufrufstelle) }
        sperre.unlock()

        let andere = gleichzeitigOffene.isEmpty ? "keine" : gleichzeitigOffene.joined(separator: ",")
        SyncDebugLogger.log(
            .scopeZugriff,
            details: "\(aufrufstelle) erfolgreich=\(erfolgreich) gleichzeitigOffen=\(andere)"
        )
    }

    /// Vor bzw. in einem `defer` zusammen mit dem passenden
    /// `stopAccessingSecurityScopedResource()`-Aufruf aufzurufen — nur wenn
    /// zuvor ``markiereOeffnen(aufrufstelle:erfolgreich:)`` mit `erfolgreich:
    /// true` für dieselbe `aufrufstelle` gemeldet wurde.
    static func markiereSchliessen(aufrufstelle: String) {
        sperre.lock()
        offeneAufrufstellen.removeAll { $0 == aufrufstelle }
        sperre.unlock()
    }
}

/// Fehler beim Festlegen des Sync-Ordners.
enum SyncOrdnerError: LocalizedError {
    case zugriffVerweigert

    var errorDescription: String? {
        switch self {
        case .zugriffVerweigert:
            return "Zugriff auf den gewählten Ordner wurde verweigert."
        }
    }
}

/// Verwaltet den vom Anwender gewählten geteilten Ordner für die
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_VERLAUF.md`,
/// GitHub #39). Hier wird nur ein zusätzlicher Ordner referenziert, in den
/// ``SyncExportService`` Peer-Exportdateien schreibt — die lokale Datenbank
/// bleibt immer am Standardpfad (siehe Plan-Dokument Abschnitt 2, GitHub #54).
enum SyncOrdnerService {
    private static let bookmarkSchluessel = "syncOrdnerBookmark"
    /// Bewusst nicht `private` — Tests setzen den zwischengespeicherten
    /// eigenen Peer-Ordnernamen (GitHub #81) gezielt zurück, analog
    /// `LamportClock.schluessel`.
    static let eigenerPeerOrdnerNameCacheSchluessel = "eigenerPeerOrdnerNameCache"

    /// Der vom Anwender gewählte Sync-Ordner, sofern einer hinterlegt und das
    /// Security-Scoped-Bookmark noch gültig ist.
    static func gewaehlterOrdner() -> URL? {
        guard let daten = UserDefaults.standard.data(forKey: bookmarkSchluessel) else { return nil }
        var veraltet = false
        guard let url = try? URL(
            resolvingBookmarkData: daten,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &veraltet
        ) else { return nil }
        return url
    }

    /// Legt den Sync-Ordner fest und merkt ihn sich per Security-Scoped-Bookmark.
    /// Es wird nichts kopiert oder verschoben — der Ordner dient ausschließlich
    /// als Ziel für Peer-Exportdateien.
    static func ordnerFestlegen(_ ordner: URL) throws {
        guard ordner.startAccessingSecurityScopedResource() else {
            throw SyncOrdnerError.zugriffVerweigert
        }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let bookmark = try ordner.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: bookmarkSchluessel)
    }

    /// Entfernt den hinterlegten Sync-Ordner — Datensynchronisation ist danach
    /// deaktiviert (``SyncExportService`` schreibt nichts mehr), bereits
    /// geschriebene Peer-Dateien im Ordner bleiben unangetastet liegen.
    static func ordnerEntfernen() {
        UserDefaults.standard.removeObject(forKey: bookmarkSchluessel)
    }

    /// Ob `ordner` bereits Peer-Unterordner anderer Geräte enthält (unter
    /// `peers/`, das eigene Gerät ausgenommen) — Grundlage für die
    /// „Zusammenführen"/„Ersetzen"-Abfrage beim erstmaligen Verknüpfen
    /// (``SyncErsetzenService``, GitHub #63). `false` sowohl bei einem völlig
    /// neuen Ordner als auch, falls der Zugriff fehlschlägt.
    static func hatVorhandenePeers(in ordner: URL) -> Bool {
        guard ordner.startAccessingSecurityScopedResource() else { return false }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
        guard let peerVerzeichnisse = SyncDateiZugriff.listeKoordiniert(peersOrdner) else { return false }

        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        return peerVerzeichnisse.contains { !PeerOrdnerName.gehoertZu($0.lastPathComponent, geraeteID: eigeneGeraeteID) }
    }

    /// Ordnername dieses Geräts unter `peers/` (GitHub #81) — Gerätename +
    /// kurzes ID-Suffix (``PeerOrdnerName``). Einmal vergeben, wird der Name
    /// in `UserDefaults` zwischengespeichert; ändert der Anwender später
    /// seinen Gerätenamen, wird der **bestehende** Ordner beim nächsten
    /// Export-Zyklus umbenannt statt ein neuer angelegt — sonst blieben dort
    /// ggf. noch nicht von Peers abgeholte Event-Dateien verwaist liegen
    /// (vgl. Revert-Begründung in ``SyncExportService``, „Kein Aufräumen
    /// alter Event-Dateien"). Erkennt auch den erstmaligen Wechsel von einem
    /// alten, reinen UUID-Ordner (vor GitHub #81) und benennt diesen um.
    @MainActor
    static func eigenerPeerOrdnerName(in syncOrdner: URL) -> String {
        let ziel = PeerOrdnerName.name(geraeteID: DatabaseLeaseService.geraeteID, geraeteName: DatabaseLeaseService.geraeteName)
        let zwischengespeichert = UserDefaults.standard.string(forKey: eigenerPeerOrdnerNameCacheSchluessel)
        guard zwischengespeichert != ziel else { return ziel }

        let alterName = zwischengespeichert ?? DatabaseLeaseService.geraeteID
        if alterName != ziel {
            let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
            let alterOrdner = peersOrdner.appendingPathComponent(alterName, isDirectory: true)
            let neuerOrdner = peersOrdner.appendingPathComponent(ziel, isDirectory: true)
            if FileManager.default.fileExists(atPath: alterOrdner.path) {
                SyncDateiZugriff.verschiebeKoordiniert(von: alterOrdner, nach: neuerOrdner)
            }
        }
        UserDefaults.standard.set(ziel, forKey: eigenerPeerOrdnerNameCacheSchluessel)
        return ziel
    }
}
