import CryptoKit
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
/// **Vertrauensmodell (gehärtet, GitHub #97):** Der Bonjour-Service-Type
/// (``SyncOrdnerService/multipeerServiceType``) ist app-weit fest und sagt
/// nichts über Gruppenzugehörigkeit — alle ShopWithMe-Installationen
/// verwenden denselben Type (siehe dortige Typ-Doku, warum das nicht anders
/// geht: `NSBonjourServices` muss statisch zur Build-Zeit deklariert werden).
/// Die eigentliche Zugehörigkeit zur selben Einkaufsgruppe prüft ein
/// Challenge-Response-Verfahren auf Basis von ``gruppenSchluessel`` (aus dem
/// geteilten Sync-Ordner abgeleitetes HMAC-Schlüsselmaterial,
/// ``SyncOrdnerService/multipeerGruppenSchluessel(fuerGruppenID:)``), das
/// selbst nie über das Netz geht:
/// 1. Der Advertiser broadcastet pro Advertising-Session einen neuen,
///    zufälligen ``discoveryNonce`` über `discoveryInfo`
///    (``starteAdvertisingUndBrowsing()``) — ein reiner Zufallswert ohne
///    Rückschluss auf den Schlüssel.
/// 2. Ein browsender Peer bildet daraus einen an seine eigene `MCPeerID`
///    gebundenen HMAC-SHA256-Nachweis und sendet NUR diesen als
///    Einladungs-`context`
///    (``browser(_:foundPeer:withDiscoveryInfo:)``).
/// 3. Der Advertiser verifiziert den Nachweis konstant-zeitig gegen seinen
///    eigenen Nonce/Schlüssel, gebunden an die tatsächliche, vom Framework
///    gelieferte `MCPeerID` des Einladenden
///    (``istGueltigerNachweis(_:von:)``,
///    ``advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)``)
///    — nur bei Erfolg wird angenommen.
///
/// Ein passiver Mitschnitt liefert damit nie das Schlüsselmaterial selbst
/// (HMAC ist nicht umkehrbar) und ist wegen der Peer-ID-Bindung nicht gegen
/// einen anderen Peer wiederverwendbar; ein Replay bleibt nur innerhalb
/// derselben, noch laufenden Advertising-Session gegen exakt denselben
/// Advertiser theoretisch möglich (Nonce wechselt bei jedem erneuten
/// Betreten von `EinkaufenView`) — bewusst dokumentierte Restlücke, siehe
/// Issue #97. Das empfangene TLS-Zertifikat selbst wird weiterhin ungeprüft
/// akzeptiert (``session(_:didReceiveCertificate:fromPeer:certificateHandler:)``),
/// das Vertrauen kommt aus dem beschriebenen Challenge-Response, nicht aus
/// einer PKI.
@MainActor
final class MultipeerSyncService: NSObject, ObservableObject {
    /// Schwache Referenz auf die laufende Instanz, damit
    /// ``SyncEventService/aufzeichnen(_:bezugsID:artikelID:geschaeftID:context:)``
    /// (reine Model-Schicht, kennt keine View-Hierarchie) neu erzeugte Events
    /// spiegeln kann — gleiches Muster wie das bereits bestehende statische
    /// `DatabaseLeaseService.geraeteID`/`.storeURL`.
    private(set) static weak var aktuell: MultipeerSyncService?

    private static let discoveryInfoSchluessel = "gruppe"

    /// Nutzer-Einstellung (GitHub #127): erlaubt, den Multipeer-Kanal
    /// vollständig abzuschalten, z.B. bei Akku-/Privacy-Bedenken zum lokalen
    /// Bonjour-Advertising — der Datei-Kanal bleibt davon unberührt. Default
    /// `true` (unveränderter Bestandsschutz für bereits installierte Apps,
    /// bei denen der Key noch nicht existiert).
    @MainActor
    static var vonNutzerAktiviert: Bool {
        get { UserDefaults.standard.object(forKey: "multipeerVonNutzerAktiviert") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "multipeerVonNutzerAktiviert") }
    }

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

    /// Ergebnis eines Empfangsversuchs für ein Bereich-B/C/D-Catch-up-Paket
    /// (``wendeCatchUpPaketAn(_:context:)``) — unterscheidet, ob Multipeer
    /// tatsächlich gegriffen hat oder wegen eines laufenden Datei-Zyklus auf
    /// den Datei-Fallback zurückgefallen ist (Re-Entranz-Schutz).
    enum CatchUpErgebnis {
        case angewendet
        case uebersprungen
    }

    /// Letztes Ergebnis eines empfangenen Catch-up-Pakets je Peer-Gerätename
    /// (`geraeteName` aus dem Paket-Manifest, nicht `peerID.displayName`,
    /// damit es sich stabil mit den übrigen Sync-Status-Anzeigen deckt) —
    /// Grundlage für die Diagnose-Übersicht (`DebuggingView`), ob der
    /// Multipeer-Kanal für einen Peer zuletzt wirklich gegriffen hat. Rein
    /// diagnostisch, ohne jeden Einfluss auf den Merge-Ablauf selbst.
    @Published private(set) var letzterCatchUpVersuch: [String: (zeitpunkt: Date, ergebnis: CatchUpErgebnis)] = [:]

    private var context: ModelContext?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Eigenes, aus dem aktuellen Sync-Ordner abgeleitetes HMAC-Schlüsselmaterial
    /// — erst nach dem asynchronen Auflösen in ``starteAdvertisingUndBrowsing()``
    /// gesetzt, für den Challenge-Response-Abgleich in beiden Delegate-Methoden
    /// zwischengespeichert. Geht nie über das Netz (siehe Typ-Doku
    /// „Vertrauensmodell").
    private var gruppenSchluessel: SymmetricKey?
    /// Pro Advertising-Session neu erzeugter Zufalls-Nonce, über
    /// `discoveryInfo` broadcastet — Grundlage des Challenge-Response-Nachweises
    /// (Typ-Doku „Vertrauensmodell").
    private var discoveryNonce: Data?
    /// Synchron (vor dem ersten `await` in ``starteAdvertisingUndBrowsing()``)
    /// gesetzte Sperre gegen überlappende Aufrufe — siehe dort.
    private var wirdAufgebaut = false

    /// Intervall des periodischen Diff-Re-Checks für den Bereich-B/C/D-
    /// Catch-up (GitHub #125, ``catchUpSchleife``) — `static var` statt
    /// `let`, damit Tests sie verkürzen können (Muster wie
    /// ``SyncPollingService/intervallAktivesEinkaufen``).
    static var catchUpPruefIntervall: Duration = .seconds(20)

    /// Fingerabdruck (``SyncSnapshotExportService/zustandsFingerabdruck(tombstones:stamm:listen:lernen:vorgaenge:preise:kaeufe:)``)
    /// des zuletzt erfolgreich an einen Peer gesendeten Catch-up-Pakets,
    /// keyed auf `peerID.displayName` — verhindert, dass ein Peer bei jedem
    /// bloßen Reconnect (z.B. kurzer AWDL-Dropout während des gemeinsamen
    /// Einkaufens) erneut das volle Paket bekommt, obwohl sich der lokale
    /// Stand seit dem letzten erfolgreichen Versand AN GENAU DIESEN Peer
    /// nicht geändert hat. Bewusst NICHT bei `.notConnected` gelöscht (nur in
    /// ``beendeAdvertisingUndBrowsing()`` komplett zurückgesetzt) — ein
    /// kurzer Connect/Disconnect/Reconnect-Zyklus ohne zwischenzeitliche
    /// lokale Änderung soll die Ersparnis genau NICHT verlieren.
    private var letzterGesendeterFingerabdruck: [String: String] = [:]

    /// Periodischer Re-Check (``catchUpPruefIntervall``), solange
    /// ``aktiv`` — Nutzer-Entscheidung (2026-08-24): nicht bei jedem
    /// Connect-Event blind senden, sondern zusätzlich in festen Abständen
    /// prüfen, ob sich der lokale Stand geändert hat, während eine
    /// Verbindung bereits besteht (z.B. während einer längeren gemeinsamen
    /// Einkaufssitzung werden laufend neue Artikel abgehakt). Läuft neben
    /// dem `.connected`-Trigger in ``session(_:peer:didChange:)``, nicht
    /// statt ihm — der Connect-Trigger deckt den „Peer war lange offline"-
    /// Fall sofort ab, diese Schleife deckt „Peer bleibt verbunden, lokale
    /// Daten ändern sich weiter" ab.
    private var catchUpSchleife: Task<Void, Never>?

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

        let schluessel = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: gruppenID)
        gruppenSchluessel = schluessel
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        discoveryNonce = nonce
        let peerID = MCPeerID(displayName: Self.displayNameSicherBegrenzt(DatabaseLeaseService.geraeteName))

        let neueSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        neueSession.delegate = self
        session = neueSession

        let neuerAdvertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: [Self.discoveryInfoSchluessel: nonce.base64EncodedString()],
            serviceType: SyncOrdnerService.multipeerServiceType
        )
        neuerAdvertiser.delegate = self
        neuerAdvertiser.startAdvertisingPeer()
        advertiser = neuerAdvertiser

        let neuerBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: SyncOrdnerService.multipeerServiceType)
        neuerBrowser.delegate = self
        neuerBrowser.startBrowsingForPeers()
        browser = neuerBrowser

        starteCatchUpSchleifeFallsNoetig()
    }

    /// Startet den periodischen Diff-Re-Check (``catchUpSchleife``), falls
    /// noch keiner läuft — wirkungslos bei bereits laufender Schleife (kein
    /// zweiter, überlappender Loop bei mehrfachem `starten(context:)`).
    private func starteCatchUpSchleifeFallsNoetig() {
        guard catchUpSchleife == nil else { return }
        catchUpSchleife = Task(priority: .utility) { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.catchUpPruefIntervall)
                guard !Task.isCancelled, let self else { return }
                await self.pruefeUndSendeCatchUpFuerAlleVerbundenenPeers()
            }
        }
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
        discoveryNonce = nil
        verbundenePeerNamen = []
        catchUpSchleife?.cancel()
        catchUpSchleife = nil
        // Peer-Identität (`peerID.displayName`) ist nur innerhalb EINER
        // Advertising-Session verlässlich derselbe reale Peer (neuer Nonce
        // pro Session, siehe Typ-Doku „Vertrauensmodell") — der Cache aus
        // einer vorigen Session hätte hier ohnehin keine sichere Aussagekraft
        // mehr, deshalb wie `gruppenSchluessel`/`discoveryNonce` komplett
        // zurückgesetzt statt über Sessions hinweg mitgeschleppt.
        letzterGesendeterFingerabdruck = [:]
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

    /// Bereich-B/C/D-Catch-up (GitHub #125) — aufgerufen sowohl beim
    /// `.connected`-Event (``session(_:peer:didChange:)``, für genau den neu
    /// verbundenen Peer) als auch periodisch aus ``catchUpSchleife`` (für
    /// ALLE aktuell verbundenen Peers gemeinsam). Der eigene
    /// Bereich-B/C/D/Kaufhistorie-Zustand hängt nicht vom jeweiligen Peer ab
    /// — deshalb wird der teure SwiftData-Fetch hier bewusst NUR EINMAL pro
    /// Aufruf gemacht, nicht einmal je verbundenem Peer (Live-Fund: eine
    /// frühere Fassung rief die alte, jetzt entfernte
    /// `pruefeUndSendeCatchUpFallsGeaendert(an:)` in einer Schleife über
    /// `session.connectedPeers` auf und vervielfachte damit unnötig
    /// dieselbe teure Arbeit).
    ///
    /// **`ModelContext`-Zugriff bleibt zwingend auf dem `MainActor`**
    /// (SwiftData-Vorgabe), aber Encoding/Hashing/Datei-Schreiben der
    /// bereits geladenen Werte NICHT — das wäre reine CPU-/I/O-Arbeit ohne
    /// `ModelContext`-Bezug und lief vorher versehentlich synchron auf dem
    /// `MainActor` mit, blockierte dort für die Dauer der UI (Live-Fund: App
    /// wurde auf einem frisch befüllten Gerät mit größerer Kaufhistorie
    /// unresponsive/beendet, unmittelbar nach dem ersten `.connected`-Event
    /// — genau die Stelle, an der dieser Pfad zum ersten Mal lief). Jetzt
    /// per `Task.detached` ausgelagert (Muster wie `SyncDateiZugriff`/
    /// `SyncKaeufeExportService.exportiereNeueKaeufe`).
    private func pruefeUndSendeCatchUpFuerAlleVerbundenenPeers() async {
        guard let context, let session, !session.connectedPeers.isEmpty else { return }
        let teile = SyncSnapshotExportService.erstellePaketTeile(context: context)
        let kaeufe = SyncKaeufeExportService.alleSnapshots(context: context)

        let fingerabdruck = await Task.detached(priority: .utility) {
            SyncSnapshotExportService.zustandsFingerabdruck(
                tombstones: teile.tombstones, stamm: teile.stamm, listen: teile.listen,
                lernen: teile.lernen, vorgaenge: teile.vorgaenge, preise: teile.preise, kaeufe: kaeufe
            )
        }.value

        for peerID in session.connectedPeers {
            guard letzterGesendeterFingerabdruck[peerID.displayName] != fingerabdruck else { continue }
            await sendeCatchUpPaket(teile: teile, kaeufe: kaeufe, fingerabdruck: fingerabdruck, an: peerID)
        }
    }

    /// Einmal-Prüfung für GENAU EINEN Peer (Aufrufer: `.connected`-Event) —
    /// dünner Wrapper um ``pruefeUndSendeCatchUpFuerAlleVerbundenenPeers()``,
    /// vermeidet aber, für den neu verbundenen Peer auf den nächsten
    /// periodischen Tick zu warten.
    private func pruefeUndSendeCatchUpFallsGeaendert(an peerID: MCPeerID) {
        Task { await pruefeUndSendeCatchUpFuerAlleVerbundenenPeers() }
    }

    /// Baut das eigentliche Übertragungspaket, kodiert und schreibt es
    /// abseits des `MainActor` (siehe Typ-Doku
    /// ``pruefeUndSendeCatchUpFuerAlleVerbundenenPeers()``) und übergibt es
    /// erst danach an `MCSession.sendResource` (Größenbudget: Kaufhistorie
    /// kann über die Zeit mehrere Megabyte erreichen, siehe Typ-Doku
    /// ``SyncKaeufeExportService`` „56% der Größe einer realen export.json").
    /// Sendet NICHT bei jedem Aufruf blind, sondern nur, wenn
    /// `fingerabdruck` vom zuletzt erfolgreich AN DIESEN Peer gesendeten
    /// abweicht (``letzterGesendeterFingerabdruck``, Nutzer-Entscheidung
    /// 2026-08-24 — kein blindes Senden bei jedem Reconnect). Ein neu
    /// verbundener Peer hat noch keinen Eintrag im Cache, der erste Aufruf
    /// sendet also immer — deckt den Issue-Fall „Peer war lange offline"
    /// sofort ab. Selbst ein unnötiger Versand wäre unschädlich: die
    /// Ziel-Merge-Funktion (``SyncSnapshotImportService/mergePaket(tombstones:stamm:listen:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``)
    /// ist bereits ein idempotentes State-CRDT — das Diffing hier ist reine
    /// Bandbreiten-/Akku-Optimierung, keine Korrektheitsvoraussetzung.
    private func sendeCatchUpPaket(
        teile: (
            manifest: SyncPeerManifest, tombstones: [SyncTombstoneSnapshot], stamm: SyncStammSnapshot,
            listen: SyncListenSnapshot, lernen: SyncLernenSnapshot, vorgaenge: SyncVorgaengeSnapshot, preise: SyncPreisSnapshot
        ),
        kaeufe: [KaufEintragSnapshot], fingerabdruck: String, an peerID: MCPeerID
    ) async {
        guard let session else { return }
        let paket = MultipeerCatchUpPaket(
            teile: SyncPaketTeile(
                manifest: teile.manifest, tombstones: teile.tombstones, stamm: teile.stamm,
                listen: teile.listen, lernen: teile.lernen, vorgaenge: teile.vorgaenge, preise: teile.preise
            ),
            kaeufe: kaeufe
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipeer-catchup-\(UUID().uuidString).json")

        let erfolgreichGeschrieben = await Task.detached(priority: .utility) { () -> Bool in
            guard let daten = try? JSONEncoder().encode(paket) else { return false }
            do {
                try daten.write(to: tempURL)
                return true
            } catch {
                return false
            }
        }.value
        guard erfolgreichGeschrieben else { return }

        // Optimistisch VOR Abschluss des Transfers vermerkt (Muster wie
        // ``sendeAnVerbundenePeers(_:)`` — fire-and-forget, kein Warten auf
        // Bestätigung): ein tatsächlich fehlgeschlagener Transfer bleibt
        // unschädlich, da der nächste periodische Re-Check oder der
        // Datei-Kanal ohnehin nachliefert (siehe Re-Entranz-Schutz-Kommentar
        // an ``wendeCatchUpPaketAn(_:context:)``).
        letzterGesendeterFingerabdruck[peerID.displayName] = fingerabdruck
        Self.sendeCatchUpDateiUndBereinige(session, tempURL: tempURL, resourceName: tempURL.lastPathComponent, an: peerID)
    }

    /// **Zweiter Live-Fund (2026-08-24), mit Stacktrace belegt — der erste
    /// Fix-Versuch (Completion-Handler nur als lokaler `@Sendable`-Wert
    /// typisiert, statt inline geschrieben) reichte NICHT aus, derselbe
    /// Absturz trat unverändert wieder auf.** Grund: `@Sendable` und
    /// Aktor-Isolation sind orthogonale Eigenschaften — ein Closure-Literal,
    /// das innerhalb einer `@MainActor`-Methode entsteht, bleibt trotz
    /// `@Sendable`-Typannotation der ZIEL-Variable weiterhin
    /// `MainActor`-isoliert, `@Sendable` allein erzwingt keine
    /// Nicht-Isolation. `MCSession.sendResource` ruft seinen
    /// Completion-Handler aber nachweislich nie auf dem `MainActor` auf,
    /// sondern synchron auf einer eigenen internen
    /// `com.apple.MCSession.callbackQueue` — ein trotzdem
    /// `MainActor`-isolierter Handler kann dort nicht sicher „hinüberhüpfen“
    /// (der Aufruf ist synchron, kein `async`-Hop möglich), Swift erzwingt
    /// stattdessen eine Laufzeit-Isolationsprüfung, die hart abbricht
    /// (`dispatch_assert_queue`-Fail, `_swift_task_checkIsolatedSwift`).
    ///
    /// Nur eine echte `nonisolated`-Methode — nicht bloß ein
    /// `@Sendable`-typisierter Wert — erzeugt einen Closure ganz ohne
    /// Aktor-Zugehörigkeit: `nonisolated` Methoden gehören zu keinem Aktor,
    /// jeder darin geschriebene Closure erbt deshalb nichts zu vererben.
    /// Bewusst `static` (keine `self`-Erfassung nötig/möglich) und ohne
    /// jeden Zugriff auf `MainActor`-isolierte Properties dieser Klasse —
    /// alle Parameter sind reine Sendable-Werte.
    private nonisolated static func sendeCatchUpDateiUndBereinige(
        _ session: MCSession, tempURL: URL, resourceName: String, an peerID: MCPeerID
    ) {
        session.sendResource(at: tempURL, withName: resourceName, toPeer: peerID) { _ in
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Wendet ein per Multipeer empfangenes Catch-up-Paket an — geteilte
    /// Merge-Logik mit dem Datei-Kanal (``SyncSnapshotImportService/mergePaket(tombstones:stamm:listen:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``),
    /// kein neuer Konfliktalgorithmus.
    ///
    /// **Re-Entranz-Schutz zwingend nötig**, obwohl dieser Aufruf außerhalb
    /// des regulären ``SyncPollingService``-Loops läuft: `mergePaket`
    /// verändert denselben `ModelContext` wie der Datei-Import, und ein
    /// unkoordinierter gleichzeitiger Aufruf hat bereits einmal echte
    /// Datenkorruption verursacht (siehe ``SyncPollingService/syncZyklus()``
    /// Typ-Doku „Re-Entranz-Schutz"). Bei bereits laufendem Zyklus wird der
    /// Catch-up komplett übersprungen statt gewartet — kein Datenverlust, da
    /// entweder der laufende Datei-Zyklus denselben Stand ohnehin gerade
    /// importiert, oder die nächste Multipeer-Verbindung erneut den
    /// vollständigen (idempotenten) Stand liefert.
    private func wendeCatchUpPaketAn(_ paket: MultipeerCatchUpPaket, context: ModelContext) {
        guard SyncImportService.versucheVollstaendigenZyklusZuStarten() else {
            SyncDebugLogger.log(.multipeerCatchUpUebersprungen, details: paket.teile.manifest.geraeteName)
            letzterCatchUpVersuch[paket.teile.manifest.geraeteName] = (Date(), .uebersprungen)
            return
        }
        defer { SyncImportService.beendeVollstaendigenZyklus() }

        SyncSnapshotImportService.mergePaket(
            tombstones: paket.teile.tombstones, stamm: paket.teile.stamm, listen: paket.teile.listen,
            lernen: paket.teile.lernen, vorgaenge: paket.teile.vorgaenge, preise: paket.teile.preise,
            kaeufe: paket.kaeufe, geraeteName: paket.teile.manifest.geraeteName,
            peerGeraeteID: paket.teile.manifest.geraeteID, erzeugtAm: paket.teile.manifest.erzeugtAm,
            context: context
        )
        try? context.save()
        SyncDebugLogger.log(.multipeerCatchUpAngewendet, details: paket.teile.manifest.geraeteName)
        letzterCatchUpVersuch[paket.teile.manifest.geraeteName] = (Date(), .angewendet)
    }

    /// Verifiziert im Advertiser einen per Einladungs-`context` empfangenen
    /// Challenge-Response-Nachweis (GitHub #97, Typ-Doku „Vertrauensmodell")
    /// gegen den eigenen, aktuell beworbenen ``discoveryNonce`` und den
    /// eigenen ``gruppenSchluessel`` — an `peerID` gebunden, damit ein
    /// mitgeschnittener Nachweis eines anderen Peers nicht wiederverwendbar
    /// ist. `HMAC<SHA256>.isValidAuthenticationCode` vergleicht dabei
    /// konstant-zeitig, um Seitenkanal-Rückschlüsse auf den erwarteten Wert
    /// zu vermeiden.
    private func istGueltigerNachweis(_ empfangenerNachweis: Data?, von peerID: MCPeerID) -> Bool {
        guard let empfangenerNachweis, let gruppenSchluessel, let discoveryNonce else { return false }
        let nachricht = discoveryNonce + Data(peerID.displayName.utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(empfangenerNachweis, authenticating: nachricht, using: gruppenSchluessel)
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
                self?.pruefeUndSendeCatchUpFallsGeaendert(an: peerID)
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
    // Ungenutzt: nur ein Fortschritts-Hook, hier nicht gebraucht.
    nonisolated func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    /// Empfangsseite des Bereich-B/C/D-Catch-up-Kanals (GitHub #125,
    /// ``sendeCatchUpPaket(an:)``). `localURL` verweist auf eine temporäre
    /// Datei, die das Framework nach Rückkehr dieser Methode aufräumt —
    /// deshalb synchron (innerhalb des `Task`) gelesen, bevor irgendein
    /// weiterer `await`-Punkt die Datei verschwinden lassen könnte.
    nonisolated func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
        at localURL: URL?, withError error: Error?
    ) {
        guard let localURL, error == nil else { return }
        guard let daten = try? Data(contentsOf: localURL) else { return }
        guard let paket = try? JSONDecoder().decode(MultipeerCatchUpPaket.self, from: daten) else { return }
        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            self.wendeCatchUpPaketAn(paket, context: context)
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSyncService: MCNearbyServiceAdvertiserDelegate {
    /// Nur annehmen, wenn der von ``browser(_:foundPeer:withDiscoveryInfo:)``
    /// als Einladungs-Kontext mitgesendete Challenge-Response-Nachweis gegen
    /// den eigenen Nonce/Schlüssel gültig ist (``istGueltigerNachweis(_:von:)``,
    /// Typ-Doku „Vertrauensmodell") — kein manuelles Pairing-UI, aber auch
    /// kein blindes Annehmen jeder Einladung allein auf Basis des (app-weit
    /// festen) Service-Types. Parameter bewusst `gruppenNachweis` benannt
    /// (nicht `context`, wie der externe Label `withContext:` nahelegen
    /// würde) — die Klasse hat bereits eine gleichnamige `context:
    /// ModelContext?`-Property, ein `context`-Parameter hier würde sie
    /// innerhalb dieser Methode ohne Warnung verdecken.
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext gruppenNachweis: Data?, invitationHandler: @escaping @Sendable (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session,
                  self.istGueltigerNachweis(gruppenNachweis, von: peerID),
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
    /// Auto-Connect, wie in Apples eigenen Multipeer-Beispielen). Bildet aus
    /// dem per `discoveryInfo` gemeldeten Nonce des gefundenen Peers und dem
    /// eigenen Gruppenschlüssel einen an die eigene `MCPeerID` gebundenen
    /// HMAC-Nachweis (Typ-Doku „Vertrauensmodell") und lädt damit ein — der
    /// Gruppenschlüssel selbst geht dabei nie über das Netz. Nicht erneut,
    /// falls der Peer bereits verbunden ist, obwohl Bonjour ihn
    /// zwischenzeitlich erneut meldet. Die Gegenseite
    /// (``advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)``)
    /// verifiziert den Nachweis anhand ihres eigenen, aktuell beworbenen
    /// Nonces.
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, let eigenerSchluessel = self.gruppenSchluessel,
                  let nonceBase64 = info?[Self.discoveryInfoSchluessel], let nonce = Data(base64Encoded: nonceBase64),
                  !session.connectedPeers.contains(peerID)
            else { return }
            let nachricht = nonce + Data(session.myPeerID.displayName.utf8)
            let nachweis = HMAC<SHA256>.authenticationCode(for: nachricht, using: eigenerSchluessel)
            browser.invitePeer(peerID, to: session, withContext: Data(nachweis), timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
