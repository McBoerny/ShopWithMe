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
    @Published var aktiv = false {
        didSet {
            guard aktiv != oldValue else { return }
            if aktiv {
                Task { await starteAdvertisingUndBrowsing() }
            } else {
                beendeAdvertisingUndBrowsing()
            }
        }
    }

    /// Namen der aktuell per Multipeer verbundenen Peers — Grundlage für die
    /// Sync-Status-Anzeige (`SyncOrdnerSettingsView`, `DebuggingView`,
    /// `EinkaufenView`-Badge). Gepflegt in ``session(_:peer:didChange:)`` und
    /// beim Session-Abbau in ``beendeAdvertisingUndBrowsing()``.
    @Published private(set) var verbundenePeerNamen: [String] = []

    private var context: ModelContext?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Eigener, aus dem aktuellen Sync-Ordner abgeleiteter Gruppen-Schlüssel
    /// — erst nach dem asynchronen Auflösen in ``starteAdvertisingUndBrowsing()``
    /// gesetzt, für den Abgleich in beiden Delegate-Methoden zwischengespeichert.
    private var gruppenSchluessel: String?
    /// Synchron (vor dem ersten `await` in ``starteAdvertisingUndBrowsing()``)
    /// gesetzte Sperre gegen überlappende Aufrufe — siehe dort.
    private var wirdAufgebaut = false

    /// Setzt `context`/`Self.aktuell` neu — z.B. beim App-Start oder bei
    /// jeder Rückkehr zu `scenePhase == .active`. Prüft dabei zusätzlich, ob
    /// `aktiv` (von `EinkaufenView`) bereits `true` ist, aber `session` fehlt:
    /// genau dieser Zustand entsteht, wenn `scenePhase` zwischenzeitlich kurz
    /// auf `.inactive` sprang (z.B. Anrufbanner, Kontrollzentrum, ein
    /// System-Dialog — nicht nur echtes Backgrounding) und `stoppen()` dabei
    /// die Verbindung beendet hat, OHNE dass `EinkaufenView` je verlassen
    /// wurde — `aktiv` bleibt in diesem Fall unverändert `true`, `didSet`
    /// feuert also nicht erneut, und ohne diesen expliziten Neustart bliebe
    /// der Multipeer-Kanal für den Rest der Einkaufssitzung stumm tot.
    func starten(context: ModelContext) {
        self.context = context
        Self.aktuell = self
        if aktiv, session == nil {
            Task { await starteAdvertisingUndBrowsing() }
        }
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
        // `!wirdAufgebaut` synchron VOR dem ersten `await` geprüft und
        // gesetzt (kein Suspension-Point dazwischen) — ein zweiter,
        // überlappender Aufruf (schnelles Verlassen+Wiederbetreten von
        // `EinkaufenView`, oder ein erneuter `starten(context:)` nach kurzem
        // `.inactive`) bricht dadurch sofort ab, statt ebenfalls
        // `SyncOrdnerService.multipeerGruppenID(in:)` aufzurufen — sonst
        // könnten beide Aufrufe unabhängig eine je eigene, unterschiedliche
        // Gruppen-ID lesen/erzeugen und die spätere Schreibung würde die
        // frühere still überschreiben, während der GEWINNENDE In-Memory-
        // Aufruf nicht zwingend die tatsächlich persistierte ID verwendet
        // (Live-Test/Review-Fund) — ein Gerät würde dann dauerhaft mit einer
        // vom eigenen Marker-Dateiinhalt abweichenden ID advertisen.
        guard aktiv, session == nil, !wirdAufgebaut, let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
        wirdAufgebaut = true
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            wirdAufgebaut = false
        }

        // `nil` bei nicht erreichbarem Ordner (Zeitlimit oder Lese-/Schreibfehler,
        // siehe dortige Typ-Doku) — dann bewusst KEINE geratene ID verwenden,
        // sondern diesen Versuch abbrechen; der nächste `starten(context:)`
        // (App-Rückkehr in den Vordergrund, erneutes Betreten von
        // `EinkaufenView`) probiert es erneut.
        guard let gruppenID = await SyncOrdnerService.multipeerGruppenID(in: syncOrdner) else {
            SyncDebugLogger.log(.multipeerGruppenIDNichtAufloesbar, details: "")
            return
        }
        // Währenddessen evtl. wieder deaktiviert (EinkaufenView bereits
        // verlassen) — dann nicht mehr verbinden.
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
    /// Entfernt deshalb ganze `Character`s (Extended Grapheme Cluster) vom
    /// Ende, bis das UTF8-Byte-Budget eingehalten ist — ein früherer Versuch,
    /// stattdessen einzelne rohe UTF8-Bytes manuell abzuschneiden, konnte
    /// eine angeschnittene Mehrbyte-Sequenz hinterlassen (Review-Fund,
    /// belegt: bei 62 ASCII-Zeichen + einem 3-Byte-Zeichen blieb das Ergebnis
    /// weiterhin über dem Limit). `Character.utf8`-Grenzen fallen dagegen nie
    /// mitten in eine Byte-Sequenz.
    private static func displayNameSicherBegrenzt(_ name: String) -> String {
        var ergebnis = name
        while ergebnis.utf8.count > 63 {
            ergebnis.removeLast()
        }
        return ergebnis
    }

    private func beendeAdvertisingUndBrowsing() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        gruppenSchluessel = nil
        verbundenePeerNamen = []
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

    /// Gemeinsamer Gruppen-Trust-Check für beide Delegate-Seiten (Browsing
    /// über `discoveryInfo`, Advertising über den Einladungs-`context`) —
    /// eine Stelle statt zweier unabhängig gepflegter Vergleiche, die sonst
    /// bei einer künftigen Änderung des Vertrauens-Checks auseinanderlaufen
    /// könnten.
    private func passtGruppenSchluessel(_ empfangen: String?) -> Bool {
        guard let gruppenSchluessel else { return false }
        return empfangen == gruppenSchluessel
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
        Task { @MainActor [weak self] in
            switch state {
            case .connected:
                if let self, !self.verbundenePeerNamen.contains(peerID.displayName) {
                    self.verbundenePeerNamen.append(peerID.displayName)
                }
                SyncDebugLogger.log(.multipeerPeerVerbunden, details: peerID.displayName)
            case .notConnected:
                self?.verbundenePeerNamen.removeAll { $0 == peerID.displayName }
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
    /// als Einladungs-Kontext mitgesendete Gruppen-Schlüssel zum eigenen
    /// passt (Typ-Doku „Vertrauensmodell") — kein manuelles Pairing-UI, aber
    /// auch kein blindes Annehmen jeder Einladung allein auf Basis des
    /// (app-weit festen) Service-Types. Parameter bewusst `gruppenContext`
    /// benannt (nicht `context`, wie der externe Label `withContext:` nahelegen
    /// würde) — die Klasse hat bereits eine gleichnamige `context:
    /// ModelContext?`-Property, ein `context`-Parameter hier würde sie
    /// innerhalb dieser Methode ohne Warnung verdecken.
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext gruppenContext: Data?, invitationHandler: @escaping @Sendable (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session,
                  self.passtGruppenSchluessel(gruppenContext.flatMap { String(data: $0, encoding: .utf8) }),
                  !session.connectedPeers.contains(peerID)
            else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
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
                  self.passtGruppenSchluessel(info?[Self.discoveryInfoSchluessel]),
                  !session.connectedPeers.contains(peerID)
            else { return }
            browser.invitePeer(peerID, to: session, withContext: Data(eigenerSchluessel.utf8), timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
