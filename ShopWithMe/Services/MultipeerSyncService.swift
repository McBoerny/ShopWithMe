import Foundation
// MultipeerConnectivity ist ein altes, nicht Sendable-auditiertes ObjC-
// Framework — `@preconcurrency` unterdrückt die sonst nötige, aber hier nicht
// leistbare Sendable-Prüfung für dessen Typen (`MCPeerID`,
// `MCNearbyServiceBrowser`, `invitationHandler`-Closure, …), die als
// Delegate-Parameter zwingend über den `Task { @MainActor in }`-Hop
// (Begründung siehe Typ-Doku) wandern müssen. Apples eigene Doku garantiert
// „Delegate calls occur on a private serial queue" — kein tatsächliches
// Race-Risiko, nur eine fehlende Swift-6-Auditierung des Frameworks selbst.
@preconcurrency import MultipeerConnectivity
import SwiftData

/// Zusätzlicher, rein beschleunigender Sync-Kanal (GitHub #49) neben dem
/// bestehenden FileProvider-Kanal (`docs/DATENSYNCHRONISATION.md`) — spiegelt
/// Bereich-A-`SyncEvent`s sofort an bereits verbundene Peers, WÄHREND aktiv
/// gemeinsam eingekauft wird (``aktiv``, von `EinkaufenView` gesetzt, analog
/// ``SyncPollingService/einkaufAktiv``). Die geteilte Datei bleibt Quelle der
/// Wahrheit: bei fehlender Verbindung (anderes WLAN, außer Reichweite) fällt
/// jedes Event unverändert auf den Datei-Kanal zurück — hier passiert dann
/// einfach nichts zusätzlich.
///
/// Funktioniert nur bei physischer Nähe (WiFi/Bluetooth/AWDL über Bonjour),
/// nicht übers offene Internet (mDNS ist link-local-scoped).
///
/// **Vertrauensmodell:** Der Bonjour-Service-Type
/// (``SyncOrdnerService/multipeerServiceType``) ist app-weit fest und sagt
/// nichts über Gruppenzugehörigkeit — alle ShopWithMe-Installationen
/// verwenden denselben Type (siehe dortige Typ-Doku, warum das nicht anders
/// geht: `NSBonjourServices` muss statisch zur Build-Zeit deklariert werden).
/// Die eigentliche Zugehörigkeit zur selben Einkaufsgruppe prüft
/// ``gruppenSchluessel`` (aus dem geteilten Sync-Ordner abgeleitet,
/// ``SyncOrdnerService/multipeerDiscoveryGruppenSchluessel(fuerGruppenID:)``):
/// auf der Browsing-Seite über `discoveryInfo` (``browser(_:foundPeer:withDiscoveryInfo:)``),
/// auf der Advertising-Seite über den Einladungs-`context`
/// (``advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)``)
/// — nur bei Übereinstimmung wird überhaupt eingeladen/angenommen. Das
/// empfangene TLS-Zertifikat selbst wird trotzdem ungeprüft akzeptiert
/// (``session(_:didReceiveCertificate:fromPeer:certificateHandler:)``), das
/// Vertrauen kommt aus dem Gruppen-Schlüssel-Abgleich, nicht aus einer PKI.
@MainActor
final class MultipeerSyncService: NSObject, ObservableObject {
    /// Schwache Referenz auf die laufende Instanz, damit
    /// ``SyncEventService/aufzeichnen(_:bezugsID:artikelID:geschaeftID:context:)``
    /// (reine Model-Schicht, kennt keine View-Hierarchie) neu erzeugte Events
    /// spiegeln kann — gleiches Muster wie das bereits bestehende statische
    /// `DatabaseLeaseService.geraeteID`/`.storeURL`.
    private(set) static weak var aktuell: MultipeerSyncService?

    private static let discoveryInfoSchluessel = "gruppe"

    /// Von `EinkaufenView` gesetzt, solange der Einkaufen-Bildschirm sichtbar
    /// ist (analog ``SyncPollingService/einkaufAktiv``) — startet/stoppt
    /// Advertising+Browsing. Bewusst kein Dauerbetrieb im Hintergrund (Akku,
    /// Privacy: kein permanentes Bluetooth-/Local-Network-Advertising).
    var aktiv = false {
        didSet {
            guard aktiv != oldValue else { return }
            if aktiv {
                Task { await starteAdvertisingUndBrowsing() }
            } else {
                beendeAdvertisingUndBrowsing()
            }
        }
    }

    private var context: ModelContext?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Eigener, aus dem aktuellen Sync-Ordner abgeleiteter Gruppen-Schlüssel
    /// — erst nach dem asynchronen Auflösen in ``starteAdvertisingUndBrowsing()``
    /// gesetzt, für den Abgleich in beiden Delegate-Methoden zwischengespeichert.
    private var gruppenSchluessel: String?

    func starten(context: ModelContext) {
        self.context = context
        Self.aktuell = self
    }

    /// Beendet auch ein evtl. noch laufendes Advertising/Browsing — z.B. beim
    /// App-Wechsel in den Hintergrund, unabhängig vom ``aktiv``-Zustand von
    /// `EinkaufenView` zu diesem Zeitpunkt.
    func stoppen() {
        beendeAdvertisingUndBrowsing()
        Self.aktuell = nil
        context = nil
    }

    /// Löst die Gruppen-ID des aktuellen Sync-Ordners auf (koordinierter,
    /// potenziell blockierender Dateizugriff, deshalb in einem
    /// `Task.detached` vom `MainActor` ferngehalten — analog dem bestehenden
    /// Muster in `SyncImportService`) und baut erst danach `MCSession`/
    /// `MCNearbyServiceAdvertiser`/`MCNearbyServiceBrowser` auf. Ohne
    /// konfigurierten Sync-Ordner passiert nichts — dieser Kanal ist rein
    /// additiv zum Datei-Kanal, nie ein eigenständiger Ersatz.
    private func starteAdvertisingUndBrowsing() async {
        guard aktiv, session == nil, let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let gruppenID = await Task.detached(priority: .utility) {
            SyncOrdnerService.multipeerGruppenID(in: syncOrdner)
        }.value
        // Währenddessen evtl. wieder deaktiviert (EinkaufenView bereits
        // verlassen) — dann nicht mehr verbinden. Ebenso `session != nil`:
        // ein schnelles Verlassen+Wiederbetreten von `EinkaufenView` kann
        // einen zweiten, überlappenden Aufruf dieser Funktion ausgelöst
        // haben, dessen Gruppen-ID-Auflösung zuerst fertig wurde — ohne
        // diesen zweiten Check würde der spätere Aufruf `session`/
        // `advertiser`/`browser` überschreiben und die zuerst erzeugten
        // Instanzen liefen unbeaufsichtigt (und unstoppbar) weiter.
        guard aktiv, session == nil else { return }

        let schluessel = SyncOrdnerService.multipeerDiscoveryGruppenSchluessel(fuerGruppenID: gruppenID)
        gruppenSchluessel = schluessel
        let peerID = MCPeerID(displayName: Self.displayNameSicherBegrenzt(DatabaseLeaseService.geraeteName))

        let neueSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        neueSession.delegate = self
        session = neueSession

        let neuerAdvertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: [Self.discoveryInfoSchluessel: schluessel],
            serviceType: SyncOrdnerService.multipeerServiceType
        )
        neuerAdvertiser.delegate = self
        neuerAdvertiser.startAdvertisingPeer()
        advertiser = neuerAdvertiser

        let neuerBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: SyncOrdnerService.multipeerServiceType)
        neuerBrowser.delegate = self
        neuerBrowser.startBrowsingForPeers()
        browser = neuerBrowser
    }

    /// `MCPeerID.displayName` erlaubt laut `MCPeerID.h` max. 63 **Bytes** in
    /// UTF8, nicht Zeichen — ein einfaches `.prefix(63)` auf den Gerätenamen
    /// würde bei Mehrbyte-Zeichen (Umlaute, Emoji) zu lang bleiben können.
    /// Kürzt stattdessen sicher auf UTF8-Byte-Ebene, ohne mitten in einer
    /// Mehrbyte-Sequenz abzuschneiden.
    private static func displayNameSicherBegrenzt(_ name: String) -> String {
        var bytes = Array(name.utf8)
        guard bytes.count > 63 else { return name }
        bytes = Array(bytes.prefix(63))
        while let letztes = bytes.last, letztes & 0b1100_0000 == 0b1000_0000 {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func beendeAdvertisingUndBrowsing() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        gruppenSchluessel = nil
    }

    /// Best-effort, fire-and-forget — blockiert nie, kein Fehlerfall
    /// meldepflichtig. Der Datei-Kanal bleibt so oder so die verlässliche
    /// Zustellung (siehe Typ-Doku); ohne verbundene Peers ist das hier
    /// einfach ein No-op.
    func sendeAnVerbundenePeers(_ darstellung: SyncEventExportDarstellung) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        guard let daten = try? JSONEncoder().encode(darstellung) else { return }
        try? session.send(daten, toPeers: session.connectedPeers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension MultipeerSyncService: MCSessionDelegate {
    /// Delegate-Callbacks laufen laut `MCSession.h` auf einer privaten
    /// seriellen Queue („Delegate calls occur on a private serial queue") —
    /// jede Implementierung hoppt deshalb bewusst per `Task { @MainActor in }`
    /// zurück, bevor sie `context`/`session` (beide `@MainActor`-isoliert)
    /// berührt.
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                SyncDebugLogger.log(.multipeerPeerVerbunden, details: peerID.displayName)
            case .notConnected:
                SyncDebugLogger.log(.multipeerPeerGetrennt, details: peerID.displayName)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            guard let empfangen = try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: data) else { return }
            SyncImportService.wendeEinzelnesEmpfangenesEventAn(empfangen, context: context)
            SyncDebugLogger.protokolliereAlter(.multipeerEventEmpfangen, erzeugtAm: empfangen.wallClock)
        }
    }

    /// Der eigentliche Gruppen-Trust-Abgleich läuft bereits vor dem Verbindungs-
    /// aufbau (Typ-Doku „Vertrauensmodell") — hier deshalb bewusst keine
    /// Zertifikatsprüfung mehr nötig. Explizit implementiert statt sich auf
    /// undokumentiertes Default-Verhalten bei fehlender Delegate-
    /// Implementierung zu verlassen (Apples Header dokumentiert für diese
    /// `@optional`-Methode kein Verhalten ohne Implementierung).
    nonisolated func session(
        _ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }

    // Ungenutzt (kein Datei-/Stream-Versand in diesem Kanal), aber laut
    // `MCSessionDelegate` nicht `@optional` — leere Pflicht-Implementierungen.
    nonisolated func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID
    ) {}
    nonisolated func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}
    nonisolated func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
        at localURL: URL?, withError error: Error?
    ) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSyncService: MCNearbyServiceAdvertiserDelegate {
    /// Nur annehmen, wenn der von ``browser(_:foundPeer:withDiscoveryInfo:)``
    /// als Einladungs-`context` mitgesendete Gruppen-Schlüssel zum eigenen
    /// passt (Typ-Doku „Vertrauensmodell") — kein manuelles Pairing-UI, aber
    /// auch kein blindes Annehmen jeder Einladung allein auf Basis des
    /// (app-weit festen) Service-Types.
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping @Sendable (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let eigenerSchluessel = self.gruppenSchluessel,
                  let context, String(data: context, encoding: .utf8) == eigenerSchluessel
            else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, self.session)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerSyncService: MCNearbyServiceBrowserDelegate {
    /// Beide Geräte browsen UND advertisen gleichzeitig (symmetrisches
    /// Auto-Connect, wie in Apples eigenen Multipeer-Beispielen). Lädt nur
    /// ein, wenn der per `discoveryInfo` gemeldete Gruppen-Schlüssel zum
    /// eigenen passt (Typ-Doku „Vertrauensmodell") — und nicht erneut, falls
    /// der Peer bereits verbunden ist, obwohl Bonjour ihn zwischenzeitlich
    /// erneut meldet. Der eigene Schlüssel wandert als Einladungs-`context`
    /// mit, damit die Gegenseite (``advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)``)
    /// ihn ebenfalls prüfen kann.
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, let eigenerSchluessel = self.gruppenSchluessel,
                  info?[Self.discoveryInfoSchluessel] == eigenerSchluessel,
                  !session.connectedPeers.contains(peerID)
            else { return }
            browser.invitePeer(peerID, to: session, withContext: Data(eigenerSchluessel.utf8), timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
