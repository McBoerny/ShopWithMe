import Foundation

/// Transport-unabhängige Datenkapsel für einen vollständigen Paket-Export.
/// Gespiegelt in `SyncSnapshotExportService.erstellePaketTeile(context:)`.
/// `Codable`, damit ``MultipeerCatchUpPaket`` (GitHub #125,
/// `Models/SyncSnapshot.swift`) es direkt als Feld einbetten und per
/// `MCSession.sendResource` als JSON übertragen kann — alle Feldtypen sind
/// bereits `Codable`, hier nur die Synthese aktiviert.
struct SyncPaketTeile: Codable {
    var manifest: SyncPeerManifest
    var tombstones: [SyncTombstoneSnapshot]
    var stamm: SyncStammSnapshot
    var listen: SyncListenSnapshot
    var lernen: SyncLernenSnapshot
    var vorgaenge: SyncVorgaengeSnapshot
    var preise: SyncPreisSnapshot
}

/// Transportschicht-Abstraktion (Layer 3, docs/SYNC_CONNECTOR_ARCHITEKTUR.md §4).
///
/// `@MainActor`-isoliert: alle Aufrufer (`SyncPollingService` u.a.) laufen bereits
/// auf dem Main Actor. Konkrete Implementierungen können I/O-intensive Arbeit intern
/// per `Task.detached` oder `SyncDateiZugriff.mitZeitlimit` auslagern.
///
/// Kein `AnyObject`-Constraint — `any SyncConnector` ist direkt als
/// Typ für gespeicherte Properties nutzbar (kein Box-Trick nötig).
///
/// **Peer-Bezeichner** in allen Methoden sind Peer-Ordnernamen
/// (`peers/{name}/`) im geteilten Sync-Verzeichnis. Die geräte-interne
/// Identität (`peerGeraeteID`) steht erst nach dem Lesen des jeweiligen
/// `manifest.json` zur Verfügung (siehe `manifest(von:)`).
@MainActor
protocol SyncConnector {

    // MARK: - Lebenszyklus

    /// Öffnet den Transportzugang für einen Sync-Zyklus.
    /// Muss genau einmal pro Zyklus aufgerufen werden; `beendeZugriff()` ist
    /// das Gegenstück. Kapselung des Security-Scope-Lebenszyklus
    /// (Risiko 1, docs/SYNC_CONNECTOR_ARCHITEKTUR.md §11): keine Methode
    /// unterhalb öffnet einen eigenen Scope, solange `beginneZugriff` aktiv ist.
    /// Liefert `false`, wenn kein Sync-Ziel konfiguriert oder der Zugang
    /// nicht geöffnet werden kann.
    func beginneZugriff() async -> Bool

    /// Schließt den Transportzugang nach einem Sync-Zyklus.
    func beendeZugriff()

    // MARK: - Peer-Verwaltung

    /// Alle Peer-Ordnernamen außer dem eigenen Gerät.
    func bekanntePeers() async -> [String]

    /// Ob dieses Gerät noch Mitglied des Sync-Verbunds ist.
    /// Darf auch außerhalb eines laufenden Zyklus aufgerufen werden.
    func binIchNochMitglied() async -> Bool?

    /// Entfernt den Peer-Ordner aus dem geteilten Verzeichnis (Transport-Schicht).
    /// SwiftData-Bereinigung (`SyncPeerInfo` löschen) obliegt dem Aufrufer.
    func entfernePeer(_ peerOrdnerName: String) async

    // MARK: - Bereich A: Event-Sync

    func veroeffentlicheNeueEvents(_ events: [SyncEventExportDarstellung]) async -> Bool
    func empfangeNeueEvents(von peer: String, bekannteIDs: Set<UUID>) async -> [SyncEventExportDarstellung]

    // MARK: - Bereich B/C/D: Snapshot-Sync

    /// Liest nur das Manifest eines Peers (ohne vollständigen Paketinhalt).
    func manifest(von peer: String) async -> SyncPeerManifest?

    /// Liest alle Snapshot-Teile eines Peers als `SyncPaketTeile`.
    func empfangePaket(von peer: String) async -> SyncPaketTeile?

    /// Schreibt den eigenen Paket-Export.
    /// Manifest wird nur bei `importErfolgreich == true` geschrieben
    /// (Peer-Lebenszyklus Baustein C0: `erzeugtAm` zertifiziert, dass dieses
    /// Gerät einen vollständigen Import-Zyklus abgeschlossen hat).
    func veroeffentlichePaket(_ teile: SyncPaketTeile, importErfolgreich: Bool) async -> Bool

    // MARK: - Bereich C: Kauf-Append-Log

    func veroeffentlicheNeueKaufEintraege(_ eintraege: [KaufEintragSnapshot]) async -> Bool
    func empfangeNeueKaufEintraege(von peer: String) async -> [KaufEintragSnapshot]

    // MARK: - Peer-Metadaten

    /// Stabile Gruppen-ID für den Multipeer-Beschleunigungskanal.
    func multipeerGruppenID() async -> UUID?
}

extension SyncConnector {
    func beginneZugriff() async -> Bool { true }
    func beendeZugriff() {}
}
