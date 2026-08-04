import Foundation

/// Lokales, nicht mit Peers geteiltes Backup-Format für ``SyncErsetzenService``
/// (GitHub #63) — wrapt einen ``SyncSnapshot`` (das Peer-Wire-Format)
/// zusätzlich um gerätelokale Daten, die nicht Teil von ``SyncSnapshot`` sind
/// (z.B. ``IgnorierterGeschaeftsVorschlag``), damit ein Restore aus dem
/// eigenen Backup wirklich vollständig ist statt diese stillschweigend zu
/// verlieren. Das Peer-Wire-Format (``SyncSnapshot/formatVersion``) bleibt
/// dadurch unangetastet.
struct SyncErsetzenBackup: Codable {
    static let aktuelleFormatVersion = 2

    var formatVersion: Int
    var erstelltAm: Date
    var snapshot: SyncSnapshot
    var ignorierteGeschaeftsVorschlaege: [IgnorierterGeschaeftsVorschlagSnapshot]
    /// Lokal bekannte ``SyncEvent``s zum Zeitpunkt des Backups (GitHub #80) —
    /// ohne das würde ein Wipe-und-Neuaufbau (``SyncErsetzenService``) die
    /// Erinnerung daran verlieren, welche Bereich-A-Events dieses Gerät
    /// bereits gesehen hat, und der nächste Sync-Zyklus würde jede noch
    /// nicht abgelaufene Peer-Event-Datei erneut lesen. `nil` bei einem vor
    /// diesem Feld erstellten Backup (Formatversion 1) — wird beim Restore
    /// wie eine leere Liste behandelt statt den Restore abzubrechen (siehe
    /// ``SyncErsetzenService/stelleSyncEventsWiederHer(_:context:)``).
    var bekannteSyncEvents: [SyncEventBackupEintrag]?
}

struct IgnorierterGeschaeftsVorschlagSnapshot: Codable {
    var name: String
    var breitengrad: Double?
    var laengengrad: Double?
    var ignoriertAm: Date
}

/// Ein einzelnes gesichertes ``SyncEvent`` (GitHub #80) — wrapt die bereits
/// bestehende Peer-Wire-Darstellung (``SyncEventExportDarstellung``)
/// zusätzlich um `hochgeladen`, das dort bewusst fehlt (bei einem von einem
/// Peer empfangenen Event ist es implizit immer `true`), für ein lokales
/// Backup des EIGENEN Bestands aber erhalten bleiben muss — sonst würde ein
/// noch nicht exportiertes eigenes Event beim Restore fälschlich als
/// „bereits geteilt" markiert und nie an Peers hochgeladen (siehe
/// ``SyncErsetzenService/stelleSyncEventsWiederHer(_:context:)``).
struct SyncEventBackupEintrag: Codable {
    var event: SyncEventExportDarstellung
    var hochgeladen: Bool
}
