import CryptoKit
import Foundation
import SwiftData

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

    /// Wie ``ordnerEntfernen()``, vergisst zusätzlich alle lokal gemerkten
    /// ``SyncPeerInfo``-Einträge — ohne aktiven Sync-Ordner sind sie ohnehin
    /// nur noch Anzeige-Ballast und werden bei einem erneuten Beitritt vom
    /// jeweiligen Peer selbst wieder neu gesetzt (``SyncSnapshotImportService``).
    @MainActor
    static func ordnerEntfernenUndPeersVergessen(context: ModelContext) async {
        ordnerEntfernen()
        let alle = (try? context.fetch(FetchDescriptor<SyncPeerInfo>())) ?? []
        guard !alle.isEmpty else { return }
        await DatabaseLeaseService.performMicroLease(context: context) {
            for peer in alle { context.delete(peer) }
        }
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

    /// Ob der eigene Peer-Ordner (``eigenerPeerOrdnerName(in:)``) noch unter
    /// `peers/` im geteilten Ordner existiert — Grundlage für die
    /// Rückkehrer-Erkennung im Peer-Lebenszyklus: fehlt er, wurde dieses
    /// Gerät von der Gruppe entfernt (siehe `DebuggingView`s
    /// Peer-Entfernung). `nil` bei nicht erreichbarem Ordner — bewusst NICHT
    /// als „ausgeschlossen" gewertet, sonst würde ein rein transientes
    /// Problem (kein Internet, Cloud-Anbieter kurz nicht erreichbar)
    /// fälschlich einen Voll-Neuaufbau samt Verwerfen der eigenen
    /// Sync-Konfiguration auslösen.
    @MainActor
    static func binIchNochMitglied(in ordner: URL) async -> Bool? {
        guard ordner.startAccessingSecurityScopedResource() else { return nil }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let eigenerName = eigenerPeerOrdnerName(in: ordner)
        let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }) ?? nil else { return nil }

        return peerVerzeichnisse.contains { $0.lastPathComponent == eigenerName }
    }

    /// Entfernt `peer` vollständig — seinen kompletten Peer-Ordner im
    /// geteilten Ordner (rekursiv, per koordiniertem Zugriff statt rohem
    /// `FileManager`) sowie den lokalen ``SyncPeerInfo``-Merkposten. Für
    /// Geräte, die die App nicht mehr nutzen (`DebuggingView`s manuelle
    /// Liste, oder eine proaktive Warnung bei langer Abwesenheit) —
    /// verhindert, dass ihr letzter bekannter Stand weiterhin zurückgespielt
    /// wird, und ist gleichzeitig die Grundlage für die Rückkehrer-Erkennung
    /// (``binIchNochMitglied(in:)``): kehrt das entfernte Gerät zurück,
    /// erkennt es dort selbst, dass sein Ordner fehlt.
    @MainActor
    static func entfernePeer(_ peer: SyncPeerInfo, in ordner: URL, context: ModelContext) async {
        if ordner.startAccessingSecurityScopedResource() {
            defer { ordner.stopAccessingSecurityScopedResource() }
            let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
            if let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
                SyncDateiZugriff.listeKoordiniert(peersOrdner)
            }) ?? nil {
                for peerOrdner in peerVerzeichnisse
                where PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: peer.peerGeraeteID) {
                    SyncDateiZugriff.loescheKoordiniert(peerOrdner)
                }
            }
        }
        // Explizites, Lease-geschütztes save() (siehe `docs/DATABASE_CONCURRENCY.md`) —
        // ohne dieses blieb das Löschen bei `autosaveEnabled = false` rein
        // In-Memory und ging bei App-Neustart vor dem nächsten zufälligen Save
        // verloren, sodass das entfernte Gerät wieder auftauchte.
        await DatabaseLeaseService.performMicroLease(context: context) {
            context.delete(peer)
        }
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

    private static let gruppenIDDateiname = ".sync-gruppen-id"

    /// Stabile, aus dem geteilten Ordner selbst abgeleitete Gruppen-ID für den
    /// Multipeer-Beschleunigungskanal (GitHub #49) — bewusst NICHT von einer
    /// einzelnen `Einkaufsliste.id` abgeleitet (wie im Issue ursprünglich
    /// skizziert): ein geteilter Ordner deckt inzwischen alle Listen eines
    /// Geräts ab, es gibt keine listen-scoped Sync-Beziehung mehr (siehe
    /// `docs/DATENSYNCHRONISATION.md` §4.2). Das Gerät, das den Ordner
    /// zuerst einrichtet, schreibt einmalig eine Marker-Datei; jedes weitere
    /// beitretende Gerät liest denselben Wert. Zugriff auf die Marker-Datei
    /// (und damit auf den geteilten Ordner) bleibt das Vertrauensmerkmal —
    /// dieselbe Logik wie im Issue skizziert, nur auf den Ordner statt eine
    /// einzelne Liste bezogen.
    ///
    /// **Rückgabewert `nil` bei nicht erreichbarem Ordner** (Nachfolgefund zu
    /// GitHub #49): ein fehlgeschlagener koordinierter Lesezugriff sieht
    /// identisch aus wie „Datei existiert noch nicht" — ohne die Unterscheidung
    /// unten hätten zwei zeitgleich nicht erreichbare Geräte unabhängig
    /// voneinander unterschiedliche IDs erfunden und sich über den
    /// Gruppenschlüssel (``multipeerGruppenSchluessel(fuerGruppenID:)``)
    /// nie mehr gefunden — silent, ohne jede Fehlermeldung. Nur wenn
    /// `FileManager.fileExists` die Abwesenheit LOKAL bestätigt (nicht bloß
    /// der Lesezugriff scheiterte), gilt „wirklich noch nie angelegt" und eine
    /// neue ID darf entstehen; deren Schreibversuch wird zusätzlich selbst
    /// geprüft statt wie zuvor ungenutzt verworfen.
    static func multipeerGruppenID(in syncOrdner: URL) async -> UUID? {
        let datei = syncOrdner.appendingPathComponent(gruppenIDDateiname)
        if let daten = await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.leseKoordiniert(datei) }) ?? nil,
           let text = String(data: daten, encoding: .utf8),
           let vorhandeneID = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return vorhandeneID
        }
        guard !FileManager.default.fileExists(atPath: datei.path) else { return nil }
        let neueID = UUID()
        guard await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.schreibeKoordiniert(Data(neueID.uuidString.utf8), nach: datei) }) == true else {
            return nil
        }
        return neueID
    }

    /// Fester Bonjour-Service-Type für den Multipeer-Beschleunigungskanal —
    /// bewusst NICHT aus ``multipeerGruppenID(in:)`` abgeleitet: der
    /// Service-Type muss laut `project.yml`/Info.plist (`NSBonjourServices`,
    /// seit iOS 14 Pflicht für jede Bonjour-Discovery) **statisch zur
    /// Build-Zeit** deklariert werden, die Gruppen-ID entsteht aber erst zur
    /// Laufzeit (zufällig, pro geteiltem Ordner) — beides lässt sich
    /// grundsätzlich nicht vereinen. Der Service-Type beschreibt laut Apples
    /// SDK-Doku ohnehin nur „das Netzwerkprotokoll der App" (max. 15 Zeichen,
    /// Kleinbuchstaben/Ziffern/Bindestrich), nicht eine konkrete
    /// Gruppenzugehörigkeit — dafür ist stattdessen `discoveryInfo`
    /// vorgesehen (siehe ``multipeerGruppenSchluessel(fuerGruppenID:)``),
    /// das MultipeerConnectivity explizit für genau diesen Zweck anbietet
    /// ("advertised for browsers to see"). Alle ShopWithMe-Installationen
    /// teilen sich denselben Service-Type; welche Peers tatsächlich zur
    /// selben Einkaufsgruppe gehören, entscheidet erst der
    /// Gruppen-Schlüssel-Abgleich in ``MultipeerSyncService``.
    static let multipeerServiceType = "swm-sync"

    /// Aus ``multipeerGruppenID(in:)`` abgeleitetes HMAC-Schlüsselmaterial
    /// für den Challenge-Response-Gruppentrust-Check in
    /// ``MultipeerSyncService`` (GitHub #97, härtet den früher direkt
    /// gesendeten Hash-Vergleich). **Verlässt das Gerät nie**: über das
    /// lokale Netz laufen nur ein pro Advertising-Session neu erzeugter
    /// Zufalls-Nonce (`discoveryInfo`) sowie ein damit gebildeter HMAC
    /// (Einladungs-Kontext) — aus beidem lässt sich dieses Schlüsselmaterial
    /// dank der Einwegeigenschaft von HMAC-SHA256 nicht zurückrechnen, anders
    /// als beim vorherigen, direkt übertragenen und beliebig oft
    /// wiederverwendbaren Hash-Wert.
    static func multipeerGruppenSchluessel(fuerGruppenID gruppenID: UUID) -> SymmetricKey {
        SymmetricKey(data: Data(gruppenID.uuidString.utf8))
    }
}
